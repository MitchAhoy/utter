import Foundation

protocol CloudTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
    /// Same as send, and also records Groq's remaining daily allowance for `usageModel`.
    func send(_ request: URLRequest, usageModel: String) async throws -> (Data, Int)
}
extension CloudTransport {
    func send(_ request: URLRequest, usageModel: String) async throws -> (Data, Int) { try await send(request) }
}
private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
final class URLSessionCloudTransport: CloudTransport, Sendable {
    /// One session for the whole app so TLS connections are reused between dictations.
    static let shared = URLSessionCloudTransport()
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await exchange(request)
        return (data, response.statusCode)
    }
    func send(_ request: URLRequest, usageModel: String) async throws -> (Data, Int) {
        let (data, response) = try await exchange(request)
        if request.url?.host == "api.groq.com" { GroqUsageStore.shared.record(model: usageModel, response: response) }
        return (data, response.statusCode)
    }
    private func exchange(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count < 2_000_000 else { throw CloudError.invalidResponse }
        return (data, response)
    }
    /// Opens a connection ahead of the real request, so DNS and TLS finish while the user is still speaking.
    /// Sends no credentials; the server's reply is ignored.
    func warm(host: String) {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.path = "/"
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        session.dataTask(with: request).resume()
    }
}

struct MultipartAudio {
    let boundary: String
    private(set) var data = Data()
    init(boundary: String = "Utter-\(UUID().uuidString)") { self.boundary = boundary }
    private mutating func append(_ text: String) { data.append(contentsOf: text.utf8) }
    mutating func field(_ name: String, _ value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }
    mutating func audio(_ bytes: Data) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        data.append(bytes)
        append("\r\n")
    }
    mutating func finish() { append("--\(boundary)--\r\n") }
}
