# Developing Ares

[Русский](DEVELOPMENT.ru.md) · [Home](../README.en.md)

- Swift 5.9+, SwiftUI/AppKit, MVVM and a service layer; actors/async-await.
- Business logic lives in Core. GUI, runtime and stdio MCP are separate executables.
- SQLite WAL, single ownership, leases/fencing, cancellation and idempotency protect
  durable tasks. XPC authenticates UID/CDHash rather than a caller-supplied clientId.
- Codex/Harness use separate endpoints and grants. Data access is denied by default.
- Inbox keeps independent delivery, a global processing claim and durable effect key.
- EcosystemKit is local and hash-pinned by snapshot.json. No sibling project is needed.

Run `swift build`, `swift test`, `swift test --package-path Packages/EcosystemKit`
and `python3 scripts/verify_snapshot.py`. After an intentional shared-package change,
review the diff and use `verify_snapshot.py --refresh`. Python scripts use type hints;
nontrivial decisions have Russian comments. Secrets belong in Keychain/environment,
never source, Git or logs.

The local baseline passed 64 domain and 180 shared XCTest checks.
Hosted CI may skip real Codex CLI tests when it is absent. It does not replace live
client, TCC, sleep or notification acceptance.

`python3 scripts/build_snapshot.py --configuration release` builds app, pkg and dmg.
`python3 scripts/package_distribution.py` repackages an existing pkg into a DMG.
Use `--update-license` after a standalone LICENSE change to reseal the app and
rebuild its ad-hoc signature. Developer ID distribution remains a separate stage.

Future work: Hermes adapter extensibility, final UX, native signed bootstrap,
consistent migrations, clean installation/upgrade and outstanding release gates.

CI portability fixes: explicit @main filename for Ares MCP; both SwiftPM resource bundle layouts; two regression tests.
