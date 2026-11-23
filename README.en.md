# Antigravity Multi-Account Launcher (Windows Native)

[中文文档](./README.md)

Run multiple concurrent **Google Antigravity 2.0** desktop instances signed into **different Google accounts side-by-side on the same Windows 10/11 desktop**, using native Windows local-user SID isolation — with zero credential collisions, per-account proxy overrides, and lossless incremental syncing for plugins, projects, and AI conversation history.

---

## Why Standard Flags (`--user-data-dir`) Are Not Enough

1. **Global Credential Storage**: On Windows, Google Antigravity stores OAuth tokens per Windows user inside **Windows Credential Manager** (`gemini:antigravity`). Launching a second window under the same Windows user causes Account B to overwrite Account A's token.
2. **Single-Instance & SQLite Locks**: Electron enforces `%APPDATA%\Antigravity\lockfile`, and concurrent `language_server.exe` instances sharing `%USERPROFILE%\.gemini\antigravity\conversation_summaries.db` will conflict or corrupt the database.

### How This Project Solves It
Each extra Antigravity account runs under its own lightweight, standard local Windows user (`AgyAcc2`, `AgyAcc3`, ...) launched on your current interactive desktop via Windows' built-in **Secondary Logon (`seclogon`)** service:

- **True OS-Level Isolation**: Separate Windows Credential Manager vault, separate `%USERPROFILE%\.gemini\antigravity`, independent `installation_id`, separate Electron `%APPDATA%\Antigravity`, and independent `language_server.exe`.
- **Clean & Zero Plaintext Passwords**: Does not patch binaries or spoof internal checks. Generated local account passwords are encrypted at rest with the current Windows user's **DPAPI (`Export-Clixml`)**.
- **Hidden from Windows Sign-In Screen**: Optionally hides helper local accounts via `HKLM\...\Winlogon\SpecialAccounts\UserList` so your lock screen remains clean.
- **Per-Account Binary Copies**: Each account has its own copy under `%LOCALAPPDATA%\Programs\antigravity` and its own `HKCU` `antigravity://` handler, preventing auto-update file locks.
- **Per-Account Proxy & Region Verification**: Automatically follows your Windows system proxy (or TUN routing) by default, or lets you assign a dedicated local proxy port and optional exit-region check per account in `proxies.json`.
- **Automatic Incremental Bidirectional Sync for Projects & AI Chats**:
  - **Pre-Launch Auto-Sync (Cold Start)**: Launching an idle sub-account automatically pulls the latest Projects and conversations via a persistent `sync_pool` (typically `~1s` incrementally).
  - **Post-Exit Auto-Push**: Closing a sub-account window automatically merges its new conversations and projects back into `sync_pool`.
  - **10-Minute Silent Background Task**: User-level Windows Scheduled Task performs safe read-only SQLite hot-backups (`sqlite3.Connection.backup()`) across all accounts and pushes updates **only to idle accounts** (never interrupts running windows or corrupts live SQLite databases).
  - Grants minimal folder-level ACLs on synced project directories (keeping your main `AppData` private) and configures per-user Git `safe.directory`.

---

## Requirements

- **OS**: Windows 10 or Windows 11 (Home & Pro supported)
- **Prerequisites**:
  - **Google Antigravity** installed for your main Windows user (`%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe`)
  - Your current Windows account is in the `Administrators` group (one-time UAC prompt during setup; daily launching requires no admin elevation)
  - **Optional**: **Python 3** (standard library only, no `pip` packages) if you want to use `SyncChats`
- **Disk Space**: ~600 MB per isolated account for its standalone binary copy (plus conversation size if using `SyncChats`).

---

## Quick Start

### 1. Clone the Repository
```powershell
git clone https://github.com/shisisishi/antigravity-multi-windows.git
cd antigravity-multi-windows
```

### 2. Run the Interactive Installer
Double-click **`Install.cmd`**, follow the prompts (number of extra accounts, hide on sign-in screen, shared workspace path, optional chat history sync), and approve the single Windows UAC elevation prompt.

Desktop shortcuts (`Antigravity - Account 2`, `Account 3`, ...) will be created automatically. Double-click any shortcut for silent, passwordless side-by-side launching.

### 3. Signing Into New Isolated Windows (Important Tip)
On Windows 11, freshly created local accounts without an interactive Explorer logon do not have a default browser `UserChoice`, so clicking **`Continue with Google`** may spin without opening a browser.

**10-Second Official Loopback Sign-In**:
1. Click **`Copy sign-in link`** directly below the `Continue with Google` button.
2. Open your regular Chrome or Edge browser and open an **Incognito / InPrivate window (`Ctrl + Shift + N`)** so Google cookies stay completely separate from your main account.
3. Paste the sign-in link and complete Google OAuth. Once approved, the browser redirects to `localhost` loopback and the waiting Antigravity window signs in automatically.
4. Close that Incognito window before opening a fresh one for the next account.

---

## Per-Account Proxy Configuration (Optional)

Edit `C:\ProgramData\AntigravityMulti\proxies.json` (template in [`config/proxies.example.json`](./config/proxies.example.json)):

```json
{
  "accounts": {
    "AgyAcc2": {
      "proxy": "127.0.0.1:10802",
      "verifyRegion": "US"
    },
    "AgyAcc3": {
      "proxy": "",
      "verifyRegion": ""
    }
  }
}
```
- Leave `proxy` empty to inherit your current Windows system proxy (or direct/TUN routing).
- Set `proxy` to a dedicated local proxy port per account for independent exit IPs.
- Set `verifyRegion` (e.g. `"US"`) to verify exit country via Cloudflare trace before launch.

---

## Automatic Sync Configuration (`sync-config.json`)

Runtime configuration is stored at `C:\ProgramData\AntigravityMulti\sync-config.json` (template: [`config/sync-config.example.json`](./config/sync-config.example.json)):

```json
{
  "autoSyncOnLaunch": true,
  "autoPushOnExit": true,
  "syncProjects": true,
  "syncChats": true,
  "syncBrain": true,
  "backgroundIntervalMinutes": 10
}
```

---

## Management Commands

All maintenance actions live in `C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1`:

```powershell
# Run an immediate incremental bidirectional sync across all accounts (non-disruptive)
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action AutoSyncNow

# Enable / customize / disable silent background Windows Scheduled Task (no admin needed)
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action EnableAutoSync -IntervalMinutes 10
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action DisableAutoSync

# Check configured accounts and running concurrent instances
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action Status

# Sync updated Antigravity binaries, plugins, and projects to all sub-accounts
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action Sync

# Quickly sync newly added Projects and folder ACLs (hot, no restart needed)
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action SyncProjects

# Force-merge main AI conversations & brain artifacts into all sub-accounts
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action SyncChats

# Grant all sub-accounts read/write access to any folder
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action GrantFolder -FolderPath "D:\MyProject"

# Launch main + all sub-accounts
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action LaunchAll

# Add another account / Remove an account
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action Add -AccountNumber 5
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action Remove -AccountName AgyAcc4
```

---

## Disclaimer & Best Practices

- Always authenticate using official Google OAuth flows and adhere to Google's Terms of Service.
- Stagger initial sign-ins across new accounts and keep exit IPs consistent to minimize false-positive security checks. No client-side tool can guarantee immunity from server-side account checks.

---

## License

Licensed under the [MIT License](./LICENSE).
