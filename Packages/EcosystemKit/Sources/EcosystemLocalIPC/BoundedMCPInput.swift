import Darwin
import Foundation

public enum MCPInputFailure: Error { case oversized }
/// Лимит применяется до JSON parsing и до накопления всей строки. Большой
/// запрос отбрасывается до newline, следующий валидный запрос не теряется.
public final class BoundedMCPInput {
    private let stream: FileHandle
    private let maximumBytes: Int
    private var pending = Data()
    private var line = Data()
    private var discarding = false
    private var ended = false
    private var buffer = [UInt8](repeating: 0, count: 32_768)
    public init(stream: FileHandle = .standardInput, maximumBytes: Int = 1_048_576) {
        self.stream = stream; self.maximumBytes = max(1, min(maximumBytes, 1_048_576))
    }
    public func next() -> Result<Data, MCPInputFailure>? {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                append(pending.prefix(upTo: newline)); pending.removeSubrange(pending.startIndex...newline)
                return finishLine()
            }
            if !pending.isEmpty { append(pending); pending.removeAll(keepingCapacity: true) }
            if ended { return line.isEmpty && !discarding ? nil : finishLine() }
            // FileHandle.read(upToCount:) на macOS может ждать заполнения
            // буфера/EOF. POSIX read возвращает уже доступные bytes и позволяет
            // ответить SDK, который держит stdin открытым между запросами.
            let descriptor = stream.fileDescriptor
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { pending = Data(buffer.prefix(count)) }
            else if count < 0 && errno == EINTR { continue }
            else { ended = true }
        }
    }
    private func append(_ data: Data) {
        guard !discarding else { return }
        if line.count + data.count > maximumBytes { line.removeAll(keepingCapacity: true); discarding = true }
        else { line.append(data) }
    }
    private func finishLine() -> Result<Data, MCPInputFailure> {
        let result: Result<Data, MCPInputFailure> = discarding ? .failure(.oversized) : .success(line)
        line.removeAll(keepingCapacity: true); discarding = false; return result
    }
}
