param([switch]$Restore)

# =====================================================================
#  dd-fix-catalog.ps1  -  Double Dealers
#
#  the game checks a fingerprint (CRC) of every language file, stored in
#  StreamingAssets\aa\catalog.bin .  after we replaced the german file the
#  fingerprint no longer matches, so the game refuses to load it and shows
#  "No translation found for ...".
#
#  this script:
#    1. finds the game + the german language file + its backup
#    2. computes the fingerprint of the new file
#    3. finds the old fingerprint inside catalog.bin (only when it is
#       clearly the entry of the german file - otherwise it stops)
#    4. saves a backup of catalog.bin and puts the new fingerprint in
#    5. sends a small report with the details
#
#  run with  -Restore  to put the original catalog.bin back.
#  (the language file itself is restored by dd-install-ar-bundle.ps1 -Restore)
# =====================================================================

$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-catalog"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:links = New-Object System.Collections.ArrayList
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }

function Upload-Report {
  $f = Join-Path $out "00-CATALOG-REPORT.txt"
  try { Set-Content -Path $f -Value $script:report -Encoding UTF8 } catch { return }
  if ($script:links.Count -eq 0) {
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
    if ($link) { [void]$script:links.Add($link) }
  }
}
function Finish([string]$msg) {
  Log ""
  Log "=========================================================="
  Log ("  " + $msg)
  Log "=========================================================="
  Upload-Report
  if ($script:links.Count -gt 0) {
    Log "  REPORT LINK - copy it into the chat:"
    foreach ($l in $script:links) { Log ("     " + $l) }
  }
  Log ""
  try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
  Write-Host ""
  Write-Host "FINISHED" -ForegroundColor Green
  Read-Host "Press Enter to close"
}

function Hex-Dump([byte[]]$b, [int]$start, [int]$len) {
  if ($start -lt 0) { $start = 0 }
  $end = [Math]::Min($b.Length, $start + $len)
  $sb = New-Object System.Text.StringBuilder
  $c = 0
  for ($i = $start; $i -lt $end; $i++) {
    [void]$sb.Append($b[$i].ToString("x2"))
    $c++
    if (($c % 32) -eq 0) { [void]$sb.Append([Environment]::NewLine) } else { [void]$sb.Append(" ") }
  }
  return $sb.ToString()
}

$script:crcTab = $null
function Get-Crc32([byte[]]$b) {
  if (-not $script:crcTab) {
    $t = New-Object 'uint32[]' 256
    for ($i = 0; $i -lt 256; $i++) {
      [int64]$c = $i
      for ($k = 0; $k -lt 8; $k++) {
        if (($c -band 1) -eq 1) { $c = [int64]((0xEDB88320) -bxor ($c -shr 1)) } else { $c = [int64]($c -shr 1) }
        $c = $c -band 0xFFFFFFFF
      }
      $t[$i] = [uint32]$c
    }
    $script:crcTab = $t
  }
  [int64]$crc = 0xFFFFFFFF
  foreach ($x in $b) {
    $idx = [int](($crc -bxor [int64]$x) -band 0xFF)
    $crc = ([int64]$script:crcTab[$idx]) -bxor ($crc -shr 8)
    $crc = $crc -band 0xFFFFFFFF
  }
  return [uint32](($crc -bxor 0xFFFFFFFF) -band 0xFFFFFFFF)
}

function Find-Value32([byte[]]$b, [uint32]$val) {
  $list = New-Object System.Collections.ArrayList
  $b0 = [int]($val -band 0xFF)
  $b1 = [int](($val -shr 8) -band 0xFF)
  $b2 = [int](($val -shr 16) -band 0xFF)
  $b3 = [int](($val -shr 24) -band 0xFF)
  for ($i = 0; $i -le ($b.Length - 4); $i++) {
    if (([int]$b[$i] -eq $b0) -and ([int]$b[$i+1] -eq $b1) -and ([int]$b[$i+2] -eq $b2) -and ([int]$b[$i+3] -eq $b3)) {
      [void]$list.Add($i)
    }
  }
  return ,$list
}

function Has-Ascii([byte[]]$b, [int]$start, [int]$len, [string]$needle) {
  if ($start -lt 0) { $start = 0 }
  $end = [Math]::Min($b.Length, $start + $len)
  if ($end -le $start) { return $false }
  $txt = [System.Text.Encoding]::ASCII.GetString($b, $start, $end - $start)
  return ($txt.IndexOf($needle) -ge 0)
}

# ---------------------------------------------------------------- find the game
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
Log "Double Dealers - catalog fingerprint fix"
Log ""
if (-not $file) { Log "[X] game not found"; Finish "STOPPED"; exit 1 }

$dir = Split-Path $file -Parent
$aa  = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$bak = $file + ".original"
$cat = Join-Path $aa "catalog.bin"
$catbak = $cat + ".original"
$hashf = Join-Path $aa "catalog.hash"
$hashbak = $hashf + ".original"

Log ("language file : " + $file)
Log ("   size : " + (Get-Item $file).Length)
Log ("backup        : " + (Test-Path $bak))
Log ("catalog.bin   : " + $cat + "   " + (Get-Item $cat -ErrorAction SilentlyContinue).Length + " bytes")
Log ""

if ($Restore) {
  Log "RESTORE"
  if (Test-Path $catbak) {
    try { Copy-Item -Force $catbak $cat; Log "   catalog.bin put back" } catch { Log ("[X] " + $_.Exception.Message) }
  } else { Log "   no catalog.bin backup found (nothing to put back)" }
  if ((Test-Path $hashbak) -and (Test-Path $hashf)) {
    try { Copy-Item -Force $hashbak $hashf; Log "   catalog.hash put back" } catch { }
  }
  Finish "DONE - catalog restored"
  exit 0
}

# ---------------------------------------------------------------- fingerprints
$crcNew = Get-Crc32 ([System.IO.File]::ReadAllBytes($file))
Log ("fingerprint of the installed file : " + ("{0:x8}" -f $crcNew) + "   (" + $crcNew + ")")
$crcOld = 0
if (Test-Path $bak) {
  $crcOld = Get-Crc32 ([System.IO.File]::ReadAllBytes($bak))
  Log ("fingerprint of the backup file    : " + ("{0:x8}" -f $crcOld) + "   (" + $crcOld + ")")
}
$sizeOld = 0
if (Test-Path $bak) { $sizeOld = (Get-Item $bak).Length }
Log ""

$cb = [System.IO.File]::ReadAllBytes($cat)
Log ("catalog.bin header (first 160 bytes):")
Log (Hex-Dump $cb 0 160)
Log ""

$posName = -1
try { $posName = ([System.Text.Encoding]::ASCII.GetString($cb)).IndexOf("german(de)") } catch { }
Log ("position of the text 'german(de)' in catalog.bin : " + $posName)
if ($posName -ge 0) {
  Log "hex around the german name (192 before / 320 after):"
  Log (Hex-Dump $cb ($posName - 192) 512)
  Log ""
}

# look for the old backup fingerprint
$cands = New-Object System.Collections.ArrayList
if ($crcOld -ne 0) {
  $raw = Find-Value32 $cb $crcOld
  Log ("the backup fingerprint appears " + $raw.Count + " time(s) in catalog.bin")
  foreach ($p in $raw) {
    $near = Has-Ascii $cb ($p - 6000) 12000 "german(de)"
    Log ("   at offset " + $p + "   near the german name : " + $near)
    if ($near) { [void]$cands.Add($p) }
  }
}
# also: is the size of the new file already there? (informational)
$rawNew = Find-Value32 $cb $crcNew
Log ("the new fingerprint appears " + $rawNew.Count + " time(s) in catalog.bin")
$szList = Find-Value32 $cb ([uint32](Get-Item $file).Length)
Log ("the size of the installed file (" + (Get-Item $file).Length + ") appears " + $szList.Count + " time(s)")
if ($sizeOld -gt 0) {
  $szOldList = Find-Value32 $cb ([uint32]$sizeOld)
  Log ("the size of the backup file (" + $sizeOld + ") appears " + $szOldList.Count + " time(s)")
  foreach ($p in $szOldList) { Log ("   size offset " + $p + "   near the german name : " + (Has-Ascii $cb ($p - 6000) 12000 "german(de)")) }
}
Log ""

if ($cands.Count -ne 1) {
  Log "[!] I could not point at exactly one place for the german entry -"
  Log "    nothing was changed in the game."
  Log "    (this report is sent to the helper to fix it)"
  Finish "STOPPED - no change"
  exit 1
}

# ---------------------------------------------------------------- patch
$pos = $cands[0]
Log "the german fingerprint is at offset " + $pos
Log "bytes around it BEFORE:"
Log (Hex-Dump $cb ($pos - 48) 96)
try {
  if (-not (Test-Path $catbak)) { Copy-Item -Force $cat $catbak; Log ("   backup of catalog.bin saved : " + $catbak) }
  if ((Test-Path $hashf) -and -not (Test-Path $hashbak)) { Copy-Item -Force $hashf $hashbak }
  $cb[$pos]   = [byte]($crcNew -band 0xFF)
  $cb[$pos+1] = [byte](($crcNew -shr 8) -band 0xFF)
  $cb[$pos+2] = [byte](($crcNew -shr 16) -band 0xFF)
  $cb[$pos+3] = [byte](($crcNew -shr 24) -band 0xFF)
  [System.IO.File]::WriteAllBytes($cat, $cb)
} catch {
  Log ("[X] could not write : " + $_.Exception.Message)
  Log "    (is the game running? close it and try again)"
  Finish "STOPPED - no change"
  exit 1
}
Log "bytes around it AFTER:"
Log (Hex-Dump $cb ($pos - 48) 96)
$check = [System.IO.File]::ReadAllBytes($cat)
$same = $true
for ($i = 0; $i -lt $cb.Length; $i++) { if ($check[$i] -ne $cb[$i]) { $same = $false; break } }
Log ("   file on disk matches : " + $same)
$nowOld = Find-Value32 $check $crcOld
$nowNew = Find-Value32 $check $crcNew
Log ("   old fingerprint left : " + $nowOld.Count + "     new fingerprint present : " + $nowNew.Count)
Log ""

# ---------------------------------------------------------------- log
try {
  $logs = Get-ChildItem -Path (Join-Path $env:USERPROFILE "AppData\LocalLow") -Filter "Player*.log" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
  if ($logs -and $logs.Count -gt 0) {
    $lg = $logs[0]
    Log ("player log : " + $lg.FullName + "   " + $lg.LastWriteTime)
    $all = Get-Content -Path $lg.FullName -ErrorAction SilentlyContinue
    $interesting = $all | Where-Object { $_ -match "crc|CRC|Addressab|addressable|bundle|Bundle|Exception|error|Error|localization" }
    Log ("---- interesting lines (" + $interesting.Count + ") ----")
    $n = 0
    foreach ($l in $interesting) { if ($n -ge 80) { break }; Log $l; $n++ }
  } else { Log "player log : not found" }
} catch { Log ("log read failed : " + $_.Exception.Message) }

Finish "DONE - the fingerprint is fixed - start the game"
exit 0
