@echo off
title Akatsuki local server
REM Double-click to run the hub locally. Leave this window open while testing.
REM Same-origin trap: this port does NOT share localStorage with Calendar or Sukkiri.
REM Supabase, signed in as the same user, is the only cross-app path.
cd /d "%~dp0"

set "ROOT=."
if not exist "%ROOT%\index.html" (
  echo Could not find index.html in this folder.
  echo Put this .bat in the same folder as index.html ^(your Akatsuki folder^).
  echo Current folder: %CD%
  pause & goto :eof
)

REM --- Find a Python: PATH first, then common Anaconda/Miniconda locations ---
REM (double-clicking uses plain cmd, where conda's PATH is usually NOT active,
REM  so we look for python.exe directly.)
set "PY="
for %%P in (
  "python.exe"
  "%USERPROFILE%\anaconda3\python.exe"
  "%USERPROFILE%\miniconda3\python.exe"
  "%USERPROFILE%\AppData\Local\anaconda3\python.exe"
  "%USERPROFILE%\AppData\Local\miniconda3\python.exe"
  "%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
  "%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
  "C:\ProgramData\anaconda3\python.exe"
  "C:\ProgramData\miniconda3\python.exe"
) do (
  if not defined PY (
    "%%~P" -c "import sys" >nul 2>nul && set "PY=%%~P"
  )
)

if not defined PY (
  echo.
  echo Could not find Python automatically.
  echo Open "Anaconda Prompt", cd to this folder, and run:
  echo     python -m http.server 8092 --directory "%ROOT%"
  echo.
  pause & goto :eof
)

echo.
echo   Akatsuki - the hub - local server
echo   Python:  %PY%
echo   Serving: %ROOT%    Open: http://localhost:8092/
echo   (Close this window to stop.)
echo.

start "" "http://localhost:8092/"
"%PY%" -m http.server 8092 --directory "%ROOT%"

echo.
echo Server stopped.
pause
