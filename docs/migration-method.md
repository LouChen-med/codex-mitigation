# Migration method

## Data classification

Keep the signed MSIX package and updater-managed binaries under Windows control. Migrate only data whose application contract permits a redirected path. Treat browser state, Login Data, cookies, credentials, and EFS files as high risk.

## Preflight

```powershell
Get-Item -LiteralPath $Source -Force | Format-List FullName,Attributes,LinkType,Target
Get-PSDrive -Name C,J | Select-Object Name,Used,Free
Get-Process | Where-Object { $_.ProcessName -match '^(ChatGPT|codex|Code)' }
```

Reject a source that is already an unexpected reparse point. Reject a destination that exists, leaves the dedicated data root, or has an incompatible filesystem.

## Ordinary data

Use a non-destructive stage copy first. The final offline copy must use a fixed source and destination, `/XJ`, no multithread mode when EFS is involved, and an exit code below 8. Compare every regular file by relative path, length, SHA-256, and attributes; compare directory ACL/owner manifests; compare reparse-point manifests.

## EFS data

Do not use `Copy-Item`, `.NET File.Copy`, or ordinary `robocopy` for a migration that must retain EFS. Run a single-file `/EFSRAW` probe first. Require the target file to remain `Encrypted` and have the same SHA-256. If the probe reports an encryption error, or produces a plaintext file, stop before renaming the source.

## Switch and rollback

1. Preserve the verified target and a source backup.
2. Rename the original source to a run-specific backup.
3. Create a directory Junction at the original path.
4. Verify `LinkType = Junction` and an exact target path.
5. Write a temporary probe through the original path and confirm it lands in the target with the expected encryption state.
6. On any failure, remove only the new Junction and restore the source backup. Keep the target for inspection.
7. Reopen the application and retain the backup until a restart and a new write have been verified.

## Windows application boundary

Windows places MSIX package files in a protected `WindowsApps` location. Use Windows Settings or the supported `Move-AppxPackage` mechanism only when the package exposes a supported move target; do not manually move or Junction the package directory.