import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ConversationCore

final class ChatGPTPlanTests: XCTestCase {
    func testLoopbackStateAndRegistrationAreBoundToAttempt() throws {
        let callback = try XCTUnwrap(URL(string: "http://127.0.0.1:9231/auth/callback"))
        let attempt = ChatGPTAuthorizationAttempt(host: UUID(), redirect: callback, state: "one", nonce: "nonce",
                                                  verifier: String(repeating: "x", count: 43), challenge: "challenge",
                                                  clientID: nil)
        let authorization = try attempt.authorizationURL()
        XCTAssertEqual(authorization.host, "auth.openai.com")
        XCTAssertTrue(authorization.absoluteString.contains("code_challenge_method=S256"))
        XCTAssertTrue(authorization.absoluteString.contains("client_id=dynamic_agent_client"))
        for invalid in ["state=two&code=ok&client_id=oaiapp_test",
                        "state=one&state=one&code=ok&client_id=oaiapp_test",
                        "state=one&code=ok&client_id=dynamic_agent_client",
                        "state=one&code=ok"] {
            XCTAssertThrowsError(try attempt.validateCallback(XCTUnwrap(URL(string: callback.absoluteString + "?" + invalid))))
        }
        let redirected = try XCTUnwrap(URL(string: callback.absoluteString + "?state=one&code=a%26b&client_id=oaiapp_test"))
        let grant = try attempt.validateCallback(redirected)
        let exchange = try attempt.exchange(grant)
        XCTAssertEqual(exchange.url?.path, "/api/accounts/oauth/token")
        XCTAssertTrue(String(decoding: exchange.httpBody ?? Data(), as: UTF8.self).contains("code=a%26b"))
    }

    func testIdentityRequiresSignedClaimsScopeAccountAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 100)
        let header = ChatGPTIDToken.encode(Data(#"{"alg":"RS256","kid":"synthetic"}"#.utf8))
        let claims = ChatGPTIDToken.encode(Data(#"{"iss":"https://auth.openai.com","sub":"account1","iat":10,"exp":200,"aud":"oaiapp_test","nonce":"exact"}"#.utf8))
        let token = header + "." + claims + "." + ChatGPTIDToken.encode(Data([1, 2]))
        let verify: (String, Data, Data) -> Bool = { key, input, signature in
            key == "synthetic" && input == Data((header + "." + claims).utf8) && signature == Data([1, 2])
        }
        let identity = try ChatGPTIDToken.verify(token, clientID: "oaiapp_test", nonce: "exact", now: now,
                                                verifySignature: verify)
        XCTAssertEqual(identity.subject, "account1")
        XCTAssertThrowsError(try ChatGPTIDToken.verify(token, clientID: "oaiapp_test", nonce: "wrong",
                                                        now: now, verifySignature: verify))
        XCTAssertThrowsError(try ChatGPTIDToken.verify(token, clientID: "oaiapp_test", nonce: "exact",
            expectedSubject: "account2", now: now, verifySignature: verify)) {
            XCTAssertEqual($0 as? PlanAuthorizationFailure, .accountMismatch)
        }
        XCTAssertThrowsError(try ChatGPTIDToken.verify(token, clientID: "oaiapp_test", nonce: "exact",
            now: Date(timeIntervalSince1970: 201), verifySignature: verify))
        XCTAssertThrowsError(try ChatGPTIDToken.verify(token, clientID: "oaiapp_test", nonce: "exact",
            now: now, verifySignature: { _, _, _ in false }))
        let credential = ChatGPTPlanCredentials(identity: identity, accessToken: "synthetic", refreshToken: nil,
                                                 idToken: token, expiry: .distantFuture, scopes: ["resource.invoke"])
        XCTAssertThrowsError(try credential.authorizedAccess())
    }

    func testSubscriptionInferenceUsesDistinctContractAndNeverFallsBack() async throws {
        let provider = ChatGPTSubscriptionProvider(model: "test", verified: [], credentials: {
            XCTFail("An unverified model must not read credentials")
            throw PlanAuthorizationFailure.authorizationMissing
        }, guidance: "", now: { .now }, data: { _ in throw ProviderFailure.disconnected },
            events: { _ in throw ProviderFailure.disconnected })
        do {
            _ = try await provider.stream(.init(question: "Explain data integrity.", instructions: "", evidence: []))
            XCTFail("Unverified model")
        } catch {
            XCTAssertEqual(error as? PlanAuthorizationFailure, .unverifiedModel)
        }
        let request = try ChatGPTSubscriptionProvider.request(access: "synthetic", model: "test",
                                                               instructions: "Instructions", content: "Content", schema: true)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertTrue(payload["stream"] as? Bool == true)
        XCTAssertTrue(payload["store"] as? Bool == false)
        XCTAssertNil(payload["max_output_tokens"])
        XCTAssertNotNil(payload["input"] as? [[String: String]])
        XCTAssertThrowsError(try ChatGPTSubscriptionProvider.decode(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)) {
            XCTAssertEqual($0 as? ProviderFailure, .quotaExhausted)
        }
    }

    func testBrowserRegistrationSwitchingAndIdentityOnlyConsent() async throws {
        let fixture = PlanFixture()
        let accounts = fixture.accounts()
        fixture.configureCode(client: "oaiapp_one", subject: "first")
        try await accounts.signIn()
        let first = try await accounts.snapshot()
        let firstID = try XCTUnwrap(first.active)
        XCTAssertTrue(first.accounts.first?.planEnabled == true)
        let initial = try XCTUnwrap(fixture.authorizations.first)
        XCTAssertEqual(initial["client_id"], "dynamic_agent_client")
        XCTAssertTrue(initial["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true)
        XCTAssertEqual(initial["redirect_uri"], fixture.redirect.absoluteString)
        XCTAssertEqual(fixture.requests.first?.url?.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
        let exchange = try XCTUnwrap(fixture.requests.first?.httpBody)
        let form = String(decoding: exchange, as: UTF8.self)
        XCTAssertTrue(form.contains("code=synthetic%2Bcode%26"))
        XCTAssertTrue(form.contains("client_id=oaiapp_one"))
        XCTAssertFalse(form.contains("client_secret"))

        fixture.configureCode(client: "oaiapp_two", subject: "second", plan: false)
        try await accounts.signIn()
        let second = try await accounts.snapshot()
        let secondID = try XCTUnwrap(second.active)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(Set(second.accounts.map(\.label)).count, 2) // Same email does not merge workspaces.
        XCTAssertTrue(second.accounts.first(where: { $0.id == secondID })?.signedIn == true)
        XCTAssertFalse(second.accounts.first(where: { $0.id == secondID })?.planEnabled == true)
        await rejects(.authorizationMissing) { try await accounts.refreshCatalog() }

        fixture.configureCode(client: "oaiapp_two", subject: "wrong", omitClient: true)
        await rejects(.accountMismatch) { try await accounts.signIn(account: secondID, requestConsent: true) }
        XCTAssertEqual(fixture.authorizations.last?["prompt"], "consent")
        XCTAssertEqual(fixture.authorizations.last?["client_id"], "oaiapp_two")
        XCTAssertEqual(fixture.authorizations.last?["login_hint"], "same+alias@example.invalid")
        XCTAssertNotNil(fixture.authorizations.last?["id_token_hint"])
        XCTAssertNil(fixture.authorizations.last?["agent_name_hint"])
        XCTAssertEqual(fixture.authorizations.last?["ext_agent_host_id"], initial["ext_agent_host_id"])
        XCTAssertNotEqual(fixture.authorizations.last?["state"], initial["state"])

        fixture.configureCode(client: "oaiapp_one", subject: "first", omitClient: true)
        try await accounts.signIn(account: firstID)
        let switched = try await accounts.snapshot()
        XCTAssertEqual(switched.active, firstID)
        XCTAssertNil(fixture.authorizations.last?["prompt"])
        let restarted = try await fixture.accounts().snapshot()
        XCTAssertEqual(restarted.active, firstID)
        XCTAssertEqual(restarted.accounts.count, 2)
        XCTAssertEqual(fixture.closes, 4)
        XCTAssertEqual(fixture.requests.count, 4) // Wrong-state and replayed callbacks never exchange.
    }

    func testBrowserFailureDenialTimeoutAndCancellationCloseListenerWithoutExchange() async throws {
        let fixture = PlanFixture()
        let accounts = fixture.accounts(timeout: .milliseconds(40))
        fixture.behavior = .browserFailure
        await rejects(.browserUnavailable) { try await accounts.signIn() }
        fixture.behavior = .deny
        await rejects(.denied) { try await accounts.signIn() }
        fixture.behavior = .idle
        await rejects(.timedOut) { try await accounts.signIn() }

        let opening = fixture.expectBrowserOpen()
        let cancellation = Task { try await fixture.accounts().signIn() }
        await fulfillment(of: [opening], timeout: 2)
        cancellation.cancel()
        do { try await cancellation.value; XCTFail("Cancelled authorization succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.closes, 4)
        XCTAssertTrue(fixture.requests.isEmpty)
        let snapshot = try await accounts.snapshot()
        XCTAssertNil(snapshot.active)
    }

    func testCodeExchangeInvalidGrantRetriesWithIssuedClientInsteadOfRegisteringAgain() async throws {
        let fixture = PlanFixture()
        let accounts = fixture.accounts()
        fixture.configureCode(client: "oaiapp_retry", subject: "retry", codeStatus: 400)
        await rejects(.invalidGrant) { try await accounts.signIn() }
        let failed = try await accounts.snapshot()
        XCTAssertTrue(failed.accounts.isEmpty)
        fixture.configureCode(client: "oaiapp_retry", subject: "retry", omitClient: true)
        try await accounts.signIn()
        XCTAssertEqual(fixture.authorizations.map { $0["client_id"] }, ["dynamic_agent_client", "oaiapp_retry"])
    }

    func testCatalogCapabilityChecksConcurrentRotationAndSignOutKeepBillingAndAccountsIsolated() async throws {
        let fixture = PlanFixture()
        let accounts = fixture.accounts()
        try await accounts.signIn()
        try await accounts.refreshCatalog()
        let selected = try await accounts.snapshot()
        let id = try XCTUnwrap(selected.active)
        XCTAssertEqual(selected.models.map(\.slug), ["synthetic-model"])
        await rejects(.unverifiedModel) { _ = try await accounts.generator(model: "synthetic-model") }
        try await accounts.checkModel("synthetic-model", service: .answer)
        await rejects(.unverifiedModel) { _ = try await accounts.classifier(model: "synthetic-model") }
        try await accounts.checkModel("synthetic-model", service: .classification, guidance: "fixture guidance")
        let generator = try await accounts.generator(model: "synthetic-model")
        let classifier = try await accounts.classifier(model: "synthetic-model")
        fixture.advance(seconds: 3_570)
        async let scanOne: Void = accounts.refreshCatalog()
        async let scanTwo: Void = accounts.refreshCatalog()
        _ = try await (scanOne, scanTwo)
        let refreshes = fixture.requests.filter { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token") }
        XCTAssertEqual(refreshes.count, 1)
        let refreshForm = String(decoding: try XCTUnwrap(refreshes.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(refreshForm.contains("refresh_token=refresh-original"))
        XCTAssertTrue(refreshForm.contains("client_id=oaiapp_one"))
        XCTAssertFalse(refreshForm.contains("scope="))
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer plan-rotated")

        let answer = AnswerRequest(question: "What is data integrity?", instructions: "", evidence: [])
        let waiting = fixture.expectStreamOpen()
        let started = try await generator.stream(answer)
        let drain = Task { for try await _ in started {} }
        await fulfillment(of: [waiting], timeout: 2)
        try await accounts.signOut(account: id)
        do { try await drain.value; XCTFail("Sign-out left an old stream usable") }
        catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = try await accounts.snapshot()
        XCTAssertNil(snapshot.active)
        XCTAssertEqual(snapshot.accounts.first?.id, id)
        XCTAssertFalse(snapshot.accounts.first?.signedIn == true)
        let revoke = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(revoke.url?.path, "/synthetic-revocation-from-discovery")
        XCTAssertTrue(String(decoding: revoke.httpBody ?? Data(), as: UTF8.self).contains("token=refresh-rotated"))
        do { _ = try await classifier.classify(fixture.question); XCTFail("Stale account lease accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.configureCode(client: "oaiapp_one", subject: "first", omitClient: true)
        try await accounts.signIn(account: id)
        XCTAssertNil(fixture.authorizations.last?["id_token_hint"])
        XCTAssertEqual(fixture.authorizations.last?["client_id"], "oaiapp_one")
    }

    func testRefreshFailureRetainsRegistrationAndRevocationFailureClearsLocalTokens() async throws {
        let fixture = PlanFixture()
        let accounts = fixture.accounts()
        try await accounts.signIn()
        let signedIn = try await accounts.snapshot()
        let id = try XCTUnwrap(signedIn.active)
        fixture.advance(seconds: 3_601)
        fixture.refreshStatus = 503
        do { try await accounts.refreshCatalog(); XCTFail("Refresh failure was ignored") }
        catch { XCTAssertEqual(error as? ProviderFailure, .unavailable) }
        let stillSignedIn = try await accounts.snapshot()
        XCTAssertTrue(stillSignedIn.accounts.first?.signedIn == true)
        fixture.refreshStatus = 400
        await rejects(.invalidGrant) { try await accounts.refreshCatalog() }
        let stale = try await fixture.accounts().snapshot()
        XCTAssertNil(stale.active)
        XCTAssertEqual(stale.accounts.first?.id, id)
        XCTAssertFalse(stale.accounts.first?.signedIn == true)

        fixture.configureCode(client: "oaiapp_one", subject: "first", omitClient: true)
        try await accounts.signIn(account: id)
        fixture.revokeStatus = 401
        await rejects(.remoteRevocationUnconfirmed) { try await accounts.signOut(account: id) }
        let local = try await fixture.accounts().snapshot()
        XCTAssertNil(local.active)
        XCTAssertFalse(local.accounts.first?.signedIn == true)
    }

    func testStreamRequiresDocumentedCompletionAndMapsTemporaryErrors() throws {
        var stream = ChatGPTSubscriptionProvider.ResponseStream()
        var text = ""
        try stream.receive(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8)) {
            if case .text(let part) = $0 { text += part }
        }
        XCTAssertEqual(text, "partial")
        XCTAssertThrowsError(try stream.finish())
        XCTAssertThrowsError(try ChatGPTSubscriptionProvider.decode(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_unavailable"}}}"#)) {
            XCTAssertEqual($0 as? ProviderFailure, .unavailable)
        }
        try stream.receive(Data("data: {\"type\":\"response.completed\"}\n\n".utf8)) { _ in }
        XCTAssertNoThrow(try stream.finish())
    }

    private func rejects(_ expected: PlanAuthorizationFailure, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? PlanAuthorizationFailure, expected) }
    }

    #if os(macOS)
    func testNativePKCEUsesSecureDistinctValuesAndUnpaddedChallenge() throws {
        XCTAssertFalse(ChatGPTPlanEligibility.desktopAvailable)
        XCTAssertNil(ChatGPTPlanAccounts.makeDesktop())
        let attempt = try MacChatGPTPlanSecurity.secrets()
        XCTAssertNotEqual(attempt.state, attempt.nonce)
        XCTAssertEqual(attempt.verifier.count, 43)
        XCTAssertEqual(attempt.challenge.count, 43)
        XCTAssertFalse(attempt.challenge.contains("="))
    }

    func testNativeLoopbackRoutesOnlyItsExactHTTPCallback() async throws {
        let listener = try await MacChatGPTLoopback.start()
        defer { listener.close() }
        let url = try XCTUnwrap(URL(string: listener.redirect.absoluteString + "?state=synthetic&code=abc"))
        var rejected = URLRequest(url: url, timeoutInterval: 3)
        rejected.httpMethod = "POST"
        let (_, denied) = try await URLSession(configuration: .ephemeral).data(for: rejected)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 400)
        let (body, response) = try await URLSession(configuration: .ephemeral).data(for: URLRequest(url: url, timeoutInterval: 3))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("synthetic"))
        let received = try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask { var iterator = listener.callbacks.makeAsyncIterator(); return try await iterator.next() }
            group.addTask { try await Task.sleep(for: .seconds(3)); throw PlanAuthorizationFailure.timedOut }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        XCTAssertEqual(received, url)
    }
    #endif
}

private final class PlanFixture: @unchecked Sendable {
    enum Behavior { case grant, deny, idle, browserFailure }

    private struct State {
        var behavior = Behavior.grant
        var now = Date(timeIntervalSince1970: 100)
        var vault: ChatGPTPlanAccounts.Vault?
        var callbacks: AsyncThrowingStream<URL, Error>.Continuation?
        var browserOpened: XCTestExpectation?
        var streamOpened: XCTestExpectation?
        var responseStream: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
        var authorizations: [[String: String]] = []
        var requests: [URLRequest] = []
        var closes = 0
        var order = 0
        var client = "oaiapp_one"
        var subject = "first"
        var plan = true
        var omitClient = false
        var codeStatus = 200
        var refreshStatus = 200
        var revokeStatus = 200
    }

    let redirect = URL(string: "http://127.0.0.1:41895/auth/callback")!
    let question = QuestionInput(turn: .init(source: .init(id: "synthetic", role: .interviewer),
        epoch: UUID(), itemID: "synthetic", text: "What is FIFO?", state: .final), previousQuestions: [])
    private var state = State()
    private let lock = NSLock()

    var behavior: Behavior { get { withState { $0.behavior } } set { withState { $0.behavior = newValue } } }
    var refreshStatus: Int { get { withState { $0.refreshStatus } } set { withState { $0.refreshStatus = newValue } } }
    var revokeStatus: Int { get { withState { $0.revokeStatus } } set { withState { $0.revokeStatus = newValue } } }
    var requests: [URLRequest] { withState { $0.requests } }
    var authorizations: [[String: String]] { withState { $0.authorizations } }
    var closes: Int { withState { $0.closes } }

    func advance(seconds: TimeInterval) { withState { $0.now.addTimeInterval(seconds) } }

    func configureCode(client: String, subject: String, plan: Bool = true, omitClient: Bool = false, codeStatus: Int = 200) {
        withState {
            $0.client = client
            $0.subject = subject
            $0.plan = plan
            $0.omitClient = omitClient
            $0.codeStatus = codeStatus
        }
    }

    func expectBrowserOpen() -> XCTestExpectation {
        let expected = XCTestExpectation(description: "Synthetic browser opened")
        withState { $0.browserOpened = expected }
        return expected
    }

    func expectStreamOpen() -> XCTestExpectation {
        let expected = XCTestExpectation(description: "Mock responses stream opened")
        withState { $0.streamOpened = expected }
        return expected
    }

    func accounts(timeout: Duration = .seconds(3)) -> ChatGPTPlanAccounts {
        ChatGPTPlanAccounts(browser: .init(listen: { self.listen() }, open: { self.open($0) }, secrets: {
            self.withState {
                $0.order += 1
                return ("state-\($0.order)", "nonce-\($0.order)", String(repeating: "x", count: 43), "synthetic-challenge")
            }
        }, timeout: timeout), transport: .init(data: { try self.data($0) }, stream: { try self.stream($0) },
            signature: { kid, _, signature in kid == "synthetic" && signature == Data([1, 2]) }),
            store: .init(load: { self.withState { $0.vault } }, save: { vault in self.withState { $0.vault = vault } }),
            now: { self.withState { $0.now } })
    }

    private func withState<T>(_ operation: (inout State) throws -> T) rethrows -> T {
        try lock.withLock { try operation(&state) }
    }

    private func listen() -> ChatGPTPlanAccounts.Listener {
        let (stream, output) = AsyncThrowingStream<URL, Error>.makeStream()
        withState { $0.callbacks = output }
        return .init(redirect: redirect, callbacks: stream, close: {
            self.withState { $0.closes += 1; $0.callbacks = nil }
            output.finish()
        })
    }

    private func open(_ url: URL) -> Bool {
        let parameters = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } })
        let (behavior, output, client, omit) = withState { s in
            XCTAssertNotNil(s.vault, "Host identifier must be persisted before opening the browser")
            XCTAssertNotNil(s.callbacks, "Listener must be ready before opening the browser")
            s.authorizations.append(parameters)
            s.browserOpened?.fulfill()
            s.browserOpened = nil
            return (s.behavior, s.callbacks, s.client, s.omitClient)
        }
        func callback(_ query: String) {
            if let result = URL(string: redirect.absoluteString + "?" + query) { output?.yield(result) }
        }
        let state = parameters["state"] ?? ""
        switch behavior {
        case .browserFailure: return false
        case .idle: break
        case .deny: callback("state=\(state)&error=access_denied&code=must-not-exchange")
        case .grant:
            callback("state=invalid&code=never-exchange&client_id=\(client)")
            let value = "state=\(state)&code=synthetic%2Bcode%26&scope=ignored" + (omit ? "" : "&client_id=\(client)")
            callback(value)
            callback(value)
        }
        return true
    }

    private func data(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        try withState { s in
            s.requests.append(request)
            let url = try XCTUnwrap(request.url)
            func response(_ status: Int, _ result: [String: Any] = [:]) throws -> (Data, HTTPURLResponse) {
                (try JSONSerialization.data(withJSONObject: result),
                 try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
            }
            switch url.absoluteString {
            case "https://auth.openai.com/api/accounts/oauth/token":
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let refreshing = body.contains("grant_type=refresh_token")
                let status = refreshing ? s.refreshStatus : s.codeStatus
                guard status == 200 else { return try response(status, ["error": "invalid_grant"]) }
                var reply: [String: Any] = ["token_type": "Bearer", "expires_in": 3_600,
                    "scope": "openid profile email offline_access resource.invoke" + (s.plan ? " chatgpt.tokens.use.direct" : ""),
                    "access_token": refreshing ? "plan-rotated" : "plan-original",
                    "refresh_token": refreshing ? "refresh-rotated" : "refresh-original"]
                if !refreshing {
                    let header = ChatGPTIDToken.encode(Data(#"{"alg":"RS256","kid":"synthetic"}"#.utf8))
                    let claims = try JSONSerialization.data(withJSONObject: ["iss": ChatGPTAuthorizationAttempt.issuer,
                        "sub": s.subject, "iat": s.now.timeIntervalSince1970, "exp": s.now.timeIntervalSince1970 + 3_600,
                        "nonce": s.authorizations.last?["nonce"] ?? "", "aud": s.client, "email": "same+alias@example.invalid"])
                    reply["id_token"] = header + "." + ChatGPTIDToken.encode(claims) + "." + ChatGPTIDToken.encode(Data([1, 2]))
                }
                return try response(200, reply)
            case "https://api.openai.com/v1/models":
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer plan-") == true)
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return try response(200, ["models": [["slug": "synthetic-model", "display_name": "Visible", "visibility": "list"],
                                                     ["slug": "hidden-model", "display_name": "Hidden", "visibility": "hidden"]]])
            case "https://auth.openai.com/.well-known/openid-configuration":
                return try response(200, ["issuer": ChatGPTAuthorizationAttempt.issuer,
                    "revocation_endpoint": "https://auth.openai.com/synthetic-revocation-from-discovery"])
            case "https://auth.openai.com/synthetic-revocation-from-discovery": return try response(s.revokeStatus)
            default: XCTFail("Unexpected endpoint"); throw ProviderFailure.unsupportedCapability
            }
        }
    }

    private func stream(_ request: URLRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        try withState { s in
            s.requests.append(request)
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer plan-") == true)
            let (stream, output) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
            if let waiting = s.streamOpened {
                s.responseStream = output
                s.streamOpened = nil
                waiting.fulfill()
            } else {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
                if body["text"] != nil {
                    let decision = QuestionDecision(decision: .accept, parts: ["What is a FIFO queue?"])
                    output.yield(.text(String(decoding: try JSONEncoder().encode(decision), as: UTF8.self)))
                } else { output.yield(.text("Synthetic answer")) }
                output.finish()
            }
            return stream
        }
    }
}
