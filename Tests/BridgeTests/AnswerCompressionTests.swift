import Foundation
import Hummingbird
import Testing

@testable import claude_bridge

/// A transcript is gzipped for a client that can read it; a stream is never held back by a
/// compressor, and a picture is never compressed twice.
@Suite("Answer compression")
struct AnswerCompressionTests {
    @Test("Only finished JSON documents are compressed, never an event stream or a picture")
    func compressionChoosesDocuments() {
        func response(_ type: String?, length: Int?) -> Response {
            var headers = HTTPFields()
            if let type { headers[.contentType] = type }
            var buffer = ByteBuffer()
            buffer.writeBytes([UInt8](repeating: 0x20, count: length ?? 0))
            let body: ResponseBody =
                length == nil ? ResponseBody { _ in } : ResponseBody(byteBuffer: buffer)
            return Response(status: .ok, headers: headers, body: body)
        }
        #expect(AnswerCompression<BridgeRequestContext>.isDocument(response("application/json", length: 4096)))
        #expect(!AnswerCompression<BridgeRequestContext>.isDocument(response("text/event-stream", length: 4096)))
        #expect(!AnswerCompression<BridgeRequestContext>.isDocument(response("image/png", length: 4096)))
        #expect(!AnswerCompression<BridgeRequestContext>.isDocument(response("application/json", length: nil)))
        #expect(!AnswerCompression<BridgeRequestContext>.isDocument(response(nil, length: 4096)))
    }
}
