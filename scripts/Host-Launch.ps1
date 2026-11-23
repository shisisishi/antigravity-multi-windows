param(
    [Parameter(Mandatory = $true)][string]$AccountName,
    [switch]$SkipProxyCheck,
    [switch]$NoDialog
)

$ErrorActionPreference = 'Stop'

$baseDir = 'C:\ProgramData\AntigravityMulti'
$hostDataDir = Join-Path $env:LOCALAPPDATA 'AntigravityMulti'
$credDir = Join-Path $hostDataDir 'creds'
New-Item -ItemType Directory -Force -Path $hostDataDir | Out-Null
$logFile = Join-Path $hostDataDir 'host-launch.log'

function Write-HostLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$AccountName] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Show-ErrorDialog {
    param([string]$Title, [string]$Message)
    Write-HostLog "ERROR: $Message"
    if ($NoDialog) {
        [Console]::Error.WriteLine($Message)
        return
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
    } catch {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-ProxyHealth {
    param([string]$ProxyHostPort, [string]$ExpectedRegion = '')
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $curlArgs = @('--disable', '--silent', '--noproxy', 'localhost,127.0.0.1,::1', '--connect-timeout', '5', '--max-time', '8')
    if ($ProxyHostPort) {
        $proxyUrl = if ($ProxyHostPort -match '^[a-zA-Z]+://') { $ProxyHostPort } else { "http://$ProxyHostPort" }
        $curlArgs += @('--proxy', $proxyUrl)
    }
    if ($ExpectedRegion) {
        $trace = & $curl @curlArgs --fail 'https://www.cloudflare.com/cdn-cgi/trace'
        if ($LASTEXITCODE -ne 0) {
            throw "Proxy ($ProxyHostPort) cannot reach Cloudflare trace. Ensure your proxy client is running."
        }
        $region = [regex]::Match(($trace -join "`n"), '(?m)^loc=([A-Z]{2})\r?$').Groups[1].Value
        if ($region -and $region -ne $ExpectedRegion.ToUpperInvariant()) {
            throw "Current exit region is '$region' (expected '$($ExpectedRegion.ToUpperInvariant())'). Switch to the expected region and retry."
        }
    }
    if ($ProxyHostPort) {
        $oauth = & $curl @curlArgs --output NUL --write-out '%{http_connect}:%{http_code}' --data 'grant_type=authorization_code' 'https://oauth2.googleapis.com/token'
        if ($LASTEXITCODE -ne 0 -or $oauth -ne '200:400') {
            throw "Proxy ($ProxyHostPort) cannot reach Google OAuth endpoint (result=$oauth). Check your proxy settings."
        }
    }
    Write-HostLog "Proxy verified: server='$ProxyHostPort' region='$ExpectedRegion'"
}

try {
    Write-HostLog 'Launch requested.'

    # 1. Resolve per-account proxy override from proxies.json, else follow current Windows system proxy
    $proxyEnable = 0
    $proxyServer = ''
    $verifyRegion = ''
    $customProxy = $false
    $proxyCfgPath = Join-Path $baseDir 'proxies.json'

    if (Test-Path -LiteralPath $proxyCfgPath -PathType Leaf) {
        try {
            $pCfg = Get-Content -LiteralPath $proxyCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pCfg.accounts -and $pCfg.accounts.PSObject.Properties[$AccountName]) {
                $entry = $pCfg.accounts.$AccountName
                if ($entry.PSObject.Properties['verifyRegion'] -and $entry.verifyRegion) {
                    $verifyRegion = $entry.verifyRegion.Trim()
                }
                if ($entry.proxy -and $entry.proxy.Trim() -ne '') {
                    $proxyServer = $entry.proxy.Trim()
                    $proxyEnable = 1
                    $customProxy = $true
                }
            }
        } catch {
            Write-HostLog "Warning: failed to parse proxies.json: $($_.Exception.Message)"
        }
    }

    if (!$customProxy) {
        $inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($inet -and $inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
            $proxyEnable = 1
            $proxyServer = $inet.ProxyServer
        } elseif ($env:HTTPS_PROXY) {
            $proxyEnable = 1
            $proxyServer = ($env:HTTPS_PROXY -replace '^[a-zA-Z]+://', '')
        } elseif ($env:HTTP_PROXY) {
            $proxyEnable = 1
            $proxyServer = ($env:HTTP_PROXY -replace '^[a-zA-Z]+://', '')
        }
    }

    if (!$SkipProxyCheck -and ($customProxy -or $verifyRegion)) {
        Test-ProxyHealth -ProxyHostPort $proxyServer -ExpectedRegion $verifyRegion
    }

    # 2. Load DPAPI-encrypted local account credential
    $credFile = Join-Path $credDir "$AccountName.xml"
    if (!(Test-Path -LiteralPath $credFile -PathType Leaf)) {
        throw "Account credential not found: $credFile. Please re-run Install.cmd."
    }
    $cred = Import-Clixml -Path $credFile

    # 3. Ensure Secondary Logon service is not disabled
    $seclogon = Get-Service -Name 'seclogon' -ErrorAction SilentlyContinue
    if ($seclogon -and $seclogon.StartType -eq 'Disabled') {
        throw 'Windows Secondary Logon (seclogon) service is disabled. Enable it to launch isolated accounts.'
    }

    $subScript = Join-Path $baseDir 'SubUser-Launch.ps1'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # Optional pre-launch incremental pull from main account into shared sync_pool
    $syncFlags = ''
    $syncCfgPath = Join-Path $baseDir 'sync-config.json'
    if (Test-Path -LiteralPath $syncCfgPath -PathType Leaf) {
        try {
            $sc = Get-Content -LiteralPath $syncCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($sc.autoSyncOnLaunch) {
                Write-HostLog 'Running pre-launch incremental pull (Main -> sync_pool)...'
                try {
                    & (Join-Path $baseDir 'AutoSync-Tick.ps1') -MainPullOnly
                } catch {
                    Write-HostLog "Warning: pre-launch pull skipped: $($_.Exception.Message)"
                }
                $syncFlags += ' -AutoSync'
            }
            if ($sc.autoPushOnExit) {
                $syncFlags += ' -AutoPushOnExit'
            }
        } catch {}
    }

    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$subScript`" -ProxyServer `"$proxyServer`" -ProxyEnable $proxyEnable$syncFlags"

    Write-HostLog "Starting isolated process as $($cred.UserName) (ProxyEnable=$proxyEnable ProxyServer=$proxyServer Flags=$syncFlags)"
    Start-Process -FilePath $psExe -ArgumentList $argList -Credential $cred -WorkingDirectory $baseDir -WindowStyle Hidden
    Write-HostLog 'Launch dispatched successfully.'
    exit 0
} catch {
    Show-ErrorDialog -Title "Antigravity ($AccountName)" -Message $_.Exception.Message
    exit 1
}
