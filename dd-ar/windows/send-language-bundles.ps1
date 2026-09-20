param([string]$Game)

# =====================================================================
#  dd-bundles.ps1  -  Double Dealers: send the language files  (v1.0)
#
#  What it does (all automatic):
#    1. finds your Double Dealers Demo folder (Steam libraries)
#    2. lists all localization bundles and their sizes
#    3. takes the GERMAN bundle, the ENGLISH bundle and the LOCALES bundle
#    4. converts them to text (base64) so they can be sent through chat
#    5. uploads the 4 text files to catbox.moe and prints the links
#
#  Output -> Desktop\dd-bundles\
#      00-REPORT.txt        what was found + sizes + CRC
#      german-b64.txt       the German bundle as text      <-- needed
#      english-b64.txt      the English bundle as text     <-- needed
#      locales-b64.txt      the language list as text      <-- needed
#      04-LINKS-TO-SEND.txt the links - send them in the chat
#
#  Nothing is changed on your PC. Read-only.
# =====================================================================

$ErrorActionPreference = "Continue"

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-bundles"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report { try { Set-Content -Path (Join-Path $out "00-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

# ------------------------------------------------------- CRC32 (for later)
$script:crcTab = $null
function Get-Crc32([byte[]]$b) {
  if (-not $script:crcTab) {
    $t = [uint32[]]::new(256)
    for ($i = 0; $i -lt 256; $i++) {
      $c = [uint32]$i
      for ($k = 0; $k -lt 8; $k++) {
        if (($c -band 1) -eq 1) { $c = [uint32]((0xEDB88320 -bxor ($c -shr 1))) } else { $c = [uint32]($c -shr 1) }
      }
      $t[$i] = $c
    }
    $script:crcTab = $t
  }
  $crc = [uint32]0xFFFFFFFF
  foreach ($x in $b) { $crc = [uint32]($script:crcTab[[int](($crc -bxor $x) -band 0xFF)] -bxor ($crc -shr 8)) }
  return [uint32]($crc -bxor 0xFFFFFFFF)
}

# ------------------------------------------------------- find the game
function Find-Game {
  $cands = New-Object System.Collections.ArrayList
  if ($Game) { [void]$cands.Add($Game) }
  try {
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { $steam = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath }
    if ($steam) {
      $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
      if (Test-Path $vdf) {
        try { $txt = Get-Content -Raw -Path $vdf } catch { $txt = "" }
        if ($txt) {
          foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
            $lib = $m.Groups[1].Value -replace '\\\\', '\'
            [void]$cands.Add((Join-Path $lib "steamapps\common\Double Dealers Demo"))
          }
        }
      }
      [void]$cands.Add((Join-Path $steam "steamapps\common\Double Dealers Demo"))
    }
  } catch { }
  foreach ($d in @("C:\SteamLibrary", "D:\SteamLibrary", "E:\SteamLibrary", "F:\SteamLibrary", "G:\SteamLibrary", "D:\Steam", "E:\Steam", "F:\Steam")) {
    [void]$cands.Add((Join-Path $d "steamapps\common\Double Dealers Demo"))
  }
  foreach ($c in $cands) { try { if ($c -and (Test-Path $c)) { return $c } } catch { } }
  return ""
}

function Find-AaDir([string]$root) {
  $hits = @()
  foreach ($d in (Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue)) {
    $p = Join-Path $d.FullName "StreamingAssets\aa\StandaloneWindows64"
    if (Test-Path $p) { $hits += $p }
    $p2 = Join-Path $d.FullName "StreamingAssets\aa"
    if (Test-Path $p2) { $hits += $p2 }
  }
  if ($hits.Count -gt 0) { return $hits[0] }
  $deep = Get-ChildItem -Path $root -Recurse -Filter "localization-string-tables-english*" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($deep) { return $deep.DirectoryName }
  return ""
}

Log "=========================================================="
Log "  Double Dealers - collect language bundles"
Log "=========================================================="
$game = Find-Game
if (-not $game) { Log "GAME FOLDER NOT FOUND - tell the assistant"; Save-Report; Read-Host "Press Enter to close"; exit 1 }
Log ("game : " + $game)

$aa = Find-AaDir $game
if (-not $aa) { Log "the aa folder was not found inside the game"; Save-Report; Read-Host "Press Enter to close"; exit 1 }
Log ("aa   : " + $aa)
Log ""
Log "All localization files found:"
$all = @(Get-ChildItem -Path $aa -Filter "localization-*.bundle" -ErrorAction SilentlyContinue)
foreach ($f in $all) { Log ("   " + $f.Name + "  (" + $f.Length + " bytes)") }
if ($all.Count -eq 0) { Log "   none - send this report to the assistant" }

# ------------------------------------------------------- pick the files
function Pick-One([string]$rx) {
  foreach ($f in $all) { if ($f.Name -match $rx) { return $f } }
  return $null
}
$fDe = Pick-One "german"
$fEn = Pick-One "english"
$fLo = Pick-One "locales"

# ------------------------------------------------------- base64 helper
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-B64([string]$src, [string]$dst) {
  if (-not $src) { return 0 }
  $bytes = [System.IO.File]::ReadAllBytes($src)
  $b64 = [Convert]::ToBase64String($bytes)
  $lines = New-Object System.Collections.ArrayList
  $i = 0
  while ($i -lt $b64.Length) {
    $n = [Math]::Min(7000, $b64.Length - $i)
    [void]$lines.Add($b64.Substring($i, $n))
    $i = $i + $n
  }
  [System.IO.File]::WriteAllText($dst, ($lines -join [Environment]::NewLine), $utf8)
  return $bytes.Length
}

$made = New-Object System.Collections.ArrayList
Log ""
Log "----------------------------------------------------------"
if ($fDe) {
  $crc = Get-Crc32 ([System.IO.File]::ReadAllBytes($fDe.FullName))
  Log ("german  : " + $fDe.Name + "  size=" + $fDe.Length + "  crc32=" + ("{0:X8}" -f $crc))
  $n = Write-B64 $fDe.FullName (Join-Path $out "german-b64.txt")
  [void]$made.Add((Join-Path $out "german-b64.txt"))
} else { Log "german  : NOT FOUND" }
if ($fEn) {
  Log ("english : " + $fEn.Name + "  size=" + $fEn.Length)
  $n = Write-B64 $fEn.FullName (Join-Path $out "english-b64.txt")
  [void]$made.Add((Join-Path $out "english-b64.txt"))
} else { Log "english : NOT FOUND" }
if ($fLo) {
  Log ("locales : " + $fLo.Name + "  size=" + $fLo.Length)
  $n = Write-B64 $fLo.FullName (Join-Path $out "locales-b64.txt")
  [void]$made.Add((Join-Path $out "locales-b64.txt"))
} else { Log "locales : NOT FOUND" }
Log "----------------------------------------------------------"
Save-Report
[void]$made.Add((Join-Path $out "00-REPORT.txt"))

# ------------------------------------------------------- auto upload
$links = New-Object System.Collections.ArrayList
foreach ($f in $made) {
  if (-not (Test-Path $f)) { continue }
  $leaf = Split-Path $f -Leaf
  $link = ""
  try {
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (-not (Test-Path $curl)) { $curl = "curl.exe" }
    $res = & $curl -s -m 180 -F "reqtype=fileupload" -F ("fileToUpload=@" + $f) "https://catbox.moe/user/api.php" 2>$null
    if ($res -and ($res -match "^https?://")) { $link = $res.Trim() }
  } catch { }
  if (-not $link) {
    try {
      $res2 = Invoke-RestMethod -Uri "https://catbox.moe/user/api.php" -Method Post -InFile $f -TimeoutSec 180
      if ($res2 -and ($res2 -match "^https?://")) { $link = $res2.Trim() }
    } catch { }
  }
  if ($link) { [void]$links.Add($leaf + "  =  " + $link) } else { [void]$links.Add($leaf + "  =  (upload failed)") }
}

Log ""
Log "=========================================================="
Log "  COPY THESE LINKS AND SEND THEM IN THE CHAT:"
Log "=========================================================="
foreach ($l in $links) { Log ("   " + $l) }
Log ""
Save-Report
try { Set-Content -Path (Join-Path $out "04-LINKS-TO-SEND.txt") -Value ($links -join [Environment]::NewLine) -Encoding UTF8 } catch { }
try { Start-Process explorer.exe -ArgumentList $out } catch { }
Write-Host ""
Write-Host "FINISHED - send the links above" -ForegroundColor Green
Read-Host "Press Enter to close"
