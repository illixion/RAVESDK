import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared REST transport. Credential storage, connectivity policy and decoding
/// stay with the host; this target has no Apple UI, decoder or logging dependency.
public struct JellyfinHTTP: Sendable {
    public let baseURL: URL
    public let authorization: String

    public init(baseURL: URL, authorization: String) {
        self.baseURL = baseURL
        self.authorization = authorization
    }

    public func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                        body: Data? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public func data(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                     body: Data? = nil, timeout: TimeInterval = 20) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(path, query: query, method: method, body: body, timeout: timeout))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return data
    }

    public enum Failure: Error, LocalizedError {
        case http(Int)
        public var errorDescription: String? {
            switch self { case .http(let status): "Jellyfin returned HTTP \(status)." }
        }
    }
}
