# Execution notes (sanitized)

- The primary Codex migration completed on 2026-08-01 with the two main Junctions targeting the dedicated J: data root.
- A later read-only audit found the signed application package still under WindowsApps, while package state already uses Windows-managed D: storage.
- The desktop log directory contained 93 files and 405,727,892 bytes with EFS attributes.
- On the current machine, `/EFSRAW`, ordinary Robocopy, and `.NET File.Copy` could not produce an encrypted target for an EFS sample. A byte copy would create plaintext, so it was rejected.
- Therefore the log directory remains on C: until EFS key/privilege support is explicitly resolved. No plaintext migration is acceptable.
- The automatic worker waits for Codex and VS Code to exit, performs the EFS probe, and automatically reopens Codex after either a safe migration or a refusal.