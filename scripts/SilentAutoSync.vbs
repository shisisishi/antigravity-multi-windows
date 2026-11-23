Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\ProgramData\AntigravityMulti\AutoSync-Tick.ps1"""
sh.Run cmd, 0, False
