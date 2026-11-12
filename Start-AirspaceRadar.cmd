@echo off
if not exist "%~dp0AirspaceRadar.exe" (
    "%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe" /nologo /target:winexe /reference:System.Windows.Forms.dll /out:"%~dp0AirspaceRadar.exe" "%~dp0tools\AirspaceDesktopLauncher.cs"
    if errorlevel 1 exit /b 1
)
start "" "%~dp0AirspaceRadar.exe"
