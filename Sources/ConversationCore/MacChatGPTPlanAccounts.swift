#if os(macOS)
import Foundation
import Security

/// Lifecycle for an approved distribution. UI composition is disabled until eligibility is established.
actor MacChatGPTPlanAccounts {
    private struct TokenReply: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let token_type: String
        let expires_in: Double
        let scope: String
    }

    private struct Discovery: Decodable { let revocation_endpoint: URL }
    private struct OAuthError: Decodable { let error: String }

    private let eligible: Bool
    private var changes: [String: UUID] = [:]

    init(eligible: Bool = false) { self.eligible = eligible }

    func exchange(_ callback: URL, attempt: ChatGPTAuthorizationAttempt,
                  expectedSubject: String? = nil) async throws -> ChatGPTPlanIdentity {
        try requireEligibility()
        let grant = try attempt.validateCallback(callback)
        let previousSubject = try MacPlanKeychain.load(grant.clientID)?.identity.subject
        let revision = UUID()
        changes[grant.clientID] = revision
        defer { if changes[grant.clientID] == revision { changes[grant.clientID] = nil } }
        let reply = try await readTokens(attempt.exchange(grant))
        guard let token = reply.id_token else { throw PlanAuthorizationFailure.invalidIdentity }
        let keys = try await MacChatGPTPlanSecurity.Keys.download()
        let identity = try ChatGPTIDToken.verify(token, clientID: grant.clientID, nonce: attempt.nonce,
                                                expectedSubject: expectedSubject ?? previousSubject, now: .now,
                                                verifySignature: keys.verify)
        guard changes[grant.clientID] == revision else { throw CancellationError() }
        let credentials = try validated(reply, identity: identity, idToken: token)
        try MacPlanKeychain.save(credentials)
        return identity
    }

    func credentials(for identity: ChatGPTPlanIdentity) async throws -> ChatGPTPlanCredentials {
        try requireEligibility()
        guard let credentials = try MacPlanKeychain.load(identity.clientID),
              credentials.identity.subject == identity.subject else { throw PlanAuthorizationFailure.authorizationMissing }
        if credentials.expiry.timeIntervalSinceNow > 60 {
            _ = try credentials.authorizedAccess()
            return credentials
        }
        if changes[identity.clientID] != nil { throw ProviderFailure.unavailable }
        let revision = UUID()
        changes[identity.clientID] = revision
        defer { if changes[identity.clientID] == revision { changes[identity.clientID] = nil } }
        do {
            let reply = try await readTokens(credentials.refreshRequest())
            let currentIdentity: ChatGPTPlanIdentity
            if let token = reply.id_token {
                let keys = try await MacChatGPTPlanSecurity.Keys.download()
                currentIdentity = try ChatGPTIDToken.verify(token, clientID: identity.clientID, nonce: nil,
                    expectedSubject: identity.subject, now: .now, verifySignature: keys.verify)
            } else {
                currentIdentity = credentials.identity
            }
            let updated = try validated(reply, identity: currentIdentity, idToken: reply.id_token ?? credentials.idToken)
            guard updated.refreshToken != nil, changes[identity.clientID] == revision else {
                throw PlanAuthorizationFailure.authorizationMissing
            }
            try MacPlanKeychain.save(updated)
            return updated
        } catch PlanAuthorizationFailure.authorizationMissing {
            if changes[identity.clientID] == revision { try MacPlanKeychain.remove(identity.clientID) }
            throw PlanAuthorizationFailure.authorizationMissing
        }
    }

    func signOut(_ identity: ChatGPTPlanIdentity) async throws {
        try requireEligibility()
        defer { changes[identity.clientID] = nil }
        changes[identity.clientID] = UUID()
        let stored = try MacPlanKeychain.load(identity.clientID)
        guard stored == nil || stored?.identity.subject == identity.subject else {
            throw PlanAuthorizationFailure.accountMismatch
        }
        try MacPlanKeychain.remove(identity.clientID)
        guard let token = stored?.refreshToken,
              let discoveryURL = URL(string: ChatGPTAuthorizationAttempt.issuer + "/.well-known/openid-configuration") else { return }
        let (bytes, response) = try await Self.http.data(for: URLRequest(url: discoveryURL, timeoutInterval: 10))
        try OpenAIResponsesClient.validate(response)
        let endpoint = try JSONDecoder().decode(Discovery.self, from: bytes).revocation_endpoint
        guard endpoint.scheme == "https", endpoint.host == "auth.openai.com", endpoint.user == nil,
              endpoint.password == nil, endpoint.fragment == nil else { throw PlanAuthorizationFailure.invalidIdentity }
        let request = ChatGPTAuthorizationAttempt.form(
            ["token": token, "token_type_hint": "refresh_token", "client_id": identity.clientID], url: endpoint)
        let (_, result) = try await Self.http.data(for: request)
        try OpenAIResponsesClient.validate(result)
    }

    private func requireEligibility() throws {
        if !eligible { throw PlanAuthorizationFailure.authorizationMissing }
    }

    private func readTokens(_ request: URLRequest) async throws -> TokenReply {
        let (bytes, response) = try await Self.http.data(for: request)
        if let error = try? JSONDecoder().decode(OAuthError.self, from: bytes), error.error == "invalid_grant" {
            throw PlanAuthorizationFailure.authorizationMissing
        }
        try OpenAIResponsesClient.validate(response)
        return try JSONDecoder().decode(TokenReply.self, from: bytes)
    }

    private func validated(_ reply: TokenReply, identity: ChatGPTPlanIdentity,
                           idToken: String) throws -> ChatGPTPlanCredentials {
        guard reply.token_type.lowercased() == "bearer", reply.expires_in.isFinite,
              reply.expires_in > 0, reply.expires_in <= 86_400 else { throw PlanAuthorizationFailure.invalidIdentity }
        let scopes = Set(reply.scope.split(separator: " ").map(String.init))
        let credentials = ChatGPTPlanCredentials(identity: identity, accessToken: reply.access_token,
            refreshToken: reply.refresh_token, idToken: idToken,
            expiry: .now.addingTimeInterval(reply.expires_in), scopes: scopes)
        _ = try credentials.authorizedAccess()
        return credentials
    }

    private static let http = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum MacPlanKeychain {
    private static let service = "com.mockinterview.desktop.chatgpt-plan"

    static func load(_ clientID: String) throws -> ChatGPTPlanCredentials? {
        var query = base(clientID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else {
            throw PlanAuthorizationFailure.authorizationMissing
        }
        return try JSONDecoder().decode(ChatGPTPlanCredentials.self, from: bytes)
    }

    static func save(_ value: ChatGPTPlanCredentials) throws {
        let query = base(value.identity.clientID)
        let bytes = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: bytes]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, latest in latest } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PlanAuthorizationFailure.authorizationMissing }
    }

    static func remove(_ clientID: String) throws {
        let status = SecItemDelete(base(clientID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PlanAuthorizationFailure.authorizationMissing
        }
    }

    private static func base(_ clientID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: clientID]
    }
}
#endif
