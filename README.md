# Antigravity Multi-Account Launcher (Windows Native)

[English Documentation](./README.en.md)

在 **Windows 10 / 11** 上通过**系统原生本地多用户安全隔离（SID 级物理隔离）**，实现 **Google Antigravity 2.0 桌面端**同屏并行多开、登录多个不同 Google 账号、互不串号，并支持一键同步 **插件、设置、Projects 以及历史 AI 对话**。

---

## 为什么直接双开或只改 `--user-data-dir` 行不通？

1. **全局登录态冲突**：Google Antigravity 在 Windows 上使用**Windows 凭据管理器**（`gemini:antigravity`）按当前 Windows 用户全局保存 OAuth 凭据。在同一 Windows 用户下打开多个实例，登录账号 B 会直接覆盖账号 A 的登录态，造成频繁顶号/串号。
2. **Electron 单实例锁与数据库竞争**：`%APPDATA%\Antigravity\lockfile` 阻止重复打开窗口，且多个 `language_server.exe` 并发读写同一个 `%USERPROFILE%\.gemini\antigravity\conversation_summaries.db` 会引发数据库锁死或损坏。

### 本项目方案：Windows 原生标准本地用户隔离
为每个额外账号创建专用的受限 Windows 本地标准用户（如 `AgyAcc2`、`AgyAcc3`、`AgyAcc4`），借助 Windows 原生 `Secondary Logon` 服务（`seclogon`）在**当前桌面同屏并排显示多个 Antigravity 窗口**：

- **100% 物理隔离**：各自独立的 Windows 凭据管理器、独立 `%USERPROFILE%\.gemini\antigravity`、独立 `installation_id`、独立 `%APPDATA%\Antigravity`、独立 `language_server.exe`。
- **零修改、零外挂、零明文密码**：不修改 Antigravity 二进制本体，不篡改/欺骗任何内部检查；副账户本地密码使用当前主用户的 **Windows DPAPI (`Export-Clixml`)** 加密存储，磁盘上绝无明文。
- **开机锁屏无感隐藏**：通过标准注册表项 `Winlogon\SpecialAccounts\UserList` 隐藏辅助本地账户，日常开机登录界面只显示你的原主账号。
- **独立程序副本**：每个副账号在各自 `%LOCALAPPDATA%\Programs\antigravity` 拥有独立程序副本并注册各自用户的 `antigravity://` 协议，避免自动更新锁文件冲突。
- **灵活的代理隔离**：支持自动跟随当前系统代理（或 TUN 模式），也支持在 `proxies.json` 中为**每个账号单独绑定不同本地代理端口与可选出口地区校验**。
- **Projects & 历史 AI 对话全自动双向增量同步**：
  - **启动前秒同步（冷启动生效）**：双击任意副账号时自动增量拉取主账号及其他账号的最新 Projects 和对话（借助持久化中心同步池 `sync_pool`，增量同步通常仅需 `~1 秒`）。
  - **关闭后自动回传**：副账号窗口关闭后，自动把该账号新聊的对话与新建 Projects 合并回中心同步池。
  - **后台每 10 分钟静默巡检**：通过用户级 Windows 计划任务自动只读热备份所有账号的新对话（基于 Python 标准库 `sqlite3.Connection.backup()`），并仅向当前空闲未运行的账号增量写入，**绝不强关正在使用的窗口、绝不损坏 SQLite 数据库、绝不误删副账号自己的新对话**。
  - 自动对具体项目目录授予最小读写权限（不暴露主用户 `AppData`），并自动配置各副账号的 Git `safe.directory`。

---

## 环境要求

- **操作系统**：Windows 10 / Windows 11（家庭版 / 专业版均支持）
- **前置软件**：
  - 已在主账号下安装 **Google Antigravity 桌面版**（`%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe`）
  - 当前 Windows 用户属于 `Administrators` 组（仅首次初始化及新增/删除账号时需要一次 UAC 提权，日常启动完全无需管理员权限）
  - **可选**：如需同步历史 AI 对话（`SyncChats`），需系统已安装 **Python 3**（仅使用标准库，零第三方依赖）
- **磁盘空间**：每个副账号约占 `~600 MB`（独立 Antigravity 程序副本）；如同步历史对话与 `brain/` 产物，空间取决于主账号历史对话大小。

---

## 快速上手

### 1. 下载项目
```powershell
git clone https://github.com/shisisishi/antigravity-multi-windows.git
cd antigravity-multi-windows
```

### 2. 一键交互式安装
双击仓库根目录的 **`Install.cmd`**（按提示输入要新增的副账号数量、是否隐藏登录界面、是否同步历史 AI 对话），在弹出的 Windows 管理员（UAC）确认框点击 **「是」**。

安装完成后，你的桌面会自动出现对应图标（例如 `Antigravity - Account 2`、`Antigravity - Account 3`、`Antigravity - Account 4`），直接双击即可无黑框免密启动，与你现有的主账号同屏并排运行！

### 3. 首次登录新账号（重要避坑）
在 Windows 11 上，由于新建的隐藏本地账户从未登录过交互式桌面，未配置默认浏览器 `UserChoice`，点击新窗口里的 **`Continue with Google`** 时可能一直转圈而未弹出浏览器。

**10 秒完美解决方法（官方回环 OAuth 流程）**：
1. 直接点击登录按钮下方的 **`Copy sign-in link`**（复制登录链接）。
2. 打开你平时使用的 Chrome / Edge，按 **`Ctrl + Shift + N`** 打开一个**无痕/隐身窗口**（确保与主浏览器 Cookie 100% 隔离、绝不串号）。
3. 粘贴登录链接并完成该副账号的 Google 授权。授权完成后浏览器会自动回调本地 `localhost` 回环端口，背后转圈的对应副账号 Antigravity 窗口将**瞬间完成登录**。
4. 登录下一个副账号前，**先关闭上一个无痕窗口**，再重新按 `Ctrl + Shift + N` 打开新的无痕窗口重复以上步骤。

---

## 每账号独立代理配置（推荐）

为了进一步降低多账号共用同一出口 IP 或跨区跳变带来的风控风险，可编辑运行时配置文件：

```text
C:\ProgramData\AntigravityMulti\proxies.json
```

示例（详见 [`config/proxies.example.json`](./config/proxies.example.json)）：
```json
{
  "accounts": {
    "AgyAcc2": {
      "proxy": "127.0.0.1:10802",
      "verifyRegion": "US"
    },
    "AgyAcc3": {
      "proxy": "127.0.0.1:10803",
      "verifyRegion": "US"
    },
    "AgyAcc4": {
      "proxy": "",
      "verifyRegion": ""
    }
  }
}
```
- `proxy` 留空：自动跟随主账号当前的 Windows 系统代理（若使用 TUN 全局模式则自动直连）。
- `proxy` 填写本地端口：该账号的 Antigravity 及后台 `language_server` 将强制走对应独立代理端口。
- `verifyRegion` 填写两位国家码（如 `"US"`）：启动前自动通过 Cloudflare Trace 校验出口国家与 Google OAuth 连通性，地区不符直接弹窗拦截，防止误登。

---

## 自动同步配置（`sync-config.json`）

运行时配置文件位于 `C:\ProgramData\AntigravityMulti\sync-config.json`（模板见 [`config/sync-config.example.json`](./config/sync-config.example.json)）：

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

- `autoSyncOnLaunch`：冷启动任意副账号前自动增量同步最新 Projects 与对话。
- `autoPushOnExit`：副账号窗口关闭后自动把新对话回传到中心同步池 `sync_pool`。
- **安全机制**：对运行中账号仅执行 SQLite 只读热备份（Pull），对数据库写入（Push）仅在目标账号空闲未运行时执行，避免多进程写锁损坏。

---

## 日常维护命令

所有维护操作统一由 `C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1` 提供：

```powershell
# 1. 立即执行一次全账号增量双向自动同步（不打断运行中窗口）
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action AutoSyncNow

# 2. 开启 / 修改 / 关闭后台静默定时自动同步（默认每 10 分钟，无需管理员权限）
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action EnableAutoSync -IntervalMinutes 10
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action DisableAutoSync

# 3. 查看当前已配置的副账号与运行中的并发实例
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action Status

# 4. 主账号更新 Antigravity 或安装新插件后，同步到所有副账号（可选加 -ForceConfig 覆盖全局设置）
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action Sync

# 5. 仅快速同步新增的 Projects 及目录读写权限（无需关闭副账号窗口）
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action SyncProjects

# 6. 强制全量合并主账号对话到所有副账号（会先安全关闭已打开的副账号窗口）
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action SyncChats

# 7. 手动给任意项目文件夹授予所有副账号的读写权限
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action GrantFolder -FolderPath "D:\MyProject"

# 8. 一键同时启动主账号与全部副账号
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action LaunchAll

# 9. 继续新增第 5 个账号 / 移除指定副账号
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action Add -AccountNumber 5
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AntigravityMulti\Manage-Accounts.ps1" -Action Remove -AccountName AgyAcc4
```

---

## 使用与合规提示

- **防风控建议**：请始终使用官方 OAuth 流程登录，避免短时间内在同一共享代理 IP 上连续密集登录多个新账号，尽量为每个账号保持固定地区的稳定出口 IP。没有任何客户端工具可以保证 100% 规避服务端风控，请遵守 Google 服务条款合理使用。
- **关于对话实时同步**：由于 SQLite 无法被多个独立 `language_server` 进程跨用户直接并发写入，本项目采用安全的**按需增量合并同步**（`SyncChats`），在合并前仅自动关闭对应副账号进程，不触碰主账号。

---

## 开源协议

本项目基于 [MIT License](./LICENSE) 开源。
