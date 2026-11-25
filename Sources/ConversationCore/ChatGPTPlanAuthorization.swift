import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatGPTPlanEligibility {
    // No runtime setting or environment variable can opt this distribution in.
    public static let desktopAvailable = false
    public static let requirement = "The repository owner must confirm eligibility for the open-source/local preview or obtain OpenAI approval for this distribution."
    public static let audioAvailability = "ChatGPT plan authorization does not include audio transcription or embeddings."
}

public enum PlanAuthorizationFailure: LocalizedError, Equatable {
    case unavailable, busy, browserUnavailable, callbackUnavailable, timedOut, denied, invalidCallback
    case invalidIdentity, authorizationMissing, accountMismatch, expired, invalidGrant, invalidClient, unverifiedModel
    case storageUnavailable, remoteRevocationUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .unavailable: ChatGPTPlanEligibility.requirement
        case .busy: "Another ChatGPT account operation is in progress."
        case .browserUnavailable: "The system browser could not open."
        case .callbackUnavailable: "The local sign-in callback could not start or was interrupted."
        case .timedOut: "ChatGPT sign-in timed out. Start again from Settings."
        case .denied: "ChatGPT authorization was not granted."
        case .invalidCallback, .invalidIdentity: "The ChatGPT sign-in could not be verified."
        case .authorizationMissing: "Sign in and enable ChatGPT plan usage for the selected account."
        case .accountMismatch: "ChatGPT returned a different account. Sign in to the selected account or add another."
        case .expired, .invalidGrant: "The ChatGPT authorization expired. Sign in again from Settings."
        case .invalidClient: "OpenAI did not accept this ChatGPT client registration."
        case .unverifiedModel: "Test the selected ChatGPT model for this service before starting."
        case .storageUnavailable: "ChatGPT account records could not be accessed in Keychain."
        case .remoteRevocationUnconfirmed: "Signed out locally. Remote revocation was not confirmed; disconnect the app in ChatGPT Settings."
        }
    }
}

struct ChatGPTAuthorizationAttempt: Sendable {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let dynamicClient = "dynamic_agent_client"
    static let accessScopes: Set<String> = ["resource.invoke", "chatgpt.tokens.use.direct"]
    static let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    let host: UUID
    let redirect: URL
    let state: String
    let nonce: String
    let verifier: String
    let challenge: String
    let clientID: String?
    var idTokenHint: String? = nil
    var loginHint: String? = nil
    var requestConsent = false

    struct Grant: Equatable {
        let code: String
        let clientID: String
    }

    func authorizationURL() throws -> URL {
        guard Self.isLoopback(redirect), (43...128).contains(verifier.count),
              !state.isEmpty, !nonce.isEmpty, !challenge.isEmpty,
              clientID == nil || Self.issuedClient(clientID ?? "") else { throw PlanAuthorizationFailure.invalidCallback }
        var url = URLComponents()
        url.scheme = "https"
        url.host = "auth.openai.com"
        url.path = "/api/accounts/authorize"
        url.queryItems = [
            .init(name: "client_id", value: clientID ?? Self.dynamicClient),
            .init(name: "ext_agent_host_id", value: "urn:uuid:" + host.uuidString.lowercased()),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.requestedScopes),
            .init(name: "resource", value: Self.resource), .init(name: "state", value: state),
            .init(name: "nonce", value: nonce), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge)
        ]
        if clientID == nil {
            url.queryItems?.append(.init(name: "agent_name_hint", value: "Live AI Mock Interview Assistant"))
        } else {
            if let idTokenHint { url.queryItems?.append(.init(name: "id_token_hint", value: idTokenHint)) }
            if let loginHint { url.queryItems?.append(.init(name: "login_hint", value: loginHint)) }
            if requestConsent { url.queryItems?.append(.init(name: "prompt", value: "consent")) }
        }
        // OAuth query values use form encoding; a literal plus must not become a space.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let request = url.url else { throw PlanAuthorizationFailure.invalidCallback }
        return request
    }

    func validateCallback(_ callback: URL) throws -> Grant {
        guard Self.isLoopback(redirect), callback.scheme == redirect.scheme, callback.host == redirect.host,
              callback.port == redirect.port, callback.fragment == nil, callback.user == nil, callback.password == nil,
              var components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == "/auth/callback" else {
            throw PlanAuthorizationFailure.invalidCallback
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        guard let items = components.queryItems else { throw PlanAuthorizationFailure.invalidCallback }
        func value(_ name: String) throws -> String? {
            let entries = items.filter { $0.name == name }
            guard entries.count <= 1, entries.first.map({ $0.value != nil }) ?? true else {
                throw PlanAuthorizationFailure.invalidCallback
            }
            return entries.first?.value
        }
        guard let received = try value("state"), Self.equal(received, state) else {
            throw PlanAuthorizationFailure.invalidCallback
        }
        if try value("error") != nil { throw PlanAuthorizationFailure.denied }
        guard let code = try value("code"), !code.isEmpty, code.utf8.count < 8_192 else {
            throw PlanAuthorizationFailure.invalidCallback
        }
        let returned = try value("client_id")
        guard let issued = clientID ?? returned, Self.issuedClient(issued), returned == nil || returned == issued else {
            throw PlanAuthorizationFailure.invalidCallback
        }
        return Grant(code: code, clientID: issued)
    }

    func exchange(_ grant: Grant) throws -> URLRequest {
        try Self.tokenRequest([
            "grant_type": "authorization_code", "client_id": grant.clientID, "code": grant.code,
            "code_verifier": verifier, "redirect_uri": redirect.absoluteString, "resource": Self.resource
        ])
    }

    static func tokenRequest(_ fields: [String: String]) throws -> URLRequest {
        guard let url = URL(string: issuer + "/api/accounts/oauth/token") else {
            throw PlanAuthorizationFailure.invalidCallback
        }
        return form(fields, url: url)
    }

    static func form(_ fields: [String: String], url: URL) -> URLRequest {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = fields.sorted { $0.key < $1.key }.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "") + "="
            + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(pairs.joined(separator: "&").utf8)
        return request
    }

    private static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && (1...65_535).contains(url.port ?? 0)
        && URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/auth/callback"
        && url.user == nil && url.password == nil
        && url.fragment == nil && url.query == nil
    }

    private static func issuedClient(_ value: String) -> Bool {
        !value.isEmpty && value != dynamicClient && value.utf8.count <= 250 &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
    }

    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == rhs.utf8.count else { return false }
        return zip(lhs.utf8, rhs.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct ChatGPTPlanIdentity: Equatable, Codable, Sendable {
    let subject: String
    let clientID: String
    let email: String?
}

struct ChatGPTIDToken {
    private struct Header: Decodable { let alg: String; let kid: String }
    private struct Claims: Decodable {
        let iss: String
        let sub: String
        let exp: TimeInterval
        let iat: TimeInterval
        let nonce: String?
        let email: String?
        let aud: [String]
        let azp: String?

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            iss = try fields.decode(String.self, forKey: .iss)
            sub = try fields.decode(String.self, forKey: .sub)
            exp = try fields.decode(TimeInterval.self, forKey: .exp)
            iat = try fields.decode(TimeInterval.self, forKey: .iat)
            nonce = try fields.decodeIfPresent(String.self, forKey: .nonce)
            email = try fields.decodeIfPresent(String.self, forKey: .email)
            azp = try fields.decodeIfPresent(String.self, forKey: .azp)
            if let values = try? fields.decode([String].self, forKey: .aud) {
                aud = values
            } else {
                aud = [try fields.decode(String.self, forKey: .aud)]
            }
        }

        private enum CodingKeys: String, CodingKey { case iss, sub, exp, iat, nonce, email, aud, azp }
    }

    static func verify(_ token: String, clientID: String, nonce: String?, expectedSubject: String? = nil,
                       now: Date, verifySignature: (String, Data, Data) -> Bool) throws -> ChatGPTPlanIdentity {
        let signed = try signatureInput(token)
        guard verifySignature(signed.kid, signed.payload, signed.signature) else {
            throw PlanAuthorizationFailure.invalidIdentity
        }
        return try signed.identity(clientID: clientID, nonce: nonce, expectedSubject: expectedSubject, now: now)
    }

    struct Signed {
        let kid: String
        let payload: Data
        let signature: Data
        fileprivate let claimsData: Data

        // Call only after signature verification. Identity claims never act as proof on their own.
        func identity(clientID: String, nonce: String?, expectedSubject: String?, now: Date) throws -> ChatGPTPlanIdentity {
            guard let claims = try? JSONDecoder().decode(Claims.self, from: claimsData),
                  claims.iss == ChatGPTAuthorizationAttempt.issuer, claims.aud.contains(clientID),
                  (claims.aud.count == 1 || claims.azp == clientID),
                  claims.azp == nil || claims.azp == clientID, !claims.sub.isEmpty,
                  claims.iat.isFinite, claims.iat <= now.timeIntervalSince1970 + 5,
                  claims.exp.isFinite, claims.exp > claims.iat else { throw PlanAuthorizationFailure.invalidIdentity }
            guard claims.exp > now.timeIntervalSince1970 else { throw PlanAuthorizationFailure.expired }
            if let nonce, !ChatGPTAuthorizationAttempt.equal(claims.nonce ?? "", nonce) {
                throw PlanAuthorizationFailure.invalidIdentity
            }
            if let expectedSubject, claims.sub != expectedSubject { throw PlanAuthorizationFailure.accountMismatch }
            return .init(subject: claims.sub, clientID: clientID, email: claims.email)
        }
    }

    static func signatureInput(_ token: String) throws -> Signed {
        guard token.utf8.count <= 32_768 else { throw PlanAuthorizationFailure.invalidIdentity }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = base64URL(String(parts[0])), let claims = base64URL(String(parts[1])),
               let signature = base64URL(String(parts[2])),
               let header = try? JSONDecoder().decode(Header.self, from: headerData),
               header.alg == "RS256", !header.kid.isEmpty, !signature.isEmpty else {
            throw PlanAuthorizationFailure.invalidIdentity
        }
        return Signed(kid: header.kid, payload: Data((parts[0] + "." + parts[1]).utf8),
                      signature: signature, claimsData: claims)
    }

    static func base64URL(_ encoded: String) -> Data? {
        guard encoded.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let standard = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard + padding)
    }

    static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct ChatGPTPlanCredentials: Codable, Sendable {
    let identity: ChatGPTPlanIdentity
    let accessToken: String
    let refreshToken: String?
    let idToken: String
    let expiry: Date
    let scopes: Set<String>

    func authorizedAccess(now: Date = .now) throws -> String {
        guard expiry > now else { throw PlanAuthorizationFailure.expired }
        guard !accessToken.isEmpty, ChatGPTAuthorizationAttempt.accessScopes.isSubset(of: scopes) else {
            throw PlanAuthorizationFailure.authorizationMissing
        }
        return accessToken
    }

    func refreshRequest() throws -> URLRequest {
        guard let refreshToken, !refreshToken.isEmpty else { throw PlanAuthorizationFailure.authorizationMissing }
        return try ChatGPTAuthorizationAttempt.tokenRequest([
            "grant_type": "refresh_token", "client_id": identity.clientID,
            "refresh_token": refreshToken, "resource": ChatGPTAuthorizationAttempt.resource
        ])
    }
}
