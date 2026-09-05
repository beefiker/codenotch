import Foundation
import os

/// Asks Antigravity's own language server for the quota, instead of asking
/// Google directly.
///
/// Google refuses us: `retrieveUserQuotaSummary` on `cloudcode-pa` answers 403
/// "You do not have a valid license of this product" for a personal account,
/// because the API judges *which client* is asking and Codenotch cannot
/// honestly claim to be Antigravity. Antigravity's window has the same problem
/// and solves it the same way — it never calls Google for this either. It calls
/// the language server running on this machine, which already holds the
/// credential and the client identity, and lets that make the call.
///
/// So this is not a workaround for a locked door; it is the door Antigravity
/// itself uses. It works only while Antigravity is running, which is honest:
/// the figure comes from Antigravity, so Antigravity has to be there.
enum AntigravityBridge {
    /// Where the language server is listening, and the token it demands.
    struct Endpoint: Equatable {
        /// Every port the server listens on. It opens two and only one serves
        /// this RPC, and which is which is not advertised — so both are tried
        /// rather than guessed at.
        let ports: [Int]
        let csrfToken: String
    }

    /// Antigravity is built on Codeium's stack, and the header still says so.
    /// Six plausible spellings were rejected before this one was found in the
    /// binary — the server's only complaint is "missing CSRF token", never
    /// which header it wanted.
    static let csrfHeader = "x-codeium-csrf-token"

    private static let service =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    // MARK: - Finding it

    /// The token is passed to the language server on its command line, so the
    /// process table is the source of truth. There is no file to read: the
    /// server is started with `--https_server_port 0`, meaning the port is
    /// chosen at runtime and never written down.
    static func discover(processTable: String? = nil, listeningPorts: ((Int) -> [Int])? = nil)
        -> Endpoint? {
        let table = processTable ?? run("/bin/ps", ["-Ao", "pid,command"])
        let lines = table.split(separator: "\n")

        // 1. Antigravity IDE / standalone language_server with --csrf_token
        if let line = lines.first(where: {
            $0.contains("language_server") && $0.contains("--csrf_token")
        }) {
            if let token = value(of: "--csrf_token", in: String(line)),
               let pid = pid(from: line) {
                let ports = listeningPorts?(pid) ?? self.listeningPorts(ofPID: pid)
                if !ports.isEmpty {
                    return Endpoint(ports: ports, csrfToken: token)
                }
            }
        }

        // 2. Antigravity CLI (agy)
        for line in lines {
            guard isAgyProcess(line) else { continue }
            guard let pid = pid(from: line) else { continue }
            let ports = listeningPorts?(pid) ?? self.listeningPorts(ofPID: pid)
            if !ports.isEmpty {
                let token = value(of: "--csrf_token", in: String(line)) ?? ""
                return Endpoint(ports: ports, csrfToken: token)
            }
        }

        return nil
    }

    static func pid(from line: Substring) -> Int? {
        Int(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
    }

    static func isAgyProcess(_ line: Substring) -> Bool {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count >= 2 else { return false }
        let binary = URL(fileURLWithPath: String(parts[1])).lastPathComponent
        return binary == "agy"
    }

    static func value(of flag: String, in line: String) -> String? {
        let parts = line.split(separator: " ")
        guard let index = parts.firstIndex(of: Substring(flag)),
              index + 1 < parts.count else { return nil }
        return String(parts[index + 1])
    }

    /// Ports are found rather than assumed. The server opens two and only one
    /// serves this RPC, so every candidate is tried in turn.
    static func listeningPorts(ofPID pid: Int) -> [Int] {
        // `-a` is load-bearing: without it lsof ORs the filters rather than
        // ANDing them, and returns every listening socket on the machine. The
        // first match was another process entirely, so the bridge dialled the
        // wrong port and silently fell back to counting requests.
        let output = run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"])
        return parsePorts(fromLSOF: output)
    }

    static func parsePorts(fromLSOF output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            guard let address = line.split(separator: " ").last(where: { $0.contains(":") }),
                  let port = Int(address.split(separator: ":").last ?? "") else { return nil }
            return port
        }
    }

    // MARK: - Asking it

    static func quota(from endpoint: Endpoint, session: URLSession) async throws -> [LimitWindow] {
        var lastError: Error?
        for port in endpoint.ports {
            do {
                let windows = try await quota(port: port, token: endpoint.csrfToken,
                                              session: session)
                if !windows.isEmpty { return windows }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private static func quota(port: Int, token: String,
                              session: URLSession) async throws -> [LimitWindow] {
        if let windows = try? await requestQuota(scheme: "https", port: port, token: token, session: session),
           !windows.isEmpty {
            return windows
        }
        return try await requestQuota(scheme: "http", port: port, token: token, session: session)
    }

    private static func requestQuota(scheme: String, port: Int, token: String,
                                     session: URLSession) async throws -> [LimitWindow] {
        var request = URLRequest(
            url: URL(string: "\(scheme)://127.0.0.1:\(port)\(service)")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: csrfHeader)
        }
        request.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UsageProviderError.badResponse(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return windows(in: data)
    }

    /// Turns the quota summary into limit windows.
    ///
    /// The server reports what is **left**, not what is spent — the notch shows
    /// the opposite, so every fraction is inverted here rather than in the view,
    /// where it would be a percentage whose meaning depended on the provider.
    static func windows(in data: Data) -> [LimitWindow] {
        struct Response: Decodable {
            struct Bucket: Decodable {
                let bucketId: String?
                let displayName: String?
                let window: String?
                let remainingFraction: Double?
                let resetTime: String?
            }
            struct Group: Decodable {
                let displayName: String?
                let buckets: [Bucket]?
            }
            struct Body: Decodable { let groups: [Group]? }
            let response: Body?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let groups = decoded.response?.groups
        else { return [] }

        return groups.flatMap { group -> [LimitWindow] in
            let buckets = group.buckets ?? []
            let multiple = buckets.count > 1
            let sortedBuckets = buckets.sorted { b1, b2 in
                let b1Is5h = b1.window == "5h" || b1.displayName?.contains("Five Hour") == true || b1.bucketId?.contains("5h") == true
                let b2Is5h = b2.window == "5h" || b2.displayName?.contains("Five Hour") == true || b2.bucketId?.contains("5h") == true
                if b1Is5h && !b2Is5h { return true }
                return false
            }
            return sortedBuckets.compactMap { bucket in
                guard let remaining = bucket.remainingFraction,
                      remaining >= 0, remaining <= 1
                else { return nil }

                let groupName = group.displayName ?? "Usage"
                let label: String
                if multiple {
                    let windowTag: String
                    if let win = bucket.window {
                        windowTag = win == "5h" ? " (5h)" : (win == "weekly" ? " (Weekly)" : " (\(win))")
                    } else if let disp = bucket.displayName {
                        windowTag = disp.contains("Five Hour") ? " (5h)" : (disp.contains("Weekly") ? " (Weekly)" : " (\(disp))")
                    } else {
                        windowTag = ""
                    }
                    label = "\(groupName)\(windowTag)"
                } else {
                    label = group.displayName ?? bucket.displayName ?? "Usage"
                }

                return LimitWindow(
                    id: bucket.bucketId ?? label,
                    label: label,
                    usedFraction: 1 - remaining,
                    resetsAt: bucket.resetTime.flatMap(AntigravityCredentials.parse)
                )
            }
        }
    }

    // MARK: - Plumbing

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
