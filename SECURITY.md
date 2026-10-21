# Security / Безопасность

Ares 0.28.0 is a local source-available agent. Access starts denied.
Production secrets belong in Keychain. Do not commit keys, profiles, databases,
bookmarks, grants, task payloads or personal paths. Operations use fixed handlers.
Cancellation, leases, fencing and receipts prevent blind replay; ambiguous
changes require recovery review. File access retains no-follow/version checks.

Сообщайте об уязвимостях через GitHub private vulnerability reporting, если оно
включено владельцем. Иначе откройте issue без деталей эксплуатации, секретов и
личных данных с просьбой предоставить приватный канал. Не предполагается, что
приватный reporting уже включён: это настройка владельца на GitHub.

Developer ID/notarization, macOS14/Intel runtime, full VoiceOver, real sleep/login
and long-duration hardware acceptance remain release gates. These builds have
local ad-hoc signatures only. No guarantee of absolute security is made.
