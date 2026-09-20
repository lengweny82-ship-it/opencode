param([switch]$DisplayReady, [switch]$ShowFolder)

# =====================================================================
#  install-translation.ps1  -  Double Dealers Arabic translation setup
#
#  What it does:
#    1. Finds the game folder
#    2. Downloads the Arabic translation files from the project repo
#    3. Installs the right translation file where XUnity.AutoTranslator
#       reads it, and switches the language to Arabic in the config
#
#  Usage:
#    plain arabic              -> install
#    -DisplayReady             -> use the joined/bidi-fixed variant
#                                 (do this if the text looks broken/reversed)
#    -ShowFolder               -> just open the translation folder
# =====================================================================

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = "https://raw.githubusercontent.com/lengweny82-ship-it/opencode/arena/01a0bf68-opencode/dd-ar/translation"
$plainFile = "_AutoTranslations.ar.txt"
$dispFile  = "_AutoTranslations.display-ready.ar.txt"
$targetName = "_AutoTranslations.ar.txt"

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Double Dealers - Arabic translation installer" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

function Find-GameFolder {
  $letters = @("C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")
  $subs = @(":\SteamLibrary","\SteamLibrary2","\SteamLibrary3","\Steam","\Games\Steam","\Games\SteamLibrary","\Program Files (x86)\Steam","\Program Files\Steam")
  foreach ($d in $letters) {
    foreach ($s in $subs) {
      $common = $d + $s + "\steamapps\common"
      if (Test-Path $common) {
        $hits = Get-ChildItem -Path $common -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*Double*Dealer*" }
        if ($hits -and $hits.Count -gt 0) { return $hits[0].FullName }
      }
    }
  }
  return ""
}

$game = Find-GameFolder
if (-not $game) {
  Write-Host "[!] Game folder not found automatically." -ForegroundColor Yellow
  Write-Host "    Paste the game folder path (from Explorer address bar):"
  $manual = Read-Host "Game folder"
  if ($manual) {
    $manual = $manual.Trim('"')
    if (Test-Path $manual) {
      $sub = Get-ChildItem -Path $manual -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*Double*Dealer*" }
      if ($sub) { $game = $sub[0].FullName } else { $game = $manual }
    }
  }
}
if (-not $game -or -not (Test-Path $game)) {
  Write-Host "[X] Could not find the game folder." -ForegroundColor Red
  Read-Host "Press Enter to close"
  exit 1
}
Write-Host "[+] Game folder:" -ForegroundColor Green
Write-Host "    $game"

# ---- where XUnity looks for translations (MelonLoader / BepInEx) ----
$candidates = New-Object System.Collections.ArrayList
[void]$candidates.Add((Join-Path $game "AutoTranslator\Translation\ar\Text"))            # MelonLoader / ReiPatcher
[void]$candidates.Add((Join-Path $game "BepInEx\Translation\ar\Text"))                  # BepInEx
[void]$candidates.Add((Join-Path $game "Translation\ar\Text"))                          # standalone

$installed = 0
foreach ($dir in $candidates) {
  $parent = Split-Path (Split-Path (Split-Path $dir -Parent) -Parent) -Parent
  if (Test-Path $parent) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $dest = Join-Path $dir $targetName
    if (Test-Path $dest) { Copy-Item $dest ($dest + ".bak") -Force -ErrorAction SilentlyContinue }

    $leaf = $plainFile
    if ($DisplayReady) { $leaf = $dispFile }
    $url = "$base/$leaf"
    $tmp = Join-Path $env:TEMP $leaf
    Write-Host ("[..] downloading " + $leaf) -ForegroundColor DarkGray
    try {
      Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 60
    } catch {
      Write-Host "[!] download failed, trying curl.exe ..." -ForegroundColor Yellow
      & "$env:SystemRoot\System32\curl.exe" -L -s -o $tmp $url
    }
    if (Test-Path $tmp) {
      Copy-Item $tmp $dest -Force
      $lines = (Get-Content $dest -ErrorAction SilentlyContinue | Measure-Object).Count
      Write-Host "[+] installed:" -ForegroundColor Green
      Write-Host "    $dest  ($lines lines)"
      $installed++
    } else {
      Write-Host "[X] could not download the translation file." -ForegroundColor Red
    }
    # also drop the other variant next to it (not active, for easy switching)
    $other = $plainFile
    if (-not $DisplayReady) { $other = $dispFile }
    $tmp2 = Join-Path $env:TEMP $other
    try {
      Invoke-WebRequest -Uri "$base/$other" -OutFile $tmp2 -UseBasicParsing -TimeoutSec 60
      Copy-Item $tmp2 (Join-Path $dir ($other + ".extra.txt")) -Force -ErrorAction SilentlyContinue
    } catch { }
  }
}

if ($installed -eq 0) {
  Write-Host ""
  Write-Host "[!] No mod folder found yet (AutoTranslator / BepInEx)." -ForegroundColor Yellow
  Write-Host "    That means XUnity.AutoTranslator is not installed yet."
  Write-Host "    Install it first (see START-HERE-AR.md), then run this again."
  Write-Host ""
}

# ---- switch the language to Arabic inside the config ----
$configs = @(
  (Join-Path $game "AutoTranslator\Config.ini"),
  (Join-Path $game "BepInEx\config\gravydevsupreme.xunity.autotranslator.ini")
)
foreach ($cfg in $configs) {
  if (Test-Path $cfg) {
    Copy-Item $cfg ($cfg + ".bak") -Force -ErrorAction SilentlyContinue
    $txt = Get-Content $cfg -Raw
    if ($txt -match "(?m)^Language=") { $txt = [regex]::Replace($txt, "(?m)^Language=.*$", "Language=ar") }
    else { $txt = $txt.TrimEnd() + "`r`nLanguage=ar`r`n" }
    if ($txt -match "(?m)^FromLanguage=") { $txt = [regex]::Replace($txt, "(?m)^FromLanguage=.*$", "FromLanguage=en") }
    else { $txt = $txt.TrimEnd() + "`r`nFromLanguage=en`r`n" }
    Set-Content -Path $cfg -Value $txt -Encoding UTF8
    Write-Host "[+] language set to Arabic in:" -ForegroundColor Green
    Write-Host "    $cfg"
  }
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  NEXT:" -ForegroundColor Cyan
Write-Host "  1) Start the game"
Write-Host "  2) In game press  ALT + R  to load the translation"
Write-Host "  3) Texts appear in Arabic. ALT + 0 opens the mod UI,"
Write-Host "     ALT + T switches between Arabic and English."
Write-Host ""
Write-Host "  If letters look split or reversed:" -ForegroundColor Yellow
Write-Host "    run this script again with  -DisplayReady"
Write-Host ""
Write-Host "  If you see empty boxes instead of letters:" -ForegroundColor Yellow
Write-Host "    the font is missing Arabic glyphs -> see START-HERE-AR.md"
Write-Host "    (FallbackFontTextMeshPro setting)."
Write-Host "==========================================================" -ForegroundColor Cyan

if ($ShowFolder) { try { Start-Process explorer.exe -ArgumentList (Join-Path $game "AutoTranslator") } catch { } }
Write-Host ""
Read-Host "Press Enter to close"
