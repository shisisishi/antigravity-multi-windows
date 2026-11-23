param(
    [string]$PoolDir = 'C:\ProgramData\AntigravityMulti\sync_pool',
    [string]$PythonExe = '',
    [string]$StatusFile = '',
    [switch]$SyncProjects,
    [switch]$SyncChats,
    [switch]$SyncBrain,
    [switch]$PullOnly,
    [switch]$PushIfIdle
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:LOCALAPPDATA 'AntigravityMulti'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'autosync.log'

function Write-SubLog {
    param([string]$Message)
    Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -Encoding UTF8
}

function Resolve-Python {
    param([string]$Hint)
    if ($Hint -and (Test-Path -LiteralPath $Hint -PathType Leaf)) {
        return @{ Exe = $Hint; Prefix = @() }
    }
    $pyCmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pyCmd -and $pyCmd.Source -notlike '*\WindowsApps\python.exe') {
        return @{ Exe = $pyCmd.Source; Prefix = @() }
    }
    $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        return @{ Exe = $pyLauncher.Source; Prefix = @('-3') }
    }
    return $null
}

function Test-OwnAntigravityRunning {
    $myAppPrefix = (Join-Path $env:LOCALAPPDATA 'Programs\antigravity').ToLowerInvariant()
    $procs = Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe' OR Name='language_server.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant().StartsWith($myAppPrefix)
    }
    return (@($procs).Count -gt 0)
}

function Sync-ProjectsBidirectional {
    param([string]$PoolProjectsDir)
    $localProjectsDir = Join-Path $env:USERPROFILE '.gemini\config\projects'
    New-Item -ItemType Directory -Force -Path $localProjectsDir, $PoolProjectsDir | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # 1. Push any newly added real (non-sidecar) projects from this sub-account to pool
    Get-ChildItem -LiteralPath $localProjectsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $pj = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pj.sidecar) { return }
            $poolTarget = Join-Path $PoolProjectsDir "$($pj.id).json"
            if (!(Test-Path -LiteralPath $poolTarget -PathType Leaf)) {
                Copy-Item -LiteralPath $_.FullName -Destination $poolTarget -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    # 2. Pull any missing real projects from pool into this sub-account + register git safe.directory
    $existingByUri = @{}
    Get-ChildItem -LiteralPath $localProjectsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $ej = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if (!$ej.sidecar -and $ej.projectResources -and $ej.projectResources.resources) {
                foreach ($r in $ej.projectResources.resources) {
                    if ($r.folderUri) { $existingByUri[$r.folderUri.ToLowerInvariant()] = $_.FullName }
                }
            }
        } catch {}
    }

    $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
    $userGitConfig = Join-Path $env:USERPROFILE '.gitconfig'
    $existingSafeDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($gitCmd -and (Test-Path -LiteralPath $userGitConfig)) {
        (& $gitCmd.Source config --file $userGitConfig --get-all safe.directory 2>$null) | ForEach-Object {
            if ($_) { [void]$existingSafeDirs.Add($_.Trim()) }
        }
    }

    $added = 0
    Get-ChildItem -LiteralPath $PoolProjectsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $pj = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pj.sidecar) { return }
            $outPath = Join-Path $localProjectsDir "$($pj.id).json"
            $uris = @()
            if ($pj.projectResources -and $pj.projectResources.resources) {
                foreach ($r in $pj.projectResources.resources) {
                    if ($r.folderUri) { $uris += $r.folderUri }
                }
            }
            if ($gitCmd) {
                foreach ($u in $uris) {
                    $decoded = [Uri]::UnescapeDataString(($u -replace '^file:///', ''))
                    if ($decoded -match '^[a-zA-Z]:/') {
                        $gitPath = $decoded.Substring(0, 1).ToUpper() + $decoded.Substring(1)
                        if (!$existingSafeDirs.Contains($gitPath)) {
                            & $gitCmd.Source config --file $userGitConfig --add safe.directory $gitPath 2>$null | Out-Null
                            [void]$existingSafeDirs.Add($gitPath)
                        }
                    }
                }
            }
            if (!(Test-Path -LiteralPath $outPath -PathType Leaf)) {
                foreach ($u in $uris) {
                    $key = $u.ToLowerInvariant()
                    if ($existingByUri.ContainsKey($key) -and ($existingByUri[$key] -ne $outPath)) {
                        Remove-Item -LiteralPath $existingByUri[$key] -Force -ErrorAction SilentlyContinue
                    }
                }
                [System.IO.File]::WriteAllText($outPath, ($pj | ConvertTo-Json -Depth 12), $utf8NoBom)
                $added++
            }
        } catch {}
    }
    return $added
}

try {
    $poolProjects = Join-Path $PoolDir 'projects'
    $poolChats = Join-Path $PoolDir 'chats'
    $subAgy = Join-Path $env:USERPROFILE '.gemini\antigravity'

    $projAdded = 0
    if ($SyncProjects) {
        $projAdded = Sync-ProjectsBidirectional -PoolProjectsDir $poolProjects
    }

    $pullInfo = 'skip'
    $pushInfo = 'skip'
    if ($SyncChats) {
        $py = Resolve-Python -Hint $PythonExe
        if ($py) {
            $brainFlag = if ($SyncBrain) { @() } else { @('--no-brain') }
            # Pull from this sub-account to pool (always safe, even while running!)
            $pullArgs = @($py.Prefix) + @('C:\ProgramData\AntigravityMulti\sync_chats.py', 'pull', '--account-antigravity', $subAgy, '--pool-dir', $poolChats) + $brainFlag
            $pullOut = & $py.Exe @pullArgs 2>&1
            $pullInfo = ($pullOut | Where-Object { $_ -like 'PULL_OK|*' } | Select-Object -Last 1)
            if (!$pullInfo) { $pullInfo = 'pull-err' }

            # Push from pool to this sub-account ONLY when idle (never writes live SQLite!)
            if (!$PullOnly) {
                $isRunning = Test-OwnAntigravityRunning
                if (!$isRunning) {
                    $pushArgs = @($py.Prefix) + @('C:\ProgramData\AntigravityMulti\sync_chats.py', 'push', '--pool-dir', $poolChats, '--account-antigravity', $subAgy) + $brainFlag
                    $pushOut = & $py.Exe @pushArgs 2>&1
                    $pushInfo = ($pushOut | Where-Object { $_ -like 'PUSH_OK|*' } | Select-Object -Last 1)
                    if (!$pushInfo) { $pushInfo = 'push-err' }
                } else {
                    $pushInfo = 'deferred-running'
                }
            }
        }
    }

    $summary = "OK|$env:USERNAME|projAdded=$projAdded|$pullInfo|$pushInfo"
    Write-SubLog $summary
    if ($StatusFile) { Set-Content -Path $StatusFile -Value $summary -Encoding UTF8 }
    exit 0
} catch {
    $err = "ERROR|$env:USERNAME|$($_.Exception.Message)"
    Write-SubLog $err
    if ($StatusFile) { Set-Content -Path $StatusFile -Value $err -Encoding UTF8 }
    exit 1
}
