@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "PORT=9999"
if not "%~1"=="" set "PORT=%~1"

echo ==============================================
echo   Cloud Clipboard / File Server
echo   Port: %PORT%
echo ==============================================
echo.

set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY (
    where py >nul 2>nul && set "PY=py"
)

if not defined PY (
    echo [ERROR] Python not found in PATH.
    echo.
    echo Please install Python 3 from https://www.python.org/
    echo and make sure to check "Add Python to PATH".
    echo.
    echo This window will stay open. Press any key to close.
    echo.
    pause
    exit /b 1
)

echo Using interpreter: %PY%
echo Verifying Python... 
%PY% --version
if errorlevel 1 (
    echo.
    echo [ERROR] %PY% exists but failed to run.
    echo It may be the Microsoft Store stub. Install real Python
    echo from https://www.python.org/ and reopen this window.
    echo.
    pause
    exit /b 1
)
echo.

rem Open browser after 2 seconds so the server has time to start
start "" cmd /c "timeout /t 2 /nobreak >nul & start http://localhost:%PORT%/sync.html"

echo Starting server on port %PORT% ...
echo PC page : http://localhost:%PORT%/sync.html
echo To stop : close this window, or press Ctrl+C
echo -------------------------------------------------
echo.

%PY% upload_server.py %PORT%
set "RC=%ERRORLEVEL%"

echo.
echo -------------------------------------------------
if "%RC%"=="0" (
    echo [INFO] Server stopped normally.
) else (
    echo [ERROR] Server exited with code %RC%.
    echo Please read the messages above for the error details.
    echo Common causes: port %PORT% is already in use.
    echo Try a different port, e.g. run:  start.bat 8080
)
echo.
echo Window stays open. Press any key to close.
pause >nul
endlocal
