import XCTest
@testable import EcosystemLocalIPC

/// Сборщик использует блокировку: callback вывода синхронный и вызывается actor.
private final class MCPOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; storage.append(data) }
    var values: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return storage.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}

private actor MCPGate {
    var waiting: [CheckedContinuation<Void, Never>] = []
    var open = false
    func wait() async { if !open { await withCheckedContinuation { waiting.append($0) } } }
    func release() { open = true; let all = waiting; waiting.removeAll(); for item in all { item.resume() } }
}

final class MCPProtocolSessionTests: XCTestCase {
    private let tools = Data(#"[{"name":"test","inputSchema":{"type":"object"},"outputSchema":{"type":"object"}}]"#.utf8)
    private let toolResult = Data(#"{"content":[{"type":"text","text":"ok"}],"structuredContent":{"ok":true},"isError":false}"#.utf8)
    private func session(_ output: MCPOutput, timeout: TimeInterval = 310,
                         handler: MCPProtocolSession.Handler? = nil) -> MCPProtocolSession {
        let result = toolResult
        return MCPProtocolSession(serverName: "test", serverVersion: "1", tools: tools,
                                  experimental: Data("{}".utf8), requestTimeout: timeout,
                                  handler: handler ?? { _, _, _ in result }, output: { output.append($0) })
    }
    private func send(_ session: MCPProtocolSession, _ value: String) async { await session.receive(Data(value.utf8)) }
    private func initialize(_ session: MCPProtocolSession, version: String = "2025-11-25") async {
        await send(session, #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":""# + version + #"","clientInfo":{"name":"test","version":"1"},"capabilities":{}}}"#)
        await send(session, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }
    private func errorCode(_ value: [String: Any]) -> Int? { (value["error"] as? [String: Any])?["code"] as? Int }

    func testStrictEnvelopesAndSilentNotifications() async {
        let output = MCPOutput(), session = session(MCPOutput())
        await session.close()
        let target = self.session(output)
        for source in ["{", "[]", #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
                       #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
                       #"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#] { await send(target, source) }
        XCTAssertEqual(output.values.compactMap(errorCode), [-32700, -32600, -32600, -32600, -32602])
        for source in [#"{"method":false}"#, #"{"jsonrpc":"2.0","method":"unknown"}"#,
                       #"{"jsonrpc":"2.0","method":"ping","params":[]}"#] { await send(target, source) }
        XCTAssertEqual(output.values.count, 5)
        await target.close()
    }

    func testOversizedIdentifierIsRejectedWithoutPoisoningSession() async throws {
        let output = MCPOutput(), target = session(output)
        let request: [String: Any] = ["jsonrpc": "2.0", "id": String(repeating: "x", count: 513), "method": "ping"]
        await target.receive(try JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(errorCode(output.values.last!), -32600)
        await send(target, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertNotNil(output.values.last?["result"])
        await target.close()
    }

    func testInvalidNestedArgumentsCannotEnterHandler() async {
        let output = MCPOutput()
        let definitions = Data(#"[{"name":"test","inputSchema":{"type":"object","required":["count"],"additionalProperties":false,"properties":{"count":{"type":"integer","minimum":1}}}}]"#.utf8)
        let target = MCPProtocolSession(serverName: "test", serverVersion: "1", tools: definitions,
            experimental: Data("{}".utf8), handler: { _, _, _ in
                XCTFail("Неверные аргументы не должны вызывать доменную операцию")
                return Data()
            }, output: { output.append($0) })
        await initialize(target)
        for (index, arguments) in ["{}", #"{"count":true}"#, #"{"count":1,"approved":true}"#].enumerated() {
            await send(target, #"{"jsonrpc":"2.0","id":"invalid-"# + String(index) + #"","method":"tools/call","params":{"name":"test","arguments":"# + arguments + "}}")
            XCTAssertEqual(errorCode(output.values.last!), -32602)
        }
        await target.finish()
    }

    func testInitializationAndTypedIDs() async {
        let output = MCPOutput(), target = session(output)
        await send(target, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        await send(target, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#)
        await initialize(target, version: "future")
        await send(target, #"{"jsonrpc":"2.0","id":"0","method":"ping"}"#)
        await send(target, #"{"jsonrpc":"2.0","id":0,"method":"ping"}"#)
        await send(target, #"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}"#)
        XCTAssertEqual(errorCode(output.values[0]), -32000)
        XCTAssertEqual(errorCode(output.values[1]), -32602)
        XCTAssertEqual((output.values[2]["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNotNil(output.values[3]["result"])
        XCTAssertEqual(errorCode(output.values[4]), -32600)
        XCTAssertEqual(errorCode(output.values[5]), -32600)
        await target.close()
    }

    func testInitializedNotificationRequiredAndUnknownMethods() async {
        let output = MCPOutput(), target = session(output)
        await send(target, #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1"},"capabilities":{}}}"#)
        await send(target, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        XCTAssertEqual(errorCode(output.values.last!), -32000)
        await send(target, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await send(target, #"{"jsonrpc":"2.0","id":2,"method":"unknown"}"#)
        XCTAssertEqual(errorCode(output.values.last!), -32601)
        await send(target, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"missing","arguments":{}}}"#)
        XCTAssertEqual(errorCode(output.values.last!), -32602)
        await send(target, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test","approved":true}}"#)
        XCTAssertEqual(errorCode(output.values.last!), -32602)
        await target.close()
    }

    func testVersionFallbackPreservesTextAndNewStructuredContent() async {
        for version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"] {
            let output = MCPOutput(), target = session(output)
            await initialize(target, version: version)
            await send(target, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            await send(target, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test","arguments":{}}}"#)
            await target.finish()
            let definitions = (output.values[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            let result = output.values.last!["result"] as? [String: Any]
            XCTAssertEqual(definitions?.first?["outputSchema"] != nil, version >= "2025-06-18")
            XCTAssertEqual(result?["structuredContent"] != nil, version >= "2025-06-18")
            XCTAssertEqual((result?["content"] as? [[String: Any]])?.first?["text"] as? String, "ok")
        }
    }

    func testConcurrentCallBoundAndPingNotBlocked() async {
        let output = MCPOutput(), gate = MCPGate(), result = toolResult
        let target = session(output, handler: { _, _, _ in await gate.wait(); return result })
        await initialize(target)
        for id in 1...9 { await send(target, "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"test\"}}") }
        await send(target, #"{"jsonrpc":"2.0","id":10,"method":"ping"}"#)
        XCTAssertEqual(errorCode(output.values.first { $0["id"] as? Int == 9 }!), -32000)
        XCTAssertNotNil(output.values.first { $0["id"] as? Int == 10 }?["result"])
        await gate.release(); await target.finish()
        XCTAssertEqual(output.values.filter { $0["result"] != nil }.count, 10)
    }

    func testCancellationSuppressesResponseWithoutReusingID() async {
        let output = MCPOutput(), gate = MCPGate(), result = toolResult
        let target = session(output, handler: { _, _, _ in await gate.wait(); return result })
        await initialize(target)
        await send(target, #"{"jsonrpc":"2.0","id":"work","method":"tools/call","params":{"name":"test"}}"#)
        await send(target, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"work"}}"#)
        await gate.release(); await target.finish()
        XCTAssertEqual(output.values.count, 1)
        let secondOutput = MCPOutput(), second = session(secondOutput)
        await initialize(second)
        await send(second, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        await send(second, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(errorCode(secondOutput.values.last!), -32600)
        await second.close()
    }

    func testTimeoutAndCloseBoundUncooperativeHandler() async {
        let output = MCPOutput(), gate = MCPGate(), result = toolResult
        let target = session(output, timeout: 0.01, handler: { _, _, _ in await gate.wait(); return result })
        await initialize(target)
        await send(target, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"test"}}"#)
        await target.finish()
        XCTAssertEqual(errorCode(output.values.last!), -32000)
        await gate.release()
        let other = session(MCPOutput(), handler: { _, _, _ in await gate.wait(); return result })
        await initialize(other)
        await other.close(); await other.finish()
    }

    func testProgressTokenRateLimitAndOversizeOutput() async {
        let output = MCPOutput(), result = toolResult
        let target = session(output, handler: { _, _, context in
            await context.progress(1, 10, "Работа")
            await context.progress(2, 10, "Работа")
            await context.progress(0, 10, "Работа")
            return result
        })
        await initialize(target)
        await send(target, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"test","_meta":{"progressToken":0}}}"#)
        await target.finish()
        let progress = output.values.filter { $0["method"] as? String == "notifications/progress" }
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual((progress.first?["params"] as? [String: Any])?["progressToken"] as? Int, 0)
        let oversized = try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": String(repeating: "x", count: 1_048_576)]]])
        let otherOutput = MCPOutput(), other = session(otherOutput, handler: { _, _, _ in oversized })
        await initialize(other)
        await send(other, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"test"}}"#)
        await other.finish()
        XCTAssertEqual(errorCode(otherOutput.values.last!), -32603)
    }

    func testLifetimeRequestBudget() async {
        let output = MCPOutput(), target = session(output)
        for id in 0...4096 { await send(target, "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\"}") }
        XCTAssertEqual(output.values.filter { $0["result"] != nil }.count, 4096)
        XCTAssertEqual(errorCode(output.values.last!), -32000)
        await target.close()
    }
}
