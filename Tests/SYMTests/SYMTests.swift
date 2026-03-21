import XCTest
@testable import SYM

final class SYMTests: XCTestCase {

    func testContextEncoderDimension() {
        let (h1, h2) = ContextEncoder.encode("test context for encoding")
        XCTAssertEqual(h1.count, ContextEncoder.dim)
        XCTAssertEqual(h2.count, ContextEncoder.dim)
    }

    func testContextEncoderDeterministic() {
        let text = "race condition in order processing"
        let (h1a, h2a) = ContextEncoder.encode(text)
        let (h1b, h2b) = ContextEncoder.encode(text)
        XCTAssertEqual(h1a, h1b)
        XCTAssertEqual(h2a, h2b)
    }

    func testContextEncoderNormalized() {
        let (h1, h2) = ContextEncoder.encode("a long text about API debugging and error handling")
        let norm1 = sqrt(h1.reduce(0) { $0 + $1 * $1 })
        let norm2 = sqrt(h2.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm1, 1.0, accuracy: 0.001)
        XCTAssertEqual(norm2, 1.0, accuracy: 0.001)
    }

    func testFrameSerialization() throws {
        let frame = SymFrame.handshake(nodeId: "test-id", name: "test-node")
        let data = try frame.serialize()
        XCTAssertGreaterThan(data.count, 4)

        // Verify length prefix
        let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(length), data.count - 4)
    }

    func testFrameParserRoundTrip() throws {
        let frame = SymFrame.message(from: "node-1", fromName: "Alice", content: "Hello mesh")
        let data = try frame.serialize()

        let parser = SymFrameParser()
        let parsed = parser.feed(data)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].type, .message)
        XCTAssertEqual(parsed[0].content, "Hello mesh")
        XCTAssertEqual(parsed[0].fromName, "Alice")
    }

    func testIdentityPersistence() {
        let id1 = SymIdentityManager.loadOrCreate(name: "test-persistence-\(UUID().uuidString)")
        let id2 = SymIdentityManager.loadOrCreate(name: id1.name)
        XCTAssertEqual(id1.nodeId, id2.nodeId)
    }
}
