param(
    [switch]$MainPullOnly,
    [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'

$baseDir = 'C:\ProgramData\AntigravityMulti'
$poolDir = Join-Path $baseDir 'sync_pool'
$poolProjects = Join-Path $poolDir 'projects'
$poolChats = Join-Path $poolDir 'chats'
$hostDataDir = Join-Path $env:LOCALAPPDATA 'AntigravityMulti'
$credDir = Join-Path $hostDataDir 'creds'
New-Item -ItemType Directory -Force -Path $hostDataDir, $poolProjects, $poolChats | Out-Null
$logFile = Join-Path $hostDataDir 'autosync.log'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-SyncLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    if ($VerboseOutput) { Write-Host $line }
}

function Get-SyncConfig {
    $cfgPath = Join-Path $baseDir 'sync-config.json'
    $defaults = [PSCustomObject]@{
        autoSyncOnLaunch = $true
        autoPushOnExit = $true
        syncProjects = $true
        syncChats = $true
        syncBrain = $true
        backgroundIntervalMinutes = 10
    }
    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        try {
            $parsed = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in @('autoSyncOnLaunch','autoPushOnExit','syncProjects','syncChats','syncBrain','backgroundIntervalMinutes')) {
                if ($parsed.PSObject.Properties[$prop]) { $defaults.$prop = $parsed.$prop }
            }
        } catch {}
    }
    return $defaults
}

function Resolve-HostPython {
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

function Ensure-PoolPermissions {
    param([string[]]$Accounts)
    if ($Accounts.Count -eq 0) { return }
    $acl = Get-Acl -LiteralPath $poolDir
    $existing = @($acl.Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights.ToString() -match 'Modify|FullControl')
    } | ForEach-Object { $_.IdentityReference.Value.Split('\')[-1] })
    $missing = @($Accounts | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -gt 0) {
        $args = @($poolDir)
        foreach ($a in $missing) { $args += '/grant'; $args += "${a}:(OI)(CI)M" }
        $args += '/C'
        & icacls.exe @args | Out-Null
    }
}

function Sync-MainProjectsToPool {
    param([string[]]$Accounts)
    $mainProjectsDir = Join-Path $env:USERPROFILE '.gemini\config\projects'
    if (!(Test-Path -LiteralPath $mainProjectsDir -PathType Container)) { return }
    $folders = @()
    Get-ChildItem -LiteralPath $mainProjectsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $pj = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pj.sidecar) { return }
            $dst = Join-Path $poolProjects "$($pj.id).json"
            if (!(Test-Path -LiteralPath $dst -PathType Leaf) -or ($_.LastWriteTimeUtc -gt (Get-Item -LiteralPath $dst).LastWriteTimeUtc)) {
                Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
            }
            if ($pj.projectResources -and $pj.projectResources.resources) {
                foreach ($r in $pj.projectResources.resources) {
                    if ($r.folderUri) {
                        $decoded = [Uri]::UnescapeDataString(($r.folderUri -replace '^file:///', '')).Replace('/', '\')
                        if ($decoded -match '^[a-zA-Z]:\\' -and (Test-Path -LiteralPath $decoded -PathType Container)) {
                            $folders += $decoded
                        }
                    }
                }
            }
        } catch {}
    }

    # Ensure newly added project folders are accessible to sub-accounts (fast no-op when ACL already set)
    foreach ($fp in ($folders | Select-Object -Unique)) {
        $acl = Get-Acl -LiteralPath $fp
        $existing = @($acl.Access | Where-Object {
            $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights.ToString() -match 'Modify|FullControl')
        } | ForEach-Object { $_.IdentityReference.Value.Split('\')[-1] })
        $missing = @($Accounts | Where-Object { $existing -notcontains $_ })
        if ($missing.Count -gt 0) {
            $icArgs = @($fp)
            foreach ($a in $missing) { $icArgs += '/grant'; $icArgs += "${a}:(OI)(CI)M" }
            $icArgs += '/C'
            & icacls.exe @icArgs | Out-Null
        }
    }
}

function Sync-PoolProjectsToMain {
    $mainProjectsDir = Join-Path $env:USERPROFILE '.gemini\config\projects'
    New-Item -ItemType Directory -Force -Path $mainProjectsDir | Out-Null
    Get-ChildItem -LiteralPath $poolProjects -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        $dst = Join-Path $mainProjectsDir $_.Name
        if (!(Test-Path -LiteralPath $dst -PathType Leaf)) {
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-MainAntigravityRunning {
    $mainPrefix = (Join-Path $env:LOCALAPPDATA 'Programs\antigravity').ToLowerInvariant()
    $procs = Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe' OR Name='language_server.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant().StartsWith($mainPrefix)
    }
    return (@($procs).Count -gt 0)
}

try {
    $cfg = Get-SyncConfig
    $accounts = if (Test-Path -LiteralPath $credDir) {
        @(Get-ChildItem -Path $credDir -Filter 'AgyAcc*.xml' | Sort-Object Name | ForEach-Object { $_.BaseName })
    } else { @() }

    if ($accounts.Count -eq 0) { exit 0 }
    Ensure-PoolPermissions -Accounts $accounts

    $py = Resolve-HostPython
    $pyHint = if ($py -and $py.Prefix.Count -eq 0) { $py.Exe } else { '' }
    $brainFlag = if ($cfg.syncBrain) { @() } else { @('--no-brain') }
    $mainAgy = Join-Path $env:USERPROFILE '.gemini\antigravity'

    # Step 1: Pull main account -> sync_pool (always safe even while main is running)
    if ($cfg.syncProjects) {
        Sync-MainProjectsToPool -Accounts $accounts
    }
    if ($cfg.syncChats -and $py) {
        $pullArgs = @($py.Prefix) + @("$baseDir\sync_chats.py", 'pull', '--account-antigravity', $mainAgy, '--pool-dir', $poolChats) + $brainFlag
        $pullOut = & $py.Exe @pullArgs 2>&1
        $pullLine = ($pullOut | Where-Object { $_ -like 'PULL_OK|*' } | Select-Object -Last 1)
        Write-SyncLog "Main->Pool: $pullLine"
    }

    if ($MainPullOnly) { exit 0 }

    # Step 2: Bidirectional tick across all sub-accounts (pull always, push only when idle)
    $flags = ''
    if ($cfg.syncProjects) { $flags += ' -SyncProjects' }
    if ($cfg.syncChats) { $flags += ' -SyncChats' }
    if ($cfg.syncBrain) { $flags += ' -SyncBrain' }
    if ($pyHint) { $flags += " -PythonExe `"$pyHint`"" }

    foreach ($acct in $accounts) {
        $credFile = Join-Path $credDir "$acct.xml"
        if (!(Test-Path -LiteralPath $credFile)) { continue }
        $cred = Import-Clixml -Path $credFile
        $stFile = Join-Path $baseDir "status\$acct.autosync"
        if (Test-Path -LiteralPath $stFile) { Remove-Item -LiteralPath $stFile -Force -ErrorAction SilentlyContinue }
        $subArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$baseDir\SubUser-SyncTick.ps1`" -PoolDir `"$poolDir`" -StatusFile `"$stFile`"$flags"
        $p = Start-Process -FilePath $psExe -ArgumentList $subArgs -Credential $cred -WorkingDirectory $baseDir -WindowStyle Hidden -PassThru
        $p.WaitForExit(120000) | Out-Null
        $st = if (Test-Path -LiteralPath $stFile) { (Get-Content -LiteralPath $stFile -Raw -Encoding UTF8).Trim().TrimStart([char]0xFEFF) } else { 'no-status' }
        Write-SyncLog "Sub($acct): $st"
    }

    # Step 3: Pull any new sub-account projects back to main; push chats back to main ONLY when main is idle
    if ($cfg.syncProjects) {
        Sync-PoolProjectsToMain
    }
    if ($cfg.syncChats -and $py) {
        if (!(Test-MainAntigravityRunning)) {
            $pushArgs = @($py.Prefix) + @("$baseDir\sync_chats.py", 'push', '--pool-dir', $poolChats, '--account-antigravity', $mainAgy) + $brainFlag
            $pushOut = & $py.Exe @pushArgs 2>&1
            $pushLine = ($pushOut | Where-Object { $_ -like 'PUSH_OK|*' } | Select-Object -Last 1)
            Write-SyncLog "Pool->Main: $pushLine"
        } else {
            Write-SyncLog 'Pool->Main: deferred (main Antigravity is running)'
        }
    }
    exit 0
} catch {
    Write-SyncLog "ERROR: $($_.Exception.Message)"
    exit 1
}
