import CZlib
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum DOCXDocument {
    private static let file = Data("word/document.xml".utf8)
    private static let maximumTextBytes = 2_000_000

    static func text(from archive: Data) throws -> String {
        guard archive.count <= 20_000_000 else { throw StorageFailure.documentTooLarge }
        let end = try endOfDirectory(in: archive)
        let entryCount = Int(try archive.word(at: end + 10))
        let centralSize = Int(try archive.dword(at: end + 12))
        var position = Int(try archive.dword(at: end + 16))
        guard try archive.word(at: end + 4) == 0, try archive.word(at: end + 6) == 0,
              try archive.word(at: end + 8) == entryCount,
              position <= end, centralSize <= end - position, entryCount <= 8_192 else {
            throw StorageFailure.unsupportedFormat
        }
        let centralEnd = position + centralSize
        for _ in 0..<entryCount {
            guard centralEnd - position >= 46, try archive.dword(at: position) == 0x02014b50 else {
                throw StorageFailure.unsupportedFormat
            }
            let nameLength = Int(try archive.word(at: position + 28))
            let extraLength = Int(try archive.word(at: position + 30))
            let commentLength = Int(try archive.word(at: position + 32))
            let nameStart = position + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= centralEnd else { throw StorageFailure.unsupportedFormat }
            if archive.subdata(in: nameStart..<(nameStart + nameLength)) == file {
                let xml = try extract(archive, entry: position, before: centralEnd - centralSize)
                return try parse(xml)
            }
            position = next
        }
        throw StorageFailure.unsupportedFormat
    }

    private static func endOfDirectory(in archive: Data) throws -> Int {
        guard archive.count >= 22 else { throw StorageFailure.unsupportedFormat }
        let lowerBound = max(0, archive.count - 22 - 65_535)
        for index in stride(from: archive.count - 22, through: lowerBound, by: -1) {
            if try archive.dword(at: index) == 0x06054b50,
               try Int(archive.word(at: index + 20)) == archive.count - index - 22 {
                return index
            }
        }
        throw StorageFailure.unsupportedFormat
    }

    private static func extract(_ archive: Data, entry: Int, before centralStart: Int) throws -> Data {
        let flags = try archive.word(at: entry + 8)
        let method = try archive.word(at: entry + 10)
        let checksum = try archive.dword(at: entry + 16)
        let compressedSize = Int(try archive.dword(at: entry + 20))
        let uncompressedSize = Int(try archive.dword(at: entry + 24))
        let offset = Int(try archive.dword(at: entry + 42))
        guard uncompressedSize <= maximumTextBytes else { throw StorageFailure.documentTooLarge }
        guard flags & 1 == 0, uncompressedSize > 0, centralStart - offset >= 30,
              try archive.dword(at: offset) == 0x04034b50,
              try archive.word(at: offset + 8) == method else {
            throw StorageFailure.unsupportedFormat
        }
        let nameLength = Int(try archive.word(at: offset + 26))
        let extraLength = Int(try archive.word(at: offset + 28))
        let start = offset + 30 + nameLength + extraLength
        guard start <= centralStart, compressedSize <= centralStart - start,
              archive.subdata(in: (offset + 30)..<(offset + 30 + nameLength)) == file else {
            throw StorageFailure.unsupportedFormat
        }
        let compressed = archive.subdata(in: start..<(start + compressedSize))
        let output: Data
        switch method {
        case 0 where compressedSize == uncompressedSize: output = compressed
        case 8: output = try inflateRaw(compressed, length: uncompressedSize)
        default: throw StorageFailure.unsupportedFormat
        }
        let actual = output.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count))
        }
        guard actual == checksum else { throw StorageFailure.unsupportedFormat }
        return output
    }

    private static func inflateRaw(_ compressed: Data, length: Int) throws -> Data {
        var input = compressed
        var output = Data(count: length)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw StorageFailure.unsupportedFormat
        }
        defer { inflateEnd(&stream) }
        let result = input.withUnsafeMutableBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = source.bindMemory(to: UInt8.self).baseAddress
                stream.avail_in = UInt32(source.count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = UInt32(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out == length, stream.avail_in == 0 else {
            throw StorageFailure.unsupportedFormat
        }
        return output
    }

    private static func parse(_ xml: Data) throws -> String {
        let parser = XMLParser(data: xml)
        let content = WordText()
        parser.delegate = content
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw StorageFailure.unsupportedFormat }
        let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StorageFailure.emptyDocument }
        return text
    }
}

private final class WordText: NSObject, XMLParserDelegate {
    private static let namespaces: Set<String> = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main"
    ]
    private var inText = false
    private(set) var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard let namespaceURI, Self.namespaces.contains(namespaceURI) else { return }
        switch elementName {
        case "t": inText = true
        case "tab": text.append("\t")
        case "br", "cr": text.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text.append(string) }
        if text.utf8.count > 2_000_000 { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let namespaceURI, Self.namespaces.contains(namespaceURI) else { return }
        switch elementName {
        case "t": inText = false
        case "p": text.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?) {
        parser.abortParsing()
    }
}

private extension Data {
    func word(at offset: Int) throws -> UInt16 { try littleEndian(at: offset) }
    func dword(at offset: Int) throws -> UInt32 { try littleEndian(at: offset) }

    func littleEndian<T: FixedWidthInteger>(at offset: Int) throws -> T {
        guard offset >= 0, offset <= count - MemoryLayout<T>.size else { throw StorageFailure.unsupportedFormat }
        return withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
