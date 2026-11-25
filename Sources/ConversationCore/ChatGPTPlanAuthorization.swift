import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatGPTPlanEligibility {
    public static let requirement = "Confirm eligibility for the documented open-source/local preview or obtain commercial partner approval before enabling sign-in."
    public static let audioAvailability = "ChatGPT plan authorization does not include audio transcription or embeddings."
}

enum PlanAuthorizationFailure: Error, Equatable {
    case invalidCallback, invalidIdentity, authorizationMissing, accountMismatch, expired, unverifiedModel
}

struct ChatGPTAuthorizationAttempt {
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
            .init(name: "ext_agent_host_id", value: host.uuidString.lowercased()),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.requestedScopes),
            .init(name: "resource", value: Self.resource), .init(name: "state", value: state),
            .init(name: "nonce", value: nonce), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge)
        ]
        if clientID == nil { url.queryItems?.append(.init(name: "agent_name_hint", value: "Live AI Mock Interview Assistant")) }
        guard let request = url.url else { throw PlanAuthorizationFailure.invalidCallback }
        return request
    }

    func validateCallback(_ callback: URL) throws -> Grant {
        guard Self.isLoopback(redirect), callback.scheme == redirect.scheme, callback.host == redirect.host,
              callback.port == redirect.port, callback.path == redirect.path, callback.fragment == nil,
              callback.user == nil, callback.password == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw PlanAuthorizationFailure.invalidCallback
        }
        func value(_ name: String) throws -> String? {
            let entries = items.filter { $0.name == name }
            guard entries.count <= 1 else { throw PlanAuthorizationFailure.invalidCallback }
            return entries.first?.value
        }
        guard let received = try value("state"), Self.equal(received, state) else {
            throw PlanAuthorizationFailure.invalidCallback
        }
        if try value("error") != nil { throw PlanAuthorizationFailure.authorizationMissing }
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
        url.scheme == "http" && url.host == "127.0.0.1" && url.port != nil
        && url.path == "/auth/callback" && url.user == nil && url.password == nil
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
        let nonce: String?
        let email: String?
        let aud: [String]
        let azp: String?

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            iss = try fields.decode(String.self, forKey: .iss)
            sub = try fields.decode(String.self, forKey: .sub)
            exp = try fields.decode(TimeInterval.self, forKey: .exp)
            nonce = try fields.decodeIfPresent(String.self, forKey: .nonce)
            email = try fields.decodeIfPresent(String.self, forKey: .email)
            azp = try fields.decodeIfPresent(String.self, forKey: .azp)
            if let values = try? fields.decode([String].self, forKey: .aud) {
                aud = values
            } else {
                aud = [try fields.decode(String.self, forKey: .aud)]
            }
        }

        private enum CodingKeys: String, CodingKey { case iss, sub, exp, nonce, email, aud, azp }
    }

    static func verify(_ token: String, clientID: String, nonce: String?, expectedSubject: String? = nil,
                       now: Date, verifySignature: (String, Data, Data) -> Bool) throws -> ChatGPTPlanIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 32_768, parts.count == 3,
              let headerData = base64URL(String(parts[0])), let payload = base64URL(String(parts[1])),
              let signature = base64URL(String(parts[2])),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              header.alg == "RS256", !header.kid.isEmpty, !signature.isEmpty,
              verifySignature(header.kid, Data((parts[0] + "." + parts[1]).utf8), signature),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              claims.iss == ChatGPTAuthorizationAttempt.issuer, claims.aud.contains(clientID),
              (claims.aud.count == 1 || claims.azp == clientID),
              claims.azp == nil || claims.azp == clientID, !claims.sub.isEmpty else {
            throw PlanAuthorizationFailure.invalidIdentity
        }
        guard claims.exp > now.timeIntervalSince1970 else { throw PlanAuthorizationFailure.expired }
        if let nonce, !ChatGPTAuthorizationAttempt.equal(claims.nonce ?? "", nonce) {
            throw PlanAuthorizationFailure.invalidIdentity
        }
        if let expectedSubject, claims.sub != expectedSubject { throw PlanAuthorizationFailure.accountMismatch }
        return .init(subject: claims.sub, clientID: clientID, email: claims.email)
    }

    static func base64URL(_ encoded: String) -> Data? {
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
