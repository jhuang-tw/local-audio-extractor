Option Explicit

Dim shell, fso, scriptDir, ps1, command, inputPath
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "local-audio-extractor.ps1")

command = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & QuoteArg(ps1)

If WScript.Arguments.Count > 0 Then
    inputPath = WScript.Arguments(0)
    command = command & " -InputPath " & QuoteArg(inputPath)
End If

shell.Run command, 0, False

Function QuoteArg(value)
    QuoteArg = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
