@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "S3_EP=https://dc-s3.spring8.or.jp"

:: ===== args =====
set "BUCKET=%~1"
set "EXP=%~2"
if "%BUCKET%"=="" (
  echo Usage: %~nx0 ^<bucket-name^> [expires-seconds]
  exit /b 1
)
if not defined EXP set "EXP=1209600"

:: ===== S3 tweaks (helpful for S3-compatible targets like DDN) =====
set "AWS_S3_FORCE_PATH_STYLE=1"
if not defined S3_REGION set "S3_REGION=us-east-1"

:: ===== optional env: set S3_EP, AWS_PROFILE in advance if needed =====
set "AWS_ARGS="
if defined AWS_PROFILE set "AWS_ARGS=%AWS_ARGS% --profile %AWS_PROFILE%"
if defined S3_EP      set "AWS_ARGS=%AWS_ARGS% --endpoint-url %S3_EP%"

where aws >nul 2>&1 || ( echo [ERROR] AWS CLI not found. & exit /b 1 )

:: ===== names/paths =====
for %%A in ("%CD%") do set "CURDIR_NAME=%%~nxA"
if not defined CURDIR_NAME set "CURDIR_NAME=downloads"
set "UP_PREFIX=%CURDIR_NAME%/"
set "OUTBAT=%CURDIR_NAME%.bat"
set "MANIFEST_NAME=%CURDIR_NAME%.url-list"
set "MANIFEST=%CD%\%MANIFEST_NAME%"

:: ===== ensure bucket =====
aws %AWS_ARGS% s3 ls "s3://%BUCKET%" >nul 2>&1 || (
  aws %AWS_ARGS% s3 mb "s3://%BUCKET%" || ( echo [ERROR] bucket create failed. & exit /b 1 )
)

:: ===== clean outputs =====
if exist "%OUTBAT%" del /q "%OUTBAT%" >nul 2>&1
if exist "%MANIFEST%" del /q "%MANIFEST%" >nul 2>&1

:: ===== write downloader header =====
>>"%OUTBAT%" echo mkdir "%CURDIR_NAME%"
>>"%OUTBAT%" echo @echo off
>>"%OUTBAT%" echo setlocal EnableExtensions EnableDelayedExpansion
>>"%OUTBAT%" echo echo Download to ".\%CURDIR_NAME%"
>>"%OUTBAT%" echo if not exist "%%~dp0%MANIFEST_NAME%" ^(
>>"%OUTBAT%" echo   echo Manifest not found: "%%~dp0%MANIFEST_NAME%"
>>"%OUTBAT%" echo   exit /b 1
>>"%OUTBAT%" echo ^)
>>"%OUTBAT%" echo.

echo Scanning, uploading and presigning...
set /a MATCH=0
set /a ADDED=0

for /f "delims=" %%F in ('dir /b /a-d') do (
  set "N=%%~nxF"
  set "OK="
  echo !N! | findstr /I /R "\.tar\.gz$"  >nul && set "OK=1"
  echo !N! | findstr /I /R "\.tar\.bz2$" >nul && set "OK=1"
  if /I "%%~xF"==".zip" set "OK=1"
  if /I "%%~xF"==".7z"  set "OK=1"
  if /I "%%~xF"==".tar" set "OK=1"
  if /I "%%~xF"==".gz"  ( echo !N! | findstr /I /R "\.tar\.gz$"  >nul || set "OK=1" )
  if /I "%%~xF"==".bz2" ( echo !N! | findstr /I /R "\.tar\.bz2$" >nul || set "OK=1" )

  if defined OK (
    set /a MATCH+=1
    set "FN=%%~nxF"
    echo   [UPLOAD] "%%F" ^> "s3://%BUCKET%/%UP_PREFIX%!FN!"
    aws %AWS_ARGS% s3 cp "%%F" "s3://%BUCKET%/%UP_PREFIX%!FN!"
    if errorlevel 1 (
      echo   !! upload failed: %%F
    ) else (
      set "URLFILE=%TEMP%\presign_url_!RANDOM!.txt"
      aws %AWS_ARGS% s3 presign "s3://%BUCKET%/%UP_PREFIX%!FN!" --expires-in %EXP% --region %S3_REGION% > "!URLFILE!" 2> "!URLFILE!.err"
      if errorlevel 1 (
        echo   !! presign failed: %%F
        for /f "usebackq delims=" %%E in ("!URLFILE!.err") do echo       %%E
      ) else (
        >>"%MANIFEST%" <nul set /p="!FN!^|"
        type "!URLFILE!" >>"%MANIFEST%"
        >>"%MANIFEST%" echo.
        set /a ADDED+=1
        echo   [OK] added: !FN!
      )
      del /q "!URLFILE!" "!URLFILE!.err" >nul 2>&1
    )
  )
)

if %MATCH%==0 (
  echo [INFO] no archive files in current directory.
  echo No downloader will be generated.
  del /q "%OUTBAT%" >nul 2>&1
  exit /b 0
)

:: ===== write downloader body (avoid premature ! expansion) =====
setlocal DisableDelayedExpansion
>>"%OUTBAT%" echo for /f "usebackq tokens=1* delims=^|" %%%%A in ("%%~dp0%MANIFEST_NAME%") do (
>>"%OUTBAT%" echo   set "NAME=%%%%~A"
>>"%OUTBAT%" echo   set "URL=%%%%B"
>>"%OUTBAT%" echo   echo Download !NAME!
>>"%OUTBAT%" echo   curl "!URL!" --output "%CURDIR_NAME%\!NAME!" 
>>"%OUTBAT%" echo   call :extract "%CURDIR_NAME%\!NAME!"
>>"%OUTBAT%" echo )
>>"%OUTBAT%" echo goto :done
>>"%OUTBAT%" echo.

>>"%OUTBAT%" echo :extract
>>"%OUTBAT%" echo setlocal EnableExtensions EnableDelayedExpansion
>>"%OUTBAT%" echo set "F=%%~1"
>>"%OUTBAT%" echo set "NAME=%%~nx1"
>>"%OUTBAT%" echo set "BASE=%%NAME%%"
>>"%OUTBAT%" echo rem --- base name: strip composite suffix (.tar.gz/.tgz/.tar.bz2/.tbz2) ---
>>"%OUTBAT%" echo if /I "%%~x1"==".zip"            set "BASE=%%~n1"
>>"%OUTBAT%" echo if /I "%%~x1"==".tar"            set "BASE=%%~n1"
>>"%OUTBAT%" echo if /I "%%~x1"==".7z"            set "BASE=%%~n1"
>>"%OUTBAT%" echo if /I "%%NAME:~-7%%"==".tar.gz"  set "BASE=%%NAME:~0,-7%%"
>>"%OUTBAT%" echo if /I "%%NAME:~-4%%"==".tgz"     set "BASE=%%NAME:~0,-4%%"
>>"%OUTBAT%" echo if /I "%%NAME:~-8%%"==".tar.bz2" set "BASE=%%NAME:~0,-8%%"
>>"%OUTBAT%" echo if /I "%%NAME:~-5%%"==".tbz2"    set "BASE=%%NAME:~0,-5%%"
>>"%OUTBAT%" echo set "OUTDIR=%CURDIR_NAME%\%%BASE%%"
>>"%OUTBAT%" echo if not exist "%%OUTDIR%%" mkdir "%%OUTDIR%%" ^>nul 2^>nul
>>"%OUTBAT%" echo rem --- prefer 7z; fallback to Windows tar ---
>>"%OUTBAT%" echo set "SEVENZIP=C:\Program Files\7-Zip\7z.exe"
>>"%OUTBAT%" echo if exist "%%SEVENZIP%%" ^(echo 7zip extraction ^& goto __x7z^) 
>>"%OUTBAT%" echo if not exist "%%SEVENZIP%%" ^(echo windows system extraction ^& goto __xtar^)
>>"%OUTBAT%" echo.
>>"%OUTBAT%" echo :__x7z
>>"%OUTBAT%" echo rem two-stage for compressed tarballs via 7z
>>"%OUTBAT%" echo if /I "%%NAME:~-7%%"==".tar.gz"  ^( "%%SEVENZIP%%" e -y -so -tgzip "%%F%%" ^| "%%SEVENZIP%%" x -y -si -ttar -o"%%OUTDIR%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%NAME:~-4%%"==".tgz"     ^( "%%SEVENZIP%%" e -y -so -tgzip "%%F%%" ^| "%%SEVENZIP%%" x -y -si -ttar -o"%%OUTDIR%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%NAME:~-8%%"==".tar.bz2" ^( "%%SEVENZIP%%" e -y -so -tbzip2 "%%F%%" ^| "%%SEVENZIP%%" x -y -si -ttar -o"%%OUTDIR%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%NAME:~-5%%"==".tbz2"    ^( "%%SEVENZIP%%" e -y -so -tbzip2 "%%F%%" ^| "%%SEVENZIP%%" x -y -si -ttar -o"%%OUTDIR%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%~x1"==".tar"  ^( "%%SEVENZIP%%" x -y -o"%%OUTDIR%%" -ttar "%%F%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%~x1"==".zip"  ^( "%%SEVENZIP%%" x -y -o"%%OUTDIR%%" "%%F%%"      ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%~x1"==".7z"   ^( "%%SEVENZIP%%" x -y -o"%%OUTDIR%%" "%%F%%"      ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%~x1"==".gz"   ^( "%%SEVENZIP%%" e -y -o"%%OUTDIR%%" -tgzip "%%F%%"      ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%~x1"==".bz2"  ^( "%%SEVENZIP%%" e -y -o"%%OUTDIR%%" -tbzip2 "%%F%%"      ^& goto __post ^)
>>"%OUTBAT%" echo echo [WARN] cannot extract: %%F%% ^(no handler in 7z path^)
>>"%OUTBAT%" echo goto :eof
>>"%OUTBAT%" echo.
>>"%OUTBAT%" echo :__xtar
>>"%OUTBAT%" echo rem Windows tar fallback
>>"%OUTBAT%" echo if /I "%%NAME:~-7%%"==".tar.gz"  ^( tar -C "%%OUTDIR%%" -xvzf "%%F%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%NAME:~-4%%"==".tgz"     ^( tar -C "%%OUTDIR%%" -xzvf "%%F%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%NAME:~-8%%"==".tar.bz2" ^( tar -C "%%OUTDIR%%" -xjvf "%%F%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%NAME:~-5%%"==".tbz2"    ^( tar -C "%%OUTDIR%%" -xjvf "%%F%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%~x1"==".tar"            ^( tar -C "%%OUTDIR%%" -xvf  "%%F%%" ^& goto __post ^)
>>"%OUTBAT%" echo if /I "%%~x1"==".zip"            ^( tar -C "%%OUTDIR%%" -xvf  "%%F%%" ^& goto __post ^)
>>"%OUTBAT%" echo echo [WARN] cannot extract: %%F%% ^(need 7z for this type^)
>>"%OUTBAT%" echo goto :eof
>>"%OUTBAT%" echo.
>>"%OUTBAT%" echo :__post
>>"%OUTBAT%" echo rem --- flatten double folder ---
>>"%OUTBAT%" echo if exist "%%OUTDIR%%\%%BASE%%\" ^(
>>"%OUTBAT%" echo   if exist "%%SystemRoot%%\System32\robocopy.exe" ^(
>>"%OUTBAT%" echo     robocopy "%%OUTDIR%%\%%BASE%%" "%%OUTDIR%%" /E /MOVE ^>nul
>>"%OUTBAT%" echo     rmdir /s /q "%%OUTDIR%%\%%BASE%%" 2^>nul
>>"%OUTBAT%" echo   ^) else ^(
>>"%OUTBAT%" echo     xcopy "%%OUTDIR%%\%%BASE%%\*" "%%OUTDIR%%\*" /E /I /Y ^>nul
>>"%OUTBAT%" echo     rmdir /s /q "%%OUTDIR%%\%%BASE%%" 2^>nul
>>"%OUTBAT%" echo   ^)
>>"%OUTBAT%" echo ^)
>>"%OUTBAT%" echo goto :eof
>>"%OUTBAT%" echo.
>>"%OUTBAT%" echo :done
>>"%OUTBAT%" echo echo All downloads complete.
>>"%OUTBAT%" echo endlocal & exit /b 0

echo Done.
if exist "%MANIFEST%" (
  for /f %%C in ('^<"%MANIFEST%" find /c /v ""') do set MCOUNT=%%C
  echo Manifest : "%MANIFEST%"  entries=%MCOUNT%
) else (
  echo Manifest : (none written)
)
echo Downloader: "%OUTBAT%"
echo Upload prefix: s3://%BUCKET%/%UP_PREFIX%*

endlocal
