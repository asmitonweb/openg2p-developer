@echo off
rem Windows wrapper: runs oan.sh through Git for Windows' bash (Docker Desktop + Git are the only requirements).
setlocal
set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not exist "%BASH%" (
  echo Git for Windows is required: https://git-scm.com/download/win
  exit /b 1
)
"%BASH%" "%~dp0oan.sh" %*
