# Эксплуатация / Operations

Откройте агент, настройте доступ к данным и клиенту внутри приложения.
Подключайте Codex или Harness через GUI-план, проверьте запрошенные изменения.
Отмена сеанса модели не равна отмене устойчивой задачи: проверяйте task status.
Нельзя автоматически повторять изменение после неопределённого transport result.

Open the app and grant data/client access explicitly. Review generated client
configuration before applying it. Cancel durable tasks separately from model
sessions; inspect status before retrying an uncertain operation.

## Язык / Language

Выбор System/RU/EN независим для каждого агента. Смена языка не переводит
пользовательские имена,пути и свободный текст истории. Системные названия
и окна macOS следуют языку macOS.
Each agent keeps its own language preference. User text/history stays unchanged;
macOS system surfaces follow macOS language.

[Current release status / Статус выпуска](STATUS.md).
