import SwiftUI
import EcosystemLocalization
import UniformTypeIdentifiers
import EcosystemContracts
import EcosystemLocalIPC

/// Сохранение разрешает только явное действие в системной панели. Закрытие
/// preview ничего не записывает и ничего не отправляет во внешнюю сеть.
private struct DiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

public struct LocalOperationsSection: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AgentLocalization { AgentLocalization(language: language) }
    @StateObject private var model: LocalOperationsModel
    @State private var preview: String?
    @State private var exporting = false
    @State private var pauseLanguage = ConfirmationLanguage(language: .english)
    @State private var emergencyLanguage = ConfirmationLanguage(language: .english)
    @State private var resumeLanguage = ConfirmationLanguage(language: .english)
    @State private var confirmingPause = false
    @State private var confirmingEmergency = false
    @State private var confirmingResume = false
    @State private var saveMessage: SharedText?

    public init(client: Result<LocalRPCClient, Error>) {
        _model = StateObject(wrappedValue: LocalOperationsModel(client: client))
    }
    init(model: LocalOperationsModel) { _model = StateObject(wrappedValue: model) }
    public var body: some View {
        Section {
            Text(l10n.text(.operationsScope))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.components) { component in
                VStack(alignment: .leading, spacing: 3) {
                    Label(l10n.text(component.title), systemImage: component.available && !component.needsAttention ? "checkmark.circle" : "exclamationmark.triangle")
                    Text(component.value.localized(using: l10n)).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("operations." + component.id)
            }
            if let date = model.refreshedAt {
                Text(l10n.message(.snapshot, .text(date.formatted(date: .abbreviated, time: .standard))))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.busy { ProgressView(l10n.text(.refreshingStatus)) }
            DisclosureGroup(l10n.text(.firstConnection)) {
                Text(l10n.text(.firstConnectionStep1))
                Text(l10n.text(.firstConnectionStep2))
                Text(l10n.text(.firstConnectionStep3))
                Text(l10n.text(.partialAgentResult))
            }
            Button(l10n.text(.refreshOverview)) { Task { await model.refresh() } }
                .disabled(model.busy).accessibilityIdentifier("operations.refresh")
            DisclosureGroup(l10n.text(.latestTasks)) {
                if model.tasks.isEmpty { Text(l10n.text(.tasksEmpty)) }
                ForEach(model.tasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.message(.taskLine, .text(String(task.id.uuidString.prefix(8))), .text(Self.statusTitle(task.status, language: language))))
                            .textSelection(.enabled)
                        if !task.status.isTerminal {
                            Button(l10n.text(.requestCancellation)) { Task { await model.cancel(task) } }
                                .disabled(model.busy)
                                .accessibilityLabel(l10n.message(.cancelTaskAccessibility, .text(String(task.id.uuidString.prefix(8)))))
                        }
                    }
                }
            }.accessibilityIdentifier("operations.tasks")
            Button(l10n.text(.stopThisAgent), role: .destructive) { emergencyLanguage = ConfirmationLanguage(language: language); confirmingEmergency = true }
                .disabled(model.busy).accessibilityIdentifier("operations.emergencyStop")
            Button(l10n.text(.resumeAdmission)) { resumeLanguage = ConfirmationLanguage(language: language); confirmingResume = true }
                .disabled(model.busy || model.emergency?.stopped != true)
                .accessibilityIdentifier("operations.emergencyResume")
            Text(l10n.text(.emergencyScope))
                .font(.caption).foregroundStyle(.secondary)
            Button(l10n.text(.pauseVisible), role: .destructive) { pauseLanguage = ConfirmationLanguage(language: language); confirmingPause = true }
                .disabled(model.busy || model.refreshedAt == nil)
                .accessibilityIdentifier("operations.pauseCancel")
            Text(l10n.text(.pauseVisibleScope))
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.actionMessage { Text(message.localized(using: l10n)).accessibilityIdentifier("operations.result") }
            Button(l10n.text(.previewDiagnostics)) { preview = model.report(language: language); saveMessage = nil }
                .disabled(model.busy || model.refreshedAt == nil)
                .accessibilityIdentifier("operations.preview")
            if let saveMessage { Text(l10n.text(saveMessage)).font(.caption) }
        } header: { Label(l10n.text(.statusHelp), systemImage: "heart.text.square") }
        .task { await model.refresh() }
        .alert(pauseLanguage.localization.text(.pauseConfirmTitle), isPresented: $confirmingPause) {
            Button(pauseLanguage.localization.text(.cancel), role: .cancel) {}
            Button(pauseLanguage.localization.text(.pauseConfirmAction), role: .destructive) { Task { await model.pauseAndCancelVisible() } }
                .accessibilityIdentifier("operations.pauseCancel.confirm")
        } message: {
            Text(pauseLanguage.localization.text(.pauseConfirmBody))
        }
        .alert(emergencyLanguage.localization.text(.stopConfirmTitle), isPresented: $confirmingEmergency) {
            Button(emergencyLanguage.localization.text(.cancel), role: .cancel) {}
            Button(emergencyLanguage.localization.text(.stop), role: .destructive) { Task { await model.setEmergencyStop(true) } }
                .accessibilityIdentifier("operations.emergencyStop.confirm")
        } message: {
            Text(emergencyLanguage.localization.text(.stopConfirmBody))
        }
        .alert(resumeLanguage.localization.text(.resumeConfirmTitle), isPresented: $confirmingResume) {
            Button(resumeLanguage.localization.text(.cancel), role: .cancel) {}
            Button(resumeLanguage.localization.text(.resume)) { Task { await model.setEmergencyStop(false) } }
                .accessibilityIdentifier("operations.emergencyResume.confirm")
        } message: {
            Text(resumeLanguage.localization.text(.resumeConfirmBody))
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n.text(.diagnosticReport)).font(.headline)
                if let saveMessage { Text(l10n.text(saveMessage)).font(.caption) }
                Text(l10n.text(.reportDisclosure))
                ScrollView { Text(preview ?? "").font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .accessibilityIdentifier("operations.preview.text")
                HStack {
                    Button(l10n.text(.close), role: .cancel) { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(l10n.text(.saveReport)) { exporting = true }
                        .accessibilityIdentifier("operations.export")
                }
            }.padding().frame(minWidth: 400, idealWidth: 580, minHeight: 340, idealHeight: 460)
            .fileExporter(isPresented: $exporting, document: DiagnosticsDocument(text: preview ?? ""),
                          contentType: .plainText, defaultFilename: "agent-diagnostics") { result in
                switch result {
                case .success: saveMessage = .reportSaved
                case .failure: saveMessage = .reportSaveFailed
                }
            }
        }
    }
    static func statusTitle(_ status: TaskStatus, language: AgentLanguage = .russian) -> String {
        let l10n = AgentLocalization(language: language)
        switch status {
        case .queued: return l10n.text(.taskQueued)
        case .running: return l10n.text(.taskRunning)
        case .waitingForApproval: return l10n.text(.taskWaitingApproval)
        case .waitingForResource: return l10n.text(.taskWaitingResource)
        case .cancelling: return l10n.text(.taskCancelling)
        case .completed: return l10n.text(.taskCompleted)
        case .partial: return l10n.text(.taskPartial)
        case .failed: return l10n.text(.taskFailed)
        case .cancelled: return l10n.text(.taskCancelled)
        case .interrupted: return l10n.text(.taskInterrupted)
        case .recoveryRequired: return l10n.text(.taskRecoveryRequired)
        }
    }
}
