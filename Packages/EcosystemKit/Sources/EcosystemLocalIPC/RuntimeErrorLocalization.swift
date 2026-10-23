import EcosystemLocalization

extension LocalRuntimeFailure: RuntimeLocalizedError {
    /// Перевод по конечному typed case, без угадывания происхождения строки.
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .invalidConfiguration: return RuntimeMessage("error.LocalRuntimeFailure.invalidConfiguration")
        case .invalidRequest: return RuntimeMessage("error.LocalRuntimeFailure.invalidRequest")
        case .denied: return RuntimeMessage("error.LocalRuntimeFailure.denied")
        case .unavailable: return RuntimeMessage("error.LocalRuntimeFailure.unavailable")
        case .busy: return RuntimeMessage("error.LocalRuntimeFailure.busy")
        case .conflict: return RuntimeMessage("error.LocalRuntimeFailure.conflict")
        case .cancelled: return RuntimeMessage("error.LocalRuntimeFailure.cancelled")
        case .deadlineExceeded: return RuntimeMessage("error.LocalRuntimeFailure.deadlineExceeded")
        case .recoveryRequired: return RuntimeMessage("error.LocalRuntimeFailure.recoveryRequired")
        case .requiresGUI: return RuntimeMessage("error.LocalRuntimeFailure.requiresGUI")
        case .staleSnapshot: return RuntimeMessage("error.LocalRuntimeFailure.staleSnapshot")
        case .operationFailed: return RuntimeMessage("error.LocalRuntimeFailure.operationFailed")
        }
    }
}

extension InstalledRuntimeBootstrap.Failure: RuntimeLocalizedError {
    /// Перевод по конечному typed case, без угадывания происхождения строки.
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .invalidProfile: return RuntimeMessage("error.InstalledRuntimeBootstrap.Failure.invalidProfile")
        case .changedApplication: return RuntimeMessage("error.InstalledRuntimeBootstrap.Failure.changedApplication")
        case .systemDisabled: return RuntimeMessage("error.InstalledRuntimeBootstrap.Failure.systemDisabled")
        case .commandFailed: return RuntimeMessage("error.InstalledRuntimeBootstrap.Failure.commandFailed")
        }
    }
}

extension InstalledRuntimeMaintenance.Failure: RuntimeLocalizedError {
    /// Перевод по конечному typed case, без угадывания происхождения строки.
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .busy: return RuntimeMessage("error.InstalledRuntimeMaintenance.Failure.busy")
        case .changedData: return RuntimeMessage("error.InstalledRuntimeMaintenance.Failure.changedData")
        case .damagedBackup: return RuntimeMessage("error.InstalledRuntimeMaintenance.Failure.damagedBackup")
        case .interrupted: return RuntimeMessage("error.InstalledRuntimeMaintenance.Failure.interrupted")
        case .incompatible: return RuntimeMessage("error.InstalledRuntimeMaintenance.Failure.incompatible")
        }
    }
}
