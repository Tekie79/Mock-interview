import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol TextEmbeddingProvider: Sendable {
    var indexIdentity: String { get }
    func embed(_ text: [String]) async throws -> [[Double]]
}

public struct OpenAIEmbeddings: TextEmbeddingProvider {
    private let apiKey: String
    private let model: String

    public init(apiKey: String, model: String = "text-embedding-3-small") {
        self.apiKey = apiKey
        self.model = model
    }

    public var indexIdentity: String { "openai:" + model + ":v1" }

    public func embed(_ text: [String]) async throws -> [[Double]] {
        guard !apiKey.isEmpty else { throw ProviderFailure.missingCredentials }
        guard !model.isEmpty, !text.isEmpty, text.count <= 32,
              let url = URL(string: "https://api.openai.com/v1/embeddings") else {
            throw ProviderFailure.requestRejected
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model, "encoding_format": "float",
            "input": text.map { String($0.prefix(4_000)) }
        ]
        if model.hasPrefix("text-embedding-3-") { body["dimensions"] = 256 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await OpenAIResponsesClient.protected {
            let (data, response) = try await URLSession.shared.data(for: request)
            try OpenAIResponsesClient.validate(response)
            guard let result = try? JSONDecoder().decode(Response.self, from: data),
                  result.data.count == text.count else { throw ProviderFailure.malformedEvent }
            let ordered = result.data.sorted { $0.index < $1.index }
            guard ordered.enumerated().allSatisfy({ $0.offset == $0.element.index }) else {
                throw ProviderFailure.malformedEvent
            }
            return ordered.map(\.embedding)
        }
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let index: Int
            let embedding: [Double]
        }
        let data: [Item]
    }
}

public extension KnowledgeStore {
    /// An explicit reindex sends only confirmed facts. Edits during the request invalidate those rows.
    func indexConfirmedFacts(profile: UUID, provider: any TextEmbeddingProvider) async throws -> Int {
        let confirmed = Array(try facts(profile: profile).filter { $0.status == .confirmed }.prefix(256))
        var indexed: [UUID: [Double]] = [:]
        for offset in stride(from: 0, to: confirmed.count, by: 32) {
            try Task.checkCancellation()
            let batch = confirmed[offset..<min(offset + 32, confirmed.count)]
            let vectors = try await provider.embed(batch.map(\.promptText))
            guard vectors.count == batch.count else { throw ProviderFailure.malformedEvent }
            for (fact, vector) in zip(batch, vectors) {
                guard let normal = Self.normalized(vector) else { throw ProviderFailure.malformedEvent }
                indexed[fact.id] = normal
            }
        }
        try Task.checkCancellation()
        let latest = Dictionary(uniqueKeysWithValues: try facts(profile: profile).map { ($0.id, $0) })
        return try database.transaction {
            try database.write("DELETE FROM fact_vectors WHERE fact IN (SELECT id FROM facts WHERE profile=?)",
                               [profile.uuidString])
            var written = 0
            for fact in confirmed where latest[fact.id] == fact {
                guard let vector = indexed[fact.id] else { continue }
                try database.write("INSERT INTO fact_vectors VALUES (?, ?, ?)",
                                   [fact.id.uuidString, provider.indexIdentity, try SQLiteDatabase.json(vector)])
                written += 1
            }
            return written
        }
    }

    func clearFactIndex(profile: UUID) throws {
        try database.write("DELETE FROM fact_vectors WHERE fact IN (SELECT id FROM facts WHERE profile=?)",
                           [profile.uuidString])
    }

    func hybridRetrieve(_ question: String, profile: UUID,
                        provider: any TextEmbeddingProvider) async throws -> [ExperienceFact] {
        let args = [profile.uuidString, provider.indexIdentity]
        let exists = try database.query("""
            SELECT 1 FROM fact_vectors JOIN facts ON facts.id=fact_vectors.fact
            WHERE facts.profile=? AND fact_vectors.model=? LIMIT 1
            """, args) { _ in true }.first ?? false
        guard exists else { return try retrieve(question, profile: profile) }

        let result = try await provider.embed([question])
        guard result.count == 1, let raw = result.first, let query = Self.normalized(raw) else {
            throw ProviderFailure.malformedEvent
        }
        try Task.checkCancellation()
        let keyword = try retrieve(question, profile: profile)
        let candidates = try database.query("""
            SELECT facts.data, fact_vectors.data FROM fact_vectors JOIN facts ON facts.id=fact_vectors.fact
            WHERE facts.profile=? AND fact_vectors.model=? LIMIT 256
            """, args) { row in
            let fact = try SQLiteDatabase.decode(ExperienceFact.self, from: row)
            let vector = try SQLiteDatabase.decode([Double].self, from: row, column: 1)
            return (fact, vector)
        }
        let semantic = candidates.compactMap { fact, vector -> (ExperienceFact, Double)? in
            guard fact.status == .confirmed, vector.count == query.count else { return nil }
            let similarity = zip(query, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
            guard similarity.isFinite, similarity >= 0.35 else { return nil }
            return (fact, similarity)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id.uuidString < rhs.0.id.uuidString : lhs.1 > rhs.1
        }.prefix(8)
        var rank: [UUID: (ExperienceFact, Double)] = [:]
        for (index, fact) in keyword.enumerated() {
            rank[fact.id] = (fact, 1 / Double(8 + index))
        }
        for (index, item) in semantic.enumerated() {
            rank[item.0.id] = (item.0, (rank[item.0.id]?.1 ?? 0) + 0.8 / Double(8 + index))
        }
        return rank.values.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id.uuidString < rhs.0.id.uuidString : lhs.1 > rhs.1
        }.prefix(8).map(\.0)
    }

    private static func normalized(_ vector: [Double]) -> [Double]? {
        guard (1...4_096).contains(vector.count), vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }
}
