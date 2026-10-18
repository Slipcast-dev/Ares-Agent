![Ares — Files. Rules. Control.](assets/ares-banner.png)

<p align="center"><strong>Files. Rules. Control.</strong><br>Authorized folders, file indexing, duplicate analysis and automation rules.</p>
<p align="center"><a href="README.md">Русский</a> · <strong>English</strong></p>

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-a65237?style=flat-square)](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.12.0-intermediate)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-414b60?style=flat-square)](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.12.0-intermediate)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-f06438?style=flat-square)](Package.swift)
[![CI](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml/badge.svg)](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Non--commercial-686b73?style=flat-square)](LICENSE)

Ares is a standalone native macOS agent. It executes authorized local operations;
Codex and DeepSeek Harness connect over MCP and can delegate to a separate specialist.
This agent owns its own data, durable queue and permissions. Building it does not
require the other agent repository.

> **E10 intermediate build · No Apple Developer ID signature.**
> The PKG and DMG have no Developer ID signature and are not Apple-notarized.
> Executables use local ad-hoc signatures only. This is an intermediate release,
> not a production-ready public distribution.

[**Download DMG**](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.12.0-intermediate/Ares-E10-arm64-local.dmg) · [Download PKG](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.12.0-intermediate/Ares-E10-arm64-local.pkg) · [Release assets](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.12.0-intermediate)

## Capabilities

| Area | Capabilities |
|---|---|
| Folders | Explicit root selection, bookmarks, separate client grants |
| Index | Durable snapshots, file versions, search and paginated results |
| Duplicates | SHA-256 within granted scope, cancellation and limits |
| Rules | Preview and approval; tags, ZIP, copies, notifications, history |
| Background | File events, schedules, durable queue and crash recovery |

EcosystemKit 0.12.0 is vendored in `Packages/EcosystemKit`.
The MCP catalog exposes 32 tools; tool availability does not grant data access.
Client permissions are approved separately in the GUI. Connections preserve the
client's selected model and provider. The current application UI is in Russian.

## Install

1. Use an **Apple Silicon Mac**, macOS 14+ and Python 3 for the intermediate launcher.
2. Download the **DMG** from Releases, open it, then open the included pkg.
3. Install `Ares Intermediate.app` into `/Applications` and launch it.
4. Approve the required permissions in the GUI. Login startup is a separate opt-in.

The installer icon and mounted-volume icon survive download inside the DMG.
A standalone pkg/DMG file's external custom Finder icon is metadata and does not
survive a direct HTTP download. Checksums are included in `SHA256SUMS.txt`.

macOS may block this unsigned release. Do not disable Gatekeeper or TCC.
See [installation and limitations](docs/INSTALL.en.md).

## Codex and DeepSeek Harness

Connect through Settings: review the plan, then confirm it. Data permissions are a
separate action. Start a new client chat after connecting. Harness **0.2.0-rc.2** is
the verified version; other versions require compatibility checks. Hermes is not
connected yet. If the same role points to another installation, use explicit
disconnect/reconnect rather than silently replacing it.

## Build and contribute

```sh
swift build
swift test
swift test --package-path Packages/EcosystemKit
python3 scripts/verify_snapshot.py
python3 scripts/build_snapshot.py --configuration release
```

The first build requires Xcode/Command Line Tools, Python 3 and access to pinned
Yams 6.2.2. Public CI builds and tests the code; live client tests require installed
clients and separately authorized test profiles.

[Architecture and verification](docs/DEVELOPMENT.en.md) · [Contributing](CONTRIBUTING.md) ·
[Code of conduct](CODE_OF_CONDUCT.md) · [Security](SECURITY.md)

## Release status

Developer ID/notarization, clean-machine installation/upgrade, a separate macOS 14
host, Intel, real sleep/logout/login, visible notification banners and a 24-hour soak
remain release gates. The installer does not import private data or automatically
register external clients.

## License

Copyright © 2026 Slipcast-dev. [Public non-commercial use](LICENSE.en.md).
Commercial use, redistribution and derivative releases require the owner's prior
written permission. This is not MIT or an unrestricted redistribution license.
The [Russian LICENSE](LICENSE) is authoritative.
[Third-party notices](THIRD_PARTY_NOTICES.md).
