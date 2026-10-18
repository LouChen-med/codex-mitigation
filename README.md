# Codex storage migration on Windows

This repository documents a reversible Windows migration for Codex user data. The application package remains managed by Windows; only approved user data is redirected to a dedicated data root.

## Scope

- `C:\Users\<user>\.codex` becomes a directory Junction to `<data-root>\home`.
- `C:\Users\<user>\.cache\codex-runtimes` becomes a directory Junction to `<data-root>\runtimes`.
- Application binaries under `C:\Program Files\WindowsApps` and updater-managed `AppData\Local\OpenAI\Codex` remain where Windows installed them.
- Encrypted desktop logs are a separate, opt-in path. The worker refuses to create a Junction unless a single-file `/EFSRAW` probe preserves encryption and SHA-256.

Junctions are directory reparse points. They are not hard links and are safe only while their exact target exists and is protected from accidental deletion.

## Workflow

1. Read the existing migration instructions and inventory sources, targets, ACLs, EFS attributes, and free space.
2. Stage a non-destructive copy.
3. Stop Codex and any VS Code process that can write the source.
4. For ordinary data, mirror with `robocopy`, preserve ACLs, and compare file counts, byte totals, paths, SHA-256, ACLs, and reparse-point manifests.
5. For EFS data, use `/EFSRAW` only. If raw copying cannot preserve encryption, stop and leave the source on C:.
6. Keep a rollback copy, rename the original source, create the Junction, verify the exact target, and run a write/read smoke test.
7. Reopen Codex and recheck after a fresh write. Do not delete the rollback copy as part of the initial migration.

## Public-safety boundary

Raw logs, `auth.json`, cookies, SQLite databases, migration state, rollback snapshots, EFS keys, and machine-specific credentials are intentionally excluded. The public scripts are parameterized and contain no user secrets.

## References

- [MSIX containerization](https://learn.microsoft.com/en-us/windows/msix/msix-containerization-overview)
- [MSIX PowerShell package management](https://learn.microsoft.com/en-us/windows/msix/desktop/powershell-msix-cmdlets)
- [Backup and restore of encrypted files](https://learn.microsoft.com/en-us/windows/win32/fileio/backup-and-restore-of-encrypted-files)