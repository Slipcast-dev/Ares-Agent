# Installing Ares

[Русский](INSTALL.ru.md) · [Home](../README.en.md)

The E10 build targets Apple Silicon, macOS14+ and Python3 at `/usr/bin/python3`
(usually supplied by Command Line Tools). Neither PKG nor DMG is
Developer ID-signed or notarized; executables have ad-hoc signatures. A developer
certificate is not required for ordinary local execution, but macOS may request
manual approval or block the package. Do not disable platform security or bypass
managed-device restrictions.

1. Download the DMG and SHA256SUMS.txt from the same release. A separate PKG is
   available, but its external Finder icon does not survive HTTP transfer.
2. In the download folder, run `shasum -a 256 -c SHA256SUMS.txt`. Download both
   pkg and dmg to verify the entire list, or compare the downloaded file's hash
   with its specific checksum entry.
3. Open the DMG, then the pkg with the Ares icon. Installer places
   `/Applications/Ares Intermediate.app` on disk.
4. Explicitly launching it creates a separate profile under
   `~/Library/Application Support/SubAgent Intermediates/Ares`.
5. Folders, operations, client connections and login startup need separate consent.
   Existing databases and client settings are not imported automatically.

## Profile control

```sh
python3 '/Applications/Ares Intermediate.app/Contents/Resources/snapshot_entry.py' status
python3 '/Applications/Ares Intermediate.app/Contents/Resources/snapshot_entry.py' stop
```

Stop your profile before upgrading. Stopping preserves its data and history;
uninstalling the app does not delete the profile. Source files are not removed.
Disable optional login startup before uninstalling if you previously enabled it.
Do not downgrade binaries over inbox document v2; use a matching state backup.

## Known limitations

The intermediate bootstrap requires Python3, which is not bundled. Intel, clean
machine installation/upgrade, a separate macOS14 host, real sleep/logout/login,
visible banners and a 24-hour soak remain unverified. DMG portability was checked
using a data-only copy and read-only remount, preserving installer and volume icons.
