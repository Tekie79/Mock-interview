#if os(macOS)
import CryptoKit
import Foundation
import Security

enum MacChatGPTPlanSecurity {
    static func secrets() throws -> (state: String, nonce: String, verifier: String, challenge: String) {
        func randomValue() throws -> String {
            var bytes = Data(count: 32)
            let result = bytes.withUnsafeMutableBytes { memory -> OSStatus in
                guard let base = memory.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, memory.count, base)
            }
            guard result == errSecSuccess else { throw PlanAuthorizationFailure.invalidIdentity }
            return ChatGPTIDToken.encode(bytes)
        }
        let verifier = try randomValue()
        return (try randomValue(), try randomValue(), verifier,
                ChatGPTIDToken.encode(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    struct Keys: Decodable {
        struct Key: Decodable {
            let kid: String
            let kty: String
            let n: String?
            let e: String?
            let alg: String?
            let use: String?
        }
        let keys: [Key]

        static func download() async throws -> Self {
            guard let url = URL(string: ChatGPTAuthorizationAttempt.issuer + "/.well-known/jwks.json") else {
                throw PlanAuthorizationFailure.invalidIdentity
            }
            let (bytes, response) = try await OpenAIResponsesClient.protected {
                try await MacChatGPTPlanHTTP.data(URLRequest(url: url, timeoutInterval: 10))
            }
            try OpenAIResponsesClient.validate(response)
            return try JSONDecoder().decode(Self.self, from: bytes)
        }

        func verify(_ kid: String, _ payload: Data, _ signature: Data) -> Bool {
            let matches = keys.filter { $0.kid == kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256")
                && ($0.use == nil || $0.use == "sig") }
            guard matches.count == 1, let key = matches.first,
                  let n = key.n.flatMap(ChatGPTIDToken.base64URL), (256...1024).contains(n.count),
                  let e = key.e.flatMap(ChatGPTIDToken.base64URL), (1...8).contains(e.count) else { return false }
            let rsaKey = der(0x30, integer(n) + integer(e))
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                        kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
            guard let publicKey = SecKeyCreateWithData(rsaKey as CFData, attrs as CFDictionary, nil) else { return false }
            return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                         payload as CFData, signature as CFData, nil)
        }

        private func integer(_ value: Data) -> Data {
            let unsigned = Data(value.drop(while: { $0 == 0 }))
            if let mostSignificant = unsigned.first, mostSignificant >= 128 { return der(2, Data([0]) + unsigned) }
            return der(2, unsigned.isEmpty ? Data([0]) : unsigned)
        }

        private func der(_ tag: UInt8, _ content: Data) -> Data {
            if content.count < 128 { return Data([tag, UInt8(content.count)]) + content }
            if content.count < 256 { return Data([tag, 0x81, UInt8(content.count)]) + content }
            return Data([tag, 0x82, UInt8(content.count >> 8), UInt8(content.count & 0xff)]) + content
        }
    }
}
#endif
