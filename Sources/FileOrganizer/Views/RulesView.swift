import SwiftUI
import FileOrganizerCore
import EcosystemLocalization
import EcosystemUI
import EcosystemLocalIPC

struct RulesView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }
    @StateObject private var model: RulesViewModel
    @State private var deleting: AutomationRule?
    @State private var deletionLanguage = ConfirmationLanguage(language: .russian)
    private var deletionL10n: AresLocalization { AresLocalization(language: deletionLanguage.language) }
    @State private var historyRule: AutomationRule?
    init(container: AppContainer) { _model = StateObject(wrappedValue: RulesViewModel(container: container)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.text("Событие → условия → действия")).font(.title2.bold())
                Spacer()
                Button(l10n.text("Создать"), systemImage: "plus") { var rule = AutomationRule(); rule.name = l10n.text("Новое правило"); model.editor = rule }
                    .disabled(model.roots.isEmpty)
            }
            Text(l10n.text("В локальном режиме включённые правила выполняет отдельный агент. Новое правило выключено; «Проверить» показывает совпадения без изменения файлов."))
                .font(.caption).foregroundStyle(.secondary)
            if model.isBusy { HStack { ProgressView(); Text(l10n.text("Выполнение…")); Button(l10n.text("Отменить")) { model.cancel() } } }
            if model.container.isLocalRuntimeClient {
                Button(l10n.text("Обновить запросы подтверждения")) { Task { await model.load() } }
            }
            List {
                if !model.pendingPlans.isEmpty {
                    Section(l10n.text("Запросы локального подтверждения")) {
                        ForEach(model.pendingPlans) { plan in
                            Button(l10n.format("Проверить план: %@", plan.name)) { model.review(plan) }
                                .accessibilityIdentifier("rule.review." + plan.kind)
                        }
                    }
                }
                if model.rules.isEmpty { Text(l10n.text("Создайте первое правило. Сначала добавьте папку в «Обзоре».")).foregroundStyle(.secondary) }
                ForEach(model.rules) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { var updated = rule; updated.enabled = $0; model.requestEnabled(rule, enabled: updated.enabled) }))
                            .font(.headline)
                        Text(l10n.format("%@ · %@", l10n.text(rule.event.title), model.roots.first(where: { $0.id == rule.rootID })?.displayName ?? l10n.text("Доступ к папке отсутствует")))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(rule.actions.map { l10n.text($0.kind.title) }.joined(separator: " → ")).font(.caption)
                        if let last = model.runs.first(where: { $0.ruleID == rule.id }) {
                            Text(l10n.format("Последний запуск: %@ · %@ · файлов: %@", last.createdAt.formatted(), l10n.ruleStatus(last.status), last.matchedCount.formatted())).font(.caption2)
                        }
                        HStack {
                            Button(l10n.text("Изменить")) { model.editor = rule }
                            Button(l10n.text("Дублировать")) { model.duplicate(rule, suffix: l10n.text(" — копия")) }
                            Button(l10n.text("Проверить")) { model.check(rule) }
                            Button(l10n.text("Запустить сейчас")) { model.run(rule) }
                            Button(l10n.text("История")) { historyRule = rule }
                            Button(l10n.text("Удалить правило"), role: .destructive) { deletionLanguage = ConfirmationLanguage(language: language); deleting = rule }
                        }.disabled(model.isBusy)
                    }.padding(.vertical, 8)
                }
            }
            Button(l10n.text("Разрешить уведомления macOS")) { model.requestNotifications() }
        }
        .padding(20)
        .task { await model.load() }
        .sheet(item: $model.editor) { rule in RuleEditorView(rule: rule, roots: model.roots, rules: model.rules, errorMessage: model.message, save: model.save) }
        .sheet(item: $historyRule) { rule in
            VStack {
                RuleHistoryView(container: model.container, ruleID: rule.id)
                Button(l10n.text("Закрыть")) { historyRule = nil }.padding()
            }.frame(minWidth: 700, minHeight: 450)
        }
        .sheet(item: $model.reviewingPlan) { plan in
            RulePlanReviewView(model: model, plan: plan, language: language)
                .id(plan.id)
        }
        .sheet(isPresented: $model.showCheckResults) {
            VStack(alignment: .leading) {
                Text(l10n.format("Совпадений: %@", model.checkResults.count.formatted())).font(.title2)
                Text(l10n.text("Проверены условия над текущими файлами. Событие и действия не выполнялись.")).font(.caption)
                List(model.checkResults, id: \.relativePath) { Text($0.relativePath).textSelection(.enabled) }
                Button(l10n.text("Закрыть")) { model.showCheckResults = false }
            }.padding().frame(minWidth: 600, minHeight: 400)
        }
        .alert("Ares", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(l10n.text("Закрыть"), role: .cancel) { model.message = nil }
        } message: { Text(model.message.map(l10n.render) ?? "") }
        .confirmationDialog(deletionL10n.text("Удалить правило? Созданные файлы останутся на месте."), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(deletionL10n.text("Удалить правило"), role: .destructive) { if let rule = deleting { model.remove(rule) }; deleting = nil }
            Button(deletionL10n.text("Отмена"), role: .cancel) { deleting = nil }
        }
    }
}

/// Редактор хранит локальный снимок до сохранения: отмена не меняет SQLite.
struct RuleEditorView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }
    @State var rule: AutomationRule
    let roots: [AuthorizedRoot]
    let rules: [AutomationRule]
    let errorMessage: AresMessage?
    let save: (AutomationRule) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            Form {
                if let errorMessage { Section { Text(l10n.render(errorMessage)).foregroundStyle(.red) } }
                Section(l10n.text("Правило")) {
                    AresInputRow(l10n.text("Название")) {
                        TextField(l10n.text("Название"), text: $rule.name)
                    }
                    Picker(l10n.text("Папка"), selection: $rule.rootID) {
                        Text(l10n.text("Выберите")).tag(Optional<UUID>.none)
                        ForEach(roots) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    Toggle(l10n.text("Включать подпапки"), isOn: $rule.includeSubfolders)
                }
                Section(l10n.text("Событие")) {
                    Picker(l10n.text("Когда"), selection: $rule.event) { ForEach(RuleEvent.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) } }
                    AresInputRow(l10n.text("Тег / ключевое слово / тип документа")) {
                        TextField(l10n.text("Тег / ключевое слово / тип документа"), text: $rule.eventValue)
                    }
                    if rule.event == .documentType { Text(l10n.text("Локальная эвристика по словам: счёт, договор или чек; результат не гарантирует тип документа.")).font(.caption) }
                    if rule.event == .diskConnected { Text(l10n.text("Выберите папку на внешнем диске. Проверка подключения выполняется каждые 30 секунд; краткое отключение между проверками может быть пропущено.")).font(.caption) }
                    AresInputRow(l10n.text("Порог (байты или количество)")) {
                        TextField(l10n.text("Порог (байты или количество)"), value: $rule.threshold, format: .number)
                    }
                    Stepper(l10n.format("Срок (дней): %@", rule.days.formatted()), value: $rule.days, in: 1...3650)
                    if rule.event == .scheduled {
                        Picker(l10n.text("Расписание"), selection: $rule.schedule) { ForEach(RuleSchedule.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) } }
                        DatePicker(l10n.text("Начало"), selection: $rule.scheduleDate)
                        Toggle(l10n.text("Календарное время с учётом часового пояса"), isOn: Binding(get: { rule.scheduleTimeZone != nil }, set: { rule.scheduleTimeZone = $0 ? TimeZone.current.identifier : nil }))
                        if rule.scheduleTimeZone != nil {
                            TextField(l10n.text("Часовой пояс"), text: Binding(get: { rule.scheduleTimeZone ?? TimeZone.current.identifier }, set: { rule.scheduleTimeZone = $0 }))
                            Text(l10n.text("Ежедневные и недельные запуски сохраняют местное время при переходе на летнее/зимнее время.")).font(.caption).foregroundStyle(.secondary)
                        }
                        AresInputRow(l10n.text("Интервал в секундах (минимум 30)")) {
                            TextField(l10n.text("Интервал в секундах (минимум 30)"), value: $rule.intervalSeconds, format: .number)
                        }
                        Toggle(l10n.text("Выполнить один пропущенный запуск при открытии"), isOn: $rule.catchUpOnce)
                    }
                    if rule.event == .ruleSucceeded || rule.event == .ruleFailed {
                        Picker(l10n.text("Исходное правило"), selection: $rule.sourceRuleID) {
                            Text(l10n.text("Выберите")).tag(Optional<UUID>.none)
                            ForEach(rules.filter { $0.id != rule.id }) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                Section(l10n.text("Условия")) {
                    Toggle(l10n.text("Все условия (выключено — любое)"), isOn: $rule.conditions.allConditions)
                    AresInputRow(l10n.text("Расширения через запятую")) {
                        TextField(l10n.text("Расширения через запятую"), text: listBinding($rule.conditions.extensions))
                    }
                    Picker(l10n.text("Имя"), selection: $rule.conditions.nameMatch) { ForEach(RuleNameMatch.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) } }
                    AresInputRow(l10n.text("Текст / шаблон (* и ?)")) {
                        TextField(l10n.text("Текст / шаблон (* и ?)"), text: $rule.conditions.name)
                    }
                    AresInputRow(l10n.text("Минимум байт")) {
                        TextField(l10n.text("Минимум байт"), text: optionalNumber($rule.conditions.minimumBytes))
                    }
                    AresInputRow(l10n.text("Максимум байт")) {
                        TextField(l10n.text("Максимум байт"), text: optionalNumber($rule.conditions.maximumBytes))
                    }
                    AresInputRow(l10n.text("Обязательный тег")) {
                        TextField(l10n.text("Обязательный тег"), text: $rule.conditions.requiredTag)
                    }
                    AresInputRow(l10n.text("Исключить тег")) {
                        TextField(l10n.text("Исключить тег"), text: $rule.conditions.absentTag)
                    }
                    AresInputRow(l10n.text("Исключить подпапки (относительные пути через запятую)")) {
                        TextField(l10n.text("Исключить подпапки (относительные пути через запятую)"), text: listBinding($rule.conditions.excludedPaths))
                    }
                    AresInputRow(l10n.text("Исключить имена (* и ?, через запятую)")) {
                        TextField(l10n.text("Исключить имена (* и ?, через запятую)"), text: listBinding($rule.conditions.excludedNames))
                    }
                    dateCondition("Создан после", value: $rule.conditions.createdAfter)
                    dateCondition("Изменён после", value: $rule.conditions.modifiedAfter)
                    dateCondition("Впервые обнаружен после", value: $rule.conditions.firstSeenAfter)
                    Text(l10n.text("Системные и служебные каталоги, приложения и проекты исключаются автоматически.")).font(.caption)
                }
                Section(l10n.text("Действия по порядку")) {
                    ForEach($rule.actions) { $action in
                        VStack(alignment: .leading) {
                            Picker(l10n.text("Действие"), selection: $action.kind) { ForEach(RuleActionKind.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) } }
                            AresInputRow(l10n.text("Тег / подпапки (каждая с новой строки)")) {
                                TextField(l10n.text("Тег / подпапки (каждая с новой строки)"), text: $action.value, axis: .vertical)
                            }
                            if action.kind == .archive { Toggle(l10n.text("Один ZIP для всех совпавших файлов"), isOn: $action.archiveTogether) }
                            if action.kind == .archive || action.kind == .copy {
                                Picker(l10n.text("Папка назначения"), selection: $action.destinationRootID) {
                                    Text(l10n.text("Выберите разрешённую папку")).tag(Optional<UUID>.none)
                                    ForEach(roots) { Text($0.displayName).tag(Optional($0.id)) }
                                }
                                Text(l10n.text("Результат будет сохранён в подпапке Ares Results. Исходники не удаляются.")).font(.caption)
                            }
                            if action.kind == .runRule {
                                Picker(l10n.text("Следующее правило"), selection: $action.nextRuleID) {
                                    Text(l10n.text("Выберите")).tag(Optional<UUID>.none)
                                    ForEach(rules.filter { $0.id != rule.id }) { Text($0.name).tag(Optional($0.id)) }
                                }
                            }
                            Button(l10n.text("Убрать действие"), role: .destructive) { rule.actions.removeAll { $0.id == action.id } }
                        }
                    }
                    Button(l10n.text("Добавить действие")) { rule.actions.append(RuleAction(kind: .log)) }
                }
                Section(l10n.text("Режим выполнения")) {
                    Toggle(l10n.text("Включено"), isOn: $rule.enabled)
                    Toggle(l10n.text("Обрабатывать существующие файлы при первом включении"), isOn: $rule.processExisting)
                    Toggle(l10n.text("Разрешить локальное чтение текста и OCR"), isOn: $rule.allowContentReading)
                    Text(l10n.text("Содержимое обрабатывается локально и не отправляется в сеть. Автоматизация действует только при открытом приложении.")).font(.caption)
                }
            }.formStyle(.grouped)
            HStack { Button(l10n.text("Отмена"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(l10n.text("Сохранить")) { save(rule) }.disabled(rule.rootID == nil || rule.actions.isEmpty || rule.name.isEmpty) }.padding()
        }.frame(minWidth: 680, minHeight: 650)
    }
    private func listBinding(_ value: Binding<[String]>) -> Binding<String> {
        Binding(get: { value.wrappedValue.joined(separator: ", ") }, set: { value.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }
    private func optionalNumber(_ value: Binding<Int64?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(String.init) ?? "" }, set: { value.wrappedValue = Int64($0) })
    }
    private func dateCondition(_ title: String, value: Binding<Date?>) -> some View {
        VStack(alignment: .leading) {
            Toggle(l10n.text(title), isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? Date() : nil }))
            if value.wrappedValue != nil {
                DatePicker(l10n.text(title), selection: Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 }))
            }
        }
    }
}


/// Решение фиксирует язык на весь просмотр: обновление настроек не меняет
/// уже показанные ограничения согласия. Новый plan.id создаёт новый снимок.
struct RulePlanReviewView: View {
    @ObservedObject var model: RulesViewModel
    let plan: RulePlanSummary
    @State private var confirmation: ConfirmationLanguage
    private var l10n: AresLocalization { AresLocalization(language: confirmation.language) }

    init(model: RulesViewModel, plan: RulePlanSummary, language: AgentLanguage) {
        self.model = model
        self.plan = plan
        _confirmation = State(initialValue: ConfirmationLanguage(language: language))
    }

    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(plan.kind == "enable" ? l10n.text("Включить правило?") : l10n.text("Подтвердить план?")).font(.title2.bold())
                Text(plan.name).font(.headline)
                Text(l10n.format("Папка: %@", model.roots.first { $0.id == plan.sourceRootID }?.relativePathHint ?? plan.source))
                Text(l10n.format("Назначения: %@", plan.destinationRootIDs.map { id in model.roots.first { $0.id == id }?.relativePathHint ?? id.uuidString }.joined(separator: ", ")))
                Text(l10n.format("Действия: %@", plan.actions.map(l10n.ruleActionTitle).joined(separator: " → ")))
                Text(l10n.format("Объектов сейчас: %@. Объём: %@.", plan.fileCount.formatted(), ByteCountFormatter.string(fromByteCount: plan.byteSize, countStyle: .file)))
                Text(l10n.format("Лимит объектов запуска: %@; лимит объёма: %@.", plan.maximumFiles.formatted(), ByteCountFormatter.string(fromByteCount: plan.maximumBytes, countStyle: .file)))
                Text(plan.kind == "enable" ? l10n.text("Разрешение действует для этой версии правила. Следующие срабатывания проверяют файлы и лимиты без нового запроса.") : l10n.text("Одноразовый план. Изменение файлов или истечение срока требует нового просмотра."))
                Text(l10n.format("Срок: %@", plan.expiresAt.formatted())).font(.caption)
                List(model.reviewingFiles, id: \.self) { Text($0) }
                if model.nextReviewOffset != nil { Button(l10n.text("Показать ещё файлы плана")) { model.moreReviewFiles() } }
                Text(l10n.format("Показано %@ из %@. Подтверждается весь указанный набор.", model.reviewingFiles.count.formatted(), plan.fileCount.formatted())).font(.caption)
                HStack {
                    Button(l10n.text("Отмена"), role: .cancel) { model.reviewingPlan = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(l10n.text("Подтвердить план")) { model.confirmPlan(plan) }.accessibilityIdentifier("rule.approve")
                }
            }.padding().frame(minWidth: 650, minHeight: 500)
    }
}
