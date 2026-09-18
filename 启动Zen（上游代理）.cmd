@echo off
rem Zen launcher (optional convenience shortcut).
rem Since 2026-09-18 Zen reads upstream-proxy.txt from its own install
rem directory at startup - the chain engages no matter how Zen is started
rem (Start Menu, autostart, this launcher). No environment variables are
rem touched at all. To change the proxy address run the settings script
rem (see README).

set "ZEN_EXE=%LOCALAPPDATA%\Programs\Zen\Zen.exe"
if not exist "%ZEN_EXE%" set "ZEN_EXE=%ProgramFiles%\Zen\Zen.exe"
if not exist "%ZEN_EXE%" (
    echo Zen.exe not found. Run the build script first.
    pause
    exit /b 1
)

if exist "%ZEN_EXE%..\upstream-proxy.txt" (
    echo Starting Zen - upstream proxy config found, chaining will engage.
) else (
    echo Starting Zen - no upstream proxy config, direct mode.
)
start "" "%ZEN_EXE%"
