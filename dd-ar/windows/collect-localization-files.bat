@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title Collect Double Dealers localization files

set "GAME=E:\SteamLibrary\steamapps\common\Double Dealers Demo"
set "AA=%GAME%\Double Dealers - Demo_Data\StreamingAssets\aa"
set "OUT=%USERPROFILE%\Desktop\dd-files"

echo ============================================================
echo   Collecting the localization files for translation
echo ============================================================
echo.

if not exist "%AA%" (
  echo [!] Game folder not found at:
  echo     %AA%
  echo.
  echo     Open Steam ^> right click the game ^> Manage ^> Browse local files
  echo     and check the folder name. Then edit the GAME path inside this file.
  echo.
  pause
  exit /b 1
)

if exist "%OUT%" rd /s /q "%OUT%"
mkdir "%OUT%" 2>nul

echo [1/3] Copying the localization bundles...
copy /y "%AA%\StandaloneWindows64\localization-string-tables-english(en)_assets_all.bundle" "%OUT%\" >nul 2>&1
copy /y "%AA%\StandaloneWindows64\localization-locales_assets_all.bundle"              "%OUT%\" >nul 2>&1
copy /y "%AA%\StandaloneWindows64\localization-assets-shared_assets_all.bundle"        "%OUT%\" >nul 2>&1

echo [2/3] Copying catalog + settings...
copy /y "%AA%\catalog.bin"    "%OUT%\" >nul 2>&1
copy /y "%AA%\catalog.hash"   "%OUT%\" >nul 2>&1
copy /y "%AA%\settings.json"  "%OUT%\" >nul 2>&1

echo [3/3] Creating the zip file...
powershell -NoProfile -Command "Compress-Archive -Path '%OUT%\*' -DestinationPath '%OUT%\dd-localization.zip' -Force" >nul 2>&1

echo.
if exist "%OUT%\dd-localization.zip" (
  echo [OK] Done. The zip file is on your Desktop:
  echo      %OUT%\dd-localization.zip
) else (
  echo [!] Zip creation failed - but the files were copied here:
  echo     %OUT%
  echo     You can right click the folder ^> Send to ^> Compressed folder
)

echo.
echo Opening the folder now...
start "" "%OUT%"
echo.
echo Now attach  dd-localization.zip  in the chat (paperclip icon).
pause
