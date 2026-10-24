![Ares](docs/assets/banner.svg)

<p align="center"><img src="docs/assets/ares-icon.png" width="160" alt="Ares"></p>

# Ares / Арес

[Русский](README.md) · [English](README.en.md)

Ares is an independent local macOS agent. Safe local file indexing, duplicate analysis and approved automation rules.

Version **0.38.1** · macOS14+ target · current release **Apple Silicon arm64**.
Intel/macOS14 execution remains unverified. This is a source-available project
under the custom non-commercial [LICENSE](LICENSE), not an MIT-licensed project.

[Release 0.38.1](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.38.1) · [PKG](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.1/Ares-0.38.1-unsigned.pkg) · [DMG](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.1/Ares-0.38.1-unsigned.dmg) · [SHA-256](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.1/SHA256SUMS) · [Validation and limits](docs/RELEASE.md)


0.38.1 validates serialized MCP model objects and reports failures without crashing. Current instructions are separated from archived release history.

## Installation

PKG/DMG are release attachments, not Git source files. They are **unsigned by
Developer ID and not notarized**. Verify SHA256SUMS before use. Local ad-hoc code
signatures provide integrity; they do not establish trusted developer identity.
Do not disable Gatekeeper globally. No automatic installation is performed.

## Build

Xcode / Command Line Tools with Swift5.9+; macOS14+ SDK. EcosystemKit is vendored:
no sibling repository is required. Yams6.2.2 is pinned in Package.resolved.

```sh
python3 scripts/verify_ecosystem_dependency.py
swift test
swift build -c release
scripts/package_app.zsh
```

Built apps: `dist/Ares.app`. Source executable names are retained for compatibility.

## Control and safety

GUI and background runtime are separate. Access starts denied; grant data access
inside this agent. Codex/Harness connection requires explicit setup in the app.
Hermes is a future extension; live Hermes support is not implemented.
No model keys or user data are bundled. See [security](SECURITY.md),
[operations](docs/OPERATIONS.md), [architecture](docs/ARCHITECTURE.md),
[performance](docs/PERFORMANCE.md), [changes](CHANGELOG.md) and [support](SUPPORT.md).

## Contributing

Read [CONTRIBUTING](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md).
Security reports should follow SECURITY.md; do not post personal data in issues.


## RU/EN localization / Локализация

Pre-release 0.38.1. Full manual VoiceOver/keyboard and hardware acceptance remain open.
Select System, Русский or English in this agent's settings. Each agent keeps its
own language. Даты/числа следуют региону macOS. User names, paths and historical
free text retain their original language. System Settings follows macOS language.

```sh
python3 scripts/verify_localization_acceptance.py --ares-dir . --kit-dir Packages/EcosystemKit --require-reviewed-boundaries --output localization-acceptance.json
ECOSYSTEM_SKIP_LSREGISTER=1 ECOSYSTEM_APP_VERSION=0.38.1 scripts/package_app.zsh
python3 scripts/prepare_local_release.py --run --version 0.38.1 --agent Ares --use-prepared-apps --apps-dir dist --output installers/0.38.1
```

Installer output is unsigned Developer ID and not notarized. These commands
create and verify artifacts; they do not install applications or publish them.
