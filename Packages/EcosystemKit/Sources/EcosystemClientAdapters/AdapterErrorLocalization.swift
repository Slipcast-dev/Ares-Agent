import EcosystemLocalization

extension CodexAdapterError: RuntimeLocalizedError {
    /// Перевод по конечному typed case, без угадывания происхождения строки.
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .unsafePath: return RuntimeMessage("error.CodexAdapterError.unsafePath")
        case .conflict: return RuntimeMessage("error.CodexAdapterError.conflict")
        case .stalePlan: return RuntimeMessage("error.CodexAdapterError.stalePlan")
        case .invalidConfiguration: return RuntimeMessage("error.CodexAdapterError.invalidConfiguration")
        case .cliUnavailable: return RuntimeMessage("error.CodexAdapterError.cliUnavailable")
        case .cliValidationFailed: return RuntimeMessage("error.CodexAdapterError.cliValidationFailed")
        case .recoveryRequired: return RuntimeMessage("error.CodexAdapterError.recoveryRequired")
        case .ioFailure: return RuntimeMessage("error.CodexAdapterError.ioFailure")
        }
    }
}

extension HarnessAdapterError: RuntimeLocalizedError {
    /// Перевод по конечному typed case, без угадывания происхождения строки.
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .unsafePath: return RuntimeMessage("error.HarnessAdapterError.unsafePath")
        case .conflict: return RuntimeMessage("error.HarnessAdapterError.conflict")
        case .stalePlan: return RuntimeMessage("error.HarnessAdapterError.stalePlan")
        case .invalidConfiguration: return RuntimeMessage("error.HarnessAdapterError.invalidConfiguration")
        case .unsupportedVersion: return RuntimeMessage("error.HarnessAdapterError.unsupportedVersion")
        case .recoveryRequired: return RuntimeMessage("error.HarnessAdapterError.recoveryRequired")
        case .ioFailure: return RuntimeMessage("error.HarnessAdapterError.ioFailure")
        }
    }
}
