import Foundation

protocol CloudTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
final class URLSessionCloudTransport: CloudTransport, Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count < 2_000_000 else { throw CloudError.invalidResponse }
        return (data, response.statusCode)
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
