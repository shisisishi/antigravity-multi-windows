param(
    [Parameter(Mandatory = $true)][string]$CredDir,
    [Parameter(Mandatory = $true)][string[]]$Accounts,
    [Parameter(Mandatory = $true)][string]$MainUser,
    [string]$SharedWorkspace = '',
    [switch]$ShowOnSignInScreen,
    [string]$LogFile = 'C:\ProgramData\AntigravityMulti\setup-elevated.log'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
    Set-Content -Path $LogFile -Value '' -Encoding UTF8
    $AccountList = @($Accounts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Log "Elevated setup started. MainUser=$MainUser Accounts=$($AccountList -join ',')"

    # 1. Ensure Secondary Logon service (seclogon) is Automatic and Running
    Write-Log 'Configuring Secondary Logon (seclogon) service...'
    Set-Service -Name 'seclogon' -StartupType Automatic
    $svc = Get-Service -Name 'seclogon'
    if ($svc.Status -ne 'Running') {
        Start-Service -Name 'seclogon'
        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    }
    Write-Log "seclogon status: $((Get-Service -Name 'seclogon').Status)"

    # Resolve localized builtin Users group name via well-known SID S-1-5-32-545
    $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $usersGroupFull = $usersSid.Translate([System.Security.Principal.NTAccount]).Value
    $usersGroupName = $usersGroupFull.Split('\')[-1]
    Write-Log "Resolved Users group: $usersGroupName"

    # 2. Create or update isolated standard local Windows accounts
    $hideRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (!$ShowOnSignInScreen -and !(Test-Path -LiteralPath $hideRegPath)) {
        New-Item -Path $hideRegPath -Force | Out-Null
    }

    foreach ($acct in $AccountList) {
        $credFile = Join-Path $CredDir "$acct.xml"
        if (!(Test-Path -LiteralPath $credFile -PathType Leaf)) {
            throw "Credential file not found: $credFile"
        }
        $cred = Import-Clixml -Path $credFile
        $existing = Get-LocalUser -Name $acct -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "Updating existing local user: $acct"
            Set-LocalUser -Name $acct -Password $cred.Password -PasswordNeverExpires $true
            if (!$existing.Enabled) {
                Enable-LocalUser -Name $acct
            }
        } else {
            Write-Log "Creating local user: $acct"
            New-LocalUser -Name $acct -Password $cred.Password `
                -FullName "Antigravity $acct" `
                -Description 'Antigravity isolated account' `
                -PasswordNeverExpires | Out-Null
        }

        $isMember = Get-LocalGroupMember -Group $usersGroupName -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*\$acct" }
        if (!$isMember) {
            Add-LocalGroupMember -Group $usersGroupName -Member $acct
            Write-Log "Added $acct to group $usersGroupName"
        }

        if (!$ShowOnSignInScreen) {
            New-ItemProperty -Path $hideRegPath -Name $acct -Value 0 -PropertyType DWord -Force | Out-Null
            Write-Log "Hidden $acct from Windows sign-in screen"
        }
    }

    # 3. Configure ACLs on ProgramData\AntigravityMulti, status, and sync_pool directories
    $baseDir = 'C:\ProgramData\AntigravityMulti'
    $statusDir = Join-Path $baseDir 'status'
    $poolDir = Join-Path $baseDir 'sync_pool'
    New-Item -ItemType Directory -Force -Path $statusDir, $poolDir | Out-Null

    & icacls.exe $baseDir /grant "${MainUser}:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" /T /C | Out-Null
    foreach ($acct in $AccountList) {
        & icacls.exe $statusDir /grant "${acct}:(OI)(CI)M" /C | Out-Null
        & icacls.exe $poolDir /grant "${acct}:(OI)(CI)M" /C | Out-Null
    }
    Write-Log 'Configured ProgramData\AntigravityMulti permissions (including sync_pool)'

    # 4. Create optional shared workspace folder and grant full control to main + sub accounts
    if ($SharedWorkspace) {
        New-Item -ItemType Directory -Force -Path $SharedWorkspace | Out-Null
        $icaclsArgs = @($SharedWorkspace, '/grant', "${MainUser}:(OI)(CI)F")
        foreach ($acct in $AccountList) {
            $icaclsArgs += '/grant'
            $icaclsArgs += "${acct}:(OI)(CI)F"
        }
        $icaclsArgs += '/C'
        & icacls.exe @icaclsArgs | Out-Null
        Write-Log "Configured shared workspace: $SharedWorkspace"
    }

    Write-Log 'ELEVATED_SETUP_SUCCESS'
    exit 0
} catch {
    Write-Log "ELEVATED_SETUP_ERROR: $($_.Exception.Message)"
    exit 1
}
