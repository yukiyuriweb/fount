import Foundation
import Security

struct GitHubSync {
    private static let clientID = "Ov23liv5yGAx1UrGUx3k"
    private static let gitHub = URL(string: "https://github.com")!
    private static let api = URL(string: "https://api.github.com")!
    static let verificationURL = gitHub.appending(path: "login/device")

    struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let expiresIn: Int
        let interval: Int
    }

    struct Account: Codable {
        let id: Int
        let login: String
    }

    struct Credential: Codable {
        let account: Account
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?

        fileprivate init(account: Account, token: TokenReply) throws {
            guard let accessToken = token.accessToken, !accessToken.isEmpty else { throw SyncError.invalidResponse }
            self.account = account
            self.accessToken = accessToken
            refreshToken = token.refreshToken
            expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        }
    }

    struct Gist: Codable {
        let id: String
        let htmlUrl: URL
    }

    private struct GistUpload: Encodable {
        struct File: Encodable {
            let content: String
        }

        let description: String?
        let `public`: Bool?
        let files: [String: File]
    }

    fileprivate struct TokenReply: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?
        let scope: String?
        let error: String?
    }

    enum SyncError: LocalizedError {
        case invalidResponse, expiredCode, denied, gistPermission, reconnect, http(Int), keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: String(localized: "GitHub returned an unexpected response.")
            case .expiredCode: String(localized: "The GitHub verification code expired. Start the connection again.")
            case .denied: String(localized: "GitHub authorization was declined.")
            case .gistPermission: String(localized: "Fount needs permission to write to GitHub Gists.")
            case .reconnect: String(localized: "The GitHub connection has expired. Reconnect to GitHub and try again.")
            case .http(let status): String(localized: "GitHub returned HTTP \(status).")
            case .keychain(let status): String(localized: "Couldn’t access the GitHub credentials in Keychain (\(status)).")
            }
        }
    }

    var session: URLSession = .shared

    func requestCode() async throws -> DeviceCode {
        try await oauth("login/device/code", ["scope": "gist"])
    }

    func authorize(_ code: DeviceCode) async throws -> Credential {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(code.expiresIn)
        var interval = max(1, code.interval)
        while true {
            let nextPoll = clock.now + .seconds(interval)
            guard nextPoll < deadline else { throw SyncError.expiredCode }
            try await clock.sleep(until: nextPoll)
            guard clock.now < deadline else { throw SyncError.expiredCode }

            let token: TokenReply = try await oauth("login/oauth/access_token", [
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            switch token.error {
            case "authorization_pending": continue
            case "slow_down":
                interval += 5
                continue
            case "expired_token", "token_expired": throw SyncError.expiredCode
            case "access_denied": throw SyncError.denied
            case .some: throw SyncError.invalidResponse
            case nil: break
            }

            guard token.scope?.split(separator: ",").contains("gist") == true else {
                throw SyncError.gistPermission
            }
            guard let accessToken = token.accessToken else { throw SyncError.invalidResponse }
            let account: Account = try await send(apiRequest("user", token: accessToken))
            return try Credential(account: account, token: token)
        }
    }

    func refresh(_ credential: Credential) async throws -> Credential {
        guard let refreshToken = credential.refreshToken else { throw SyncError.reconnect }
        let token: TokenReply = try await oauth("login/oauth/access_token", [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        switch token.error {
        case "bad_refresh_token", "incorrect_client_credentials", "invalid_grant": throw SyncError.reconnect
        case .some: throw SyncError.invalidResponse
        case nil: return try Credential(account: credential.account, token: token)
        }
    }

    func upload(_ content: String, gistID: String?, credential: Credential) async throws -> Gist {
        var request = apiRequest(gistID.map { "gists/\($0)" } ?? "gists", token: credential.accessToken)
        request.httpMethod = gistID == nil ? "POST" : "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GistUpload(
            description: gistID == nil ? "Fount Sync" : nil,
            public: gistID == nil ? false : nil,
            files: ["fount-sync.json": .init(content: content)]
        ))
        return try await send(request)
    }

    private func oauth<Response: Decodable>(_ path: String, _ parameters: [String: String]) async throws -> Response {
        var request = URLRequest(url: Self.gitHub.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields = parameters
        fields["client_id"] = Self.clientID
        request.httpBody = try JSONEncoder().encode(fields)
        return try await send(request)
    }

    private func apiRequest(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: Self.api.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw SyncError.invalidResponse
        }
    }
}

enum GitHubCredentialStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.fount.github-sync",
        kSecAttrAccount as String: "oauth",
    ]

    static func load() throws -> GitHubSync.Credential? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, value in value } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GitHubSync.SyncError.keychain(status) }
        return try JSONDecoder().decode(GitHubSync.Credential.self, from: data)
    }

    static func save(_ credential: GitHubSync.Credential) throws {
        let values = [kSecValueData as String: try JSONEncoder().encode(credential)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GitHubSync.SyncError.keychain(status) }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubSync.SyncError.keychain(status) }
    }
}
