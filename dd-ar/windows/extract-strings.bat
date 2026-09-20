@echo off
title Double Dealers - localization extractor
setlocal
set "PSTMP=%TEMP%\dd-strings.ps1"
if exist "%PSTMP%" del "%PSTMP%"

echo ============================================================
echo   Double Dealers - localization extractor
echo   (creates a folder called dd-strings on your Desktop)
echo ============================================================
echo.
echo param([string]$Target)
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo # ============================================================
>>"%PSTMP%"
echo #  Double Dealers - localization extractor
>>"%PSTMP%"
echo #  Finds the English string-table bundle inside the installed
>>"%PSTMP%"
echo #  game and writes:
>>"%PSTMP%"
echo #    00-REPORT.txt            : what was found + what to send
>>"%PSTMP%"
echo #    01-en-readable.txt       : readable text (if not compressed)
>>"%PSTMP%"
echo #    02-en-partN.txt          : the raw file as base64 text parts
>>"%PSTMP%"
echo #    01-locales-readable.txt / 02-locales-partN.txt (if present)
>>"%PSTMP%"
echo #  Everything is saved on the Desktop in the folder: dd-strings
>>"%PSTMP%"
echo # ============================================================
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo $ErrorActionPreference = "Continue"
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo $out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-strings"
>>"%PSTMP%"
echo New-Item -ItemType Directory -Force -Path $out -ErrorAction SilentlyContinue
>>"%PSTMP%"
echo $reportPath = Join-Path $out "00-REPORT.txt"
>>"%PSTMP%"
echo $report = New-Object System.Collections.ArrayList
>>"%PSTMP%"
echo $script:LastHits = 0
>>"%PSTMP%"
echo $script:LastParts = 0
>>"%PSTMP%"
echo $script:LastLines = 0
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo function Say([string]$m) {
>>"%PSTMP%"
echo   [void]$report.Add($m)
>>"%PSTMP%"
echo   Write-Host $m
>>"%PSTMP%"
echo }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo function Save-Report {
>>"%PSTMP%"
echo   Set-Content -Path $reportPath -Value $report -Encoding UTF8
>>"%PSTMP%"
echo }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo function Get-LibraryDirs {
>>"%PSTMP%"
echo   $dirs = New-Object System.Collections.ArrayList
>>"%PSTMP%"
echo   $letters = @("C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")
>>"%PSTMP%"
echo   $subs = @(":\SteamLibrary","\SteamLibrary2","\SteamLibrary3","\Steam","\Games\Steam","\Games\SteamLibrary","\Program Files (x86)\Steam","\Program Files\Steam")
>>"%PSTMP%"
echo   foreach ($d in $letters) {
>>"%PSTMP%"
echo     foreach ($s in $subs) {
>>"%PSTMP%"
echo       $p = $d + $s + "\steamapps\common"
>>"%PSTMP%"
echo       if (Test-Path $p) { [void]$dirs.Add($p) }
>>"%PSTMP%"
echo     }
>>"%PSTMP%"
echo   }
>>"%PSTMP%"
echo   return $dirs
>>"%PSTMP%"
echo }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo function Find-Bundle([string]$leaf) {
>>"%PSTMP%"
echo   foreach ($dir in (Get-LibraryDirs)) {
>>"%PSTMP%"
echo     $hits = Get-ChildItem -Path $dir -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue
>>"%PSTMP%"
echo     if ($hits -and $hits.Count -gt 0) { return $hits[0].FullName }
>>"%PSTMP%"
echo   }
>>"%PSTMP%"
echo   return ""
>>"%PSTMP%"
echo }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo function Convert-One([string]$path, [string]$tag) {
>>"%PSTMP%"
echo   $bytes = [System.IO.File]::ReadAllBytes($path)
>>"%PSTMP%"
echo   $list = New-Object System.Collections.ArrayList
>>"%PSTMP%"
echo   $cur = New-Object System.Text.StringBuilder
>>"%PSTMP%"
echo   foreach ($b in $bytes) {
>>"%PSTMP%"
echo     if (($b -ge 32) -and ($b -lt 127)) {
>>"%PSTMP%"
echo       [void]$cur.Append([char]$b)
>>"%PSTMP%"
echo     } else {
>>"%PSTMP%"
echo       if ($cur.Length -ge 4) { [void]$list.Add($cur.ToString()) }
>>"%PSTMP%"
echo       [void]$cur.Clear()
>>"%PSTMP%"
echo     }
>>"%PSTMP%"
echo   }
>>"%PSTMP%"
echo   if ($cur.Length -ge 4) { [void]$list.Add($cur.ToString()) }
>>"%PSTMP%"
echo   $text = $list -join [Environment]::NewLine
>>"%PSTMP%"
echo   Set-Content -Path (Join-Path $out ("01-" + $tag + "-readable.txt")) -Value $text -Encoding UTF8
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo   $hits = 0
>>"%PSTMP%"
echo   foreach ($w in @("Clause","Auction","Market","Bid","Seller","Buyer","Item","Profit","Deal","Card")) {
>>"%PSTMP%"
echo     if ($text.Contains($w)) { $hits = $hits + 1 }
>>"%PSTMP%"
echo   }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo   $b64 = [Convert]::ToBase64String($bytes)
>>"%PSTMP%"
echo   $i = 0
>>"%PSTMP%"
echo   $n = 0
>>"%PSTMP%"
echo   while ($i -lt $b64.Length) {
>>"%PSTMP%"
echo     $n = $n + 1
>>"%PSTMP%"
echo     $len = [Math]::Min(7000, $b64.Length - $i)
>>"%PSTMP%"
echo     $chunk = $b64.Substring($i, $len)
>>"%PSTMP%"
echo     Set-Content -Path (Join-Path $out ("02-" + $tag + "-part" + $n + ".txt")) -Value $chunk -Encoding ASCII
>>"%PSTMP%"
echo     $i = $i + $len
>>"%PSTMP%"
echo   }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo   $script:LastHits = $hits
>>"%PSTMP%"
echo   $script:LastParts = $n
>>"%PSTMP%"
echo   $script:LastLines = $list.Count
>>"%PSTMP%"
echo }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo Say "=========================================================="
>>"%PSTMP%"
echo Say "  Double Dealers - localization file extractor"
>>"%PSTMP%"
echo Say "=========================================================="
>>"%PSTMP%"
echo Say ""
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo $enPath = $Target
>>"%PSTMP%"
echo if (-not $enPath) { $enPath = Find-Bundle "localization-string-tables-english(en)_assets_all.bundle" }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo if (-not $enPath -or -not (Test-Path $enPath)) {
>>"%PSTMP%"
echo   Say "[!] Could not find the game automatically."
>>"%PSTMP%"
echo   Say "    Paste the game folder path below (from the Explorer address bar)."
>>"%PSTMP%"
echo   $manual = Read-Host "Game folder path"
>>"%PSTMP%"
echo   if ($manual) {
>>"%PSTMP%"
echo     $manual = $manual.Trim('"')
>>"%PSTMP%"
echo     if (Test-Path $manual) {
>>"%PSTMP%"
echo       $found = Get-ChildItem -Path $manual -Filter "localization-string-tables-english(en)_assets_all.bundle" -Recurse -File -ErrorAction SilentlyContinue
>>"%PSTMP%"
echo       if ($found -and $found.Count -gt 0) { $enPath = $found[0].FullName }
>>"%PSTMP%"
echo     }
>>"%PSTMP%"
echo   }
>>"%PSTMP%"
echo }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo if ($enPath -and (Test-Path $enPath)) {
>>"%PSTMP%"
echo   Say "[+] Found the localization file:"
>>"%PSTMP%"
echo   Say ("    " + $enPath)
>>"%PSTMP%"
echo   Say ""
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo   Convert-One $enPath "en"
>>"%PSTMP%"
echo   $enHits = $script:LastHits
>>"%PSTMP%"
echo   $enParts = $script:LastParts
>>"%PSTMP%"
echo   $enLines = $script:LastLines
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo   Say ("English - readable text lines : " + $enLines)
>>"%PSTMP%"
echo   Say ("English - known game words     : " + $enHits + " of 10")
>>"%PSTMP%"
echo   Say ("English - base64 parts written : " + $enParts)
>>"%PSTMP%"
echo   Say ""
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo   $folder = Split-Path $enPath -Parent
>>"%PSTMP%"
echo   $locPath = Join-Path $folder "localization-locales_assets_all.bundle"
>>"%PSTMP%"
echo   $locParts = 0
>>"%PSTMP%"
echo   if (Test-Path $locPath) {
>>"%PSTMP%"
echo     Convert-One $locPath "locales"
>>"%PSTMP%"
echo     $locParts = $script:LastParts
>>"%PSTMP%"
echo     Say ("Locales - base64 parts written : " + $locParts)
>>"%PSTMP%"
echo     Say ""
>>"%PSTMP%"
echo   }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo   Say "----------------------------------------------------------"
>>"%PSTMP%"
echo   Say "WHAT TO SEND BACK TO ME:"
>>"%PSTMP%"
echo   Say ""
>>"%PSTMP%"
echo   if ($enHits -ge 3) {
>>"%PSTMP%"
echo     Say "RESULT = OK-TEXT"
>>"%PSTMP%"
echo     Say "1) Open the file:  01-en-readable.txt"
>>"%PSTMP%"
echo     if ($enLines -gt 400) {
>>"%PSTMP%"
echo       Say "   It is long, so send it in 2 or 3 chat messages (select all, copy, paste)."
>>"%PSTMP%"
echo     } else {
>>"%PSTMP%"
echo       Say "   Select all (Ctrl+A), copy (Ctrl+C) and paste it in the chat."
>>"%PSTMP%"
echo     }
>>"%PSTMP%"
echo   } else {
>>"%PSTMP%"
echo     Say "RESULT = BASE64"
>>"%PSTMP%"
echo     Say "1) Send parts 02-en-part1.txt up to 02-en-part" + $enParts + ".txt"
>>"%PSTMP%"
echo     Say "   Open each file, Ctrl+A, Ctrl+C, then paste it as a chat message"
>>"%PSTMP%"
echo     Say "   (one message per file - 5 or 6 short messages)."
>>"%PSTMP%"
echo     if ($locParts -gt 0) {
>>"%PSTMP%"
echo       Say "2) Then the same for 02-locales-part1.txt up to part" + $locParts + ".txt"
>>"%PSTMP%"
echo     }
>>"%PSTMP%"
echo   }
>>"%PSTMP%"
echo   Say ""
>>"%PSTMP%"
echo   Say "The files are here: " + $out
>>"%PSTMP%"
echo } else {
>>"%PSTMP%"
echo   Say "[X] Could not find the file:"
>>"%PSTMP%"
echo   Say "    localization-string-tables-english(en)_assets_all.bundle"
>>"%PSTMP%"
echo   Say ""
>>"%PSTMP%"
echo   Say "Open Steam - right click the game - Manage - Browse local files,"
>>"%PSTMP%"
echo   Say "then look inside:  ..._Data\StreamingAssets\aa\StandaloneWindows64"
>>"%PSTMP%"
echo   Say "and check the folder name."
>>"%PSTMP%"
echo }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo Save-Report
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo try { Start-Process notepad.exe -ArgumentList $reportPath } catch { }
>>"%PSTMP%"
echo try { Start-Process explorer.exe -ArgumentList $out } catch { }
>>"%PSTMP%"
echo(
>>"%PSTMP%"
echo Write-Host ""
>>"%PSTMP%"
echo Write-Host "DONE. Report saved. Files are on the Desktop in the folder dd-strings"
>>"%PSTMP%"
echo Read-Host "Press Enter to close this window"
>>"%PSTMP%"

echo Running the extractor, please wait...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSTMP%" %1
echo.
echo If the report window opened, send a screenshot of it.
pause
