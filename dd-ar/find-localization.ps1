# find-localization.ps1  —  Windows / PowerShell version
# Finds the localization files of a Unity game (made for Double Dealers, works for any Unity game).
#
# Usage (open PowerShell in this folder):
#   powershell -ExecutionPolicy Bypass -File .\find-localization.ps1
#   powershell -ExecutionPolicy Bypass -File .\find-localization.ps1 -GameDir "C:\Program Files (x86)\Steam\steamapps\common\Double Dealers Demo"
#
# It prints a report and saves it next to the script as localization-report.txt

param(
  [string]$GameDir = ""
)

$ErrorActionPreference = "SilentlyContinue"
$script:Log = New-Object System.Collections.ArrayList

function Say  { param([string]$m, [string]$c="White")
  Write-Host $m -ForegroundColor $c
  [void]$script:Log.Add($m)
}
function Head { param([string]$m) ; Say "" ; Say ("== " + $m + " ==") "Cyan" }
function OK   { param([string]$m) ; Say ("[+] " + $m) "Green" }
function Warn { param([string]$m) ; Say ("[!] " + $m) "Yellow" }

$KeyWords = @('Clause','Auction','Bid','Market','Seller','Buyer','Bluff','Profit','Bankrupt','Item','Curse','Bonus')

# ---------------------------------------------------------------- find game
function Get-GameDir {
  $roots = @(
    "C:\Program Files (x86)\Steam",
    "C:\Program Files\Steam",
    (Join-Path ${env:ProgramFiles(x86)} "Steam"),
    "D:\Steam", "E:\Steam", "D:\SteamLibrary", "E:\SteamLibrary",
    "D:\Games\Steam", "E:\Games\Steam"
  ) | Where-Object { $_ -and (Test-Path $_) }

  $libs = New-Object System.Collections.ArrayList
  foreach ($r in $roots) {
    [void]$libs.Add($r)
    $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
      foreach ($line in Get-Content $vdf) {
        if ($line -match '"path"\s+"(.+?)"') {
          [void]$libs.Add(($matches[1] -replace '\\\\','\'))
        }
      }
    }
  }
  foreach ($lib in ($libs | Select-Object -Unique)) {
    $common = Join-Path $lib "steamapps\common"
    if (Test-Path $common) {
      $hit = Get-ChildItem $common -Directory | Where-Object { $_.Name -like "*Double*Dealer*" }
      if ($hit) { return $hit[0].FullName }
    }
  }
  return $null
}

if (-not $GameDir) {
  $GameDir = Get-GameDir
  if ($GameDir) { OK "Auto-detected game folder: $GameDir" }
}
if (-not $GameDir -or -not (Test-Path $GameDir)) {
  Warn "Game folder not found."
  Say  "  In Steam: right click the game > Manage > Browse local files"
  Say  "  Default path: C:\Program Files (x86)\Steam\steamapps\common\Double Dealers Demo"
  Say  "  Then run:  .\find-localization.ps1 -GameDir ""<that path>"""
  exit 1
}

Head "0) Folder overview"
Say "Path: $GameDir"
Get-ChildItem $GameDir | Select-Object -First 30 | ForEach-Object {
  Say ("   " + $_.Name + $(if ($_.PSIsContainer) { "\" } else { "" }))
}

# ---------------------------------------------------------------- data dir & build type
Head "1) Engine structure"
$DataDir = Get-ChildItem $GameDir -Directory | Where-Object { $_.Name -like "*_Data" } | Select-Object -First 1
if ($DataDir) {
  OK "Data folder: $($DataDir.Name)"
  Get-ChildItem $DataDir.FullName | Select-Object -First 20 | ForEach-Object { Say ("     " + $_.Name) }
}
if (Test-Path (Join-Path $GameDir "GameAssembly.dll")) {
  OK "Build type: IL2CPP  (text lives in global-metadata.dat + GameAssembly.dll)"
} elseif ($DataDir -and (Test-Path (Join-Path $DataDir.FullName "Managed\Assembly-CSharp.dll"))) {
  OK "Build type: Mono  (text lives in Assembly-CSharp.dll - easier to edit)"
} else {
  Warn "Could not detect build type."
}
$StreamingAssets = if ($DataDir) { Join-Path $DataDir.FullName "StreamingAssets" } else { $null }
if ($StreamingAssets -and (Test-Path $StreamingAssets)) {
  OK "StreamingAssets exists - most likely place for localization files:"
  Get-ChildItem $StreamingAssets -Recurse -File | Select-Object -First 30 | ForEach-Object {
    Say ("     " + $_.FullName.Replace($GameDir + "\",""))
  }
  if (Test-Path (Join-Path $StreamingAssets "aa")) {
    Warn "Found an 'aa' folder -> Unity Localization package + Addressables."
    Say  "     Translation tables are inside .bundle files; open them with UABEA or AssetRipper."
  }
} else { Warn "No StreamingAssets - text is probably inside resources.assets or inside the code." }

# ---------------------------------------------------------------- explicit text files
Head "2) Plain text files (best case - easy to translate)"
$TextFiles = Get-ChildItem $GameDir -Recurse -File |
  Where-Object { $_.Extension -match '^\.(csv|tsv|po|pot|json|xml|resx|lang|loc|txt)$' -and $_.FullName -notmatch '\\Managed\\' } |
  Select-Object -First 60
if ($TextFiles) {
  foreach ($f in $TextFiles) { Say ("   {0,8:N0} B  {1}" -f $f.Length, $f.FullName.Replace($GameDir + "\","")) }
  Warn "Open one of them: if you see language columns (en/tr/de...) that IS the localization file."
} else { Say "   none found" }

# ---------------------------------------------------------------- detection markers
Head "2.5) Which localization system?"
$AssetFiles = Get-ChildItem $GameDir -Recurse -File |
  Where-Object { $_.Extension -match '^\.(assets|bundle|dll|dat|so)$' -and $_.Length -lt 400MB } |
  Select-Object -First 60

function Test-Marker {
  param([string]$Marker, [int]$MaxHits = 3)
  $hits = @()
  foreach ($f in $AssetFiles) {
    try {
      $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
      $s = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
      if ($s.IndexOf($Marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $hits += $f.FullName.Replace($GameDir + "\","")
        if ($hits.Count -ge $MaxHits) { break }
      }
    } catch {}
  }
  return $hits
}

$i2 = Test-Marker "i2languages"
if ($i2.Count -gt 0) {
  OK "Detected: I2 Localization"
  $i2 | ForEach-Object { Say ("     file: " + $_) }
  Say  "     Next: export the MonoBehaviour named 'i2languages' with UABEA, then use pyI2L to add a language."
}
elseif (Test-Path (Join-Path $StreamingAssets "aa")) {
  OK "Detected: Unity Localization package + Addressables (.bundle tables)"
}
else {
  Warn "No localization system detected -> strings are hardcoded in the code."
  Say  "     Best approach here: XUnity.AutoTranslator (runtime translation mod)."
}

# ---------------------------------------------------------------- deep binary scan
Head "3) Searching game strings inside binary files"
function Search-Binary {
  param([string]$Path)
  $chunkSize = 8MB; $overlap = 512
  $hits = @()
  try {
    $fs = [System.IO.File]::OpenRead($Path)
    $buffer = New-Object byte[] $chunkSize
    $prev = ""; $pos = 0
    while (($read = $fs.Read($buffer,0,$chunkSize)) -gt 0) {
      $text = $prev + [System.Text.Encoding]::GetEncoding(28591).GetString($buffer,0,$read)
      $lower = $text.ToLowerInvariant()
      foreach ($kw in $KeyWords) {
        $k = $kw.ToLowerInvariant()
        $found = 0; $idx = 0
        while ($found -lt 2) {
          $idx = $lower.IndexOf($k, $idx)
          if ($idx -lt 0) { break }
          $start = [Math]::Max(0, $idx - 60)
          $len = [Math]::Min(150, $text.Length - $start)
          $ctx = ($text.Substring($start,$len) -replace '[^\x20-\x7E]',' ')
          $hits += ("   {0} @{1} : ...{2}..." -f $kw, ($pos + $idx - $prev.Length), $ctx)
          $idx += $k.Length; $found++
        }
      }
      $prev = $text.Substring([Math]::Max(0, $text.Length - $overlap))
      $pos += $read
    }
    $fs.Close()
  } catch {}
  return $hits
}

$scanned = 0
foreach ($f in $AssetFiles) {
  $hits = Search-Binary $f.FullName
  if ($hits.Count -gt 0) {
    Say (">>> " + $f.FullName.Replace($GameDir + "\","")) "Cyan"
    $hits | Select-Object -First 12 | ForEach-Object { Say $_ }
    $scanned++
  }
}
if ($scanned -eq 0) {
  Warn "No hits. Add a word you actually see in the game to the KeyWords list at the top of this script."
} else {
  OK "$scanned binary file(s) contain game text (see above)."
  Say  "   resources.assets + 'i2languages' -> I2 Localization (use pyI2L)"
  Say  "   .bundle files                    -> Unity Localization tables (use UABEA / AssetRipper)"
  Say  "   global-metadata.dat / *.dll      -> text hardcoded in the code"
}

# ---------------------------------------------------------------- summary
Head "4) Summary"
if ($TextFiles) { OK "You have plain text files - start there, copy/paste is enough." }
elseif (Test-Path (Join-Path $StreamingAssets "aa")) { Warn "Probably Unity Localization + Addressables - unpack with UABEA/AssetRipper." }
elseif (Test-Path (Join-Path $GameDir "GameAssembly.dll")) { Warn "Probably IL2CPP - use AssetRipper or XUnity.AutoTranslator." }
else { Warn "Probably Mono - open Assembly-CSharp.dll with dnSpy." }

$report = Join-Path (Get-Location) "localization-report.txt"
$script:Log | Out-File -FilePath $report -Encoding UTF8
Say ""
OK "Report saved to: $report"
