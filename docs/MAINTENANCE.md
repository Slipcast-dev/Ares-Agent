# Обновление / Maintenance

Перед обновлением остановите агент, создайте штатную резервную копию профиля.
Не удаляйте базы, grants или fencing state. При несовместимой схеме требуется
совместимая резервная копия и соответствующая версия приложения.

Stop the agent and use its maintenance backup before upgrade. Never delete the
queue or grants to bypass schema guards. Rollback must use a compatible backup.
