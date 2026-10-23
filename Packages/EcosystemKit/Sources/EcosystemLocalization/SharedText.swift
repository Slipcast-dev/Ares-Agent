import Foundation

/// Общие UI keys: технические IDs и свободный текст не являются ключами перевода.
public enum SharedText: String, CaseIterable, Sendable {
    case accessIntro = "shared.accessIntro"
    case client = "shared.client"
    case shareMetadata = "shared.shareMetadata"
    case chooseAresFolder = "shared.chooseAresFolder"
    case allowedOperations = "shared.allowedOperations"
    case accessDuration = "shared.accessDuration"
    case oneHour = "shared.oneHour"
    case oneDay = "shared.oneDay"
    case oneWeek = "shared.oneWeek"
    case preparePermission = "shared.preparePermission"
    case refreshPermissions = "shared.refreshPermissions"
    case grantExpires = "shared.grantExpires"
    case revokeAccess = "shared.revokeAccess"
    case reviewRequest = "shared.reviewRequest"
    case externalPermissions = "shared.externalPermissions"
    case approveAccessTitle = "shared.approveAccessTitle"
    case aggregateDisclosure = "shared.aggregateDisclosure"
    case metadataDisclosure = "shared.metadataDisclosure"
    case folders = "shared.folders"
    case unavailableFolder = "shared.unavailableFolder"
    case operations = "shared.operations"
    case accessLimits = "shared.accessLimits"
    case accessExpiry = "shared.accessExpiry"
    case accessBoundary = "shared.accessBoundary"
    case cancel = "shared.cancel"
    case approveAccess = "shared.approveAccess"
    case legacyMCP = "shared.legacyMCP"
    case capEvents = "shared.capEvents"
    case capRoots = "shared.capRoots"
    case capScan = "shared.capScan"
    case capSearch = "shared.capSearch"
    case capVolume = "shared.capVolume"
    case capComputeDuplicates = "shared.capComputeDuplicates"
    case capFindDuplicates = "shared.capFindDuplicates"
    case capAudit = "shared.capAudit"
    case capSystemInfo = "shared.capSystemInfo"
    case capSystemMetrics = "shared.capSystemMetrics"
    case capDiagnostics = "shared.capDiagnostics"
    case capStorage = "shared.capStorage"
    case capDiagnosticsHistory = "shared.capDiagnosticsHistory"
    case capMonitorList = "shared.capMonitorList"
    case capMonitorGet = "shared.capMonitorGet"
    case capMonitorPreview = "shared.capMonitorPreview"
    case capMonitorPropose = "shared.capMonitorPropose"
    case capMonitorEnable = "shared.capMonitorEnable"
    case capMonitorDisable = "shared.capMonitorDisable"
    case capMonitorHistory = "shared.capMonitorHistory"
    case capRuleList = "shared.capRuleList"
    case capRuleGet = "shared.capRuleGet"
    case capRuleValidate = "shared.capRuleValidate"
    case capRulePropose = "shared.capRulePropose"
    case capRulePreview = "shared.capRulePreview"
    case capRuleRun = "shared.capRuleRun"
    case capRuleEnable = "shared.capRuleEnable"
    case capRuleDisable = "shared.capRuleDisable"
    case capRuleHistory = "shared.capRuleHistory"
    case partialData = "shared.partialData"
    case automationSaveFailed = "shared.automationSaveFailed"
    case notificationRequestFailed = "shared.notificationRequestFailed"
    case notificationSettingsManual = "shared.notificationSettingsManual"
    case loginSaveFailed = "shared.loginSaveFailed"
    case backgroundPaused = "shared.backgroundPaused"
    case backgroundEnabled = "shared.backgroundEnabled"
    case pauseBackground = "shared.pauseBackground"
    case pauseScope = "shared.pauseScope"
    case importantNotifications = "shared.importantNotifications"
    case allowNotifications = "shared.allowNotifications"
    case notificationConsent = "shared.notificationConsent"
    case notificationSender = "shared.notificationSender"
    case openNotifications = "shared.openNotifications"
    case backgroundUnavailable = "shared.backgroundUnavailable"
    case loginStartup = "shared.loginStartup"
    case disableLogin = "shared.disableLogin"
    case enableLogin = "shared.enableLogin"
    case serviceRegistered = "shared.serviceRegistered"
    case serviceUnregistered = "shared.serviceUnregistered"
    case loginDisableScope = "shared.loginDisableScope"
    case backgroundBoundary = "shared.backgroundBoundary"
    case eventsEmpty = "shared.eventsEmpty"
    case eventsReadOnly = "shared.eventsReadOnly"
    case agentEvents = "shared.agentEvents"
    case refreshBackground = "shared.refreshBackground"
    case backgroundNotifications = "shared.backgroundNotifications"
    case loginConfirmTitle = "shared.loginConfirmTitle"
    case enable = "shared.enable"
    case loginConfirmBody = "shared.loginConfirmBody"
    case notificationsAuthorized = "shared.notificationsAuthorized"
    case notificationsDenied = "shared.notificationsDenied"
    case notificationsUndetermined = "shared.notificationsUndetermined"
    case notificationsProvisional = "shared.notificationsProvisional"
    case notificationsUnavailable = "shared.notificationsUnavailable"
    case loginSystemDenied = "shared.loginSystemDenied"
    case enabled = "shared.enabled"
    case disabled = "shared.disabled"
    case service = "shared.service"
    case available = "shared.available"
    case needsAttention = "shared.needsAttention"
    case emergencyStop = "shared.emergencyStop"
    case admissionClosed = "shared.admissionClosed"
    case admissionOpen = "shared.admissionOpen"
    case backgroundActivity = "shared.backgroundActivity"
    case paused = "shared.paused"
    case backgroundOn = "shared.backgroundOn"
    case loginComponent = "shared.loginComponent"
    case blockedByMacOS = "shared.blockedByMacOS"
    case clientPermissions = "shared.clientPermissions"
    case grantCounts = "shared.grantCounts"
    case tasks = "shared.tasks"
    case taskCounts = "shared.taskCounts"
    case inboxEvents = "shared.inboxEvents"
    case eventSample = "shared.eventSample"
    case unavailableRefresh = "shared.unavailableRefresh"
    case cancellationSent = "shared.cancellationSent"
    case cancellationFailed = "shared.cancellationFailed"
    case stopSent = "shared.stopSent"
    case resumeSent = "shared.resumeSent"
    case actionUnconfirmed = "shared.actionUnconfirmed"
    case pauseUnconfirmed = "shared.pauseUnconfirmed"
    case pauseResult = "shared.pauseResult"
    case operationsScope = "shared.operationsScope"
    case snapshot = "shared.snapshot"
    case refreshingStatus = "shared.refreshingStatus"
    case firstConnection = "shared.firstConnection"
    case firstConnectionStep1 = "shared.firstConnectionStep1"
    case firstConnectionStep2 = "shared.firstConnectionStep2"
    case firstConnectionStep3 = "shared.firstConnectionStep3"
    case partialAgentResult = "shared.partialAgentResult"
    case refreshOverview = "shared.refreshOverview"
    case latestTasks = "shared.latestTasks"
    case tasksEmpty = "shared.tasksEmpty"
    case taskLine = "shared.taskLine"
    case requestCancellation = "shared.requestCancellation"
    case cancelTaskAccessibility = "shared.cancelTaskAccessibility"
    case stopThisAgent = "shared.stopThisAgent"
    case resumeAdmission = "shared.resumeAdmission"
    case emergencyScope = "shared.emergencyScope"
    case pauseVisible = "shared.pauseVisible"
    case pauseVisibleScope = "shared.pauseVisibleScope"
    case previewDiagnostics = "shared.previewDiagnostics"
    case statusHelp = "shared.statusHelp"
    case pauseConfirmTitle = "shared.pauseConfirmTitle"
    case pauseConfirmAction = "shared.pauseConfirmAction"
    case pauseConfirmBody = "shared.pauseConfirmBody"
    case stopConfirmTitle = "shared.stopConfirmTitle"
    case stop = "shared.stop"
    case stopConfirmBody = "shared.stopConfirmBody"
    case resumeConfirmTitle = "shared.resumeConfirmTitle"
    case resume = "shared.resume"
    case resumeConfirmBody = "shared.resumeConfirmBody"
    case diagnosticReport = "shared.diagnosticReport"
    case reportDisclosure = "shared.reportDisclosure"
    case close = "shared.close"
    case saveReport = "shared.saveReport"
    case reportSaved = "shared.reportSaved"
    case reportSaveFailed = "shared.reportSaveFailed"
    case taskQueued = "shared.taskQueued"
    case taskRunning = "shared.taskRunning"
    case taskWaitingApproval = "shared.taskWaitingApproval"
    case taskWaitingResource = "shared.taskWaitingResource"
    case taskCancelling = "shared.taskCancelling"
    case taskCompleted = "shared.taskCompleted"
    case taskPartial = "shared.taskPartial"
    case taskFailed = "shared.taskFailed"
    case taskCancelled = "shared.taskCancelled"
    case taskInterrupted = "shared.taskInterrupted"
    case taskRecoveryRequired = "shared.taskRecoveryRequired"
    case recovery = "shared.recovery"
    case recoveryIntro = "shared.recoveryIntro"
    case refreshRecovery = "shared.refreshRecovery"
    case recoveryEmpty = "shared.recoveryEmpty"
    case inspectRecovery = "shared.inspectRecovery"
    case executorActive = "shared.executorActive"
    case actionRecorded = "shared.actionRecorded"
    case noEffectRecorded = "shared.noEffectRecorded"
    case verifiedOutcome = "shared.verifiedOutcome"
    case outcomeUnchecked = "shared.outcomeUnchecked"
    case outcomeDone = "shared.outcomeDone"
    case outcomeNoEffect = "shared.outcomeNoEffect"
    case recoveryNotes = "shared.recoveryNotes"
    case recoveryFacts = "shared.recoveryFacts"
    case saveRecoveryResult = "shared.saveRecoveryResult"
    case recoveryConfirmTitle = "shared.recoveryConfirmTitle"
    case saveRecovery = "shared.saveRecovery"
    case recoveryConfirmBody = "shared.recoveryConfirmBody"
    case recoverySaved = "shared.recoverySaved"
    case hermesPlanned = "shared.hermesPlanned"
    case hermesDisclosure = "shared.hermesDisclosure"
    case aggregateType = "shared.aggregateType"
    case metadataType = "shared.metadataType"
    case originalContent = "shared.originalContent"
    case reportAgent = "shared.reportAgent"
    case reportSnapshot = "shared.reportSnapshot"
    case reportScope = "shared.reportScope"
    case reportSamples = "shared.reportSamples"
    case reportPrivacy = "shared.reportPrivacy"
    case notRefreshed = "shared.notRefreshed"
    case errorInvalidConfiguration = "shared.errorInvalidConfiguration"
    case errorInvalidRequest = "shared.errorInvalidRequest"
    case errorDenied = "shared.errorDenied"
    case errorUnavailable = "shared.errorUnavailable"
    case errorBusy = "shared.errorBusy"
    case errorConflict = "shared.errorConflict"
    case errorCancelled = "shared.errorCancelled"
    case errorDeadlineExceeded = "shared.errorDeadlineExceeded"
    case errorRecoveryRequired = "shared.errorRecoveryRequired"
    case errorRequiresGUI = "shared.errorRequiresGUI"
    case errorStaleSnapshot = "shared.errorStaleSnapshot"
    case errorOperationFailed = "shared.errorOperationFailed"

    var argumentKinds: [SharedArgument.Kind] {
        switch self {
        case .grantExpires: return [.text, .text]
        case .reviewRequest: return [.text]
        case .approveAccessTitle: return [.text]
        case .folders: return [.text]
        case .operations: return [.text]
        case .accessLimits: return [.count, .count, .count, .count, .count, .count]
        case .accessExpiry: return [.count, .text]
        case .notificationSender: return [.text]
        case .admissionClosed: return [.count, .count, .count]
        case .grantCounts: return [.count, .count]
        case .taskCounts: return [.count, .count]
        case .eventSample: return [.count]
        case .pauseResult: return [.count]
        case .snapshot: return [.text]
        case .taskLine: return [.text, .text]
        case .cancelTaskAccessibility: return [.text]
        case .inspectRecovery: return [.text, .text]
        case .reportAgent: return [.text]
        case .reportSnapshot: return [.text]
        default: return []
        }
    }
}

public enum SharedArgument: Sendable, Equatable {
    case text(String)
    case count(Int)
    enum Kind: Equatable { case text, count }
    var kind: Kind { switch self { case .text: return .text; case .count: return .count } }
    var formatted: String { switch self { case .text(let value): return value; case .count(let value): return value.formatted() } }
}

/// Модели сохраняют смысл и параметры, а не строку текущего языка. При смене
/// языка старый снимок можно показать заново без RPC, cancellation или retry.
public struct SharedMessage: Sendable, Equatable {
    public let key: SharedText
    let arguments: [SharedArgument]
    public init(_ key: SharedText, _ arguments: SharedArgument...) { self.key = key; self.arguments = arguments }
    public func localized(using localization: AgentLocalization) -> String {
        localization.render(key, arguments: arguments)
    }
}

public extension AgentLocalization {
    func text(_ key: SharedText) -> String { render(key, arguments: []) }
    func message(_ key: SharedText, _ arguments: SharedArgument...) -> String { render(key, arguments: arguments) }

    /// Все resource placeholders — %@; число/тип аргументов проверяются до
    /// NSString formatter. Пользовательский '%' остаётся данными, не форматом.
    internal func render(_ key: SharedText, arguments: [SharedArgument]) -> String {
        guard key.argumentKinds == arguments.map(\.kind),
              let format = table?.localizedString(forKey: key.rawValue, value: nil, table: "Shared"),
              format != key.rawValue else { return "Localization resource unavailable." }
        return String(format: format, locale: Locale.current,
                      arguments: arguments.map { $0.formatted as CVarArg })
    }
}

/// Snapshot создаётся именно при открытии подтверждения. Живой Environment
/// не меняет язык уже показанного решения; пользователь сначала закрывает его.
public struct ConfirmationLanguage: Sendable {
    public let language: AgentLanguage
    public init(language: AgentLanguage) { self.language = language }
    public var localization: AgentLocalization { AgentLocalization(language: language) }
}
