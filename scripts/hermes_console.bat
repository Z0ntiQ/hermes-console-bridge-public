@echo off
rem starts the HERMES tray applet; the tray finds hermes_bridge.ps1 next to itself
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0hermes_tray.ps1"
