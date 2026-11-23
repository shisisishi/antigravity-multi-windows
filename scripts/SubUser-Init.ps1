param(
    [string]$SeedAppDir = '',
    [Parameter(Mandatory = $true)][string]$SeedConfigDir,
    [string]$SeedChatsDir = '',
    [Parameter(Mandatory = $true)][int]$AccountIndex,
    [string]$ProxyServer = '',
    [int]$ProxyEnable = 0,
    [string]$ExtraPathDirs = '',
    [string]$PythonExe = '',
    [string]$StatusFile = '',
    [switch]$ForceConfig,
    [switch]$ProjectsOnly,
    [switch]$ChatsOnly
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:LOCALAPPDATA 'AntigravityMulti'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'init.log'

function Write-SubLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Write-Status {
    param([string]$Text)
    if ($StatusFile) {
        Set-Content -Path $StatusFile -Value $Text -Encoding UTF8
    }
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
    throw 'Python 3 was not found in PATH. Install Python 3 to use SyncChats.'
}

try {
    Write-SubLog "SubUser-Init started for user=$env:USERNAME profile=$env:USERPROFILE ProjectsOnly=$ProjectsOnly ChatsOnly=$ChatsOnly"

    $targetAppDir = Join-Path $env:LOCALAPPDATA 'Programs\antigravity'
    $targetExe = Join-Path $targetAppDir 'Antigravity.exe'
    $targetConfigDir = Join-Path $env:USERPROFILE '.gemini\config'
    New-Item -ItemType Directory -Force -Path $targetConfigDir | Out-Null

    if (!$ProjectsOnly -and !$ChatsOnly) {
        # 1. Mirror Antigravity binary into this user's own LocalAppData
        New-Item -ItemType Directory -Force -Path $targetAppDir | Out-Null
        Write-SubLog "Syncing Antigravity binaries from $SeedAppDir to $targetAppDir"
        & robocopy.exe $SeedAppDir $targetAppDir /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -ge 8) {
            throw "robocopy app binaries failed with exit code $rc"
        }
        if (!(Test-Path -LiteralPath $targetExe -PathType Leaf)) {
            throw "Antigravity.exe missing after copy: $targetExe"
        }
        Write-SubLog "App binaries synced (robocopy=$rc)"

        # 2. Sync non-sensitive plugins & userSettings into ~/.gemini/config
        $seedPluginsDir = Join-Path $SeedConfigDir 'plugins'
        if (Test-Path -LiteralPath $seedPluginsDir -PathType Container) {
            $targetPluginsDir = Join-Path $targetConfigDir 'plugins'
            New-Item -ItemType Directory -Force -Path $targetPluginsDir | Out-Null
            & robocopy.exe $seedPluginsDir $targetPluginsDir /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XD '.git' 'cache' /XF '*.db' '*.db-wal' '*.db-shm' '*.log' | Out-Null
            if ($LASTEXITCODE -ge 8) {
                throw "robocopy plugins failed with exit code $LASTEXITCODE"
            }
            Write-SubLog 'Synced plugins directory'
        }

        $seedCapsuleSettings = Join-Path $SeedConfigDir 'agy-capsule\settings.json'
        if (Test-Path -LiteralPath $seedCapsuleSettings -PathType Leaf) {
            $targetCapsuleDir = Join-Path $targetConfigDir 'agy-capsule'
            $targetCapsuleSettings = Join-Path $targetCapsuleDir 'settings.json'
            New-Item -ItemType Directory -Force -Path $targetCapsuleDir | Out-Null
            if ($ForceConfig -or !(Test-Path -LiteralPath $targetCapsuleSettings -PathType Leaf)) {
                Copy-Item -LiteralPath $seedCapsuleSettings -Destination $targetCapsuleSettings -Force
                Write-SubLog 'Synced agy-capsule settings.json'
            }
        }

        $seedMainConfig = Join-Path $SeedConfigDir 'config.json'
        if (Test-Path -LiteralPath $seedMainConfig -PathType Leaf) {
            $targetMainConfig = Join-Path $targetConfigDir 'config.json'
            if ($ForceConfig -or !(Test-Path -LiteralPath $targetMainConfig -PathType Leaf)) {
                $raw = Get-Content -LiteralPath $seedMainConfig -Raw -Encoding UTF8
                $cfg = $raw | ConvertFrom-Json
                # Strip machine/sidecar identifiers to avoid cross-account collisions
                if ($cfg.PSObject.Properties['sidecars']) {
                    $cfg.PSObject.Properties.Remove('sidecars')
                }
                if ($cfg.userSettings) {
                    if ($cfg.userSettings.PSObject.Properties['remoteControlEnabled']) {
                        $cfg.userSettings.remoteControlEnabled = $false
                    }
                    if ($cfg.userSettings.PSObject.Properties['remoteControlHostname']) {
                        $cfg.userSettings.PSObject.Properties.Remove('remoteControlHostname')
                    }
                }
                $jsonOut = $cfg | ConvertTo-Json -Depth 12
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($targetMainConfig, $jsonOut, $utf8NoBom)
                Write-SubLog 'Synced sanitized config.json'
            }
        }
    }

    # Sync real (non-sidecar) projects preserving main project UUIDs so conversation_summaries.project_id links cleanly
    $seedProjectsDir = Join-Path $SeedConfigDir 'projects'
    $syncedProjectCount = 0
    if (Test-Path -LiteralPath $seedProjectsDir -PathType Container) {
        $targetProjectsDir = Join-Path $targetConfigDir 'projects'
        New-Item -ItemType Directory -Force -Path $targetProjectsDir | Out-Null

        $existingByUri = @{}
        Get-ChildItem -LiteralPath $targetProjectsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
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

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        Get-ChildItem -LiteralPath $seedProjectsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            $pj = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pj.sidecar) { return }
            $uris = @()
            if ($pj.projectResources -and $pj.projectResources.resources) {
                foreach ($r in $pj.projectResources.resources) {
                    if ($r.folderUri) { $uris += $r.folderUri }
                }
            }
            if ($uris.Count -eq 0) { return }

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

            $canonicalId = $pj.id
            $outPath = Join-Path $targetProjectsDir "$canonicalId.json"
            foreach ($u in $uris) {
                $key = $u.ToLowerInvariant()
                if ($existingByUri.ContainsKey($key) -and ($existingByUri[$key] -ne $outPath)) {
                    Remove-Item -LiteralPath $existingByUri[$key] -Force -ErrorAction SilentlyContinue
                }
            }
            [System.IO.File]::WriteAllText($outPath, ($pj | ConvertTo-Json -Depth 12), $utf8NoBom)
            $syncedProjectCount++
        }
        Write-SubLog "Synced projects (canonical IDs): count=$syncedProjectCount"
    }

    if ($ProjectsOnly -and !$ChatsOnly) {
        Write-SubLog 'SUBUSER_PROJECTS_SYNC_OK'
        Write-Status "OK|$(Get-Date -Format 'o')|$env:USERNAME|ProjectsSynced=$syncedProjectCount"
        exit 0
    }

    # Optional: Merge AI conversations + brain artifacts safely (closing ONLY this sub-user's own Antigravity processes first)
    if ($SeedChatsDir -and (Test-Path -LiteralPath $SeedChatsDir -PathType Container)) {
        $myAppPrefix = $targetAppDir.ToLowerInvariant()
        Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe' OR Name='language_server.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant().StartsWith($myAppPrefix)) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 1200

        $subAgyDir = Join-Path $env:USERPROFILE '.gemini\antigravity'
        New-Item -ItemType Directory -Force -Path $subAgyDir | Out-Null

        $py = Resolve-Python -Hint $PythonExe
        $pyArgs = @($py.Prefix) + @('C:\ProgramData\AntigravityMulti\sync_chats.py', 'merge-sub', '--seed-dir', $SeedChatsDir, '--sub-antigravity', $subAgyDir)
        $pyOut = & $py.Exe @pyArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "sync_chats.py merge-sub failed: $($pyOut -join ' ')"
        }
        $mergeSummary = ($pyOut | Where-Object { $_ -like 'MERGE_OK|*' } | Select-Object -Last 1)
        Write-SubLog "Chat DB merge result: $mergeSummary"

        $seedBrain = Join-Path $SeedChatsDir 'brain'
        if (Test-Path -LiteralPath $seedBrain -PathType Container) {
            $subBrain = Join-Path $subAgyDir 'brain'
            New-Item -ItemType Directory -Force -Path $subBrain | Out-Null
            & robocopy.exe $seedBrain $subBrain /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD 'browser_sandbox' | Out-Null
            if ($LASTEXITCODE -ge 8) {
                Write-SubLog "Warning: robocopy brain exited with $LASTEXITCODE"
            } else {
                Write-SubLog "Synced brain artifacts (robocopy=$LASTEXITCODE)"
            }
        }

        if ($ChatsOnly) {
            Write-SubLog 'SUBUSER_CHATS_SYNC_OK'
            Write-Status "OK|$(Get-Date -Format 'o')|$env:USERNAME|Projects=$syncedProjectCount|$mergeSummary"
            exit 0
        }
    }

    # 3. Configure per-user Internet Settings proxy
    $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (!(Test-Path -LiteralPath $inetKey)) { New-Item -Path $inetKey -Force | Out-Null }
    Set-ItemProperty -Path $inetKey -Name 'ProxyEnable' -Value $ProxyEnable -Type DWord
    if ($ProxyEnable -eq 1 -and $ProxyServer) {
        Set-ItemProperty -Path $inetKey -Name 'ProxyServer' -Value $ProxyServer -Type String
        Set-ItemProperty -Path $inetKey -Name 'ProxyOverride' -Value 'localhost;127.0.0.1;::1;<local>' -Type String
    }
    Write-SubLog "Configured HKCU proxy: Enable=$ProxyEnable Server=$ProxyServer"

    # 4. Register per-user antigravity:// URL protocol pointing to THIS user's exe
    $protoRoot = 'HKCU:\Software\Classes\antigravity'
    $protoCmd = 'HKCU:\Software\Classes\antigravity\shell\open\command'
    New-Item -Path $protoCmd -Force | Out-Null
    Set-ItemProperty -Path $protoRoot -Name '(default)' -Value 'URL:Antigravity Protocol'
    Set-ItemProperty -Path $protoRoot -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path $protoCmd -Name '(default)' -Value "`"$targetExe`" `"%1`""
    Write-SubLog "Registered HKCU antigravity:// protocol -> $targetExe"

    # 5. Sync shared non-user-scoped dev tool directories into this user's User PATH
    if ($ExtraPathDirs) {
        $extraTools = @($ExtraPathDirs -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
        $curPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @()
        if ($curPath) {
            $parts = @($curPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
        }
        foreach ($dir in $extraTools) {
            if ((Test-Path -LiteralPath $dir -PathType Container) -and ($parts -notcontains $dir)) {
                $parts += $dir
            }
        }
        $newPath = $parts -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-SubLog "Updated User PATH: $newPath"
    }

    Write-SubLog 'SUBUSER_INIT_OK'
    Write-Status "OK|$(Get-Date -Format 'o')|$env:USERNAME|$targetExe"
    exit 0
} catch {
    $errMsg = $_.Exception.Message
    Write-SubLog "SUBUSER_INIT_ERROR: $errMsg"
    Write-Status "ERROR|$(Get-Date -Format 'o')|$env:USERNAME|$errMsg"
    exit 1
}
