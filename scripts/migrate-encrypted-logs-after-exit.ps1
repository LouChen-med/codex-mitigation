# Public parameterized worker. It aborts before switching paths if EFSRAW cannot preserve encryption.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Target,
    [string]$LogRoot = (Join-Path (Get-Location) 'tmp'),
    [int]$WaitTimeoutMinutes = 1440,
    [string]$TaskName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This one-shot worker migrates only the encrypted desktop log directory.
# It intentionally leaves the Codex application, package data, and parent
# AppData\Local\Codex directory on the original application drive
$source = $Source
$target = $Target
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$source.pre-migration-$runId"
$logPath = Join-Path $LogRoot "codex-local-logs-migration-$runId.log"
$statePath = Join-Path $LogRoot "codex-local-logs-migration-$runId.json"
$probeName = ".codex-migration-probe-$runId.tmp"
$switched = $false
$targetCreated = $false

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

function Save-State {
    param([Parameter(Mandatory)][string]$Status, [string]$Message = '')
    [ordered]@{
        status = $Status
        message = $Message
        run_id = $runId
        source = $source
        target = $target
        backup = $backup
        updated_at = (Get-Date).ToString('o')
        log_path = $logPath
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Get-BlockingProcess {
    $names = @(
        'ChatGPT', 'codex', 'codex-code-mode-host',
        'codex-computer-use-swift', 'codex-windows-sandbox-service',
        'codex-command-runner', 'Code'
    )
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName })
}

function Wait-ForCleanShutdown {
    $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
    do {
        $blocking = @(Get-BlockingProcess)
        if ($blocking.Count -eq 0) { return }
        Write-Log ("Waiting for processes to exit: " + (($blocking | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '))
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw 'Codex/VS Code processes did not exit before the timeout.'
}

function Get-TreeManifest {
    param([Parameter(Mandatory)][string]$Root)
    $rootItem = Get-Item -LiteralPath $Root -Force
    $directories = @([pscustomobject]@{
        Relative = '.'
        Sddl = (Get-Acl -LiteralPath $Root).Sddl
        Owner = (Get-Acl -LiteralPath $Root).Owner
        Attributes = [string]$rootItem.Attributes
    })
    $files = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Unexpected reparse point in tree: $($item.FullName)"
        }
        $relative = [IO.Path]::GetRelativePath($Root, $item.FullName)
        $acl = Get-Acl -LiteralPath $item.FullName
        if ($item.PSIsContainer) {
            $directories += [pscustomobject]@{
                Relative = $relative
                Sddl = $acl.Sddl
                Owner = $acl.Owner
                Attributes = [string]$item.Attributes
            }
        } else {
            $files += [pscustomobject]@{
                Relative = $relative
                Length = [int64]$item.Length
                Sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                Encrypted = [bool]($item.Attributes -band [IO.FileAttributes]::Encrypted)
                Sddl = $acl.Sddl
                Owner = $acl.Owner
            }
        }
    }
    [pscustomobject]@{ Directories = $directories; Files = $files }
}

function Assert-EquivalentTree {
    param(
        [Parameter(Mandatory)]$SourceManifest,
        [Parameter(Mandatory)]$TargetManifest
    )
    if ($SourceManifest.Files.Count -ne $TargetManifest.Files.Count) {
        throw "File count mismatch: $($SourceManifest.Files.Count) vs $($TargetManifest.Files.Count)"
    }
    if ($SourceManifest.Directories.Count -ne $TargetManifest.Directories.Count) {
        throw "Directory count mismatch: $($SourceManifest.Directories.Count) vs $($TargetManifest.Directories.Count)"
    }
    $sourceBytes = ($SourceManifest.Files | Measure-Object Length -Sum).Sum
    $targetBytes = ($TargetManifest.Files | Measure-Object Length -Sum).Sum
    if ($sourceBytes -ne $targetBytes) { throw "Byte count mismatch: $sourceBytes vs $targetBytes" }

    $targetFiles = @{}
    foreach ($entry in $TargetManifest.Files) { $targetFiles[$entry.Relative] = $entry }
    foreach ($entry in $SourceManifest.Files) {
        if (-not $targetFiles.ContainsKey($entry.Relative)) { throw "Missing target file: $($entry.Relative)" }
        $other = $targetFiles[$entry.Relative]
        foreach ($property in @('Length','Sha256','Encrypted','Sddl','Owner')) {
            if ([string]$entry.$property -cne [string]$other.$property) {
                throw "File manifest mismatch ($property): $($entry.Relative)"
            }
        }
    }

    $targetDirs = @{}
    foreach ($entry in $TargetManifest.Directories) { $targetDirs[$entry.Relative] = $entry }
    foreach ($entry in $SourceManifest.Directories) {
        if (-not $targetDirs.ContainsKey($entry.Relative)) { throw "Missing target directory: $($entry.Relative)" }
        $other = $targetDirs[$entry.Relative]
        foreach ($property in @('Sddl','Owner')) {
            if ([string]$entry.$property -cne [string]$other.$property) {
                throw "Directory manifest mismatch ($property): $($entry.Relative)"
            }
        }
    }
    Write-Log "Manifest verification passed: files=$($SourceManifest.Files.Count), bytes=$sourceBytes, directories=$($SourceManifest.Directories.Count)"
}

function Restore-SourceIfNeeded {
    if (Test-Path -LiteralPath $source) {
        $sourceItem = Get-Item -LiteralPath $source -Force
        if ($sourceItem.LinkType -eq 'Junction') {
            Remove-Item -LiteralPath $source -Force
        }
    }
    if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $source)) {
        Move-Item -LiteralPath $backup -Destination $source
        Write-Log "Restored source from backup: $backup"
    }
}

function Remove-SelfTask {
    if ([string]::IsNullOrWhiteSpace($TaskName)) { return }
    try {
        & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN $TaskName /F | Out-Null
        Write-Log "Removed one-shot scheduled task: $TaskName"
    } catch {
        Write-Log ("Could not remove scheduled task: " + $_.Exception.Message) 'WARN'
    }
}

function Test-EfsRawCopy {
    $probeRoot = Join-Path $LogRoot "codex-efs-probe-$runId"
    try {
        New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
        $sample = Get-ChildItem -LiteralPath $source -Force -File -Recurse | Select-Object -First 1
        if ($null -eq $sample) { throw 'No source log file was found for the EFS probe.' }
        $sampleHash = (Get-FileHash -LiteralPath $sample.FullName -Algorithm SHA256).Hash
        $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
        & $robocopy $sample.DirectoryName $probeRoot $sample.Name '/EFSRAW' '/COPY:DAT' '/R:0' '/W:0' '/NP' "/LOG+:$logPath"
        if ($LASTEXITCODE -ge 8) { throw "Single-file EFSRAW probe failed with exit code $LASTEXITCODE" }
        $copied = Join-Path $probeRoot $sample.Name
        if (-not (Test-Path -LiteralPath $copied)) { throw 'Single-file EFSRAW probe produced no target file.' }
        $copiedItem = Get-Item -LiteralPath $copied -Force
        if (-not ($copiedItem.Attributes -band [IO.FileAttributes]::Encrypted)) {
            throw 'Single-file EFSRAW probe target is not encrypted.'
        }
        $copiedHash = (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash
        if ($sampleHash -cne $copiedHash) { throw 'Single-file EFSRAW probe SHA-256 mismatch.' }
        Write-Log 'Single-file EFSRAW probe passed: encrypted attribute and SHA-256 match.'
    } finally {
        if (Test-Path -LiteralPath $probeRoot) {
            Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
    Write-Log 'Worker started.'
    Save-State -Status 'WaitingForShutdown'
    Wait-ForCleanShutdown
    Write-Log 'All Codex and VS Code blocker processes have exited.'

    $sourceItem = Get-Item -LiteralPath $source -Force
    if ($sourceItem.LinkType) { throw "Source is already a reparse point: $source" }
    if (Test-Path -LiteralPath $target) { throw "Target already exists; refusing to overwrite: $target" }
    if (Test-Path -LiteralPath $backup) { throw "Backup path already exists: $backup" }

    Test-EfsRawCopy
    Save-State -Status 'Copying'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $targetCreated = $true
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $copyArgs = @(
        $source, $target, '/E', '/EFSRAW', '/COPY:DATS', '/DCOPY:DAT',
        '/XJ', '/R:0', '/W:0', '/NP', "/LOG+:$logPath"
    )
    & $robocopy @copyArgs
    if ($LASTEXITCODE -ge 8) { throw "Robocopy failed with exit code $LASTEXITCODE" }

    # Ensure new files inherit EFS encryption before the source path is switched.
    & (Join-Path $env:SystemRoot 'System32\cipher.exe') /e /s:$target /a >> $logPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "cipher /e failed with exit code $LASTEXITCODE" }

    $sourceManifest = Get-TreeManifest -Root $source
    $targetManifest = Get-TreeManifest -Root $target
    Assert-EquivalentTree -SourceManifest $sourceManifest -TargetManifest $targetManifest
    Save-State -Status 'Verified'

    Move-Item -LiteralPath $source -Destination $backup
    New-Item -ItemType Junction -Path $source -Target $target | Out-Null
    $switched = $true
    $junction = Get-Item -LiteralPath $source -Force
    if ($junction.LinkType -ne 'Junction' -or ($junction.Target -join '') -ne $target) {
        throw 'Junction verification failed.'
    }

    $probe = Join-Path $source $probeName
    try {
        [IO.File]::WriteAllText($probe, "codex migration probe $runId")
        $probeItem = Get-Item -LiteralPath $probe -Force
        if (-not ($probeItem.Attributes -band [IO.FileAttributes]::Encrypted)) {
            throw 'A new file through the Junction did not inherit EFS encryption.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $target $probeName))) {
            throw 'Junction write probe did not land in the J target.'
        }
    } finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
    }

    Save-State -Status 'Complete' -Message 'Logs migrated with EFSRAW, manifest verification, ACL verification, Junction verification, and encrypted write probe.'
    Write-Log "Migration complete. C backup retained at $backup"
    Remove-SelfTask
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList 'codex:'
    exit 0
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    Save-State -Status 'Failed' -Message $_.Exception.Message
    if ($switched) {
        try { Restore-SourceIfNeeded } catch { Write-Log ("Rollback failed: " + $_.Exception.Message) 'ERROR' }
    }
    # The target is intentionally retained for inspection; no unverified data is deleted.
    Remove-SelfTask
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList 'codex:' } catch { }
    exit 1
}

