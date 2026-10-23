import AppKit
import SwiftUI
import EcosystemLocalIPC
import EcosystemLocalization

/// Одна модель на приложение, общая для его окон, но не для второго агента.
@MainActor public final class LocalLanguageModel: ObservableObject {
    typealias Transport = @Sendable (String, LocalLanguageChange?) async throws -> LocalLanguageStatus
    @Published public private(set) var state: LocalLanguageStatus
    @Published public private(set) var loaded = false
    @Published public private(set) var busy = false
    @Published private(set) var issue: AgentText?
    private let transport: Transport

    init(transport: @escaping Transport) {
        self.transport = transport
        state = LocalLanguageStatus(preference: .system, effectiveLanguage: AgentLanguage.resolve(preferredLanguages: Locale.preferredLanguages))
    }
    public convenience init(client: Result<LocalRPCClient, Error>?) {
        self.init { operation, change in
            guard let client else { throw LocalRuntimeFailure.unavailable }
            let rpc = try client.get()
            if let change { return try await rpc.call(operation, change, as: LocalLanguageStatus.self) }
            return try await rpc.call(operation, LocalEmpty(), as: LocalLanguageStatus.self)
        }
    }
    public func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { state = try await transport("language.get", nil); loaded = true; issue = nil }
        catch { loaded = false; issue = .languageUnavailable }
    }
    public func select(_ preference: AgentLanguagePreference) async {
        guard loaded, !busy, preference != state.preference else { return }
        busy = true; defer { busy = false }
        do {
            state = try await transport("language.set", LocalLanguageChange(preference: preference))
            issue = nil
        } catch {
            // Ответ мог потеряться после atomic write. Повторяем только чтение,
            // не запись и тем более не доменную задачу. До сверки Picker блокируется.
            loaded = false; issue = .languageUnconfirmed
            if let reconciled = try? await transport("language.get", nil) { state = reconciled; loaded = true }
        }
    }
}

private struct LanguageModelKey: EnvironmentKey { static let defaultValue: LocalLanguageModel? = nil }
private struct LanguageValueKey: EnvironmentKey {
    static let defaultValue = AgentLanguage.resolve(preferredLanguages: Locale.preferredLanguages)
}
public extension EnvironmentValues {
    var localLanguageModel: LocalLanguageModel? {
        get { self[LanguageModelKey.self] }
        set { self[LanguageModelKey.self] = newValue }
    }
    var agentLanguage: AgentLanguage {
        get { self[LanguageValueKey.self] }
        set { self[LanguageValueKey.self] = newValue }
    }
}

/// Меняем только язык встроенного текста, не Environment.locale: регион,
/// календарь/часовой пояс и формат пользовательских чисел остаются прежними.
private struct LanguageContext: ViewModifier {
    @ObservedObject var model: LocalLanguageModel
    func body(content: Content) -> some View {
        content.environment(\.localLanguageModel, model)
            .environment(\.agentLanguage, model.state.effectiveLanguage)
            .task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refresh() }
            }
    }
}
public extension View {
    func agentLanguageContext(_ model: LocalLanguageModel) -> some View { modifier(LanguageContext(model: model)) }
}

public struct LocalLanguageSection: View {
    @ObservedObject private var model: LocalLanguageModel
    public init(model: LocalLanguageModel) { self.model = model }
    public var body: some View {
        let l10n = AgentLocalization(language: model.state.effectiveLanguage)
        Section {
            Picker(l10n.text(.languageChoice), selection: Binding(
                get: { model.state.preference }, set: { choice in Task { await model.select(choice) } }
            )) {
                ForEach(AgentLanguagePreference.allCases, id: \.rawValue) { value in
                    Text(value.nativeTitle).tag(value)
                }
            }
            .disabled(!model.loaded || model.busy)
            .accessibilityIdentifier("settings.language")
            Text(l10n.text(.languageScope)).font(.caption).foregroundStyle(.secondary)
            if let issue = model.issue {
                Text(l10n.text(issue)).font(.caption).foregroundStyle(.secondary)
            }
            Button(l10n.text(.languageRetry)) { Task { await model.refresh() } }
                .disabled(model.busy).accessibilityIdentifier("settings.language.refresh")
        } header: { Label(l10n.text(.languageTitle), systemImage: "globe") }
    }
}
