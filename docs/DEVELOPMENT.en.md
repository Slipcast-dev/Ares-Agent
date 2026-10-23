# Development Ares0.37.0

Swift5.9+, macOS14+ target. Vendored EcosystemKit0.29.0, Yams6.2.2 pinned.
No sibling repository is required.

```sh
python3 scripts/verify_ecosystem_dependency.py
swift test
swift test --package-path Packages/EcosystemKit
scripts/package_app.zsh
```

Permission, queue, cancellation and recovery changes require negative regression checks.

[Architecture](ARCHITECTURE.md) · [Contributing](../CONTRIBUTING.md) · [Security](../SECURITY.md).

```sh
python3 scripts/verify_localization_acceptance.py --ares-dir . --kit-dir Packages/EcosystemKit --require-reviewed-boundaries --output localization-acceptance.json
```
