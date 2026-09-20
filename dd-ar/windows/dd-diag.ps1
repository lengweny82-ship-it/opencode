# =====================================================================
#  dd-diag.ps1  -  Double Dealers: send a small diagnostic report
#  (only reads files, changes nothing)
# =====================================================================
$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-diag"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$lines = New-Object System.Collections.ArrayList
function Log([string]$m) { Write-Host $m; [void]$lines.Add($m) }

function Hex-At([byte[]]$b, [int]$start, [int]$len) {
  $end = [Math]::Min($b.Length, $start + $len)
  if ($start -lt 0) { $start = 0 }
  $sb = New-Object System.Text.StringBuilder
  for ($i = $start; $i -lt $end; $i++) {
    [void]$sb.Append($b[$i].ToString("x2"))
    if ((($i - $start) % 32) -eq 31) { [void]$sb.Append([Environment]::NewLine) }
  }
  return $sb.ToString()
}
function IndexOf-Bytes([byte[]]$hay, [byte[]]$needle, [int]$from) {
  $n = $hay.Length; $m = $needle.Length
  for ($i = $from; $i -le ($n - $m); $i++) {
    $ok = $true
    for ($k = 0; $k -lt $m; $k++) { if ($hay[$i+$k] -ne $needle[$k]) { $ok = $false; break } }
    if ($ok) { return $i }
  }
  return -1
}

$leaf = "localization-string-tables-german(de)_assets_all.bundle"
$file = ""
$letters = @("C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")
$subs = @(":\SteamLibrary","\SteamLibrary2","\SteamLibrary3","\Steam","\Games\Steam","\Games\SteamLibrary","\Program Files (x86)\Steam","\Program Files\Steam")
foreach ($d in $letters) {
  foreach ($s in $subs) {
    $base = $d + $s + "\steamapps\common"
    if (-not (Test-Path $base)) { continue }
    $hits = Get-ChildItem -Path $base -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue
    if ($hits -and $hits.Count -gt 0) { $file = $hits[0].FullName; break }
  }
  if ($file) { break }
}
if (-not $file) {
  Log "[X] game not found"
  $lines -join [Environment]::NewLine | Set-Content -Path (Join-Path $out "diag.txt") -Encoding UTF8
  Read-Host "Press Enter to close"
  exit 1
}

$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
Log ("game file : " + $file)
Log ("game file size : " + (Get-Item $file).Length)
$orig = $file + ".original"
if (Test-Path $orig) { Log ("backup size : " + (Get-Item $orig).Length) }
Log ""

$cat = Join-Path $aa "catalog.bin"
if (Test-Path $cat) {
  $cb = [System.IO.File]::ReadAllBytes($cat)
  Log ("catalog.bin : " + $cb.Length + " bytes")
  Log "catalog.bin first 256 bytes:"
  Log (Hex-At $cb 0 256)
  Log ""
  $needle = [System.Text.Encoding]::ASCII.GetBytes("german(de)")
  $pos = -1
  $found = 0
  while ($true) {
    $pos = IndexOf-Bytes $cb $needle ($pos + 1)
    if ($pos -lt 0) { break }
    $found++
    Log ("--- catalog.bin around 'german(de)' at " + $pos + " ---")
    Log (Hex-At $cb ($pos - 128) 320)
    Log ""
    if ($found -ge 3) { break }
  }
  if ($found -eq 0) { Log "no ascii 'german(de)' found" }
} else { Log "catalog.bin : not found" }

$hash = Join-Path $aa "catalog.hash"
if (Test-Path $hash) {
  $hb = [System.IO.File]::ReadAllBytes($hash)
  Log ("catalog.hash : " + $hb.Length + " bytes")
  Log (Hex-At $hb 0 64)
  Log ("as text : " + ([System.Text.Encoding]::ASCII.GetString($hb)))
  Log ""
}

try {
  $logs = Get-ChildItem -Path (Join-Path $env:USERPROFILE "AppData\LocalLow") -Filter "Player*.log" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
  if ($logs -and $logs.Count -gt 0) {
    $lg = $logs[0]
    Log ("player log : " + $lg.FullName + "  (" + $lg.Length + " bytes, " + $lg.LastWriteTime + ")")
    $all = Get-Content -Path $lg.FullName -ErrorAction SilentlyContinue
    $interesting = $all | Where-Object { $_ -match "crc|CRC|Addressab|addressable|bundle|Bundle|Exception|error|Error|LoadFromFile|localization" }
    Log ("---- interesting lines (" + $interesting.Count + ") ----")
    $n = 0
    foreach ($l in $interesting) { if ($n -ge 120) { break }; Log $l; $n++ }
    Log "---- last 40 lines ----"
    $tail = $all | Select-Object -Last 40
    foreach ($l in $tail) { Log $l }
  } else { Log "player log : not found" }
} catch { Log ("log read failed : " + $_.Exception.Message) }

$f = Join-Path $out "diag.txt"
$lines -join [Environment]::NewLine | Set-Content -Path $f -Encoding UTF8
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
Write-Host ""
if ($link) {
  Write-Host "SEND THIS LINK:" -ForegroundColor Green
  Write-Host $link
  Set-Content -Path (Join-Path $out "LINK-TO-SEND.txt") -Value $link -Encoding UTF8
} else {
  Write-Host "upload failed - the file is here:" -ForegroundColor Yellow
  Write-Host $f
}
try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
Write-Host ""
Write-Host "FINISHED" -ForegroundColor Green
Read-Host "Press Enter to close"
