# Архитектура / Architecture

SwiftUI GUI → domain runtime → durable SQLite queue → fixed operation registry.
MCP clients use authenticated local IPC. Each agent owns independent profiles,
permissions and queues. Shared EcosystemKit provides contracts, adapters and
queue safety; it does not merge data or grant permissions across agents.

Агенты сохраняют отдельные данные и полномочия. Клиент не выбирает произвольный
shell или handler. Изменения правил требуют штатного подтверждения.
