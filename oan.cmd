@echo off
rem Windows wrapper: runs oan.sh through Git for Windows' bash (Docker Desktop + Git are the only requirements).
setlocal
set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not exist "%BASH%" for /f "delims=" %%G in ('where git 2^>nul') do if not defined GITEXE set "GITEXE=%%G"
if not exist "%BASH%" if defined GITEXE set "BASH=%GITEXE%\..\..\bin\bash.exe"
if not exist "%BASH%" (
  echo Git for Windows is required: https://git-scm.com/download/win
  exit /b 1
)
rem Colours, the checklist and the progress lines need a terminal type and UTF-8 output.
if not defined TERM set "TERM=xterm-256color"
chcp 65001 >nul
"%BASH%" "%~dp0oan.sh" %*
