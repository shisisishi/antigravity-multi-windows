param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Sync', 'SyncProjects', 'SyncChats', 'AutoSyncNow', 'EnableAutoSync', 'DisableAutoSync', 'GrantFolder', 'LaunchAll', 'Add', 'Remove', 'Status')]
    [string]$Action,
    [string]$FolderPath = '',
    [int]$AccountNumber = 0,
    [string]$AccountName = '',
    [int]$IntervalMinutes = 10,
    [switch]$ForceConfig
)

$ErrorActionPreference = 'Stop'

$baseDir = 'C:\ProgramData\AntigravityMulti'
$hostDataDir = Join-Path $env:LOCALAPPDATA 'AntigravityMulti'
$credDir = Join-Path $hostDataDir 'creds'
$mainAppDir = Join-Path $env:LOCALAPPDATA 'Programs\antigravity'
$mainConfigDir = Join-Path $env:USERPROFILE '.gemini\config'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-StrongPassword {
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 24
    $rng.GetBytes($bytes)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%^&*_-'
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 18; $i++) {
        [void]$sb.Append($chars[$bytes[$i] % $chars.Length])
    }
    return ('Aa9!' + $sb.ToString())
}

function Get-ConfiguredAccounts {
    if (!(Test-Path -LiteralPath $credDir)) { return @() }
    return @(Get-ChildItem -Path $credDir -Filter 'AgyAcc*.xml' | Sort-Object Name | ForEach-Object { $_.BaseName })
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
    throw 'Python 3 is required for SyncChats. Install Python 3 and ensure python or py is in PATH.'
}

function Get-SharedUserPathDirs {
    $userProfilePrefix = $env:USERPROFILE.TrimEnd('\')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (!$userPath) { return '' }
    $shared = @($userPath -split ';' | Where-Object {
        $d = $_.Trim().TrimEnd('\')
        $d -and (!$d.StartsWith($userProfilePrefix, [System.StringComparison]::OrdinalIgnoreCase)) -and (Test-Path -LiteralPath $d -PathType Container)
    } | Select-Object -Unique)
    return ($shared -join ';')
}

function Grant-ProjectFoldersAccess {
    param([string[]]$Accounts, [string[]]$FolderPaths)
    foreach ($fp in $FolderPaths) {
        if (!(Test-Path -LiteralPath $fp -PathType Container)) { continue }
        $acl = Get-Acl -LiteralPath $fp
        $existingIdentities = @($acl.Access | Where-Object {
            $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights.ToString() -match 'Modify|FullControl')
        } | ForEach-Object { $_.IdentityReference.Value.Split('\')[-1] })

        $missing = @($Accounts | Where-Object { $existingIdentities -notcontains $_ })
        if ($missing.Count -eq 0) {
            Write-Host "  [ACL already OK] $fp"
            continue
        }
        $icaclsArgs = @($fp)
        foreach ($acct in $missing) {
            $icaclsArgs += '/grant'
            $icaclsArgs += "${acct}:(OI)(CI)M"
        }
        $icaclsArgs += '/C'
        Write-Host "  [ACL] Granting $($missing -join ',') on $fp ..."
        & icacls.exe @icaclsArgs | Out-Null
    }
}

function Stage-RealProjects {
    param([string]$SeedProjectsDir, [string[]]$Accounts)
    $mainProjectsDir = Join-Path $mainConfigDir 'projects'
    if (!(Test-Path -LiteralPath $mainProjectsDir -PathType Container)) { return @() }
    New-Item -ItemType Directory -Force -Path $SeedProjectsDir | Out-Null

    $folderPaths = @()
    Get-ChildItem -LiteralPath $mainProjectsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $pj = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pj.sidecar) { return }
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $SeedProjectsDir $_.Name) -Force
            if ($pj.projectResources -and $pj.projectResources.resources) {
                foreach ($r in $pj.projectResources.resources) {
                    if ($r.folderUri) {
                        $decoded = [Uri]::UnescapeDataString(($r.folderUri -replace '^file:///', '')).Replace('/', '\')
                        if ($decoded -match '^[a-zA-Z]:\\' -and (Test-Path -LiteralPath $decoded -PathType Container)) {
                            $folderPaths += $decoded
                        }
                    }
                }
            }
        } catch {}
    }

    if ($folderPaths.Count -gt 0) {
        $uniqueFolders = @($folderPaths | Select-Object -Unique)
        Write-Host "Granting minimal project folder access ($($uniqueFolders.Count) folders) to $($Accounts -join ', ')..."
        Grant-ProjectFoldersAccess -Accounts $Accounts -FolderPaths $uniqueFolders
        return $uniqueFolders
    }
    return @()
}

function Sync-SubAccounts {
    param([string[]]$Accounts, [switch]$OverwriteConfig, [switch]$ProjectsOnly, [switch]$IncludeChats)
    $seedRoot = Join-Path $baseDir 'seed'
    $seedApp = Join-Path $seedRoot 'app'
    $seedCfg = Join-Path $seedRoot 'config'
    $seedChats = Join-Path $seedRoot 'chats'
    if (Test-Path -LiteralPath $seedRoot) { Remove-Item -LiteralPath $seedRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $seedApp, $seedCfg | Out-Null

    if (!$ProjectsOnly -and !$IncludeChats) {
        if (!(Test-Path -LiteralPath (Join-Path $mainAppDir 'Antigravity.exe') -PathType Leaf)) {
            throw "Antigravity.exe not found at $mainAppDir. Please install Google Antigravity first."
        }
        Write-Host 'Preparing staging copy of Antigravity binaries and plugins...'
        & robocopy.exe $mainAppDir $seedApp /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Failed to stage Antigravity app binaries (robocopy=$LASTEXITCODE)" }

        if (Test-Path -LiteralPath (Join-Path $mainConfigDir 'plugins')) {
            & robocopy.exe (Join-Path $mainConfigDir 'plugins') (Join-Path $seedCfg 'plugins') /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XD '.git' 'cache' /XF '*.db' '*.db-wal' '*.db-shm' '*.log' | Out-Null
        }
        if (Test-Path -LiteralPath (Join-Path $mainConfigDir 'config.json')) {
            Copy-Item -LiteralPath (Join-Path $mainConfigDir 'config.json') -Destination (Join-Path $seedCfg 'config.json') -Force
        }
        if (Test-Path -LiteralPath (Join-Path $mainConfigDir 'agy-capsule\settings.json')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $seedCfg 'agy-capsule') | Out-Null
            Copy-Item -LiteralPath (Join-Path $mainConfigDir 'agy-capsule\settings.json') -Destination (Join-Path $seedCfg 'agy-capsule\settings.json') -Force
        }
    }

    $stagedFolders = Stage-RealProjects -SeedProjectsDir (Join-Path $seedCfg 'projects') -Accounts $Accounts

    $pythonHint = ''
    if ($IncludeChats) {
        New-Item -ItemType Directory -Force -Path $seedChats | Out-Null
        $mainAgyDir = Join-Path $env:USERPROFILE '.gemini\antigravity'
        $py = Resolve-HostPython
        if ($py.Prefix.Count -eq 0) { $pythonHint = $py.Exe }
        Write-Host 'Hot-backing up main account SQLite conversations (non-disruptive)...'
        $pyArgs = @($py.Prefix) + @("$baseDir\sync_chats.py", 'export-main', '--main-antigravity', $mainAgyDir, '--seed-dir', $seedChats)
        $expOut = & $py.Exe @pyArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to export main conversations: $($expOut -join ' ')"
        }
        Write-Host "  $($expOut | Select-Object -Last 1)"

        $mainBrain = Join-Path $mainAgyDir 'brain'
        if (Test-Path -LiteralPath $mainBrain -PathType Container) {
            Write-Host 'Staging brain artifacts (excluding browser_sandbox)...'
            & robocopy.exe $mainBrain (Join-Path $seedChats 'brain') /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD 'browser_sandbox' | Out-Null
            if ($LASTEXITCODE -ge 8) {
                Write-Host "  Warning: robocopy brain exited with $LASTEXITCODE"
            }
        }
    }

    & icacls.exe $seedRoot /grant '*S-1-5-32-545:(OI)(CI)RX' /C | Out-Null

    $inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $proxyEnable = if ($inet -and $inet.ProxyEnable -eq 1 -and $inet.ProxyServer) { 1 } else { 0 }
    $proxyServer = if ($proxyEnable -eq 1) { $inet.ProxyServer } else { '' }
    $extraPathDirs = Get-SharedUserPathDirs

    try {
        foreach ($acct in $Accounts) {
            $idx = 2
            if ($acct -match '(\d+)$') { $idx = [int]$Matches[1] }
            $cred = Import-Clixml -Path (Join-Path $credDir "$acct.xml")
            $statusFile = Join-Path $baseDir "status\$acct.status"
            if (Test-Path -LiteralPath $statusFile) { Remove-Item -LiteralPath $statusFile -Force }

            $extraFlags = ''
            if ($OverwriteConfig) { $extraFlags += ' -ForceConfig' }
            if ($ProjectsOnly) { $extraFlags += ' -ProjectsOnly' }
            if ($IncludeChats) { $extraFlags += " -SeedChatsDir `"$seedChats`" -ChatsOnly" }
            if ($extraPathDirs) { $extraFlags += " -ExtraPathDirs `"$extraPathDirs`"" }
            if ($pythonHint) { $extraFlags += " -PythonExe `"$pythonHint`"" }

            $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$baseDir\SubUser-Init.ps1`" -SeedAppDir `"$seedApp`" -SeedConfigDir `"$seedCfg`" -AccountIndex $idx -ProxyServer `"$proxyServer`" -ProxyEnable $proxyEnable -StatusFile `"$statusFile`"$extraFlags"
            Write-Host "Syncing isolated profile for $acct..."
            $proc = Start-Process -FilePath $psExe -ArgumentList $args -Credential $cred -WorkingDirectory $baseDir -WindowStyle Hidden -PassThru
            $proc.WaitForExit(300000) | Out-Null
            if (!$proc.HasExited) {
                throw "Timed out waiting for $acct sync."
            }
            $statusText = if (Test-Path -LiteralPath $statusFile) { (Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8).Trim().TrimStart([char]0xFEFF) } else { "ExitCode=$($proc.ExitCode)" }
            $exitOk = ($null -eq $proc.ExitCode -or $proc.ExitCode -eq 0)
            if (!$exitOk -or $statusText -notlike 'OK|*') {
                throw "Sync failed for ${acct}: $statusText (ExitCode=$($proc.ExitCode))"
            }
            Write-Host "  [OK] $acct -> $statusText"
        }
    } finally {
        if (Test-Path -LiteralPath $seedRoot) {
            Remove-Item -LiteralPath $seedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Create-DesktopShortcut {
    param([string]$AccountName, [int]$Index)
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop "Antigravity - Account $Index.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc.Arguments = "`"$baseDir\SilentLaunch.vbs`" `"$AccountName`""
    $sc.WorkingDirectory = $baseDir
    $sc.IconLocation = "$mainAppDir\Antigravity.exe,0"
    $sc.Description = "Launch isolated Antigravity instance ($AccountName)"
    $sc.Save()
    Write-Host "  Shortcut created: $lnkPath"
}

switch ($Action) {
    'Status' {
        $accts = Get-ConfiguredAccounts
        Write-Host "Configured sub-accounts ($($accts.Count)): $($accts -join ', ')"
        Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe'" |
            Where-Object { $_.CommandLine -notmatch '(?:^|\s)--(?:type=|import(?:[=\s]|$))' } |
            ForEach-Object {
                $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
                [PSCustomObject]@{
                    PID = $_.ProcessId
                    Owner = if ($owner -and $owner.User) { $owner.User } else { '(isolated-user)' }
                    Path = $_.ExecutablePath
                }
            } | Format-Table -AutoSize
    }
    'Sync' {
        $accts = Get-ConfiguredAccounts
        if ($accts.Count -eq 0) { throw 'No sub-accounts configured yet.' }
        Sync-SubAccounts -Accounts $accts -OverwriteConfig:$ForceConfig
        Write-Host 'All sub-accounts synced successfully.'
    }
    'SyncProjects' {
        $accts = Get-ConfiguredAccounts
        if ($accts.Count -eq 0) { throw 'No sub-accounts configured yet.' }
        Sync-SubAccounts -Accounts $accts -ProjectsOnly
        Write-Host 'All projects synced successfully.'
    }
    'SyncChats' {
        $accts = Get-ConfiguredAccounts
        if ($accts.Count -eq 0) { throw 'No sub-accounts configured yet.' }
        Sync-SubAccounts -Accounts $accts -IncludeChats
        Write-Host 'All projects and AI conversations synced successfully.'
    }
    'AutoSyncNow' {
        & "$baseDir\AutoSync-Tick.ps1" -VerboseOutput
        Write-Host 'Incremental bidirectional auto-sync tick completed.'
    }
    'EnableAutoSync' {
        if ($IntervalMinutes -lt 1) { $IntervalMinutes = 10 }
        $taskName = 'AntigravityMultiAutoSync'
        $tr = "`"$env:SystemRoot\System32\wscript.exe`" `"$baseDir\SilentAutoSync.vbs`""
        & schtasks.exe /Create /TN $taskName /SC MINUTE /MO $IntervalMinutes /TR $tr /F
        if ($LASTEXITCODE -ne 0) { throw "Failed to register scheduled task $taskName" }
        Write-Host "Background auto-sync enabled: every $IntervalMinutes minute(s) via Scheduled Task '$taskName'."
    }
    'DisableAutoSync' {
        $taskName = 'AntigravityMultiAutoSync'
        & schtasks.exe /Delete /TN $taskName /F 2>$null
        Write-Host "Background auto-sync scheduled task '$taskName' removed."
    }
    'GrantFolder' {
        if (!$FolderPath -or !(Test-Path -LiteralPath $FolderPath -PathType Container)) {
            throw "Valid -FolderPath is required: $FolderPath"
        }
        $accts = Get-ConfiguredAccounts
        $icaclsArgs = @($FolderPath)
        foreach ($acct in $accts) {
            $icaclsArgs += '/grant'
            $icaclsArgs += "${acct}:(OI)(CI)M"
        }
        $icaclsArgs += '/C'
        & icacls.exe @icaclsArgs
        Write-Host "Granted access on $FolderPath to: $($accts -join ', ')"
    }
    'LaunchAll' {
        $mainRunning = Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe'" |
            Where-Object { $_.ExecutablePath -eq (Join-Path $mainAppDir 'Antigravity.exe') -and $_.CommandLine -notmatch '(?:^|\s)--(?:type=|import(?:[=\s]|$))' }
        if (!$mainRunning) {
            Start-Process -FilePath (Join-Path $mainAppDir 'Antigravity.exe') -ArgumentList '--remote-debugging-port=0' -WorkingDirectory $mainAppDir
            Start-Sleep -Seconds 2
        }
        foreach ($acct in (Get-ConfiguredAccounts)) {
            & $psExe -NoProfile -ExecutionPolicy Bypass -File "$baseDir\Host-Launch.ps1" -AccountName $acct
            Start-Sleep -Seconds 2
        }
    }
    'Add' {
        if ($AccountNumber -lt 2) { throw 'Please provide -AccountNumber >= 2 (e.g. -AccountNumber 5).' }
        $acct = "AgyAcc$AccountNumber"
        New-Item -ItemType Directory -Force -Path $credDir | Out-Null
        $pwd = New-StrongPassword
        $secPwd = ConvertTo-SecureString $pwd -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("$env:COMPUTERNAME\$acct", $secPwd)
        $cred | Export-Clixml -Path (Join-Path $credDir "$acct.xml")

        $logFile = Join-Path $baseDir 'setup-elevated.log'
        $elevArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$baseDir\Setup-Elevated.ps1`" -CredDir `"$credDir`" -Accounts `"$acct`" -MainUser `"$env:USERNAME`" -LogFile `"$logFile`""
        $elev = Start-Process -FilePath $psExe -ArgumentList $elevArgs -Verb RunAs -PassThru -Wait
        if ($elev.ExitCode -ne 0) {
            throw "Elevated setup failed. Check $logFile"
        }
        Sync-SubAccounts -Accounts @($acct) -OverwriteConfig
        Create-DesktopShortcut -AccountName $acct -Index $AccountNumber
        Write-Host "Account $acct added successfully."
    }
    'Remove' {
        if (!$AccountName -or $AccountName -notmatch '^AgyAcc\d+$') {
            throw 'Provide -AccountName like AgyAcc4.'
        }
        $idx = [int]($AccountName -replace '^AgyAcc', '')
        $removeCmd = "Remove-LocalUser -Name '$AccountName' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList' -Name '$AccountName' -ErrorAction SilentlyContinue"
        $elev = Start-Process -FilePath $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$removeCmd`"" -Verb RunAs -PassThru -Wait
        Remove-Item -LiteralPath (Join-Path $credDir "$AccountName.xml") -Force -ErrorAction SilentlyContinue
        $desktop = [Environment]::GetFolderPath('Desktop')
        foreach ($name in @("Antigravity - Account $idx.lnk", "Antigravity - 账号$idx.lnk")) {
            Remove-Item -LiteralPath (Join-Path $desktop $name) -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Removed $AccountName (note: user profile folder C:\Users\$AccountName can be deleted via System Properties -> User Profiles if desired)."
    }
}
exit 0
