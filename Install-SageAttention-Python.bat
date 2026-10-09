@echo off
setlocal EnableExtensions DisableDelayedExpansion

pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Could not open the installer directory.
  goto :prelaunch_fail
)

set "SAGEATTN_DOUBLECLICK="
echo(%CMDCMDLINE% | findstr /i /c:" /c " >nul 2>&1 && set "SAGEATTN_DOUBLECLICK=1"

if not exist "python_embeded\python.exe" (
  echo.
  echo [ERROR] python_embeded\python.exe was not found.
  echo Place this file in the ComfyUI Windows Portable root folder.
  goto :prelaunch_fail
)

if not exist "Install-SageAttention.py" (
  echo.
  echo [ERROR] Install-SageAttention.py was not found next to this launcher.
  goto :prelaunch_fail
)

rem The launcher contains no resolver/install logic. The Python process handles
rem the guided UI and (for double-click starts) the final close prompt.
"python_embeded\python.exe" -S -B "Install-SageAttention.py" %*
set "SAGEATTN_EXIT=%ERRORLEVEL%"
goto :done

:prelaunch_fail
set "SAGEATTN_EXIT=1"
if defined SAGEATTN_DOUBLECLICK (
  echo.
  pause
)

:done
popd >nul 2>&1
exit /b %SAGEATTN_EXIT%
