# Public parameterized version of the local migration script. It never contains auth, logs, or rollback data.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MigrationRoot,
    [Parameter(Mandatory)][string]$DataRoot,
    [string]$HomeSource = (Join-Path $env:USERPROFILE '.codex'),
    [string]$RuntimeSource = (Join-Path $env:USERPROFILE '.cache\codex-runtimes'),
    [ValidateSet('Stage', 'Finalize', 'ResumePartial', 'Verify', 'Rollback')]
    [string]$Mode = 'Stage',

    [ValidateRange(5, 1440)]
    [int]$ShutdownTimeoutMinutes = 1440,

    [ValidateRange(0, 3600)]
    [int]$RequestCloseAfterSeconds = 90,

    [ValidateRange(30, 600)]
    [int]$LaunchTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MigrationRoot = $MigrationRoot
$script:DataRoot = $DataRoot
$script:RollbackRoot = Join-Path $script:DataRoot 'rollback'
$script:CancelPath = Join-Path $script:MigrationRoot 'CANCEL'
$script:StatePath = Join-Path $script:MigrationRoot 'migration-state.json'
$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogPath = Join-Path $script:MigrationRoot ("migration-{0}-{1}.log" -f $Mode, $script:RunId)
$script:LockPath = Join-Path $script:MigrationRoot 'migration.lock'
$script:LockStream = $null

$script:Mappings = @(
    [pscustomobject]@{
        Name = 'home'
        Source = $HomeSource
        Target = (Join-Path $script:DataRoot 'home')
        CriticalFiles = @('config.toml', 'auth.json', 'state_5.sqlite', 'logs_2.sqlite')
    },
    [pscustomobject]@{
        Name = 'runtimes'
        Source = $RuntimeSource
        Target = (Join-Path $script:DataRoot 'runtimes')
        CriticalFiles = @()
    }
)

if (-not ('CodexMigrationNativeAcl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class CodexMigrationNativeAcl {
    private const uint DACL_SECURITY_INFORMATION = 0x00000004;
    private const uint PROTECTED_DACL_SECURITY_INFORMATION = 0x80000000;
    private const int SE_FILE_OBJECT = 1;

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetNamedSecurityInfo(
        string pObjectName, int objectType, uint securityInfo,
        out IntPtr owner, out IntPtr group, out IntPtr dacl,
        out IntPtr sacl, out IntPtr securityDescriptor);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    private static extern uint SetNamedSecurityInfo(
        string pObjectName, int objectType, uint securityInfo,
        IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static void CopyProtectedDacl(string source, string target) {
        IntPtr owner, group, dacl, sacl, descriptor;
        uint result = GetNamedSecurityInfo(
            source, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
            out owner, out group, out dacl, out sacl, out descriptor);
        if (result != 0) {
            throw new Win32Exception((int)result, "GetNamedSecurityInfo failed");
        }

        try {
            if (dacl == IntPtr.Zero) {
                throw new InvalidOperationException(
                    "Source has a null DACL; refusing to copy it.");
            }
            result = SetNamedSecurityInfo(
                target, SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
            if (result != 0) {
                throw new Win32Exception((int)result, "SetNamedSecurityInfo failed");
            }
        } finally {
            if (descriptor != IntPtr.Zero) {
                LocalFree(descriptor);
            }
        }
    }
}
'@
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
    Write-Host $line
}

function Save-State {
    param(
        [Parameter(Mandatory)]
        [string]$Status,

        [string]$Message = '',

        [hashtable]$Details = @{}
    )

    $state = [ordered]@{
        status = $Status
        message = $Message
        mode = $Mode
        run_id = $script:RunId
        updated_at = (Get-Date).ToString('o')
        log_path = $script:LogPath
        details = $Details
    }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StatePath -Encoding utf8
}

function Enter-MigrationLock {
    New-Item -ItemType Directory -Path $script:MigrationRoot -Force | Out-Null
    try {
        $script:LockStream = [System.IO.File]::Open(
            $script:LockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        throw "Another migration process already holds $script:LockPath"
    }
}

function Exit-MigrationLock {
    if ($null -ne $script:LockStream) {
        $script:LockStream.Dispose()
        $script:LockStream = $null
    }
}

function Assert-LocalNtfsDrive {
    param([Parameter(Mandatory)][string]$Path)

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    $drive = [System.IO.DriveInfo]::new($root)
    if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
        throw "Path is not on a fixed drive: $Path"
    }
    if ($drive.DriveFormat -ne 'NTFS') {
        throw "Path is not on NTFS: $Path"
    }
}

function Assert-SafeDedicatedTarget {
    param([Parameter(Mandatory)][string]$Path)

    $fullDataRoot = [System.IO.Path]::GetFullPath($script:DataRoot).TrimEnd('\') + '\'
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($fullDataRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing target outside dedicated data root: $fullPath"
    }
}

function Assert-SafeReparseTarget {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowOriginalSource
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullDataRoot = [System.IO.Path]::GetFullPath($script:DataRoot).TrimEnd('\') + '\'
    if ($fullPath.StartsWith($fullDataRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    if ($AllowOriginalSource) {
        foreach ($mapping in $script:Mappings) {
            if ($fullPath -eq [System.IO.Path]::GetFullPath($mapping.Source)) {
                return
            }
        }
    }

    throw "Refusing reparse-point synchronization outside approved paths: $fullPath"
}

function Protect-PathFromSource {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    # SetNamedSecurityInfo writes only the DACL and never requests SACL access,
    # so this works without SeSecurityPrivilege and leaves auditing untouched.
    [CodexMigrationNativeAcl]::CopyProtectedDacl($Source, $Target)
}

function Get-AccessSignature {
    param([Parameter(Mandatory)][string]$Path)

    $acl = Get-Acl -LiteralPath $Path
    $rules = $acl.Access | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}' -f 
            $_.IdentityReference.Value,
            [int]$_.FileSystemRights,
            $_.AccessControlType,
            $_.InheritanceFlags,
            $_.PropagationFlags
    }
    return ($rules | Sort-Object) -join "`n"
}

function Assert-EquivalentAccessRules {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    $sourceSignature = Get-AccessSignature -Path $Source
    $targetSignature = Get-AccessSignature -Path $Target
    if ($sourceSignature -ne $targetSignature) {
        throw "ACL access rules differ: $Source -> $Target"
    }
}

function Initialize-TargetSecurity {
    foreach ($mapping in $script:Mappings) {
        Assert-SafeDedicatedTarget -Path $mapping.Target
        if (-not (Test-Path -LiteralPath $mapping.Target)) {
            New-Item -ItemType Directory -Path $mapping.Target -Force | Out-Null
        }
        Protect-PathFromSource -Source $mapping.Source -Target $mapping.Target
    }

    if (-not (Test-Path -LiteralPath $script:RollbackRoot)) {
        New-Item -ItemType Directory -Path $script:RollbackRoot -Force | Out-Null
    }
    Protect-PathFromSource -Source $script:Mappings[0].Source -Target $script:DataRoot
    Protect-PathFromSource -Source $script:Mappings[0].Source -Target $script:RollbackRoot
}

function Invoke-RobocopyMirror {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [switch]$AllowIncomplete
    )

    Assert-SafeDedicatedTarget -Path $Target
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Mirror source does not exist: $Source"
    }
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    $arguments = @(
        $Source,
        $Target,
        '/MIR',
        '/COPY:DATS',
        '/DCOPY:DAT',
        '/XJ',
        '/R:2',
        '/W:2',
        '/NP',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS'
    )

    Write-Log "Robocopy mirror started: $Source -> $Target"
    & "$env:SystemRoot\System32\robocopy.exe" @arguments
    $exitCode = $LASTEXITCODE
    Write-Log "Robocopy exit code ${exitCode}: $Source -> $Target"

    if ($exitCode -ge 8 -and -not $AllowIncomplete) {
        throw "Robocopy failed with exit code ${exitCode}: $Source -> $Target"
    }
    if ($exitCode -ge 8 -and $AllowIncomplete) {
        Write-Log "Stage copy was incomplete; final offline mirror will retry all files." 'WARN'
    }
    return $exitCode
}

function Get-ReparseRecords {
    param([Parameter(Mandatory)][string]$Root)

    $records = @()
    Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
        ForEach-Object {
            $records += [pscustomobject]@{
                RelativePath = [System.IO.Path]::GetRelativePath($Root, $_.FullName)
                LinkType = [string]$_.LinkType
                Target = ([string[]]$_.Target) -join ';'
                IsDirectory = [bool]$_.PSIsContainer
            }
        }
    return @($records | Sort-Object RelativePath)
}

function Sync-ReparsePoints {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [switch]$AllowOriginalSourceTarget
    )

    Assert-SafeReparseTarget -Path $Target -AllowOriginalSource:$AllowOriginalSourceTarget
    $sourceRecords = @(Get-ReparseRecords -Root $Source)
    $sourceMap = @{}
    foreach ($record in $sourceRecords) {
        $sourceMap[$record.RelativePath] = $record
    }

    $targetRecords = @(Get-ReparseRecords -Root $Target)
    foreach ($targetRecord in $targetRecords) {
        if (-not $sourceMap.ContainsKey($targetRecord.RelativePath)) {
            $extraPath = Join-Path $Target $targetRecord.RelativePath
            $extraItem = Get-Item -LiteralPath $extraPath -Force
            if (-not ($extraItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing to remove non-reparse target: $extraPath"
            }
            Remove-Item -LiteralPath $extraPath -Force
            Write-Log "Removed stale target reparse point: $extraPath"
        }
    }

    foreach ($record in $sourceRecords) {
        $destination = Join-Path $Target $record.RelativePath
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $needsCreate = $true
        if (Test-Path -LiteralPath $destination) {
            $existing = Get-Item -LiteralPath $destination -Force
            $existingTarget = ([string[]]$existing.Target) -join ';'
            if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
                [string]$existing.LinkType -eq $record.LinkType -and
                $existingTarget -eq $record.Target) {
                $needsCreate = $false
            } else {
                if (-not ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    throw "Refusing to replace non-reparse target: $destination"
                }
                Remove-Item -LiteralPath $destination -Force
            }
        }

        if ($needsCreate) {
            if ($record.LinkType -eq 'Junction' -and $record.IsDirectory) {
                New-Item -ItemType Junction -Path $destination -Target $record.Target | Out-Null
            } elseif ($record.LinkType -eq 'SymbolicLink') {
                New-Item -ItemType SymbolicLink -Path $destination -Target $record.Target | Out-Null
            } else {
                throw "Unsupported reparse point type $($record.LinkType): $($record.RelativePath)"
            }
            Write-Log "Created $($record.LinkType): $destination -> $($record.Target)"
        }
    }
}

function Get-RegularFiles {
    param([Parameter(Mandatory)][string]$Root)

    return @(Get-ChildItem -LiteralPath $Root -Force -File -Recurse -ErrorAction Stop |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
}

function Get-DirectoryCount {
    param([Parameter(Mandatory)][string]$Root)

    return @(Get-ChildItem -LiteralPath $Root -Force -Directory -Recurse -ErrorAction Stop |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }).Count
}

function Get-FileHashWithRetry {
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-SqliteStabilityFingerprint {
    param([Parameter(Mandatory)][string]$Root)

    $records = Get-ChildItem -LiteralPath $Root -Force -File -Recurse -ErrorAction Stop |
        Where-Object { $_.Name -match '\.sqlite(?:-wal|-shm)?$' } |
        Sort-Object FullName |
        ForEach-Object {
            $contentHash = ''
            if ($_.Name -like '*.sqlite-shm') {
                $contentHash = Get-FileHashWithRetry -Path $_.FullName
            }
            '{0}|{1}|{2}|{3}' -f 
                [System.IO.Path]::GetRelativePath($Root, $_.FullName),
                $_.Length,
                $_.LastWriteTimeUtc.Ticks,
                $contentHash
        }
    return ($records -join "`n")
}

function Wait-ForSqliteStability {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$RequiredStableSeconds = 20,
        [int]$TimeoutSeconds = 180
    )

    Write-Log "Waiting for SQLite files to remain stable: $Root"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $previousFingerprint = $null
    $stableSince = $null

    while ((Get-Date) -lt $deadline) {
        if (@(Get-BlockingProcesses).Count -ne 0) {
            throw 'A Codex process restarted during offline SQLite stability checking.'
        }

        $fingerprint = Get-SqliteStabilityFingerprint -Root $Root
        if ($fingerprint -eq $previousFingerprint) {
            if ($null -eq $stableSince) { $stableSince = Get-Date }
            if (((Get-Date) - $stableSince).TotalSeconds -ge $RequiredStableSeconds) {
                Write-Log "SQLite stability check passed: $Root"
                return
            }
        } else {
            $previousFingerprint = $fingerprint
            $stableSince = $null
        }
        Start-Sleep -Seconds 2
    }

    throw "SQLite files did not remain stable for $RequiredStableSeconds seconds: $Root"
}

function Sync-SqliteFilesForced {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    Assert-SafeDedicatedTarget -Path $Target
    $sqliteFiles = @(Get-ChildItem -LiteralPath $Source -Force -File -Recurse -ErrorAction Stop |
        Where-Object { $_.Name -match '\.sqlite(?:-wal|-shm)?$' })

    foreach ($sourceFile in $sqliteFiles) {
        $relative = [System.IO.Path]::GetRelativePath($Source, $sourceFile.FullName)
        $targetFile = Join-Path $Target $relative
        $targetParent = Split-Path -Parent $targetFile
        if (-not (Test-Path -LiteralPath $targetParent)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }
        [System.IO.File]::Copy($sourceFile.FullName, $targetFile, $true)
        Protect-PathFromSource -Source $sourceFile.FullName -Target $targetFile
    }
    Write-Log "Force-copied $($sqliteFiles.Count) SQLite database/sidecar files: $Source -> $Target"
}

function Invoke-FinalMirrorAndVerify {
    param([Parameter(Mandatory)]$Mapping)

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Log "Offline mirror/verification attempt $attempt of 3: $($Mapping.Name)"
            Wait-ForSqliteStability -Root $Mapping.Source
            $null = Invoke-RobocopyMirror -Source $Mapping.Source -Target $Mapping.Target
            Sync-ReparsePoints -Source $Mapping.Source -Target $Mapping.Target
            Sync-SqliteFilesForced -Source $Mapping.Source -Target $Mapping.Target
            Secure-And-VerifyTarget -Source $Mapping.Source -Target $Mapping.Target -CriticalFiles $Mapping.CriticalFiles
            Assert-TreesIdentical -Source $Mapping.Source -Target $Mapping.Target
            return
        } catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Write-Log "Attempt $attempt failed for $($Mapping.Name): $($_.Exception.Message). Retrying safely." 'WARN'
                Start-Sleep -Seconds 10
            }
        }
    }
    throw $lastError
}

function Assert-TreesIdentical {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    Write-Log "Full SHA-256 verification started: $Source -> $Target"
    $sourceFiles = @(Get-RegularFiles -Root $Source)
    $targetFiles = @(Get-RegularFiles -Root $Target)
    if ($sourceFiles.Count -ne $targetFiles.Count) {
        throw "File count differs: $($sourceFiles.Count) vs $($targetFiles.Count)"
    }

    $sourceBytes = ($sourceFiles | Measure-Object Length -Sum).Sum
    $targetBytes = ($targetFiles | Measure-Object Length -Sum).Sum
    if ($sourceBytes -ne $targetBytes) {
        throw "Byte count differs: $sourceBytes vs $targetBytes"
    }

    $sourceDirectoryCount = Get-DirectoryCount -Root $Source
    $targetDirectoryCount = Get-DirectoryCount -Root $Target
    if ($sourceDirectoryCount -ne $targetDirectoryCount) {
        throw "Directory count differs: $sourceDirectoryCount vs $targetDirectoryCount"
    }

    $targetMap = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($targetFile in $targetFiles) {
        $relative = [System.IO.Path]::GetRelativePath($Target, $targetFile.FullName)
        $targetMap[$relative] = $targetFile
    }

    $verified = 0
    foreach ($sourceFile in $sourceFiles) {
        $relative = [System.IO.Path]::GetRelativePath($Source, $sourceFile.FullName)
        if (-not $targetMap.ContainsKey($relative)) {
            throw "Target file is missing: $relative"
        }
        $targetFile = $targetMap[$relative]
        if ($sourceFile.Length -ne $targetFile.Length) {
            throw "File length differs: $relative"
        }
        $sourceHash = Get-FileHashWithRetry -Path $sourceFile.FullName
        $targetHash = Get-FileHashWithRetry -Path $targetFile.FullName
        if ($sourceHash -ne $targetHash) {
            throw "SHA-256 differs: $relative"
        }
        $verified++
        if (($verified % 1000) -eq 0) {
            Write-Log "Verified $verified of $($sourceFiles.Count) files: $Source"
        }
    }

    $sourceLinks = @(Get-ReparseRecords -Root $Source | ConvertTo-Json -Compress)
    $targetLinks = @(Get-ReparseRecords -Root $Target | ConvertTo-Json -Compress)
    if (($sourceLinks -join "`n") -ne ($targetLinks -join "`n")) {
        throw "Reparse point manifests differ: $Source -> $Target"
    }

    Write-Log "Verification passed: files=$verified bytes=$sourceBytes directories=$sourceDirectoryCount"
}

function Secure-And-VerifyTarget {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [string[]]$CriticalFiles = @()
    )

    Protect-PathFromSource -Source $Source -Target $Target
    Assert-EquivalentAccessRules -Source $Source -Target $Target

    foreach ($relative in $CriticalFiles) {
        $sourceCritical = Join-Path $Source $relative
        $targetCritical = Join-Path $Target $relative
        if (-not (Test-Path -LiteralPath $sourceCritical)) {
            throw "Critical source file is missing: $sourceCritical"
        }
        if (-not (Test-Path -LiteralPath $targetCritical)) {
            throw "Critical target file is missing: $targetCritical"
        }
        Protect-PathFromSource -Source $sourceCritical -Target $targetCritical
        Assert-EquivalentAccessRules -Source $sourceCritical -Target $targetCritical
    }
}

function Get-BlockingProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^(ChatGPT|codex|codex-code-mode-host)$' -or
        $_.ProcessName -like 'codex-command-runner*'
    })
}

function Request-GracefulAppClose {
    $windowProcesses = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 })
    foreach ($process in $windowProcesses) {
        try {
            $null = $process.CloseMainWindow()
            Write-Log "Requested graceful close for ChatGPT PID $($process.Id)."
        } catch {
            Write-Log "Could not request graceful close for PID $($process.Id): $($_.Exception.Message)" 'WARN'
        }
    }
    if ($windowProcesses.Count -eq 0) {
        Write-Log 'No ChatGPT process exposed a main window; waiting for manual close.' 'WARN'
    }
}

function Wait-ForCleanShutdown {
    $startedAt = Get-Date
    $deadline = $startedAt.AddMinutes($ShutdownTimeoutMinutes)
    $closeRequested = $false
    $zeroSince = $null
    $lastReport = [datetime]::MinValue

    Save-State -Status 'WaitingForShutdown' -Message 'Waiting for all Codex processes to exit.'
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $script:CancelPath) {
            Save-State -Status 'Cancelled' -Message "Cancellation file detected: $script:CancelPath"
            throw 'Migration cancelled before switching any paths.'
        }

        $elapsed = ((Get-Date) - $startedAt).TotalSeconds
        if (-not $closeRequested -and $RequestCloseAfterSeconds -gt 0 -and $elapsed -ge $RequestCloseAfterSeconds) {
            Request-GracefulAppClose
            $closeRequested = $true
        }

        $blocking = @(Get-BlockingProcesses)
        if ($blocking.Count -eq 0) {
            if ($null -eq $zeroSince) {
                $zeroSince = Get-Date
                Write-Log 'All blocking processes exited; confirming stable shutdown.'
            }
            if (((Get-Date) - $zeroSince).TotalSeconds -ge 10) {
                return
            }
        } else {
            $zeroSince = $null
            if (((Get-Date) - $lastReport).TotalSeconds -ge 30) {
                $summary = ($blocking | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '
                Write-Log "Still waiting for processes: $summary"
                $lastReport = Get-Date
            }
        }
        Start-Sleep -Seconds 2
    }

    Save-State -Status 'ShutdownTimeout' -Message 'No paths were switched.'
    throw "Timed out after $ShutdownTimeoutMinutes minutes waiting for Codex to close."
}

function Switch-ToJunction {
    param([Parameter(Mandatory)]$Mapping)

    $sourceItem = Get-Item -LiteralPath $Mapping.Source -Force
    if ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Source is already a reparse point: $($Mapping.Source)"
    }

    $backup = '{0}.migration-backup-{1}' -f $Mapping.Source, $script:RunId
    if (Test-Path -LiteralPath $backup) {
        throw "Backup path already exists: $backup"
    }

    $backupLeaf = Split-Path -Leaf $backup
    Rename-Item -LiteralPath $Mapping.Source -NewName $backupLeaf
    try {
        New-Item -ItemType Junction -Path $Mapping.Source -Target $Mapping.Target | Out-Null
    } catch {
        Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $Mapping.Source)
        throw
    }

    $junction = Get-Item -LiteralPath $Mapping.Source -Force
    $junctionTarget = ([string[]]$junction.Target)[0]
    if ($junction.LinkType -ne 'Junction' -or
        [System.IO.Path]::GetFullPath($junctionTarget) -ne [System.IO.Path]::GetFullPath($Mapping.Target)) {
        Remove-Item -LiteralPath $Mapping.Source -Force
        Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $Mapping.Source)
        throw "Junction verification failed: $($Mapping.Source)"
    }

    foreach ($critical in $Mapping.CriticalFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Mapping.Source $critical))) {
            throw "Critical file is unavailable through junction: $critical"
        }
    }

    Write-Log "Switched to junction: $($Mapping.Source) -> $($Mapping.Target); backup=$backup"
    return [pscustomobject]@{
        Name = $Mapping.Name
        Source = $Mapping.Source
        Target = $Mapping.Target
        Backup = $backup
        CriticalFiles = $Mapping.CriticalFiles
    }
}

function Close-NewAppForRollback {
    Request-GracefulAppClose
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-BlockingProcesses).Count -eq 0) { return }
        Start-Sleep -Seconds 2
    }

    Write-Log 'Graceful close timed out during rollback; force-stopping only Codex/ChatGPT processes.' 'WARN'
    Get-BlockingProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    if (@(Get-BlockingProcesses).Count -ne 0) {
        throw 'Could not stop all Codex processes for rollback.'
    }
}

function Undo-Switches {
    param([object[]]$SwitchedMappings)

    for ($index = $SwitchedMappings.Count - 1; $index -ge 0; $index--) {
        $switched = $SwitchedMappings[$index]
        if (Test-Path -LiteralPath $switched.Source) {
            $item = Get-Item -LiteralPath $switched.Source -Force
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                throw "Rollback refuses non-reparse source path: $($switched.Source)"
            }
            Remove-Item -LiteralPath $switched.Source -Force
        }
        if (-not (Test-Path -LiteralPath $switched.Backup)) {
            throw "Rollback backup is missing: $($switched.Backup)"
        }
        Rename-Item -LiteralPath $switched.Backup -NewName (Split-Path -Leaf $switched.Source)
        Write-Log "Rolled back source path: $($switched.Source)"
    }
}

function Start-CodexAndWait {
    Write-Log 'Launching Codex through the registered codex: protocol.'
    Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList 'codex:'
    $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
    $stableSince = $null

    while ((Get-Date) -lt $deadline) {
        $processes = @(Get-Process -ErrorAction SilentlyContinue)
        $chatGptCount = @($processes | Where-Object { $_.ProcessName -eq 'ChatGPT' }).Count
        $codexCount = @($processes | Where-Object { $_.ProcessName -eq 'codex' }).Count
        if ($chatGptCount -gt 0 -and $codexCount -gt 0) {
            if ($null -eq $stableSince) { $stableSince = Get-Date }
            if (((Get-Date) - $stableSince).TotalSeconds -ge 20) {
                Write-Log "Codex launch test passed: ChatGPT=$chatGptCount codex=$codexCount"
                return
            }
        } else {
            $stableSince = $null
        }
        Start-Sleep -Seconds 2
    }
    throw "Codex did not remain healthy for 20 seconds within $LaunchTimeoutSeconds seconds."
}

function Remove-ValidatedBackup {
    param(
        [Parameter(Mandatory)][string]$Backup,
        [Parameter(Mandatory)][string]$OriginalSource,
        [string]$ExpectedRunId = $script:RunId
    )

    $fullBackup = [System.IO.Path]::GetFullPath($Backup)
    $expectedParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $OriginalSource)).TrimEnd('\')
    $actualParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $fullBackup)).TrimEnd('\')
    $leaf = Split-Path -Leaf $fullBackup
    if ($actualParent -ne $expectedParent) {
        throw "Backup is outside expected parent: $fullBackup"
    }
    if ($leaf -notlike "*.migration-backup-$ExpectedRunId") {
        throw "Backup name lacks exact run marker: $fullBackup"
    }
    $item = Get-Item -LiteralPath $fullBackup -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing recursive delete of a reparse point: $fullBackup"
    }

    Write-Log "Validated backup removal target: $fullBackup"
    Remove-Item -LiteralPath $fullBackup -Recurse -Force
    Write-Log "Removed verified C-drive backup: $fullBackup"
}

function Invoke-Stage {
    Save-State -Status 'Staging' -Message 'Live pre-copy started; no source paths will be switched.'
    Initialize-TargetSecurity

    foreach ($mapping in $script:Mappings) {
        $null = Invoke-RobocopyMirror -Source $mapping.Source -Target $mapping.Target -AllowIncomplete
        Sync-ReparsePoints -Source $mapping.Source -Target $mapping.Target
        Secure-And-VerifyTarget -Source $mapping.Source -Target $mapping.Target -CriticalFiles $mapping.CriticalFiles
    }

    Save-State -Status 'Staged' -Message 'Live pre-copy completed. Final offline mirror and hashes are still required.'
    Write-Log 'Stage completed. No C-drive path was renamed, deleted, or linked.'
}

function Invoke-Verify {
    foreach ($mapping in $script:Mappings) {
        Assert-TreesIdentical -Source $mapping.Source -Target $mapping.Target
        Secure-And-VerifyTarget -Source $mapping.Source -Target $mapping.Target -CriticalFiles $mapping.CriticalFiles
    }
    Save-State -Status 'Verified' -Message 'Source and active target trees are identical.'
}

function Invoke-Finalize {
    $switched = @()
    $launchAttempted = $false
    try {
        Wait-ForCleanShutdown
        Save-State -Status 'FinalMirroring' -Message 'Codex is offline; performing final mirror and full hashes.'

        # Verify the static runtime cache first and the actively-written Codex
        # home last, minimizing the interval between its final hash and switch.
        $verificationMappings = @(
            @($script:Mappings | Where-Object { $_.Name -ne 'home' })
            @($script:Mappings | Where-Object { $_.Name -eq 'home' })
        )
        foreach ($mapping in $verificationMappings) {
            Save-State -Status 'FinalMirroring' -Message "Verifying $($mapping.Name) before switch."
            Invoke-FinalMirrorAndVerify -Mapping $mapping
        }

        $restartedProcesses = @(Get-BlockingProcesses)
        if ($restartedProcesses.Count -gt 0) {
            $names = ($restartedProcesses | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '
            throw "Codex restarted during final verification; refusing to switch paths: $names"
        }

        Save-State -Status 'Switching' -Message 'Targets verified; switching original paths to junctions.'
        foreach ($mapping in $script:Mappings) {
            $switched += Switch-ToJunction -Mapping $mapping
        }

        Save-State -Status 'LaunchTesting' -Message 'Junctions active; launching Codex for smoke test.'
        $launchAttempted = $true
        Start-CodexAndWait

        $snapshotRoot = Join-Path $script:RollbackRoot $script:RunId
        New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
        Protect-PathFromSource -Source $switched[0].Backup -Target $snapshotRoot

        foreach ($entry in $switched) {
            $snapshotTarget = Join-Path $snapshotRoot $entry.Name
            New-Item -ItemType Directory -Path $snapshotTarget -Force | Out-Null
            Protect-PathFromSource -Source $entry.Backup -Target $snapshotTarget
            $null = Invoke-RobocopyMirror -Source $entry.Backup -Target $snapshotTarget
            Sync-ReparsePoints -Source $entry.Backup -Target $snapshotTarget
            Secure-And-VerifyTarget -Source $entry.Backup -Target $snapshotTarget -CriticalFiles $entry.CriticalFiles
            Assert-TreesIdentical -Source $entry.Backup -Target $snapshotTarget
        }

        Save-State -Status 'RemovingVerifiedCBackups' -Message 'App and rollback snapshot verified; removing original C-drive backups.'
        foreach ($entry in $switched) {
            Remove-ValidatedBackup -Backup $entry.Backup -OriginalSource $entry.Source
        }

        $details = @{
            home_junction = $script:Mappings[0].Source
            home_target = $script:Mappings[0].Target
            runtimes_junction = $script:Mappings[1].Source
            runtimes_target = $script:Mappings[1].Target
            rollback_snapshot = $snapshotRoot
        }
        Save-State -Status 'Complete' -Message 'Migration completed and Codex launch test passed.' -Details $details
        Write-Log "Migration complete. Rollback snapshot retained at $snapshotRoot"
    } catch {
        $failureMessage = $_.Exception.Message
        Write-Log "Finalize failed: $failureMessage" 'ERROR'
        if ($switched.Count -gt 0) {
            try {
                if ($launchAttempted -or @(Get-BlockingProcesses).Count -gt 0) {
                    Close-NewAppForRollback
                }
                Undo-Switches -SwitchedMappings $switched
                Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList 'codex:'
                Save-State -Status 'RolledBack' -Message $failureMessage
                Write-Log 'Automatic rollback completed; Codex was relaunched from the original C-drive paths.' 'WARN'
            } catch {
                $rollbackFailure = $_.Exception.Message
                Save-State -Status 'RollbackNeedsAttention' -Message "$failureMessage | rollback: $rollbackFailure"
                Write-Log "Automatic rollback needs attention: $rollbackFailure" 'ERROR'
            }
        } else {
            Save-State -Status 'FailedBeforeSwitch' -Message $failureMessage
        }
        throw
    }
}

function Invoke-ResumePartial {
    $homeMapping = $script:Mappings | Where-Object { $_.Name -eq 'home' } | Select-Object -First 1
    $runtimeMapping = $script:Mappings | Where-Object { $_.Name -eq 'runtimes' } | Select-Object -First 1
    $runtimeSwitch = $null
    $cleanupStarted = $false

    $homeItem = Get-Item -LiteralPath $homeMapping.Source -Force
    $homeTarget = ([string[]]$homeItem.Target)[0]
    if ($homeItem.LinkType -ne 'Junction' -or
        [System.IO.Path]::GetFullPath($homeTarget) -ne [System.IO.Path]::GetFullPath($homeMapping.Target)) {
        throw "Partial resume expected the active home junction: $($homeMapping.Source)"
    }

    $runtimeItem = Get-Item -LiteralPath $runtimeMapping.Source -Force
    if ($runtimeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Partial resume expected an ordinary runtime source directory: $($runtimeMapping.Source)"
    }

    $homeBackupPrefix = (Split-Path -Leaf $homeMapping.Source) + '.migration-backup-'
    $homeBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $homeMapping.Source) -Force -Directory |
        Where-Object { $_.Name.StartsWith($homeBackupPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($homeBackups.Count -ne 1) {
        throw "Partial resume requires exactly one home backup; found $($homeBackups.Count)."
    }
    if ($homeBackups[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Home backup must be an ordinary directory: $($homeBackups[0].FullName)"
    }
    $homeBackup = $homeBackups[0].FullName
    $homeBackupRunId = $homeBackups[0].Name.Substring($homeBackupPrefix.Length)

    try {
        Wait-ForCleanShutdown
        Save-State -Status 'ResumingPartial' -Message 'Home is active on J; verifying and switching runtimes.'
        Invoke-FinalMirrorAndVerify -Mapping $runtimeMapping

        $restartedProcesses = @(Get-BlockingProcesses)
        if ($restartedProcesses.Count -gt 0) {
            $names = ($restartedProcesses | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '
            throw "Codex restarted during runtime verification; refusing to switch paths: $names"
        }

        $runtimeSwitch = Switch-ToJunction -Mapping $runtimeMapping
        Save-State -Status 'LaunchTesting' -Message 'Both junctions active; launching Codex for smoke test.'
        Start-CodexAndWait

        $snapshotRoot = Join-Path $script:RollbackRoot $script:RunId
        New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
        Protect-PathFromSource -Source $homeBackup -Target $snapshotRoot

        $snapshotEntries = @(
            [pscustomobject]@{
                Name = 'home'
                Source = $homeMapping.Source
                Backup = $homeBackup
                CriticalFiles = $homeMapping.CriticalFiles
            }
            [pscustomobject]@{
                Name = 'runtimes'
                Source = $runtimeMapping.Source
                Backup = $runtimeSwitch.Backup
                CriticalFiles = $runtimeMapping.CriticalFiles
            }
        )

        foreach ($entry in $snapshotEntries) {
            $snapshotTarget = Join-Path $snapshotRoot $entry.Name
            New-Item -ItemType Directory -Path $snapshotTarget -Force | Out-Null
            Protect-PathFromSource -Source $entry.Backup -Target $snapshotTarget
            $null = Invoke-RobocopyMirror -Source $entry.Backup -Target $snapshotTarget
            Sync-ReparsePoints -Source $entry.Backup -Target $snapshotTarget
            Secure-And-VerifyTarget -Source $entry.Backup -Target $snapshotTarget -CriticalFiles $entry.CriticalFiles
            Assert-TreesIdentical -Source $entry.Backup -Target $snapshotTarget
        }

        Save-State -Status 'RemovingVerifiedCBackups' -Message 'Rollback snapshot verified; removing both C-drive backups.'
        $cleanupStarted = $true
        Remove-ValidatedBackup -Backup $homeBackup -OriginalSource $homeMapping.Source -ExpectedRunId $homeBackupRunId
        Remove-ValidatedBackup -Backup $runtimeSwitch.Backup -OriginalSource $runtimeMapping.Source

        $details = @{
            home_junction = $homeMapping.Source
            home_target = $homeMapping.Target
            runtimes_junction = $runtimeMapping.Source
            runtimes_target = $runtimeMapping.Target
            rollback_snapshot = $snapshotRoot
        }
        Save-State -Status 'Complete' -Message 'Partial migration resumed and completed; launch test passed.' -Details $details
        Write-Log "Partial migration resume complete. Rollback snapshot retained at $snapshotRoot"
    } catch {
        $failureMessage = $_.Exception.Message
        Write-Log "Partial resume failed: $failureMessage" 'ERROR'
        if ($null -ne $runtimeSwitch -and -not $cleanupStarted) {
            try {
                if (@(Get-BlockingProcesses).Count -gt 0) {
                    Close-NewAppForRollback
                }
                Undo-Switches -SwitchedMappings @($runtimeSwitch)
                Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList 'codex:'
                Save-State -Status 'PartialResumeRolledBack' -Message $failureMessage
                Write-Log 'Runtime switch rolled back; the existing home junction was preserved.' 'WARN'
            } catch {
                $rollbackFailure = $_.Exception.Message
                Save-State -Status 'RollbackNeedsAttention' -Message "$failureMessage | rollback: $rollbackFailure"
                Write-Log "Partial-resume rollback needs attention: $rollbackFailure" 'ERROR'
            }
        } else {
            Save-State -Status 'PartialResumeNeedsAttention' -Message $failureMessage
        }
        throw
    }
}

function Invoke-RollbackSnapshot {
    Wait-ForCleanShutdown
    $latestSnapshot = Get-ChildItem -LiteralPath $script:RollbackRoot -Directory -ErrorAction Stop |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($null -eq $latestSnapshot) {
        throw 'No rollback snapshot exists.'
    }

    foreach ($mapping in $script:Mappings) {
        $sourceItem = Get-Item -LiteralPath $mapping.Source -Force
        if ($sourceItem.LinkType -ne 'Junction') {
            throw "Rollback expected a junction: $($mapping.Source)"
        }
        Remove-Item -LiteralPath $mapping.Source -Force

        $snapshotSource = Join-Path $latestSnapshot.FullName $mapping.Name
        New-Item -ItemType Directory -Path $mapping.Source -Force | Out-Null
        $restoreArguments = @(
            $snapshotSource,
            $mapping.Source,
            '/MIR', '/COPY:DATS', '/DCOPY:DAT', '/XJ', '/R:2', '/W:2',
            '/NP', '/NFL', '/NDL', '/NJH', '/NJS'
        )
        & "$env:SystemRoot\System32\robocopy.exe" @restoreArguments
        if ($LASTEXITCODE -ge 8) {
            throw "Rollback robocopy failed for $($mapping.Name): $LASTEXITCODE"
        }
        Sync-ReparsePoints -Source $snapshotSource -Target $mapping.Source -AllowOriginalSourceTarget
        Protect-PathFromSource -Source $snapshotSource -Target $mapping.Source
        Assert-TreesIdentical -Source $snapshotSource -Target $mapping.Source
    }

    Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList 'codex:'
    Save-State -Status 'ManualRollbackComplete' -Message "Restored from $($latestSnapshot.FullName)"
}

New-Item -ItemType Directory -Path $script:MigrationRoot -Force | Out-Null
New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
Assert-LocalNtfsDrive -Path $script:Mappings[0].Source
Assert-LocalNtfsDrive -Path $script:DataRoot
Enter-MigrationLock

try {
    Write-Log "Mode=$Mode RunId=$script:RunId"
    switch ($Mode) {
        'Stage' { Invoke-Stage }
        'Finalize' { Invoke-Finalize }
        'ResumePartial' { Invoke-ResumePartial }
        'Verify' { Invoke-Verify }
        'Rollback' { Invoke-RollbackSnapshot }
    }
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    throw
} finally {
    Exit-MigrationLock
}

