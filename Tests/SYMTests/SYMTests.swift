import XCTest
@testable import SYM

// MARK: - Context Encoder Tests

final class ContextEncoderTests: XCTestCase {

    func testDimension() {
        let (h1, h2) = ContextEncoder.encode("test context for encoding")
        XCTAssertEqual(h1.count, ContextEncoder.dim)
        XCTAssertEqual(h2.count, ContextEncoder.dim)
    }

    func testDeterministic() {
        let text = "race condition in order processing"
        let (h1a, h2a) = ContextEncoder.encode(text)
        let (h1b, h2b) = ContextEncoder.encode(text)
        XCTAssertEqual(h1a, h1b)
        XCTAssertEqual(h2a, h2b)
    }

    func testNonZero() {
        let (h1, h2) = ContextEncoder.encode("a long text about API debugging and error handling")
        let norm1 = sqrt(h1.reduce(0) { $0 + $1 * $1 })
        let norm2 = sqrt(h2.reduce(0) { $0 + $1 * $1 })
        XCTAssertGreaterThan(norm1, 0.0, "h1 should be non-zero")
        XCTAssertGreaterThan(norm2, 0.0, "h2 should be non-zero")
        XCTAssertFalse(norm1.isNaN, "h1 norm should not be NaN")
        XCTAssertFalse(norm2.isNaN, "h2 norm should not be NaN")
    }

    func testDifferentInputsDifferentOutput() {
        let (h1a, _) = ContextEncoder.encode("debugging auth module")
        let (h1b, _) = ContextEncoder.encode("relaxing at the beach")
        XCTAssertNotEqual(h1a, h1b, "different text should produce different encodings")
    }

    func testEmptyInput() {
        let (h1, h2) = ContextEncoder.encode("")
        XCTAssertEqual(h1.count, ContextEncoder.dim)
        XCTAssertEqual(h2.count, ContextEncoder.dim)
    }
}

// MARK: - Identity Tests

final class IdentityTests: XCTestCase {

    // MARK: UUID v7

    func testUUIDv7Format() {
        let id = SymIdentityManager.uuidv7()
        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        XCTAssertNotNil(id.range(of: pattern, options: .regularExpression), "should be lowercase 8-4-4-4-12 hex")
    }

    func testUUIDv7VersionNibble() {
        let id = SymIdentityManager.uuidv7()
        let idx = id.index(id.startIndex, offsetBy: 14)
        XCTAssertEqual(String(id[idx]), "7", "version nibble should be 7")
    }

    func testUUIDv7VariantBits() {
        let id = SymIdentityManager.uuidv7()
        let idx = id.index(id.startIndex, offsetBy: 19)
        let variantChar = String(id[idx])
        XCTAssertTrue("89ab".contains(variantChar), "variant char should be 8/9/a/b, got '\(variantChar)'")
    }

    func testUUIDv7Uniqueness() {
        let ids = Set((0..<100).map { _ in SymIdentityManager.uuidv7() })
        XCTAssertEqual(ids.count, 100, "100 UUIDs should all be unique")
    }

    func testUUIDv7TimeOrdered() {
        let a = SymIdentityManager.uuidv7()
        let b = SymIdentityManager.uuidv7()
        // Remove hyphens, compare first 12 hex chars (48-bit timestamp)
        let tsA = a.replacingOccurrences(of: "-", with: "").prefix(12)
        let tsB = b.replacingOccurrences(of: "-", with: "").prefix(12)
        XCTAssertGreaterThanOrEqual(String(tsB), String(tsA), "should be time-ordered")
    }

    // MARK: Name Validation

    func testValidNames() {
        XCTAssertNoThrow(try SymIdentityManager.validateName("claude-code"))
        XCTAssertNoThrow(try SymIdentityManager.validateName("a"))
        XCTAssertNoThrow(try SymIdentityManager.validateName("my-node-123"))
    }

    func testUnicodeNames() {
        XCTAssertNoThrow(try SymIdentityManager.validateName("日本語"))
    }

    func testEmptyNameRejected() {
        XCTAssertThrowsError(try SymIdentityManager.validateName(""))
    }

    func testLongNameRejected() {
        let long = String(repeating: "a", count: 65)
        XCTAssertThrowsError(try SymIdentityManager.validateName(long))
    }

    func testControlCharsRejected() {
        XCTAssertThrowsError(try SymIdentityManager.validateName("test\0node"))
        XCTAssertThrowsError(try SymIdentityManager.validateName("test\nnewline"))
        XCTAssertThrowsError(try SymIdentityManager.validateName("test\ttab"))
    }

    // MARK: Signing Keypair

    func testSigningKeyPairGeneration() {
        let kp = SymIdentityManager.generateSigningKeyPair()
        XCTAssertFalse(kp.publicKey.isEmpty, "publicKey should not be empty")
        XCTAssertFalse(kp.privateKey.isEmpty, "privateKey should not be empty")
    }

    func testSigningKeyPairUniqueness() {
        let a = SymIdentityManager.generateSigningKeyPair()
        let b = SymIdentityManager.generateSigningKeyPair()
        XCTAssertNotEqual(a.publicKey, b.publicKey, "different calls should produce different keys")
    }

    func testSigningKeyPairBase64URL() {
        let kp = SymIdentityManager.generateSigningKeyPair()
        XCTAssertFalse(kp.publicKey.contains("+"), "should not contain +")
        XCTAssertFalse(kp.publicKey.contains("="), "should not contain =")
        XCTAssertFalse(kp.publicKey.contains("/"), "should not contain /")
    }

    // MARK: Identity Persistence

    func testLoadOrCreateNewIdentity() {
        let name = "test-new-\(UUID().uuidString)"
        let id = SymIdentityManager.loadOrCreate(name: name)
        XCTAssertFalse(id.nodeId.isEmpty)
        XCTAssertEqual(id.name, name)
        XCTAssertNotNil(id.publicKey, "new identity should have Ed25519 publicKey")
        XCTAssertNotNil(id.privateKey, "new identity should have Ed25519 privateKey")
        // UUID v7 version check
        let idx = id.nodeId.index(id.nodeId.startIndex, offsetBy: 14)
        XCTAssertEqual(String(id.nodeId[idx]), "7", "new node should use UUID v7")
    }

    func testLoadOrCreatePersistence() {
        let name = "test-persist-\(UUID().uuidString)"
        let id1 = SymIdentityManager.loadOrCreate(name: name)
        let id2 = SymIdentityManager.loadOrCreate(name: name)
        XCTAssertEqual(id1.nodeId, id2.nodeId, "should return same nodeId on second call")
        XCTAssertEqual(id1.publicKey, id2.publicKey, "should return same publicKey")
    }

    func testNodeDirectory() {
        let dir = SymIdentityManager.nodeDirectory(for: "test-dir")
        XCTAssertTrue(dir.path.contains("nodes"), "path should contain 'nodes'")
        XCTAssertTrue(dir.path.contains("test-dir"), "path should contain node name")
    }

    // MARK: E2E Keypair

    func testE2EKeyPairGeneration() {
        let name = "test-e2e-\(UUID().uuidString)"
        let kp = SymIdentityManager.loadOrCreateE2EKeyPair(name: name)
        XCTAssertEqual(kp.publicKey.count, 32, "Curve25519 public key should be 32 bytes")
    }

    func testE2EKeyPairPersistence() {
        let name = "test-e2e-persist-\(UUID().uuidString)"
        let kp1 = SymIdentityManager.loadOrCreateE2EKeyPair(name: name)
        let kp2 = SymIdentityManager.loadOrCreateE2EKeyPair(name: name)
        XCTAssertEqual(kp1.publicKey, kp2.publicKey, "should return same key on second call")
    }

    // MARK: Base64URL

    func testBase64URLRoundTrip() {
        let original = Data([0, 1, 2, 255, 254, 253, 128, 64, 32])
        let encoded = original.base64URLEncodedString()
        let decoded = Data(base64URLEncoded: encoded)
        XCTAssertEqual(decoded, original, "base64url round-trip should preserve data")
    }

    func testBase64URLNoUnsafeChars() {
        // Data that would produce + and / in standard base64
        let data = Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        let encoded = data.base64URLEncodedString()
        XCTAssertFalse(encoded.contains("+"), "should not contain +")
        XCTAssertFalse(encoded.contains("/"), "should not contain /")
        XCTAssertFalse(encoded.contains("="), "should not contain padding =")
    }

    func testBase64URLDecodePadding() {
        // 1-byte data = 2 base64 chars + 2 padding (omitted in base64url)
        let data = Data([42])
        let encoded = data.base64URLEncodedString()
        XCTAssertFalse(encoded.contains("="), "should omit padding")
        let decoded = Data(base64URLEncoded: encoded)
        XCTAssertEqual(decoded, data, "should decode correctly without padding")
    }
}

// MARK: - Frame Tests

final class FrameTests: XCTestCase {

    // MARK: Factory Methods

    func testHandshakeFactory() {
        let frame = SymFrame.handshake(nodeId: "abc-123", name: "test", publicKey: "pk123", e2ePublicKey: "e2e456")
        XCTAssertEqual(frame.type, .handshake)
        XCTAssertEqual(frame.nodeId, "abc-123")
        XCTAssertEqual(frame.name, "test")
        XCTAssertEqual(frame.publicKey, "pk123")
        XCTAssertEqual(frame.e2ePublicKey, "e2e456")
    }

    func testStateSyncFactory() {
        let frame = SymFrame.stateSync(h1: [1.0, 2.0], h2: [3.0, 4.0], confidence: 0.9)
        XCTAssertEqual(frame.type, .stateSync)
        XCTAssertEqual(frame.h1, [1.0, 2.0])
        XCTAssertEqual(frame.h2, [3.0, 4.0])
        XCTAssertEqual(frame.confidence, 0.9)
    }

    func testMessageFactory() {
        let frame = SymFrame.message(from: "node-1", fromName: "Alice", content: "Hello mesh")
        XCTAssertEqual(frame.type, .message)
        XCTAssertEqual(frame.from, "node-1")
        XCTAssertEqual(frame.fromName, "Alice")
        XCTAssertEqual(frame.content, "Hello mesh")
    }

    func testPingPongFactory() {
        let ping = SymFrame.ping()
        let pong = SymFrame.pong()
        XCTAssertEqual(ping.type, .ping)
        XCTAssertEqual(pong.type, .pong)
    }

    // MARK: Serialization

    func testSerializationLengthPrefix() throws {
        let frame = SymFrame.handshake(nodeId: "test-id", name: "test-node")
        let data = try frame.serialize()
        XCTAssertGreaterThan(data.count, 4)

        let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(length), data.count - 4)
    }

    func testHandshakeRoundTrip() throws {
        let frame = SymFrame.handshake(nodeId: "abc-123", name: "test-node", publicKey: "pk", e2ePublicKey: "e2e")
        let data = try frame.serialize()
        let parsed = SymFrameParser().feed(data)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].type, .handshake)
        XCTAssertEqual(parsed[0].nodeId, "abc-123")
        XCTAssertEqual(parsed[0].name, "test-node")
        XCTAssertEqual(parsed[0].publicKey, "pk")
        XCTAssertEqual(parsed[0].e2ePublicKey, "e2e")
    }

    func testMessageRoundTrip() throws {
        let frame = SymFrame.message(from: "node-1", fromName: "Alice", content: "Hello mesh")
        let data = try frame.serialize()
        let parsed = SymFrameParser().feed(data)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].type, .message)
        XCTAssertEqual(parsed[0].content, "Hello mesh")
        XCTAssertEqual(parsed[0].fromName, "Alice")
    }

    func testStateSyncRoundTrip() throws {
        let frame = SymFrame.stateSync(h1: [0.1, 0.2, 0.3], h2: [0.4, 0.5, 0.6], confidence: 0.85)
        let data = try frame.serialize()
        let parsed = SymFrameParser().feed(data)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].type, .stateSync)
        XCTAssertEqual(parsed[0].h1?.count, 3)
        XCTAssertEqual(parsed[0].confidence, 0.85)
    }

    // MARK: Parser

    func testParserMultipleFrames() throws {
        let f1 = try SymFrame.ping().serialize()
        let f2 = try SymFrame.pong().serialize()
        var combined = Data()
        combined.append(f1)
        combined.append(f2)

        let parsed = SymFrameParser().feed(combined)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].type, .ping)
        XCTAssertEqual(parsed[1].type, .pong)
    }

    func testParserPartialFrame() throws {
        let data = try SymFrame.ping().serialize()
        let parser = SymFrameParser()

        let mid = data.count / 2
        let part1 = parser.feed(data[0..<mid])
        XCTAssertEqual(part1.count, 0, "should not emit on partial data")

        let part2 = parser.feed(data[mid...])
        XCTAssertEqual(part2.count, 1)
        XCTAssertEqual(part2[0].type, .ping)
    }

    func testParserGarbageData() {
        let parser = SymFrameParser()
        let garbage = Data([0xFF, 0xFF, 0xFF, 0xFF]) // length = 4 billion
        let result = parser.feed(garbage)
        XCTAssertEqual(result.count, 0, "should not parse garbage")
    }
}

// MARK: - Memory Store Tests

final class MemoryStoreTests: XCTestCase {

    var store: SymMemoryStore!
    var nodeDir: URL!

    override func setUp() {
        super.setUp()
        let name = "test-store-\(UUID().uuidString)"
        nodeDir = SymIdentityManager.nodeDirectory(for: name)
        store = SymMemoryStore(nodeDir: nodeDir, sourceName: "test-agent")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: nodeDir)
        super.tearDown()
    }

    func testWriteAndCount() {
        let before = store.count
        store.write(content: "test observation", tags: ["test"])
        XCTAssertEqual(store.count, before + 1)
    }

    func testWriteAndSearch() {
        store.write(content: "unique xylophone memory for search test", tags: ["music"])
        let results = store.search(query: "xylophone")
        XCTAssertGreaterThanOrEqual(results.count, 1, "should find the written entry")
    }

    func testWriteMultipleAndAllEntries() {
        store.write(content: "entry one")
        store.write(content: "entry two")
        store.write(content: "entry three")
        let all = store.allEntries()
        XCTAssertGreaterThanOrEqual(all.count, 3)
    }

    func testWriteWithTags() {
        store.write(content: "tagged entry", tags: ["alpha", "beta"])
        let results = store.search(query: "tagged entry")
        XCTAssertGreaterThanOrEqual(results.count, 1)
    }
}

// MARK: - Node Tests

final class NodeTests: XCTestCase {

    func testNodeIdAvailableImmediately() {
        let node = SymNode(name: "test-immediate-\(UUID().uuidString)")
        XCTAssertFalse(node.nodeId.isEmpty, "nodeId should be set in constructor")
        XCTAssertEqual(node.nodeId.count, 36, "nodeId should be full UUID (36 chars with hyphens)")
    }

    func testNodeNameSet() {
        let name = "test-name-\(UUID().uuidString)"
        let node = SymNode(name: name)
        XCTAssertEqual(node.name, name)
    }

    func testDifferentNodesGetDifferentIds() {
        let a = SymNode(name: "test-a-\(UUID().uuidString)")
        let b = SymNode(name: "test-b-\(UUID().uuidString)")
        XCTAssertNotEqual(a.nodeId, b.nodeId)
    }

    func testStatusWhenNotRunning() {
        let node = SymNode(name: "test-status-\(UUID().uuidString)")
        let status = node.status()
        XCTAssertEqual(status.nodeId, node.nodeId)
        XCTAssertEqual(status.name, node.name)
        XCTAssertEqual(status.running, false)
        XCTAssertEqual(status.peerCount, 0)
        XCTAssertEqual(status.peers.count, 0)
    }

    func testSameNameSameNodeId() {
        let name = "test-persist-node-\(UUID().uuidString)"
        let a = SymNode(name: name)
        let b = SymNode(name: name)
        XCTAssertEqual(a.nodeId, b.nodeId, "same name should produce same nodeId")
    }
}
