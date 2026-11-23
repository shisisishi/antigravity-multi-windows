param(
    [string]$ProxyServer = '',
    [int]$ProxyEnable = 0,
    [switch]$AutoSync,
    [switch]$AutoPushOnExit
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:LOCALAPPDATA 'AntigravityMulti'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'launch.log'

function Write-SubLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

try {
    $appDir = Join-Path $env:LOCALAPPDATA 'Programs\antigravity'
    $appExe = Join-Path $appDir 'Antigravity.exe'
    if (!(Test-Path -LiteralPath $appExe -PathType Leaf)) {
        throw "Antigravity.exe not found for $env:USERNAME at $appExe"
    }

    # 1. Sync per-user Windows proxy settings
    $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (!(Test-Path -LiteralPath $inetKey)) { New-Item -Path $inetKey -Force | Out-Null }
    Set-ItemProperty -Path $inetKey -Name 'ProxyEnable' -Value $ProxyEnable -Type DWord
    if ($ProxyEnable -eq 1 -and $ProxyServer) {
        Set-ItemProperty -Path $inetKey -Name 'ProxyServer' -Value $ProxyServer -Type String
        Set-ItemProperty -Path $inetKey -Name 'ProxyOverride' -Value 'localhost;127.0.0.1;::1;<local>' -Type String
    }

    try {
        Add-Type -Namespace WinINet -Name Native -MemberDefinition @'
            [System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true)]
            public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
'@ -ErrorAction SilentlyContinue
        [WinINet.Native]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
        [WinINet.Native]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    } catch {
        # Best-effort WinINet refresh
    }

    # 2. Ensure antigravity:// protocol points to this user's own Antigravity.exe
    $protoRoot = 'HKCU:\Software\Classes\antigravity'
    $protoCmd = 'HKCU:\Software\Classes\antigravity\shell\open\command'
    New-Item -Path $protoCmd -Force | Out-Null
    Set-ItemProperty -Path $protoRoot -Name '(default)' -Value 'URL:Antigravity Protocol'
    Set-ItemProperty -Path $protoRoot -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path $protoCmd -Name '(default)' -Value "`"$appExe`" `"%1`""

    # 3. Set proxy environment variables for Electron + language_server
    if ($ProxyEnable -eq 1 -and $ProxyServer) {
        $proxyUrl = if ($ProxyServer -match '^[a-zA-Z]+://') { $ProxyServer } else { "http://$ProxyServer" }
        $env:HTTP_PROXY = $proxyUrl
        $env:HTTPS_PROXY = $proxyUrl
        $env:ALL_PROXY = $proxyUrl
        $env:NO_PROXY = 'localhost,127.0.0.1,::1'
    } else {
        Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:ALL_PROXY -ErrorAction SilentlyContinue
    }

    # 4. Cold-start auto-sync before launching Antigravity (never touches live SQLite if already running)
    $myAppPrefix = $appDir.ToLowerInvariant()
    $alreadyRunning = @(Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe' OR Name='language_server.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant().StartsWith($myAppPrefix)
    }).Count -gt 0

    $syncCfgPath = 'C:\ProgramData\AntigravityMulti\sync-config.json'
    $syncProjects = $true; $syncChats = $true; $syncBrain = $true
    if (Test-Path -LiteralPath $syncCfgPath -PathType Leaf) {
        try {
            $sc = Get-Content -LiteralPath $syncCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($sc.PSObject.Properties['syncProjects']) { $syncProjects = [bool]$sc.syncProjects }
            if ($sc.PSObject.Properties['syncChats']) { $syncChats = [bool]$sc.syncChats }
            if ($sc.PSObject.Properties['syncBrain']) { $syncBrain = [bool]$sc.syncBrain }
        } catch {}
    }

    if ($AutoSync -and !$alreadyRunning -and (Test-Path -LiteralPath 'C:\ProgramData\AntigravityMulti\SubUser-SyncTick.ps1')) {
        Write-SubLog 'Running cold-start auto-sync before launching Antigravity...'
        try {
            & 'C:\ProgramData\AntigravityMulti\SubUser-SyncTick.ps1' -SyncProjects:$syncProjects -SyncChats:$syncChats -SyncBrain:$syncBrain
        } catch {
            Write-SubLog "Warning: cold-start auto-sync failed: $($_.Exception.Message)"
        }
    }

    Write-SubLog "Launching $appExe (ProxyEnable=$ProxyEnable ProxyServer=$ProxyServer AlreadyRunning=$alreadyRunning)"
    $proc = Start-Process -FilePath $appExe -ArgumentList '--remote-debugging-port=0' -WorkingDirectory $appDir -PassThru

    # 5. Optional post-exit pull back into shared sync_pool when this window closes
    if ($AutoPushOnExit -and !$alreadyRunning -and $proc -and (Test-Path -LiteralPath 'C:\ProgramData\AntigravityMulti\SubUser-SyncTick.ps1')) {
        try {
            $proc.WaitForExit()
            Start-Sleep -Milliseconds 1500
            Write-SubLog 'Antigravity exited; pulling new conversations/projects back to sync_pool...'
            & 'C:\ProgramData\AntigravityMulti\SubUser-SyncTick.ps1' -SyncProjects:$syncProjects -SyncChats:$syncChats -SyncBrain:$syncBrain -PullOnly
        } catch {
            Write-SubLog "Warning: post-exit sync failed: $($_.Exception.Message)"
        }
    }
    exit 0
} catch {
    Write-SubLog "LAUNCH_ERROR: $($_.Exception.Message)"
    exit 1
}
