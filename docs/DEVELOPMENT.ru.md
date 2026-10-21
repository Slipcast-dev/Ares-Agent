# Разработка Ares0.29.0

Swift5.9+, macOS14+ target. Vendored EcosystemKit0.23.0, Yams6.2.2 pinned.
No sibling repository is required.

```sh
python3 scripts/verify_ecosystem_dependency.py
swift test
swift test --package-path Packages/EcosystemKit
scripts/package_app.zsh
```

Изменения прав, очередей, отмены и восстановления требуют отрицательных регрессий.

[Architecture](ARCHITECTURE.md) · [Contributing](../CONTRIBUTING.md) · [Security](../SECURITY.md).
