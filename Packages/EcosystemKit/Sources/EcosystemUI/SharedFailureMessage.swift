import EcosystemLocalIPC
import EcosystemLocalization

extension SharedMessage {
    /// Переводим известный код на границе GUI. Исходное errorDescription и
    /// сохранённые сообщения runtime не переписываются и не используются как key.
    static func failure(_ failure: LocalRuntimeFailure) -> SharedMessage {
        let key: SharedText
        switch failure {
        case .invalidConfiguration: key = .errorInvalidConfiguration
        case .invalidRequest: key = .errorInvalidRequest
        case .denied: key = .errorDenied
        case .unavailable: key = .errorUnavailable
        case .busy: key = .errorBusy
        case .conflict: key = .errorConflict
        case .cancelled: key = .errorCancelled
        case .deadlineExceeded: key = .errorDeadlineExceeded
        case .recoveryRequired: key = .errorRecoveryRequired
        case .requiresGUI: key = .errorRequiresGUI
        case .staleSnapshot: key = .errorStaleSnapshot
        case .operationFailed: key = .errorOperationFailed
        }
        return SharedMessage(key)
    }
}
