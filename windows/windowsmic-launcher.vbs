' Hidden launcher for windowsmic.ps1.
'
' powershell -WindowStyle Hidden alone is not enough: in PS5.1 the conhost
' window is created BEFORE -WindowStyle is applied, so it briefly flashes,
' and on some Windows builds it stays visible until the script exits. This
' VBS uses WScript.Shell.Run with intWindowStyle=0 (vbHidden), which
' creates the powershell process with the window already hidden -- no flash
' and nothing for the user to see in the taskbar.
'
' The path to the script is taken from the same directory as this .vbs so
' the launcher works regardless of install location.
Set fso  = CreateObject("Scripting.FileSystemObject")
Set sh   = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path   = fso.BuildPath(scriptDir, "windowsmic.ps1")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1Path & """", 0, False
