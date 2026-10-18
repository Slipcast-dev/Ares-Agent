import Foundation
import Darwin

/// Межпроцессная блокировка защищает действия при одновременном запуске GUI и
/// будущего фонового worker. flock освобождается ядром даже после аварии процесса.
public struct RuleExecutionLock: Sendable {
    let url: URL
    public init(url: URL) { self.url = url }
    public func acquire() throws -> Int32 {
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RuleExecutionError.accessRevoked }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw RuleExecutionError.busy }
        return descriptor
    }
    public func release(_ descriptor: Int32) { flock(descriptor, LOCK_UN); close(descriptor) }
}
