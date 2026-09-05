import Foundation
import os

/// The credentials Grok CLI and Grok Bot store in `~/.grok/auth.json`.
///
/// Borrowed, like Claude, Cursor, and Codex — Grok signs in, Codenotch only
/// reads what it stored and refreshes the token when near expiry.
struct GrokCredentials: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let email: String?
    let userId: String?
    let issuer: String
    let clientId: String
    let entryKey: String
    let authFileURL: URL

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// Within 5 minutes of expiring, refresh ahead of time so requests don't fail mid-flight.
    var isNearExpiry: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(300)
    }

    static var defaultAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    private static let cache = CredentialCache<GrokCredentials> { $0.isExpired }

    static func forgetCached() { cache.forget() }

    static func load(from url: URL = defaultAuthURL) throws -> GrokCredentials {
        try cache.value(
            itemModifiedAt: {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                return attrs?[.modificationDate] as? Date
            },
            reload: {
                guard FileManager.default.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url)
                else {
                    throw UsageProviderError.needsAuth
                }
                guard let creds = decode(data: data, authFileURL: url) else {
                    throw UsageProviderError.needsAuth
                }
                return creds
            }
        )
    }

    /// Decode the auth map from `~/.grok/auth.json`.
    static func decode(data: Data, authFileURL: URL = defaultAuthURL) -> GrokCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Search for the first entry containing a valid token key
        for (key, val) in root {
            guard let dict = val as? [String: Any],
                  let token = dict["key"] as? String, !token.isEmpty
            else { continue }

            let refreshToken = dict["refresh_token"] as? String
            let email = dict["email"] as? String
            let userId = dict["user_id"] as? String
            let issuer = (dict["oidc_issuer"] as? String) ?? "https://auth.x.ai"
            let clientId = (dict["oidc_client_id"] as? String) ?? "b1a00492-073a-47ea-816f-4c329264a828"
            let expiresAt = (dict["expires_at"] as? String).flatMap(parseDate)

            return GrokCredentials(
                accessToken: token,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                email: email,
                userId: userId,
                issuer: issuer,
                clientId: clientId,
                entryKey: key,
                authFileURL: authFileURL
            )
        }
        return nil
    }

    /// Refresh token via `https://auth.x.ai/oauth2/token` and persist back to `auth.json`.
    func refresh(session: URLSession = .shared) async throws -> GrokCredentials {
        guard let refreshToken, !refreshToken.isEmpty else {
            return self
        }

        guard let tokenURL = URL(string: "\(issuer)/oauth2/token") else {
            return self
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ]
        let encodedBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        req.httpBody = encodedBody.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 400 || status == 401 {
            Self.forgetCached()
            throw UsageProviderError.needsAuth
        }
        guard status == 200 else {
            throw UsageProviderError.badResponse(status: status)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }

        guard let tokenResp = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let newAccess = tokenResp.access_token
        let newRefresh = tokenResp.refresh_token ?? refreshToken
        let newExpiry = tokenResp.expires_in.map { Date().addingTimeInterval($0) }

        // Update auth.json on disk atomically
        if let existingData = try? Data(contentsOf: authFileURL),
           var root = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any] {
            if var entry = root[entryKey] as? [String: Any] {
                entry["key"] = newAccess
                entry["refresh_token"] = newRefresh
                if let newExpiry {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    entry["expires_at"] = formatter.string(from: newExpiry)
                }
                root[entryKey] = entry
                if let updatedData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
                    try? updatedData.write(to: authFileURL, options: .atomic)
                }
            }
        }

        let updated = GrokCredentials(
            accessToken: newAccess,
            refreshToken: newRefresh,
            expiresAt: newExpiry,
            email: email,
            userId: userId,
            issuer: issuer,
            clientId: clientId,
            entryKey: entryKey,
            authFileURL: authFileURL
        )
        return updated
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
