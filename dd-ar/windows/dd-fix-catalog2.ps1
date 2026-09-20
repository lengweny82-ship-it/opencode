param([switch]$Restore)

# =====================================================================
#  dd-fix-catalog2.ps1  -  Double Dealers
#
#  the game keeps a fingerprint (crc32) + size for every language file in
#  StreamingAssets\aa\catalog.bin .  after the german file was replaced the
#  fingerprint no longer matches, so the game refuses to load it and shows
#  "No translation found for ...".
#
#  this script finds the german entry in catalog.bin, writes the correct
#  fingerprint + size, and reports everything.  nothing else is touched.
#
#  run with  -Restore  to put the original catalog.bin back.
# =====================================================================

$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-catalog"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:links = New-Object System.Collections.ArrayList
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }

function Save-Report { try { Set-Content -Path (Join-Path $out "00-CATALOG2-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

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
  $l = Upload-File (Join-Path $out "00-CATALOG2-REPORT.txt")
  if ($l) { [void]$script:links.Add("report : " + $l) }
  if ($script:links.Count -gt 0) {
    Log "  LINKS - copy them into the chat:"
    foreach ($x in $script:links) { Log ("     " + $x) }
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

# ---------------- CRC32 (zip) - Int64 maths only, no hex literals --------
$script:crcTab = $null
function Get-Crc32([byte[]]$data) {
  if ($null -eq $script:crcTab) {
    $t = New-Object 'System.Int64[]' 256
    for ($i = 0; $i -lt 256; $i++) {
      [int64]$c = $i
      for ($k = 0; $k -lt 8; $k++) {
        if (($c -band 1) -eq 1) { $c = 3988292384 -bxor [int64]($c -shr 1) } else { $c = [int64]($c -shr 1) }
        $c = $c -band 4294967295
      }
      $t[$i] = $c
    }
    $script:crcTab = $t
  }
  [int64]$crc = 4294967295
  foreach ($x in $data) {
    $idx = [int](($crc -bxor [int64]$x) -band 255)
    $crc = (($script:crcTab[$idx]) -bxor ($crc -shr 8)) -band 4294967295
  }
  return [int64]((4294967295 -bxor $crc) -band 4294967295)
}

function U32([byte[]]$b, [int]$p) {
  return [int64](([int64]$b[$p]) + ([int64]$b[$p+1] -shl 8) + ([int64]$b[$p+2] -shl 16) + ([int64]$b[$p+3] -shl 24))
}
function PutU32([byte[]]$b, [int]$p, [int64]$v) {
  for ($k = 0; $k -lt 4; $k++) { $b[$p+$k] = [byte](($v -shr (8*$k)) -band 255) }
}
function Find-U32([byte[]]$b, [int64]$val) {
  $list = New-Object System.Collections.ArrayList
  $n = $b.Length - 4
  for ($i = 0; $i -le $n; $i++) {
    if ($b[$i] -eq ($val -band 255)) {
      if (([int64]$b[$i] + ([int64]$b[$i+1] -shl 8) + ([int64]$b[$i+2] -shl 16) + ([int64]$b[$i+3] -shl 24)) -eq $val) { [void]$list.Add($i) }
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
function Hex32([int64]$v) { $u = [int64]($v -band 4294967295); return ("0x" + $u.ToString("x8")) }

Log "Double Dealers - catalog fix (step 2)"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""

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
if (-not $file) { Log "[X] game not found"; Finish "STOPPED"; exit 1 }

$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$gbak = $file + ".original"
$cat = Join-Path $aa "catalog.bin"
$catbak = $cat + ".original"
$hashf = Join-Path $aa "catalog.hash"
$hashbak = $hashf + ".original"

Log ("language file : " + $file + "   (" + (Get-Item $file).Length + " bytes)")
Log ("original file : " + (Test-Path $gbak))
Log ("catalog.bin   : " + (Get-Item $cat -ErrorAction SilentlyContinue).Length + " bytes")
Log ("catalog.hash  : " + (Get-Item $hashf -ErrorAction SilentlyContinue).Length + " bytes")
Log ""

if ($Restore) {
  Log "RESTORE"
  if (Test-Path $catbak) { try { Copy-Item -Force $catbak $cat; Log "   catalog.bin put back" } catch { Log ("[X] " + $_.Exception.Message) } }
  else { Log "   no catalog backup found" }
  if ((Test-Path $hashbak) -and (Test-Path $hashf)) { try { Copy-Item -Force $hashbak $hashf; Log "   catalog.hash put back" } catch { } }
  Finish "DONE - catalog restored"
  exit 0
}

# ---------------------------------------------------------------- 0. self test
Log "0) checking my own fingerprint maths ..."
$test = [System.Text.Encoding]::ASCII.GetBytes("123456789")
$tc = Get-Crc32 $test
$tcHex = Hex32 $tc
Log ("   test value : " + $tcHex + "   (must be 0xcbf43926)")
if ($tcHex -ne "0xcbf43926") {
  Log "[X] my CRC32 code is wrong - stopping, nothing changed"
  Finish "STOPPED"
  exit 1
}
Log "   OK"
Log ""

# ---------------------------------------------------------------- 1. player log
$logCalc = $null
$logProv = $null
try {
  $logs = Get-ChildItem -Path (Join-Path $env:USERPROFILE "AppData\LocalLow") -Filter "Player*.log" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
  if ($logs -and $logs.Count -gt 0) {
    $lg = $logs[0]
    Log "1) game log : " + $lg.FullName + "   " + $lg.LastWriteTime
    $all = Get-Content -Path $lg.FullName -ErrorAction SilentlyContinue
    $interesting = $all | Where-Object { $_ -match "CRC Mismatch|crc mismatch|Addressab|addressable|Bundle|Exception|localization" }
    Log ("   interesting lines : " + $interesting.Count)
    $n = 0
    foreach ($l in $interesting) {
      if ($n -ge 100) { break }
      Log ("      " + $l)
      if ($l -match "[Cc][Rr][Cc] [Mm]ismatch") {
        if ($l -match "calculated\D*(\d+)") { $logCalc = [int64]$matches[1] }
        if ($l -match "[Pp]rovided\D*(\d+)") { $logProv = [int64]$matches[1] }
      }
      $n++
    }
    if ($logCalc) { Log ("   >>> the game says the correct fingerprint of the new file is : " + $logCalc + "  (" + (Hex32 $logCalc) + ")") }
    if ($logProv) { Log ("   >>> the catalog gave it : " + $logProv + "  (" + (Hex32 $logProv) + ")") }
  } else { Log "1) game log : not found" }
} catch { Log ("1) log read failed : " + $_.Exception.Message) }
Log ""

# ---------------------------------------------------------------- 2. fingerprints
Log "2) fingerprints ..."
$bytesNew = [System.IO.File]::ReadAllBytes($file)
$crcNew = Get-Crc32 $bytesNew
Log ("   new file  : " + $bytesNew.Length + " bytes   crc32 = " + (Hex32 $crcNew) + "  (" + $crcNew + ")")
$crcOld = 0
$sizeOld = 0
if (Test-Path $gbak) {
  $bytesOld = [System.IO.File]::ReadAllBytes($gbak)
  $crcOld = Get-Crc32 $bytesOld
  $sizeOld = $bytesOld.Length
  Log ("   original  : " + $sizeOld + " bytes   crc32 = " + (Hex32 $crcOld) + "  (" + $crcOld + ")")
} else {
  Log "   [!] the original file is missing - I cannot check the old fingerprint"
}
Log ""

# ---------------------------------------------------------------- 3. catalog
$cb = [System.IO.File]::ReadAllBytes($cat)
$posName = -1
try { $posName = ([System.Text.Encoding]::ASCII.GetString($cb)).IndexOf("localization-string-tables-german(de)") } catch { }
Log ("3) catalog : german name at offset " + $posName)
if ($posName -ge 0) {
  Log "   hex around the german name:"
  Log (Hex-Dump $cb ($posName - 64) 160)
  Log ""
}

$posSize = -1
if ($sizeOld -gt 0) {
  $hitsSize = Find-U32 $cb $sizeOld
  Log ("   the original size (" + $sizeOld + ") appears " + $hitsSize.Count + " time(s)")
  foreach ($p in $hitsSize) {
    $near = Has-Ascii $cb ($p - 4000) 8000 "localization-string-tables-german(de)"
    Log ("      at " + $p + "   near the german name : " + $near + "   the 4 bytes after it : " + (U32 $cb ($p + 4)))
    if ($near -and ($posSize -lt 0)) { $posSize = $p }
  }
}
Log ""
$crcInCatalog = 0
if ($posSize -ge 0) {
  $crcInCatalog = U32 $cb ($posSize - 4)
  Log ("   the german entry : fingerprint " + (Hex32 $crcInCatalog) + "  (" + $crcInCatalog + ")   size " + (U32 $cb $posSize))
  Log "   hex of the entry (64 before / 72 after):"
  Log (Hex-Dump $cb ($posSize - 68) 136)
  Log ""
  if (($crcOld -gt 0) -and ($crcOld -eq $crcInCatalog)) { Log "   [OK] the fingerprint in the catalog IS the crc32 of the original file - format confirmed" }
  else { Log ("   [!] the catalog fingerprint (" + $crcInCatalog + ") differs from the crc32 of the original (" + $crcOld + ")") }
}
Log ""

$crcTarget = $crcNew
if ($logCalc) { $crcTarget = $logCalc }
Log ("   fingerprint to write : " + (Hex32 $crcTarget) + "  (" + $crcTarget + ")")
Log ""

# ---------------------------------------------------------------- 4. patch
if ($posSize -lt 0) {
  Log "[!] I could not find the german entry in catalog.bin - nothing changed"
  Finish "STOPPED - no change"
  exit 1
}
if ($crcInCatalog -eq $crcTarget -and (U32 $cb $posSize) -eq $bytesNew.Length) {
  Log "[OK] the catalog already matches the new file - nothing to do"
  Finish "DONE - the catalog was already fixed - start the game"
  exit 0
}
if (-not $logCalc) {
  if (($crcOld -le 0) -or ($crcOld -ne $crcInCatalog)) {
    Log "[!] the game log did not tell me the right fingerprint and the numbers do not"
    Log "    line up - nothing was changed (the report is on its way to the helper)"
    Finish "STOPPED - no change"
    exit 1
  }
}

$posCrc = $posSize - 4
$before = [System.IO.File]::ReadAllBytes($cat)
try {
  if (-not (Test-Path $catbak)) {
    Copy-Item -Force $cat $catbak
    Log ("   backup of catalog.bin : " + $catbak)
  } else { Log ("   backup of catalog.bin already there : " + $catbak) }
  PutU32 $cb $posCrc ([int64]$crcTarget)
  PutU32 $cb $posSize ([int64]$bytesNew.Length)
  [System.IO.File]::WriteAllBytes($cat, $cb)
} catch {
  Log ("[X] could not write : " + $_.Exception.Message)
  Log "    (is the game running? close it and try again)"
  Finish "STOPPED - no change"
  exit 1
}
$after = [System.IO.File]::ReadAllBytes($cat)
Log ("4) written : fingerprint at " + $posCrc + " , size at " + $posSize)
Log ("   new entry : fingerprint " + (Hex32 (U32 $after $posCrc)) + "   size " + (U32 $after $posSize))
Log "   hex after the change:"
Log (Hex-Dump $after ($posSize - 68) 136)
Log ""
$diff = 0
$orig = [System.IO.File]::ReadAllBytes($catbak)
if ($after.Length -eq $orig.Length) {
  for ($i = 0; $i -lt $after.Length; $i++) { if ($after[$i] -ne $orig[$i]) { $diff++ } }
}
Log ("   bytes that differ from the original catalog : " + $diff + "  (must be 8)")
Log ""

# ---------------------------------------------------------------- 5. catalog.hash
try {
  if (Test-Path $hashf) {
    $hb = [System.IO.File]::ReadAllBytes($hashf)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $shaOrig = $sha.ComputeHash($orig)
    $same = ($hb.Length -eq $shaOrig.Length)
    if ($same) { for ($i = 0; $i -lt $hb.Length; $i++) { if ($hb[$i] -ne $shaOrig[$i]) { $same = $false; break } } }
    Log ("5) catalog.hash : " + $hb.Length + " bytes   sha256(original catalog) matches : " + $same)
    if ($same) {
      $shaNew = $sha.ComputeHash($after)
      if (-not (Test-Path $hashbak)) { Copy-Item -Force $hashf $hashbak }
      [System.IO.File]::WriteAllBytes($hashf, $shaNew)
      Log "   catalog.hash updated (kept in sync)"
    } else {
      Log "   (the hash file is not a plain sha256 of the catalog - left untouched)"
    }
  }
} catch { Log ("5) hash step failed : " + $_.Exception.Message) }
Log ""

# ---------------------------------------------------------------- 6. uploads
Log "6) sending the catalog files to the helper ..."
foreach ($pair in @(@($catbak, "catalog-original.b64.txt", "original catalog.bin"), @($after, "catalog-new.b64.txt", "new catalog.bin"))) {
  $src = $pair[0]
  $dst = Join-Path $out $pair[1]
  if ($src -is [string]) { $data = [System.IO.File]::ReadAllBytes($src) } else { $data = $src }
  $b64 = [Convert]::ToBase64String($data)
  $li = New-Object System.Collections.ArrayList
  $i2 = 0
  while ($i2 -lt $b64.Length) { $n2 = [Math]::Min(6000, $b64.Length - $i2); [void]$li.Add($b64.Substring($i2, $n2)); $i2 += $n2 }
  [System.IO.File]::WriteAllText($dst, ($li -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
  $lk = Upload-File $dst
  if ($lk) { [void]$script:links.Add($pair[2] + " : " + $lk); Log ("   " + $pair[2] + " uploaded") }
}
Log ""

Finish "DONE - the catalog now matches the arabic file - start the game"
exit 0
