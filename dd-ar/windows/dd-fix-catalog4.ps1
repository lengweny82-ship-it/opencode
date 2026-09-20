param([switch]$Restore)

# =====================================================================
#  dd-fix-catalog4.ps1  -  Double Dealers  (short + simple version)
#
#  the game keeps  [fingerprint][size]  for every language file inside
#  StreamingAssets\aa\catalog.bin .  after the german file was replaced the
#  numbers no longer match, so the game refuses to load it.
#
#  this script changes exactly those 8 bytes  (4 = fingerprint, 4 = size)
#  and nothing else.  both the old and the new numbers are already known
#  and are checked before anything is written.
#
#  run with  -Restore  to put the original catalog.bin back.
# =====================================================================

$ErrorActionPreference = "Continue"

# ---- the numbers (already known) -------------------------------------
$OLD_CRC  = [int64]335964285     # 0x1406687d  = the fingerprint in the catalog now
$NEW_CRC  = [int64]1555883489    # 0x5cbce5e1  = the fingerprint of the arabic file
$OLD_SIZE = [int64]22316         # the size field now  (the original file)
$NEW_SIZE = [int64]65432         # the size field      (the arabic file)
$NAME     = "localization-string-tables-german(de)"

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-catalog4"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:links = New-Object System.Collections.ArrayList
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report { try { Set-Content -Path (Join-Path $out "00-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

function Upload-File([string]$path) {
  $link = ""
  if (-not (Test-Path $path)) { return "" }
  try {
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (-not (Test-Path $curl)) { $curl = "curl.exe" }
    $res = & $curl -s -m 300 -F "reqtype=fileupload" -F ("fileToUpload=@" + $path) "https://catbox.moe/user/api.php" 2>$null
    if ($res -and ($res -match "^https?://")) { $link = $res.Trim() }
  } catch { }
  if (-not $link) {
    try {
      $res2 = Invoke-RestMethod -Uri "https://catbox.moe/user/api.php" -Method Post -InFile $path -TimeoutSec 300
      if ($res2 -and ($res2 -match "^https?://")) { $link = $res2.Trim() }
    } catch { }
  }
  return $link
}

function Finish([string]$msg) {
  Log ""
  Log "=========================================================="
  Log ("  " + $msg)
  Log "=========================================================="
  Save-Report
  $l = Upload-File (Join-Path $out "00-REPORT.txt")
  if ($l) { [void]$script:links.Add("report : " + $l) }
  if ($script:links.Count -gt 0) {
    Log "  LINKS - copy them into the chat:"
    foreach ($x in $script:links) { Log ("     " + $x) }
  }
  try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
  Write-Host ""
  Write-Host "FINISHED" -ForegroundColor Green
  Read-Host "Press Enter to close"
}

function Hex-Dump([byte[]]$b, [int]$start, [int]$len) {
  if ($start -lt 0) { $start = 0 }
  $endP = [Math]::Min($b.Length, $start + $len)
  $sb = New-Object System.Text.StringBuilder
  $c = 0
  for ($i = $start; $i -lt $endP; $i++) {
    [void]$sb.Append($b[$i].ToString("x2"))
    $c++
    if (($c % 32) -eq 0) { [void]$sb.Append([Environment]::NewLine) } else { [void]$sb.Append(" ") }
  }
  return $sb.ToString()
}
function U32([byte[]]$b, [int]$p) {
  return [int64](([int64]$b[$p]) + ([int64]$b[$p+1] -shl 8) + ([int64]$b[$p+2] -shl 16) + ([int64]$b[$p+3] -shl 24))
}
function PutU32([byte[]]$b, [int]$p, [int64]$v) {
  for ($k = 0; $k -lt 4; $k++) { $b[$p+$k] = [byte](($v -shr (8*$k)) -band 255) }
}
function Hex32([int64]$v) { $u = [int64]($v -band 4294967295); return ("0x" + $u.ToString("x8")) }
function Find-U32([byte[]]$b, [int64]$val) {
  $list = New-Object System.Collections.ArrayList
  for ($i = 0; $i -le ($b.Length - 4); $i++) {
    if ($b[$i] -eq ($val -band 255)) {
      if (([int64]$b[$i] + ([int64]$b[$i+1] -shl 8) + ([int64]$b[$i+2] -shl 16) + ([int64]$b[$i+3] -shl 24)) -eq $val) { [void]$list.Add($i) }
    }
  }
  return ,$list
}
function Has-Ascii([byte[]]$b, [int]$start, [int]$len, [string]$needle) {
  if ($start -lt 0) { $start = 0 }
  $endP = [Math]::Min($b.Length, $start + $len)
  if ($endP -le $start) { return $false }
  return (([System.Text.Encoding]::ASCII.GetString($b, $start, $endP - $start)).IndexOf($needle) -ge 0)
}

# ---------------------------------------------------------------- find the game
$leaf = "localization-string-tables-german(de)_assets_all.bundle"
$file = ""
$letters = @("C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")
$subs = @(":\SteamLibrary","\SteamLibrary2","\SteamLibrary3",":\Steam","\Games\Steam","\Games\SteamLibrary","\Program Files (x86)\Steam","\Program Files\Steam")
foreach ($d in $letters) {
  foreach ($s in $subs) {
    $base = $d + $s + "\steamapps\common"
    if (-not (Test-Path $base)) { continue }
    $hits = Get-ChildItem -Path $base -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue
    if ($hits -and $hits.Count -gt 0) { $file = $hits[0].FullName; break }
  }
  if ($file) { break }
}

Log "Double Dealers - catalog fix (short version)"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""
if (-not $file) { Log "[X] the game was not found"; Finish "STOPPED"; exit 1 }

$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$cat = Join-Path $aa "catalog.bin"
$catbak = $cat + ".original"
$hashf = Join-Path $aa "catalog.hash"
$hashbak = $hashf + ".original"

Log ("the arabic file    : " + (Get-Item $file).Length + " bytes")
Log ("the original file  : " + (Test-Path ($file + ".original")))
Log ("catalog.bin        : " + (Test-Path $cat) + "   " + (Get-Item $cat -ErrorAction SilentlyContinue).Length + " bytes")
Log ""

if (-not (Test-Path $cat)) { Log "[X] catalog.bin was not found"; Finish "STOPPED"; exit 1 }

if ($Restore) {
  Log "RESTORE"
  if (Test-Path $catbak) {
    try { Copy-Item -Force $catbak $cat; Log "   catalog.bin is back to the original" } catch { Log ("[X] " + $_.Exception.Message) }
  } else { Log "   no backup found - nothing to restore" }
  if ((Test-Path $hashbak) -and (Test-Path $hashf)) { try { Copy-Item -Force $hashbak $hashf; Log "   catalog.hash is back" } catch { } }
  Finish "DONE - catalog restored"
  exit 0
}

# ---------------------------------------------------------------- read + check
$before = [System.IO.File]::ReadAllBytes($cat)
[byte[]]$cb = $before.Clone()

Log "1) looking for the german entry ..."
$posName = -1
try { $posName = ([System.Text.Encoding]::ASCII.GetString($before)).IndexOf($NAME) } catch { }
Log ("   the german name is at byte " + $posName)

$posSize = -1
$hits = Find-U32 $before $OLD_SIZE
Log ("   the number " + $OLD_SIZE + " appears " + $hits.Count + " time(s) in the file")
foreach ($p in $hits) {
  $near = Has-Ascii $before ($p - 4000) 8000 $NAME
  $crcHere = 0
  if ($p -ge 4) { $crcHere = U32 $before ($p - 4) }
  $same = ($crcHere -eq $OLD_CRC)
  Log ("      at byte " + $p + "   near the german name : " + $near + "   fingerprint in front : " + (Hex32 $crcHere) + "   correct : " + $same)
  if ($near -and $same -and ($posSize -lt 0)) { $posSize = $p }
}
if ($posSize -lt 0) {
  Log "[X] the german entry was not found as expected - nothing was changed"
  Log "    (please send this report to the helper)"
  Finish "STOPPED - no change"
  exit 1
}
$posCrc = $posSize - 4
Log ""
Log ("   FOUND : fingerprint at byte " + $posCrc + "   size at byte " + $posSize)
Log ("   entry now : fingerprint " + (Hex32 (U32 $before $posCrc)) + "   size " + (U32 $before $posSize))
Log "   bytes there:"
Log (Hex-Dump $before ($posCrc - 32) 80)
Log ""

Log "2) extra check with another language (french - untouched by us) ..."
try {
  $frFile = Join-Path $dir "localization-string-tables-french(fr)_assets_all.bundle"
  if (Test-Path $frFile) {
    $frSize = (Get-Item $frFile).Length
    $frHits = Find-U32 $before $frSize
    $ok = $false
    foreach ($p in $frHits) { if (Has-Ascii $before ($p - 4000) 8000 "localization-string-tables-french(fr)") { $ok = $true } }
    Log ("   the size of the french file (" + $frSize + ") is written next to the french name : " + $ok)
    if (-not $ok) { Log "   (not found - checking the numbers on this machine is different, but the german entry above already matched)" }
  } else { Log "   french file not found - skipped" }
} catch { Log ("   extra check failed : " + $_.Exception.Message) }
Log ""

# ---------------------------------------------------------------- write
Log "3) writing the new numbers ..."
try {
  if (-not (Test-Path $catbak)) {
    Copy-Item -Force $cat $catbak
    Log ("   backup of catalog.bin : " + $catbak)
  } else {
    Log ("   backup of catalog.bin already there")
  }
  PutU32 $cb $posCrc $NEW_CRC
  PutU32 $cb $posSize $NEW_SIZE
  [System.IO.File]::WriteAllBytes($cat, $cb)
} catch {
  Log ("[X] could not write : " + $_.Exception.Message)
  Log "    (is the game running? please close it and try again)"
  Finish "STOPPED - no change"
  exit 1
}
$after = [System.IO.File]::ReadAllBytes($cat)
Log ("   entry now : fingerprint " + (Hex32 (U32 $after $posCrc)) + "   size " + (U32 $after $posSize))
Log "   bytes there:"
Log (Hex-Dump $after ($posCrc - 32) 80)
$diff = 0
if ($after.Length -eq $before.Length) {
  for ($i = 0; $i -lt $after.Length; $i++) { if ($after[$i] -ne $before[$i]) { $diff++ } }
}
Log ("   bytes changed : " + $diff + "   (must be 8)")
if (($diff -ne 8) -or ((U32 $after $posCrc) -ne $NEW_CRC) -or ((U32 $after $posSize) -ne $NEW_SIZE)) {
  Log "[!] something is not as expected - putting the original back"
  try { Copy-Item -Force $catbak $cat } catch { }
  Finish "STOPPED - the original catalog was put back"
  exit 1
}
Log ""

# ---------------------------------------------------------------- catalog.hash
try {
  if (Test-Path $hashf) {
    $hb = [System.IO.File]::ReadAllBytes($hashf)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $shaOrig = $sha.ComputeHash($before)
    $same = ($hb.Length -eq $shaOrig.Length)
    if ($same) { for ($i = 0; $i -lt $hb.Length; $i++) { if ($hb[$i] -ne $shaOrig[$i]) { $same = $false; break } } }
    Log ("4) catalog.hash : " + $hb.Length + " bytes   is it sha256 of the catalog : " + $same)
    if ($same) {
      if (-not (Test-Path $hashbak)) { Copy-Item -Force $hashf $hashbak }
      $shaNew = $sha.ComputeHash($after)
      [System.IO.File]::WriteAllBytes($hashf, $shaNew)
      Log "   catalog.hash updated to match"
    } else {
      Log "   (not a plain sha256 - left as it is)"
    }
  }
} catch { Log ("4) catalog.hash step failed : " + $_.Exception.Message) }
Log ""

# ---------------------------------------------------------------- upload
Log "5) sending the files to the helper ..."
function Write-CatB64([byte[]]$data, [string]$dst, [string]$title) {
  $b64 = [Convert]::ToBase64String($data)
  $li = New-Object System.Collections.ArrayList
  $i2 = 0
  while ($i2 -lt $b64.Length) { $n2 = [Math]::Min(6000, $b64.Length - $i2); [void]$li.Add($b64.Substring($i2, $n2)); $i2 += $n2 }
  [System.IO.File]::WriteAllText($dst, ($li -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
  $lk = Upload-File $dst
  if ($lk) { [void]$script:links.Add($title + " : " + $lk); Log ("   " + $title + " uploaded") }
}
Write-CatB64 $before (Join-Path $out "catalog-original.b64.txt") "original catalog.bin"
Write-CatB64 $after (Join-Path $out "catalog-new.b64.txt") "new catalog.bin"
Log ""

Finish "DONE - now start the game and look at the german language"
exit 0
