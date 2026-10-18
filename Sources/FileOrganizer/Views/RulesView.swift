import SwiftUI
import FileOrganizerCore

struct RulesView: View {
    @StateObject private var model: RulesViewModel
    @State private var deleting: AutomationRule?
    @State private var historyRule: AutomationRule?
    init(container: AppContainer) { _model = StateObject(wrappedValue: RulesViewModel(container: container)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Событие → условия → действия").font(.title2.bold())
                Spacer()
                Button("Создать", systemImage: "plus") { model.editor = AutomationRule() }
                    .disabled(model.roots.isEmpty)
            }
            Text("В локальном режиме включённые правила выполняет отдельный агент. Новое правило выключено; «Проверить» показывает совпадения без изменения файлов.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isBusy { HStack { ProgressView(); Text("Выполнение…"); Button("Отменить") { model.cancel() } } }
            if model.container.isLocalRuntimeClient {
                Button("Обновить запросы подтверждения") { Task { await model.load() } }
            }
            List {
                if !model.pendingPlans.isEmpty {
                    Section("Запросы локального подтверждения") {
                        ForEach(model.pendingPlans) { plan in
                            Button("Проверить план: " + plan.name) { model.review(plan) }
                                .accessibilityIdentifier("rule.review." + plan.kind)
                        }
                    }
                }
                if model.rules.isEmpty { Text("Создайте первое правило. Сначала добавьте папку в «Обзоре».").foregroundStyle(.secondary) }
                ForEach(model.rules) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { var updated = rule; updated.enabled = $0; model.requestEnabled(rule, enabled: updated.enabled) }))
                            .font(.headline)
                        Text("\(rule.event.title) · \(model.roots.first(where: { $0.id == rule.rootID })?.displayName ?? "Доступ к папке отсутствует")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(rule.actions.map { $0.kind.title }.joined(separator: " → ")).font(.caption)
                        if let last = model.runs.first(where: { $0.ruleID == rule.id }) {
                            Text("Последний запуск: \(last.createdAt.formatted()) · \(RulePresentation.status(last.status)) · файлов: \(last.matchedCount)").font(.caption2)
                        }
                        HStack {
                            Button("Изменить") { model.editor = rule }
                            Button("Дублировать") { model.duplicate(rule) }
                            Button("Проверить") { model.check(rule) }
                            Button("Запустить сейчас") { model.run(rule) }
                            Button("История") { historyRule = rule }
                            Button("Удалить правило", role: .destructive) { deleting = rule }
                        }.disabled(model.isBusy)
                    }.padding(.vertical, 8)
                }
            }
            Button("Разрешить уведомления macOS") { model.requestNotifications() }
        }
        .padding(20)
        .task { await model.load() }
        .sheet(item: $model.editor) { rule in RuleEditorView(rule: rule, roots: model.roots, rules: model.rules, errorMessage: model.message, save: model.save) }
        .sheet(item: $historyRule) { rule in
            VStack {
                RuleHistoryView(container: model.container, ruleID: rule.id)
                Button("Закрыть") { historyRule = nil }.padding()
            }.frame(minWidth: 700, minHeight: 450)
        }
        .sheet(item: $model.reviewingPlan) { plan in
            VStack(alignment: .leading, spacing: 12) {
                Text(plan.kind == "enable" ? "Включить правило?" : "Подтвердить план?").font(.title2.bold())
                Text(plan.name).font(.headline)
                Text("Папка: " + (model.roots.first { $0.id == plan.sourceRootID }?.relativePathHint ?? plan.source))
                Text("Назначения: " + plan.destinationRootIDs.map { id in model.roots.first { $0.id == id }?.relativePathHint ?? id.uuidString }.joined(separator: ", "))
                Text("Действия: " + plan.actions.joined(separator: " → "))
                Text("Объектов сейчас: \(plan.fileCount). Объём: \(ByteCountFormatter.string(fromByteCount: plan.byteSize, countStyle: .file)).")
                Text("Лимит запуска: \(plan.maximumFiles) объектов; \(ByteCountFormatter.string(fromByteCount: plan.maximumBytes, countStyle: .file)).")
                Text(plan.kind == "enable" ? "Разрешение действует для этой версии правила. Следующие срабатывания проверяют файлы и лимиты без нового запроса." : "Одноразовый план. Изменение файлов или истечение срока требует нового просмотра.")
                Text("Срок: " + plan.expiresAt.formatted()).font(.caption)
                List(model.reviewingFiles, id: \.self) { Text($0) }
                if model.nextReviewOffset != nil { Button("Показать ещё файлы плана") { model.moreReviewFiles() } }
                Text("Показано \(model.reviewingFiles.count) из \(plan.fileCount). Подтверждается весь указанный набор.").font(.caption)
                HStack {
                    Button("Отмена") { model.reviewingPlan = nil }
                    Spacer()
                    Button("Подтвердить план") { model.confirmPlan(plan) }.accessibilityIdentifier("rule.approve")
                }
            }.padding().frame(minWidth: 650, minHeight: 500)
        }
        .sheet(isPresented: $model.showCheckResults) {
            VStack(alignment: .leading) {
                Text("Совпадений: \(model.checkResults.count)").font(.title2)
                Text("Проверены условия над текущими файлами. Событие и действия не выполнялись.").font(.caption)
                List(model.checkResults, id: \.relativePath) { Text($0.relativePath).textSelection(.enabled) }
                Button("Закрыть") { model.showCheckResults = false }
            }.padding().frame(minWidth: 600, minHeight: 400)
        }
        .alert("Ares", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("Закрыть", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
        .confirmationDialog("Удалить правило? Созданные файлы останутся на месте.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Удалить правило", role: .destructive) { if let rule = deleting { model.remove(rule) }; deleting = nil }
        }
    }
}

/// Редактор хранит локальный снимок до сохранения: отмена не меняет SQLite.
private struct RuleEditorView: View {
    @State var rule: AutomationRule
    let roots: [AuthorizedRoot]
    let rules: [AutomationRule]
    let errorMessage: String?
    let save: (AutomationRule) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            Form {
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                Section("Правило") {
                    AresInputRow("Название") {
                        TextField("Название", text: $rule.name)
                    }
                    Picker("Папка", selection: $rule.rootID) {
                        Text("Выберите").tag(Optional<UUID>.none)
                        ForEach(roots) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    Toggle("Включать подпапки", isOn: $rule.includeSubfolders)
                }
                Section("Событие") {
                    Picker("Когда", selection: $rule.event) { ForEach(RuleEvent.allCases, id: \.self) { Text($0.title).tag($0) } }
                    AresInputRow("Тег / ключевое слово / тип документа") {
                        TextField("Тег / ключевое слово / тип документа", text: $rule.eventValue)
                    }
                    if rule.event == .documentType { Text("Локальная эвристика по словам: счёт, договор или чек; результат не гарантирует тип документа.").font(.caption) }
                    if rule.event == .diskConnected { Text("Выберите папку на внешнем диске. Проверка подключения выполняется каждые 30 секунд; краткое отключение между проверками может быть пропущено.").font(.caption) }
                    AresInputRow("Порог (байты или количество)") {
                        TextField("Порог (байты или количество)", value: $rule.threshold, format: .number)
                    }
                    Stepper("Срок: \(rule.days) дней", value: $rule.days, in: 1...3650)
                    if rule.event == .scheduled {
                        Picker("Расписание", selection: $rule.schedule) { ForEach(RuleSchedule.allCases, id: \.self) { Text($0.title).tag($0) } }
                        DatePicker("Начало", selection: $rule.scheduleDate)
                        Toggle("Календарное время с учётом часового пояса", isOn: Binding(get: { rule.scheduleTimeZone != nil }, set: { rule.scheduleTimeZone = $0 ? TimeZone.current.identifier : nil }))
                        if rule.scheduleTimeZone != nil {
                            TextField("Часовой пояс", text: Binding(get: { rule.scheduleTimeZone ?? TimeZone.current.identifier }, set: { rule.scheduleTimeZone = $0 }))
                            Text("Ежедневные и недельные запуски сохраняют местное время при переходе на летнее/зимнее время.").font(.caption).foregroundStyle(.secondary)
                        }
                        AresInputRow("Интервал в секундах (минимум 30)") {
                            TextField("Интервал в секундах (минимум 30)", value: $rule.intervalSeconds, format: .number)
                        }
                        Toggle("Выполнить один пропущенный запуск при открытии", isOn: $rule.catchUpOnce)
                    }
                    if rule.event == .ruleSucceeded || rule.event == .ruleFailed {
                        Picker("Исходное правило", selection: $rule.sourceRuleID) {
                            Text("Выберите").tag(Optional<UUID>.none)
                            ForEach(rules.filter { $0.id != rule.id }) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                Section("Условия") {
                    Toggle("Все условия (выключено — любое)", isOn: $rule.conditions.allConditions)
                    AresInputRow("Расширения через запятую") {
                        TextField("Расширения через запятую", text: listBinding($rule.conditions.extensions))
                    }
                    Picker("Имя", selection: $rule.conditions.nameMatch) { ForEach(RuleNameMatch.allCases, id: \.self) { Text($0.title).tag($0) } }
                    AresInputRow("Текст / шаблон (* и ?)") {
                        TextField("Текст / шаблон (* и ?)", text: $rule.conditions.name)
                    }
                    AresInputRow("Минимум байт") {
                        TextField("Минимум байт", text: optionalNumber($rule.conditions.minimumBytes))
                    }
                    AresInputRow("Максимум байт") {
                        TextField("Максимум байт", text: optionalNumber($rule.conditions.maximumBytes))
                    }
                    AresInputRow("Обязательный тег") {
                        TextField("Обязательный тег", text: $rule.conditions.requiredTag)
                    }
                    AresInputRow("Исключить тег") {
                        TextField("Исключить тег", text: $rule.conditions.absentTag)
                    }
                    AresInputRow("Исключить подпапки (относительные пути через запятую)") {
                        TextField("Исключить подпапки (относительные пути через запятую)", text: listBinding($rule.conditions.excludedPaths))
                    }
                    AresInputRow("Исключить имена (* и ?, через запятую)") {
                        TextField("Исключить имена (* и ?, через запятую)", text: listBinding($rule.conditions.excludedNames))
                    }
                    dateCondition("Создан после", value: $rule.conditions.createdAfter)
                    dateCondition("Изменён после", value: $rule.conditions.modifiedAfter)
                    dateCondition("Впервые обнаружен после", value: $rule.conditions.firstSeenAfter)
                    Text("Системные и служебные каталоги, приложения и проекты исключаются автоматически.").font(.caption)
                }
                Section("Действия по порядку") {
                    ForEach($rule.actions) { $action in
                        VStack(alignment: .leading) {
                            Picker("Действие", selection: $action.kind) { ForEach(RuleActionKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                            AresInputRow("Тег / подпапки (каждая с новой строки)") {
                                TextField("Тег / подпапки (каждая с новой строки)", text: $action.value, axis: .vertical)
                            }
                            if action.kind == .archive { Toggle("Один ZIP для всех совпавших файлов", isOn: $action.archiveTogether) }
                            if action.kind == .archive || action.kind == .copy {
                                Picker("Папка назначения", selection: $action.destinationRootID) {
                                    Text("Выберите разрешённую папку").tag(Optional<UUID>.none)
                                    ForEach(roots) { Text($0.displayName).tag(Optional($0.id)) }
                                }
                                Text("Результат будет сохранён в подпапке Ares Results. Исходники не удаляются.").font(.caption)
                            }
                            if action.kind == .runRule {
                                Picker("Следующее правило", selection: $action.nextRuleID) {
                                    Text("Выберите").tag(Optional<UUID>.none)
                                    ForEach(rules.filter { $0.id != rule.id }) { Text($0.name).tag(Optional($0.id)) }
                                }
                            }
                            Button("Убрать действие", role: .destructive) { rule.actions.removeAll { $0.id == action.id } }
                        }
                    }
                    Button("Добавить действие") { rule.actions.append(RuleAction(kind: .log)) }
                }
                Section("Режим выполнения") {
                    Toggle("Включено", isOn: $rule.enabled)
                    Toggle("Обрабатывать существующие файлы при первом включении", isOn: $rule.processExisting)
                    Toggle("Разрешить локальное чтение текста и OCR", isOn: $rule.allowContentReading)
                    Text("Содержимое обрабатывается локально и не отправляется в сеть. Автоматизация действует только при открытом приложении.").font(.caption)
                }
            }.formStyle(.grouped)
            HStack { Button("Отмена") { dismiss() }; Spacer(); Button("Сохранить") { save(rule) }.disabled(rule.rootID == nil || rule.actions.isEmpty || rule.name.isEmpty) }.padding()
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
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? Date() : nil }))
            if value.wrappedValue != nil {
                DatePicker(title, selection: Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 }))
            }
        }
    }
}
