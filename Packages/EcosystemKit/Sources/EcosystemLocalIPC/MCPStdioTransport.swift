import Foundation

/// Читатель stdio работает на основном потоке отдельного executable, а actor
/// принимает только готовые ограниченные кадры. Ожидание доменной операции
/// не останавливает чтение ping/уведомлений отмены из того же соединения.
public enum MCPStdioTransport {
    public static func run(serverName: String, serverVersion: String, tools: [[String: Any]],
                           experimental: [String: Any], handler: @escaping MCPProtocolSession.Handler) {
        guard let definitions = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]),
              let features = try? JSONSerialization.data(withJSONObject: experimental, options: [.sortedKeys]) else { return }
        let writer = Writer()
        let session = MCPProtocolSession(serverName: serverName, serverVersion: serverVersion,
            tools: definitions, experimental: features, handler: handler, output: { writer.write($0) })
        let input = BoundedMCPInput()
        while let record = input.next() {
            switch record {
            case .success(let data):
                // Ждём только admission; сама handler Task продолжает независимо.
                let admitted = DispatchSemaphore(value: 0)
                Task { await session.receive(data); admitted.signal() }
                admitted.wait()
            case .failure:
                writer.write(Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"MCP_REQUEST_LIMIT"}}"#.utf8))
            }
        }
        // EOF не отменяет уже принятые durable jobs. Для пакетных клиентов
        // даём ответам закончиться; таймер сеанса ограничивает это ожидание.
        let drained = DispatchSemaphore(value: 0)
        Task { await session.finish(); drained.signal() }
        drained.wait()
    }
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        func write(_ data: Data) {
            // Oversize-ошибка читателя и ответ actor могут приходить одновременно.
            lock.lock(); defer { lock.unlock() }
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
