import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ChatGPTPlanModel: Decodable, Identifiable, Sendable {
    public let slug: String
    public let displayName: String
    let visibility: String
    public var id: String { slug }

    private enum CodingKeys: String, CodingKey { case slug, visibility, displayName = "display_name" }
}

public actor ChatGPTPlanAccounts {
    public struct Account: Identifiable, Sendable {
        public let id: UUID
        public let label: String
        public let signedIn: Bool
        public let planEnabled: Bool
    }

    public struct Snapshot: Sendable {
        public let active: UUID?
        public let accounts: [Account]
        public let models: [ChatGPTPlanModel]
    }

    struct Registration: Codable, Sendable {
        let id: UUID
        var identity: ChatGPTPlanIdentity
        var credentials: ChatGPTPlanCredentials?
    }

    struct Vault: Codable, Sendable {
        var host = UUID()
        var accounts: [Registration] = []
        var active: UUID?
    }

    struct Store: Sendable {
        let load: @Sendable () throws -> Vault?
        let save: @Sendable (Vault) throws -> Void
    }

    struct Listener: Sendable {
        let redirect: URL
        let callbacks: AsyncThrowingStream<URL, Error>
        let close: @Sendable () -> Void
    }

    struct Browser: Sendable {
        let listen: @Sendable () async throws -> Listener
        let open: @MainActor @Sendable (URL) -> Bool
        let secrets: @Sendable () throws -> (state: String, nonce: String, verifier: String, challenge: String)
        var timeout: Duration = .seconds(300)
    }

    struct Transport: Sendable {
        let data: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        let stream: @Sendable (URLRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error>
        let signature: @Sendable (String, Data, Data) async throws -> Bool
    }

    private struct TokenReply: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let token_type: String
        let expires_in: Double
        let scope: String
    }

    private struct OAuthError: Decodable { let error: String }
    private struct Discovery: Decodable { let issuer: String; let revocation_endpoint: URL }

    private let browser: Browser
    private let transport: Transport
    private let store: Store
    private let now: @Sendable () -> Date
    private var vault: Vault?
    private var managing = false
    private var blockedAccount: UUID?
    private var pendingClientID: String?
    private var revision = UUID()
    private var catalog: [ChatGPTPlanModel] = []
    private var verified: [String: Set<ChatGPTSubscriptionProvider.ModelCapability>] = [:]
    private var refreshes: [UUID: Task<ChatGPTPlanCredentials, Error>] = [:]
    private var streams: [UUID: Task<Void, Never>] = [:]

    init(browser: Browser, transport: Transport, store: Store, now: @escaping @Sendable () -> Date = { .now }) {
        self.browser = browser
        self.transport = transport
        self.store = store
        self.now = now
    }

    public func snapshot() throws -> Snapshot {
        let vault = try load()
        return Snapshot(active: vault.active, accounts: vault.accounts.enumerated().map { index, record in
            let email = record.identity.email ?? "ChatGPT account"
            return Account(id: record.id, label: "\(email) (\(index + 1))", signedIn: record.credentials != nil,
                planEnabled: record.credentials.map { ChatGPTAuthorizationAttempt.accessScopes.isSubset(of: $0.scopes) } ?? false)
        }, models: catalog)
    }

    public func signIn(account id: UUID? = nil, requestConsent: Bool = false) async throws {
        guard !managing else { throw PlanAuthorizationFailure.busy }
        managing = true
        defer { managing = false; blockedAccount = nil }
        let vault = try load()
        let returning = vault.accounts.first { $0.id == id }
        guard id == nil || returning != nil, !requestConsent || returning != nil else {
            throw PlanAuthorizationFailure.accountMismatch
        }
        let existingClient = returning?.identity.clientID ?? pendingClientID
        if id == nil { pendingClientID = nil }
        let (attempt, grant) = try await receiveGrant(host: vault.host, registration: returning,
                                                     clientID: existingClient, requestConsent: requestConsent)
        // A new registration may resolve to an already saved client. Never race its rotating token.
        let previous = try load().accounts.first { $0.identity.clientID == grant.clientID }
        if let previous {
            blockedAccount = previous.id
            _ = try? await refreshes[previous.id]?.value
        }
        try Task.checkCancellation()
        let reply: TokenReply
        do { reply = try await readTokens(attempt.exchange(grant)) }
        catch PlanAuthorizationFailure.invalidGrant {
            if id == nil { pendingClientID = grant.clientID }
            throw PlanAuthorizationFailure.invalidGrant
        }
        guard let token = reply.id_token else { throw PlanAuthorizationFailure.invalidIdentity }
        let identity = try await verify(token, clientID: grant.clientID, nonce: attempt.nonce,
                                        expectedSubject: (returning ?? previous)?.identity.subject)
        let credentials = try credentials(reply, identity: identity, idToken: token)
        try Task.checkCancellation()
        var current = try load()
        let record = Registration(id: previous?.id ?? UUID(), identity: identity, credentials: credentials)
        if let index = current.accounts.firstIndex(where: { $0.id == record.id }) { current.accounts[index] = record }
        else { current.accounts.append(record) }
        current.active = record.id
        try save(current)
        invalidateProviders()
    }

    public func signOut(account id: UUID) async throws {
        guard !managing else { throw PlanAuthorizationFailure.busy }
        guard let record = try load().accounts.first(where: { $0.id == id }) else {
            throw PlanAuthorizationFailure.accountMismatch
        }
        managing = true
        blockedAccount = id
        defer { managing = false; blockedAccount = nil }
        if try load().active == id { invalidateProviders() }
        // Finish any rotation before revoking, so the latest renewable token is used.
        _ = try? await refreshes[id]?.value
        let tokens = try load().accounts.first(where: { $0.id == id })?.credentials
        var confirmed = true
        if let token = tokens?.refreshToken {
            do { try await revoke(token, clientID: record.identity.clientID) }
            catch { confirmed = false }
        }
        try clearTokens(id)
        if !confirmed { throw PlanAuthorizationFailure.remoteRevocationUnconfirmed }
    }

    public func refreshCatalog() async throws {
        let lease = try activeLease()
        let models = try await provider(lease: lease, model: "", verified: []).availableModels()
        try requireCurrent(lease)
        catalog = models
        verified = verified.filter { model, _ in models.contains { $0.slug == model } }
    }

    public func checkModel(_ model: String, service: ProviderService, guidance: String = "") async throws {
        let lease = try activeLease()
        guard catalog.contains(where: { $0.slug == model }) else { throw PlanAuthorizationFailure.unverifiedModel }
        let question = "What is a FIFO queue?"
        let capability: ChatGPTSubscriptionProvider.ModelCapability
        switch service {
        case .classification: capability = .streamedStructuredOutput
        case .answer: capability = .streamedText
        default: throw ProviderFailure.unsupportedCapability
        }
        let provider = provider(lease: lease, model: model, verified: [capability], guidance: guidance)
        switch service {
        case .classification:
            let input = QuestionInput(turn: TranscriptEvent(source: CaptureSource(id: "Connection test", role: .interviewer),
                epoch: UUID(), itemID: "test", text: question, state: .final), previousQuestions: [])
            let result = try await provider.classify(input)
            guard result.decision == .accept, !result.parts.isEmpty else { throw ProviderFailure.unsupportedCapability }
        case .answer:
            for try await _ in try await provider.stream(.init(question: question, instructions: "One sentence.", evidence: [])) {}
        default: throw ProviderFailure.unsupportedCapability
        }
        try requireCurrent(lease)
        guard catalog.contains(where: { $0.slug == model }) else { throw PlanAuthorizationFailure.unverifiedModel }
        verified[model, default: []].insert(capability)
    }

    public func classifier(model: String, guidance: String = "") throws -> any QuestionClassifier {
        let lease = try activeLease()
        guard verified[model]?.contains(.streamedStructuredOutput) == true else { throw PlanAuthorizationFailure.unverifiedModel }
        return provider(lease: lease, model: model, verified: [.streamedStructuredOutput], guidance: guidance)
    }

    public func generator(model: String) throws -> any TextGenerator {
        let lease = try activeLease()
        guard verified[model]?.contains(.streamedText) == true else { throw PlanAuthorizationFailure.unverifiedModel }
        return provider(lease: lease, model: model, verified: [.streamedText])
    }

    private func receiveGrant(host: UUID, registration: Registration?, clientID: String?, requestConsent: Bool)
        async throws -> (ChatGPTAuthorizationAttempt, ChatGPTAuthorizationAttempt.Grant) {
        let listener = try await browser.listen()
        defer { listener.close() }
        let secrets = try browser.secrets()
        let attempt = ChatGPTAuthorizationAttempt(host: host, redirect: listener.redirect, state: secrets.state,
            nonce: secrets.nonce, verifier: secrets.verifier, challenge: secrets.challenge, clientID: clientID,
            idTokenHint: registration?.credentials?.idToken, loginHint: registration?.identity.email,
            requestConsent: requestConsent)
        let authorization = try attempt.authorizationURL()
        return try await withThrowingTaskGroup(of: ChatGPTAuthorizationAttempt.Grant.self) { group in
            group.addTask { [open = browser.open] in
                try Task.checkCancellation()
                guard await open(authorization) else { throw PlanAuthorizationFailure.browserUnavailable }
                for try await callback in listener.callbacks {
                    try Task.checkCancellation()
                    do { return try attempt.validateCallback(callback) }
                    catch PlanAuthorizationFailure.invalidCallback { continue }
                }
                try Task.checkCancellation()
                throw PlanAuthorizationFailure.callbackUnavailable
            }
            group.addTask { [timeout = browser.timeout] in
                try await Task.sleep(for: timeout)
                throw PlanAuthorizationFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw PlanAuthorizationFailure.callbackUnavailable }
            return (attempt, result)
        }
    }

    private struct Lease: Sendable { let account: UUID; let revision: UUID }

    private func activeLease() throws -> Lease {
        let vault = try load()
        guard let id = vault.active, blockedAccount != id,
              let credentials = vault.accounts.first(where: { $0.id == id })?.credentials,
              ChatGPTAuthorizationAttempt.accessScopes.isSubset(of: credentials.scopes) else {
            throw PlanAuthorizationFailure.authorizationMissing
        }
        return Lease(account: id, revision: revision)
    }

    private func requireCurrent(_ lease: Lease) throws {
        guard revision == lease.revision, vault?.active == lease.account, blockedAccount != lease.account else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func invalidateProviders() {
        revision = UUID()
        catalog = []
        verified = [:]
        streams.values.forEach { $0.cancel() }
        streams = [:]
    }

    private func provider(lease: Lease, model: String, verified: Set<ChatGPTSubscriptionProvider.ModelCapability>,
                          guidance: String = "") -> ChatGPTSubscriptionProvider {
        ChatGPTSubscriptionProvider(model: model, verified: verified, credentials: { try await self.access(lease) },
            guidance: guidance, now: now, data: transport.data,
            events: { try await self.boundStream($0, lease: lease) })
    }

    private func boundStream(_ request: URLRequest, lease: Lease) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        try requireCurrent(lease)
        let (stream, output) = AsyncThrowingStream<GenerationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let id = UUID()
        let task = Task {
            defer { streams[id] = nil }
            do {
                for try await event in try await transport.stream(request) {
                    try requireCurrent(lease)
                    if case .dropped = output.yield(event) { throw CaptureFailure.bufferOverrun }
                }
                try requireCurrent(lease)
                output.finish()
            } catch { output.finish(throwing: error) }
        }
        streams[id] = task
        output.onTermination = { _ in task.cancel() }
        return stream
    }

    private func access(_ lease: Lease) async throws -> ChatGPTPlanCredentials {
        try requireCurrent(lease)
        guard let current = try load().accounts.first(where: { $0.id == lease.account })?.credentials else {
            throw PlanAuthorizationFailure.authorizationMissing
        }
        if current.expiry.timeIntervalSince(now()) > 60 || current.refreshToken == nil { return current }
        let task: Task<ChatGPTPlanCredentials, Error>
        if let inProgress = refreshes[lease.account] { task = inProgress }
        else {
            task = Task { try await refresh(lease.account, current: current) }
            refreshes[lease.account] = task
        }
        let updated = try await task.value
        try requireCurrent(lease)
        return updated
    }

    private func refresh(_ id: UUID, current: ChatGPTPlanCredentials) async throws -> ChatGPTPlanCredentials {
        defer { refreshes[id] = nil }
        let reply: TokenReply
        do { reply = try await readTokens(current.refreshRequest()) }
        catch PlanAuthorizationFailure.invalidGrant {
            if try load().active == id { invalidateProviders() }
            try clearTokens(id)
            throw PlanAuthorizationFailure.invalidGrant
        }
        guard reply.refresh_token?.isEmpty == false else { throw PlanAuthorizationFailure.invalidIdentity }
        let identity: ChatGPTPlanIdentity
        if let token = reply.id_token {
            identity = try await verify(token, clientID: current.identity.clientID, nonce: nil,
                                        expectedSubject: current.identity.subject)
        } else { identity = current.identity }
        let updated = try credentials(reply, identity: identity, idToken: reply.id_token ?? current.idToken)
        var vault = try load()
        guard let index = vault.accounts.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        vault.accounts[index].identity = identity
        vault.accounts[index].credentials = updated
        try save(vault)
        if !ChatGPTAuthorizationAttempt.accessScopes.isSubset(of: updated.scopes), vault.active == id {
            invalidateProviders()
            throw PlanAuthorizationFailure.authorizationMissing
        }
        return updated
    }

    private func clearTokens(_ id: UUID) throws {
        var vault = try load()
        guard let index = vault.accounts.firstIndex(where: { $0.id == id }) else { return }
        vault.accounts[index].credentials = nil
        if vault.active == id { vault.active = nil }
        try save(vault)
    }

    private func load() throws -> Vault {
        if let vault { return vault }
        do {
            if let saved = try store.load() { vault = saved; return saved }
        } catch { throw PlanAuthorizationFailure.storageUnavailable }
        let initial = Vault()
        try save(initial)
        return initial
    }

    private func save(_ value: Vault) throws {
        do { try store.save(value) }
        catch { throw PlanAuthorizationFailure.storageUnavailable }
        vault = value
    }

    private func verify(_ token: String, clientID: String, nonce: String?, expectedSubject: String?) async throws
        -> ChatGPTPlanIdentity {
        let signature = try ChatGPTIDToken.signatureInput(token)
        guard try await transport.signature(signature.kid, signature.payload, signature.signature) else {
            throw PlanAuthorizationFailure.invalidIdentity
        }
        return try signature.identity(clientID: clientID, nonce: nonce, expectedSubject: expectedSubject, now: now())
    }

    private func readTokens(_ request: URLRequest) async throws -> TokenReply {
        let send = transport.data
        let (data, response) = try await OpenAIResponsesClient.protected { @Sendable in try await send(request) }
        if response.statusCode == 400 || response.statusCode == 401,
           let error = try? JSONDecoder().decode(OAuthError.self, from: data) {
            switch error.error {
            case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                 "refresh_token_invalidated", "refresh_token_reused": throw PlanAuthorizationFailure.invalidGrant
            case "invalid_client": throw PlanAuthorizationFailure.invalidClient
            default: break
            }
        }
        try OpenAIResponsesClient.validate(response)
        guard response.statusCode == 200, let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else {
            throw PlanAuthorizationFailure.invalidIdentity
        }
        return reply
    }

    private func credentials(_ reply: TokenReply, identity: ChatGPTPlanIdentity, idToken: String) throws -> ChatGPTPlanCredentials {
        let scopes = Set(reply.scope.split(separator: " ").map(String.init))
        guard reply.token_type.lowercased() == "bearer", reply.expires_in.isFinite, reply.expires_in > 0,
              reply.expires_in <= 86_400, !reply.access_token.isEmpty,
              !scopes.contains("offline_access") || reply.refresh_token?.isEmpty == false else {
            throw PlanAuthorizationFailure.invalidIdentity
        }
        return ChatGPTPlanCredentials(identity: identity, accessToken: reply.access_token, refreshToken: reply.refresh_token,
            idToken: idToken, expiry: now().addingTimeInterval(reply.expires_in), scopes: scopes)
    }

    private func revoke(_ token: String, clientID: String) async throws {
        let issuer = ChatGPTAuthorizationAttempt.issuer
        guard let discoveryURL = URL(string: issuer + "/.well-known/openid-configuration") else {
            throw PlanAuthorizationFailure.invalidIdentity
        }
        for attempt in 0..<3 {
            do {
                let (data, response) = try await transport.data(URLRequest(url: discoveryURL, timeoutInterval: 5))
                try validateRevocationResponse(response)
                let discovery = try JSONDecoder().decode(Discovery.self, from: data)
                let endpoint = discovery.revocation_endpoint
                guard discovery.issuer == issuer, endpoint.scheme == "https", endpoint.host == "auth.openai.com",
                      endpoint.port == nil, endpoint.user == nil, endpoint.password == nil,
                      endpoint.query == nil, endpoint.fragment == nil else { throw PlanAuthorizationFailure.invalidIdentity }
                var request = ChatGPTAuthorizationAttempt.form(
                    ["token": token, "token_type_hint": "refresh_token", "client_id": clientID], url: endpoint)
                request.timeoutInterval = 5
                let (_, result) = try await transport.data(request)
                try validateRevocationResponse(result)
                return
            } catch where attempt < 2 && ((error as? ProviderFailure) == .unavailable || error is URLError) {
                try await Task.sleep(for: .milliseconds(250 * (1 << attempt)))
            }
        }
    }

    private func validateRevocationResponse(_ response: HTTPURLResponse) throws {
        if (500...599).contains(response.statusCode) { throw ProviderFailure.unavailable }
        guard response.statusCode == 200 else { throw ProviderFailure.requestRejected }
    }
}
