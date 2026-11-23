$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$baseDir = 'C:\ProgramData\AntigravityMulti'
$hostDataDir = Join-Path $env:LOCALAPPDATA 'AntigravityMulti'
$credDir = Join-Path $hostDataDir 'creds'
$mainAppExe = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'
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

Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  Antigravity Multi-Account Installer (Windows Native)' -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host ''

if (!(Test-Path -LiteralPath $mainAppExe -PathType Leaf)) {
    Write-Host "ERROR: Google Antigravity not found at: $mainAppExe" -ForegroundColor Red
    Write-Host 'Please install Google Antigravity for your main user first.' -ForegroundColor Yellow
    Read-Host 'Press Enter to exit'
    exit 1
}

try {
    # 1. Interactive options
    $countRaw = Read-Host 'How many EXTRA Antigravity accounts do you want to create? [1-9, default: 3]'
    $extraCount = 3
    if ($countRaw -and $countRaw.Trim() -match '^\d+$') {
        $parsed = [int]$countRaw.Trim()
        if ($parsed -ge 1 -and $parsed -le 9) { $extraCount = $parsed }
    }

    $hideRaw = Read-Host 'Hide isolated accounts from Windows sign-in screen? [Y/n, default: Y]'
    $showOnLogin = ($hideRaw -match '^[nN]')

    $defaultShared = if (Test-Path 'D:\') { 'D:\AntigravityWorkspaces' } else { 'C:\AntigravityWorkspaces' }
    $sharedRaw = Read-Host "Shared workspace folder path (blank for $defaultShared, 'none' to skip)"
    $sharedWorkspace = if (!$sharedRaw) { $defaultShared } elseif ($sharedRaw.Trim().ToLowerInvariant() -eq 'none') { '' } else { $sharedRaw.Trim() }

    $syncChatsRaw = Read-Host 'Also copy existing AI chat history from main account? (requires Python 3) [y/N, default: N]'
    $doSyncChats = ($syncChatsRaw -match '^[yY]')

    $accounts = @()
    for ($i = 2; $i -le ($extraCount + 1); $i++) {
        $accounts += "AgyAcc$i"
    }

    Write-Host ''
    Write-Host "Installing $($accounts.Count) isolated account(s): $($accounts -join ', ')" -ForegroundColor Green

    # 2. Deploy runtime scripts to C:\ProgramData\AntigravityMulti
    New-Item -ItemType Directory -Force -Path $baseDir, (Join-Path $baseDir 'status'), $credDir | Out-Null
    $scriptFiles = @(
        'SilentLaunch.vbs',
        'Setup-Elevated.ps1',
        'SubUser-Init.ps1',
        'SubUser-Launch.ps1',
        'Host-Launch.ps1',
        'Manage-Accounts.ps1',
        'sync_chats.py'
    )
    foreach ($sf in $scriptFiles) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $sf) -Destination (Join-Path $baseDir $sf) -Force
    }

    # Create proxies.json if missing
    $proxiesDest = Join-Path $baseDir 'proxies.json'
    if (!(Test-Path -LiteralPath $proxiesDest -PathType Leaf)) {
        $acctMap = [ordered]@{}
        foreach ($a in $accounts) {
            $acctMap[$a] = [ordered]@{ proxy = ''; verifyRegion = '' }
        }
        $pObj = [ordered]@{
            _comment = 'Optional per-account proxy override. Leave proxy empty to follow current Windows system proxy. Example proxy: 127.0.0.1:10802. Optional verifyRegion: US.'
            accounts = $acctMap
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($proxiesDest, ($pObj | ConvertTo-Json -Depth 6), $utf8NoBom)
    }

    # 3. Generate DPAPI-encrypted local account credentials (bound to current Windows user)
    Write-Host '[1/4] Generating DPAPI-encrypted local credentials...' -ForegroundColor Yellow
    foreach ($acct in $accounts) {
        $credFile = Join-Path $credDir "$acct.xml"
        if (!(Test-Path -LiteralPath $credFile -PathType Leaf)) {
            $pwd = New-StrongPassword
            $secPwd = ConvertTo-SecureString $pwd -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential("$env:COMPUTERNAME\$acct", $secPwd)
            $cred | Export-Clixml -Path $credFile
        }
    }

    # 4. Run single UAC-elevated setup to create Windows accounts, enable seclogon, and set ACLs
    Write-Host '[2/4] Requesting Windows Administrator permission (UAC) to create isolated accounts...' -ForegroundColor Yellow
    $logFile = Join-Path $baseDir 'setup-elevated.log'
    $showFlag = if ($showOnLogin) { '-ShowOnSignInScreen' } else { '' }
    $sharedArg = if ($sharedWorkspace) { "-SharedWorkspace `"$sharedWorkspace`"" } else { '' }
    $elevArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$baseDir\Setup-Elevated.ps1`" -CredDir `"$credDir`" -Accounts `"$($accounts -join ',')`" -MainUser `"$env:USERNAME`" $sharedArg $showFlag -LogFile `"$logFile`""
    $elev = Start-Process -FilePath $psExe -ArgumentList $elevArgs -Verb RunAs -PassThru -Wait
    if ($elev.ExitCode -ne 0) {
        throw "Elevated setup failed (ExitCode=$($elev.ExitCode)). Check $logFile"
    }

    # 5. Initialize sub-user profiles, mirror Antigravity binaries, sync plugins & projects
    Write-Host '[3/4] Initializing isolated profiles and syncing Antigravity, plugins, and projects...' -ForegroundColor Yellow
    $global:LASTEXITCODE = 0
    & "$baseDir\Manage-Accounts.ps1" -Action Sync -ForceConfig
    if ($LASTEXITCODE -ne 0) { throw 'Profile sync failed.' }

    if ($doSyncChats) {
        Write-Host 'Syncing AI chat history (SQLite online hot backup)...' -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        & "$baseDir\Manage-Accounts.ps1" -Action SyncChats
        if ($LASTEXITCODE -ne 0) { throw 'Chat sync failed.' }
    }

    # 6. Create desktop shortcuts
    Write-Host '[4/4] Creating desktop shortcuts...' -ForegroundColor Yellow
    $desktop = [Environment]::GetFolderPath('Desktop')
    $wsh = New-Object -ComObject WScript.Shell
    for ($i = 2; $i -le ($extraCount + 1); $i++) {
        $acct = "AgyAcc$i"
        $lnkPath = Join-Path $desktop "Antigravity - Account $i.lnk"
        $sc = $wsh.CreateShortcut($lnkPath)
        $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $sc.Arguments = "`"$baseDir\SilentLaunch.vbs`" `"$acct`""
        $sc.WorkingDirectory = $baseDir
        $sc.IconLocation = "$mainAppExe,0"
        $sc.Description = "Antigravity Isolated Instance ($acct)"
        $sc.Save()
        Write-Host "  Created: $lnkPath" -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host '=== INSTALLATION COMPLETE ===' -ForegroundColor Green
    Write-Host 'Tip: When signing into a new Antigravity window, if the browser does not pop up automatically,' -ForegroundColor Cyan
    Write-Host 'click "Copy sign-in link" and open it in an Incognito/InPrivate browser window (Ctrl+Shift+N).' -ForegroundColor Cyan
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
Read-Host 'Press Enter to close this window'
