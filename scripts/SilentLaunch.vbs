Set sh = CreateObject("WScript.Shell")
If WScript.Arguments.Count < 1 Then WScript.Quit 1
acct = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\ProgramData\AntigravityMulti\Host-Launch.ps1"" -AccountName """ & acct & """"
sh.Run cmd, 0, False
