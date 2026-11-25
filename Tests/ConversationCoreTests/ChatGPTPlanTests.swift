import Foundation
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
        let claims = ChatGPTIDToken.encode(Data(#"{"iss":"https://auth.openai.com","sub":"account1","exp":200,"aud":"oaiapp_test","nonce":"exact"}"#.utf8))
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
        })
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

    #if os(macOS)
    func testNativePKCEUsesSecureDistinctValuesAndUnpaddedChallenge() throws {
        let attempt = try MacChatGPTPlanSecurity.secrets()
        XCTAssertNotEqual(attempt.state, attempt.nonce)
        XCTAssertEqual(attempt.verifier.count, 43)
        XCTAssertEqual(attempt.challenge.count, 43)
        XCTAssertFalse(attempt.challenge.contains("="))
    }
    #endif
}
