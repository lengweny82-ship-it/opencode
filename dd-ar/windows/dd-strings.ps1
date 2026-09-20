param([string]$Target)

# ============================================================
#  Double Dealers - localization extractor
#  Finds the English string-table bundle inside the installed
#  game and writes:
#    00-REPORT.txt            : what was found + what to send
#    01-en-readable.txt       : readable text (if not compressed)
#    02-en-partN.txt          : the raw file as base64 text parts
#    01-locales-readable.txt / 02-locales-partN.txt (if present)
#  Everything is saved on the Desktop in the folder: dd-strings
# ============================================================

$ErrorActionPreference = "Continue"

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-strings"
New-Item -ItemType Directory -Force -Path $out -ErrorAction SilentlyContinue
$reportPath = Join-Path $out "00-REPORT.txt"
$report = New-Object System.Collections.ArrayList
$script:LastHits = 0
$script:LastParts = 0
$script:LastLines = 0

function Say([string]$m) {
  [void]$report.Add($m)
  Write-Host $m
}

function Save-Report {
  Set-Content -Path $reportPath -Value $report -Encoding UTF8
}

function Get-LibraryDirs {
  $dirs = New-Object System.Collections.ArrayList
  $letters = @("C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")
  $subs = @(":\SteamLibrary","\SteamLibrary2","\SteamLibrary3","\Steam","\Games\Steam","\Games\SteamLibrary","\Program Files (x86)\Steam","\Program Files\Steam")
  foreach ($d in $letters) {
    foreach ($s in $subs) {
      $p = $d + $s + "\steamapps\common"
      if (Test-Path $p) { [void]$dirs.Add($p) }
    }
  }
  return $dirs
}

function Find-Bundle([string]$leaf) {
  foreach ($dir in (Get-LibraryDirs)) {
    $hits = Get-ChildItem -Path $dir -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue
    if ($hits -and $hits.Count -gt 0) { return $hits[0].FullName }
  }
  return ""
}

function Convert-One([string]$path, [string]$tag) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $list = New-Object System.Collections.ArrayList
  $cur = New-Object System.Text.StringBuilder
  foreach ($b in $bytes) {
    if (($b -ge 32) -and ($b -lt 127)) {
      [void]$cur.Append([char]$b)
    } else {
      if ($cur.Length -ge 4) { [void]$list.Add($cur.ToString()) }
      [void]$cur.Clear()
    }
  }
  if ($cur.Length -ge 4) { [void]$list.Add($cur.ToString()) }
  $text = $list -join [Environment]::NewLine
  Set-Content -Path (Join-Path $out ("01-" + $tag + "-readable.txt")) -Value $text -Encoding UTF8

  $hits = 0
  foreach ($w in @("Clause","Auction","Market","Bid","Seller","Buyer","Item","Profit","Deal","Card")) {
    if ($text.Contains($w)) { $hits = $hits + 1 }
  }

  $b64 = [Convert]::ToBase64String($bytes)
  $i = 0
  $n = 0
  while ($i -lt $b64.Length) {
    $n = $n + 1
    $len = [Math]::Min(7000, $b64.Length - $i)
    $chunk = $b64.Substring($i, $len)
    Set-Content -Path (Join-Path $out ("02-" + $tag + "-part" + $n + ".txt")) -Value $chunk -Encoding ASCII
    $i = $i + $len
  }

  $script:LastHits = $hits
  $script:LastParts = $n
  $script:LastLines = $list.Count
}

Say "=========================================================="
Say "  Double Dealers - localization file extractor"
Say "=========================================================="
Say ""

$enPath = $Target
if (-not $enPath) { $enPath = Find-Bundle "localization-string-tables-english(en)_assets_all.bundle" }

if (-not $enPath -or -not (Test-Path $enPath)) {
  Say "[!] Could not find the game automatically."
  Say "    Paste the game folder path below (from the Explorer address bar)."
  $manual = Read-Host "Game folder path"
  if ($manual) {
    $manual = $manual.Trim('"')
    if (Test-Path $manual) {
      $found = Get-ChildItem -Path $manual -Filter "localization-string-tables-english(en)_assets_all.bundle" -Recurse -File -ErrorAction SilentlyContinue
      if ($found -and $found.Count -gt 0) { $enPath = $found[0].FullName }
    }
  }
}

if ($enPath -and (Test-Path $enPath)) {
  Say "[+] Found the localization file:"
  Say ("    " + $enPath)
  Say ""

  Convert-One $enPath "en"
  $enHits = $script:LastHits
  $enParts = $script:LastParts
  $enLines = $script:LastLines

  Say ("English - readable text lines : " + $enLines)
  Say ("English - known game words     : " + $enHits + " of 10")
  Say ("English - base64 parts written : " + $enParts)
  Say ""

  $folder = Split-Path $enPath -Parent
  $locPath = Join-Path $folder "localization-locales_assets_all.bundle"
  $locParts = 0
  if (Test-Path $locPath) {
    Convert-One $locPath "locales"
    $locParts = $script:LastParts
    Say ("Locales - base64 parts written : " + $locParts)
    Say ""
  }

  Say "----------------------------------------------------------"
  Say "WHAT TO SEND BACK TO ME:"
  Say ""
  if ($enHits -ge 3) {
    Say "RESULT = OK-TEXT"
    Say "1) Open the file:  01-en-readable.txt"
    if ($enLines -gt 400) {
      Say "   It is long, so send it in 2 or 3 chat messages (select all, copy, paste)."
    } else {
      Say "   Select all (Ctrl+A), copy (Ctrl+C) and paste it in the chat."
    }
  } else {
    Say "RESULT = BASE64"
    Say "1) Send parts 02-en-part1.txt up to 02-en-part" + $enParts + ".txt"
    Say "   Open each file, Ctrl+A, Ctrl+C, then paste it as a chat message"
    Say "   (one message per file - 5 or 6 short messages)."
    if ($locParts -gt 0) {
      Say "2) Then the same for 02-locales-part1.txt up to part" + $locParts + ".txt"
    }
  }
  Say ""
  Say "The files are here: " + $out
} else {
  Say "[X] Could not find the file:"
  Say "    localization-string-tables-english(en)_assets_all.bundle"
  Say ""
  Say "Open Steam - right click the game - Manage - Browse local files,"
  Say "then look inside:  ..._Data\StreamingAssets\aa\StandaloneWindows64"
  Say "and check the folder name."
}

Save-Report

try { Start-Process notepad.exe -ArgumentList $reportPath } catch { }
try { Start-Process explorer.exe -ArgumentList $out } catch { }

Write-Host ""
Write-Host "DONE. Report saved. Files are on the Desktop in the folder dd-strings"
Read-Host "Press Enter to close this window"
