import Foundation

/// Процессная диагностика выполняется вне MainActor. Ограничение времени
/// гарантирует возврат управления даже при зависшем или повреждённом helper.
enum MCPHealthCheck {
    static func run(helperURL: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { return false }
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = helperURL
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let handshake = """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ares-health-check","version":"1"}}}
                {"jsonrpc":"2.0","method":"notifications/initialized"}
                {"jsonrpc":"2.0","id":2,"method":"tools/list"}

                """
                try input.fileHandleForWriting.write(contentsOf: Data(handshake.utf8))
                try input.fileHandleForWriting.close()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning && Date() < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard !process.isRunning else {
                    // Не ждём завершения после terminate: зависший helper не
                    // должен удерживать ни кнопку, ни жизненный цикл окна.
                    process.terminate()
                    return false
                }
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                let replies = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                }
                guard process.terminationStatus == 0, replies.count == 2,
                      let initialization = replies.first?["result"] as? [String: Any],
                      let server = initialization["serverInfo"] as? [String: Any], server["name"] as? String == "ares",
                      let response = replies.first(where: { $0["id"] as? Int == 2 }),
                      let result = response["result"] as? [String: Any],
                      let tools = result["tools"] as? [[String: Any]] else { return false }
                return tools.contains { $0["name"] as? String == "file.list_roots" }
            } catch {
                if process.isRunning { process.terminate() }
                return false
            }
        }.value
    }
}
