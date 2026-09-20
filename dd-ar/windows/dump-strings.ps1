param([string]$Target)

# =====================================================================
#  dd-dump.ps1  -  Double Dealers localization extractor  (v3.0)
#
#  Fixed in v3.0:
#    * PowerShell "array unrolling" bug in the block table parser
#      (functions must return ",$list" or powershell flattens it)
#    * block data offset must be aligned to 16 bytes when the
#      0x200 flag (BlockInfoNeedPaddingAtStart) is set
#    * each block has its own compression flag -> use it
#    * automatic fallback matrix + diagnostics + auto upload
#
#  Output -> Desktop\dd-strings2\
#     00-REPORT2.txt    report (screenshot / upload if it fails)
#     01-strings.txt    the game strings      <-- needed
#     02-runs.txt       readable runs         <-- needed
#     03-LINKS-TO-SEND.txt
# =====================================================================

$ErrorActionPreference = "Continue"

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-strings2"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:lastErr = ""

function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report { Set-Content -Path (Join-Path $out "00-REPORT2.txt") -Value $script:report -Encoding UTF8 }
function Align16([int]$v) { return [int]([Math]::Ceiling($v / 16.0) * 16) }

function Read-BE32([byte[]]$b, [int]$p) {
  return ([long]$b[$p] -shl 24) + ([long]$b[$p+1] -shl 16) + ([long]$b[$p+2] -shl 8) + [long]$b[$p+3]
}
function Read-LE32([byte[]]$b, [int]$p) {
  return ([long]$b[$p]) + ([long]$b[$p+1] -shl 8) + ([long]$b[$p+2] -shl 16) + ([long]$b[$p+3] -shl 24)
}
function Read-LE16([byte[]]$b, [int]$p) {
  return ([long]$b[$p]) + ([long]$b[$p+1] -shl 8)
}
function Read-BE64([byte[]]$b, [int]$p) {
  return ((Read-BE32 $b $p) * 4294967296) + (Read-BE32 $b ($p + 4))
}
function Read-LE64([byte[]]$b, [int]$p) {
  return ((Read-LE32 $b $p) * 4294967296) + (Read-LE32 $b ($p + 4))
}
function Read-NullString([byte[]]$b, [ref]$p) {
  $sb = New-Object System.Text.StringBuilder
  while ($p.Value -lt $b.Length -and $b[$p.Value] -ne 0) { [void]$sb.Append([char]$b[$p.Value]); $p.Value++ }
  $p.Value = $p.Value + 1
  return $sb.ToString()
}

$PRINT = [bool[]]::new(256)
for ($x = 0; $x -lt 256; $x++) { $PRINT[$x] = (($x -ge 32 -and $x -ne 127) -or $x -ge 128) }

# --------------------------------------------------------------- LZ4
function Decompress-LZ4([byte[]]$src, [int]$expected) {
  foreach ($usePrefix in @($true, $false)) {
    try {
      $i = 0
      $declared = -1
      if ($usePrefix) {
        if ($src.Length -lt 4) { continue }
        $declared = [BitConverter]::ToInt32($src, 0)
        $i = 4
        if ($declared -lt 0) { continue }
      }
      $outB = [byte[]]::new($expected)
      $op = 0
      $n = $src.Length
      while ($i -lt $n) {
        $token = [int]$src[$i]; $i++
        $lit = $token -shr 4
        if ($lit -eq 15) { while ($true) { $v = [int]$src[$i]; $i++; $lit += $v; if ($v -ne 255) { break } } }
        if ($lit -gt 0) {
          if (($i + $lit) -gt $n) { throw "literal past end" }
          [Array]::Copy($src, $i, $outB, $op, $lit); $op += $lit; $i += $lit
        }
        if ($i -ge $n) { break }
        $offset = [int]$src[$i] + ([int]$src[$i+1] -shl 8); $i += 2
        if ($offset -le 0 -or $offset -gt $op) { throw "bad match offset" }
        $mlen = $token -band 0x0F
        if ($mlen -eq 15) { while ($true) { $v = [int]$src[$i]; $i++; $mlen += $v; if ($v -ne 255) { break } } }
        $mlen += 4
        $from = $op - $offset
        while ($mlen -gt 0) {
          $c = [Math]::Min($offset, $mlen)
          if (($op + $c) -gt $expected) { throw "out of range" }
          [Array]::Copy($outB, $from, $outB, $op, $c)
          $op += $c; $mlen -= $c
        }
      }
      if ($declared -ge 0 -and $declared -ne $op) { throw "declared mismatch" }
      if ($op -ne $expected) { throw "size mismatch" }
      return ,$outB
    } catch {
      $script:lastErr = $_.Exception.Message
    }
  }
  throw ("LZ4 failed: " + $script:lastErr)
}

function Decompress-Chunk([byte[]]$src, [int]$expected, [int]$comp) {
  if ($comp -eq 0) {
    if ($src.Length -ne $expected) { throw "raw size mismatch" }
    return ,$src
  }
  if ($comp -eq 2 -or $comp -eq 3) { return ,(Decompress-LZ4 $src $expected) }
  throw ("unsupported compression " + $comp)
}

function Confirm-Serialized([byte[]]$cand) {
  if ($null -eq $cand -or $cand.Length -lt 20) { return $false }
  if ((Read-BE32 $cand 4) -ne $cand.Length) { return $false }
  $v = Read-BE32 $cand 8
  if ($v -lt 5 -or $v -gt 40) { return $false }
  return $true
}

# --------------------------------------------------------------- block table
# NOTE: returned wrapped with a leading comma, otherwise PowerShell flattens
# the list into loose numbers (that was the v2 bug).
function Parse-Blocks([byte[]]$bi, [int]$entryMode, [bool]$hasHash, [bool]$be) {
  # NOTE: UnityFS stores the block table BIG-ENDIAN (that was the v3 bug).
  $q = 0
  if ($hasHash) { $q += 16 }
  if (($q + 4) -gt $bi.Length) { throw "short table" }
  if ($be) { $bc = [int](Read-BE32 $bi $q) } else { $bc = [int](Read-LE32 $bi $q) }
  $q += 4
  if ($bc -le 0 -or $bc -gt 5000) { throw ("bad block count " + $bc) }
  $list = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $bc; $i++) {
    if (($q + 12) -gt $bi.Length) { throw "short entry" }
    if ($entryMode -eq 10) {
      if ($be) { $us = [int](Read-BE32 $bi $q) } else { $us = [int](Read-LE32 $bi $q) }
      $q += 4
      if ($be) { $cs = [int](Read-BE32 $bi $q) } else { $cs = [int](Read-LE32 $bi $q) }
      $q += 4
      if ($be) { $fl = [int](Read-BE32 $bi $q -band 0xFFFF) } else { $fl = [int](Read-LE32 $bi $q -band 0xFFFF) }
      $q += 2
    } else {
      if ($be) { $us = [int](Read-BE32 $bi $q -band 0xFFFF) } else { $us = [int](Read-LE32 $bi $q -band 0xFFFF) }
      $q += 2
      if ($be) { $cs = [int](Read-BE32 $bi $q -band 0xFFFF) } else { $cs = [int](Read-LE32 $bi $q -band 0xFFFF) }
      $q += 2
      if ($be) { $fl = [int](Read-BE32 $bi $q -band 0xFFFF) } else { $fl = [int](Read-LE32 $bi $q -band 0xFFFF) }
      $q += 2
    }
    if ($us -le 0 -or $us -gt 200000000 -or $cs -le 0 -or $cs -gt 200000000) { throw ("bad block size us=" + $us + " cs=" + $cs) }
    [void]$list.Add([pscustomobject]@{ U = $us; C = $cs; F = $fl })
  }
  # node count (kept for the diagnostics only)
  $nc = 0
  if (($q + 4) -le $bi.Length) {
    if ($be) { $nc = [int](Read-BE32 $bi $q) } else { $nc = [int](Read-LE32 $bi $q) }
    $q += 4
  }
  return ,@($list.ToArray(), $nc)
}

function Try-Unpack([byte[]]$bytes, [int]$dataStart, [int]$bip, [int]$cbi, [int]$ubi, [int]$comp, [bool]$atEnd, [bool]$pad, [int]$entryMode, [bool]$hasHash, [bool]$alignData, [bool]$be, [System.Text.StringBuilder]$dbg) {
  $biRaw = [byte[]]::new($cbi)
  [Array]::Copy($bytes, $bip, $biRaw, 0, $cbi)
  $table = $null
  if ($cbi -eq $ubi) { $table = $biRaw }
  else { $table = Decompress-Chunk $biRaw $ubi $comp }

  $res = Parse-Blocks $table $entryMode $hasHash $be
  $blocks = $res[0]
  $nc = $res[1]
  [void]$dbg.AppendLine("  endian=$(if($be){'BE'}else{'LE'}) mode=$entryMode hash=$hasHash align=$alignData blocks=$($blocks.Count) nodes=$nc")

  $totalC = 0
  foreach ($blk in $blocks) { $totalC += $blk.C }

  $dataPos = $dataStart
  if (-not $atEnd) {
    $dataPos = $bip + $cbi
    if ($alignData -and $pad) { $dataPos = Align16 $dataPos }
  }
  if (($dataPos + $totalC) -gt $bytes.Length) { throw ("data past end: need " + $totalC + " at " + $dataPos + " of " + $bytes.Length) }

  $buf = New-Object 'System.Collections.Generic.List[byte]'
  $cur = $dataPos
  foreach ($blk in $blocks) {
    $chunk = [byte[]]::new($blk.C)
    [Array]::Copy($bytes, $cur, $chunk, 0, $blk.C)
    $cur += $blk.C
    $c = $blk.F -band 0x3F
    if ($c -eq 0) { $c = $comp }
    $dec = Decompress-Chunk $chunk $blk.U $c
    $buf.AddRange($dec)
  }
  return ,$buf.ToArray()
}

# --------------------------------------------------------------- find game
function Find-Bundle {
  $leaf = "localization-string-tables-english(en)_assets_all.bundle"
  $letters = @("C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")
  $subs = @(":\SteamLibrary","\SteamLibrary2","\SteamLibrary3","\Steam","\Games\Steam","\Games\SteamLibrary","\Program Files (x86)\Steam","\Program Files\Steam")
  foreach ($d in $letters) {
    foreach ($s in $subs) {
      $base = $d + $s + "\steamapps\common"
      if (Test-Path $base) {
        $hits = Get-ChildItem -Path $base -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue
        if ($hits -and $hits.Count -gt 0) { return $hits[0].FullName }
      }
    }
  }
  return ""
}

Log "=========================================================="
Log "  Double Dealers - localization dumper v3.0"
Log "=========================================================="
Log ""

$file = $Target
if (-not $file) { $file = Find-Bundle }
if ((-not $file) -or (-not (Test-Path $file))) {
  Log "[!] Not found automatically. Paste the game folder path:"
  $manual = Read-Host "Game folder"
  if ($manual) {
    $manual = $manual.Trim('"')
    if (Test-Path $manual) {
      $f2 = Get-ChildItem -Path $manual -Filter "localization-string-tables-english(en)_assets_all.bundle" -Recurse -File -ErrorAction SilentlyContinue
      if ($f2 -and $f2.Count -gt 0) { $file = $f2[0].FullName }
    }
  }
}
if ((-not $file) -or (-not (Test-Path $file))) { Log "[X] file not found."; Save-Report; Read-Host "Enter"; exit 1 }

Log ("[+] File : " + $file)
$bytes = [System.IO.File]::ReadAllBytes($file)
Log ("    size : " + $bytes.Length + " bytes")

$p = 0
$sig = Read-NullString $bytes ([ref]$p)
$ver = [int](Read-BE32 $bytes $p); $p += 4
$uv = Read-NullString $bytes ([ref]$p)
$ur = Read-NullString $bytes ([ref]$p)
$p += 8
$cbi = [int](Read-BE32 $bytes $p); $p += 4
$ubi = [int](Read-BE32 $bytes $p); $p += 4
$flags = [int](Read-BE32 $bytes $p); $p += 4
$comp = $flags -band 0x3F
$atEnd = (($flags -band 0x80) -ne 0)
$pad = (($flags -band 0x200) -ne 0)

Log ("    sig  : " + $sig + "  fmt=" + $ver + "  unity=" + $ur)
Log ("    comp : " + $comp + "  flags=0x" + ("{0:x}" -f $flags) + "  cbi=" + $cbi + "  ubi=" + $ubi + "  atEnd=" + $atEnd + "  pad=" + $pad)

if ($sig -ne "UnityFS") { Log "[X] not a UnityFS bundle"; Save-Report; Read-Host "Enter"; exit 1 }

$dataStart = $p
if ($ver -ge 7) { $dataStart = Align16 $p }
$bip = $dataStart
if ($atEnd) { $bip = $bytes.Length - $cbi }

$dbg = New-Object System.Text.StringBuilder
$data = $null
$combos = @()
foreach ($be in @($true, $false)) {
  foreach ($mode in @(10, 6)) {
    foreach ($hash in @($true, $false)) {
      foreach ($align in @($true, $false)) { $combos += ,@($be, $mode, $hash, $align) }
    }
  }
}
foreach ($cb in $combos) {
  try {
    $cand = Try-Unpack $bytes $dataStart $bip $cbi $ubi $comp $atEnd $pad $cb[1] $cb[2] $cb[3] $cb[0] $dbg
    if (Confirm-Serialized $cand) {
      $data = $cand
      Log ("    unpacked OK: " + $data.Length + " bytes   [endian=" + $(if($cb[0]){"BE"}else{"LE"}) + " mode=" + $cb[1] + " hash=" + $cb[2] + " align=" + $cb[3] + "]")
      break
    } else {
      [void]$dbg.AppendLine("    -> decoded " + $cand.Length + " bytes but header check failed")
    }
  } catch {
    [void]$dbg.AppendLine("    -> " + $_.Exception.Message)
  }
}

if ($null -eq $data) {
  Log ""
  Log "[X] Could not unpack the bundle. Diagnostics:"
  Log $dbg.ToString()
  # hex dump of the interesting regions for analysis
  $hex = New-Object System.Text.StringBuilder
  [void]$hex.AppendLine("file=" + $file + "  size=" + $bytes.Length)
  [void]$hex.AppendLine("dataStart=" + $dataStart + " bip=" + $bip + " cbi=" + $cbi + " ubi=" + $ubi + " flags=0x" + ("{0:x}" -f $flags))
  [void]$hex.AppendLine("")
  [void]$hex.AppendLine("--- first 320 bytes ---")
  for ($i = 0; $i -lt [Math]::Min(320, $bytes.Length); $i += 32) {
    $sb = New-Object System.Text.StringBuilder
    for ($k = $i; $k -lt [Math]::Min($i + 32, $bytes.Length); $k++) { [void]$sb.Append($bytes[$k].ToString("x2")) }
    [void]$hex.AppendLine(("{0,6}: " -f $i) + $sb.ToString())
  }
  [void]$hex.AppendLine("")
  [void]$hex.AppendLine("--- block table raw (from bip) ---")
  for ($i = $bip; $i -lt [Math]::Min($bip + [Math]::Max($cbi, 96), $bytes.Length); $i += 32) {
    $sb = New-Object System.Text.StringBuilder
    for ($k = $i; $k -lt [Math]::Min($i + 32, $bytes.Length); $k++) { [void]$sb.Append($bytes[$k].ToString("x2")) }
    [void]$hex.AppendLine(("{0,6}: " -f $i) + $sb.ToString())
  }
  $hp = Join-Path $out "04-DIAGNOSTIC-HEX.txt"
  [System.IO.File]::WriteAllText($hp, $hex.ToString(), (New-Object System.Text.UTF8Encoding($false)))
  Log ("    hex dump saved: " + $hp)
  Save-Report
  Log ""
  Log "Send the diagnostic file so it can be analysed."
  Read-Host "Enter"
  exit 1
}

# --------------------------------------------------------------- strings
$strings = New-Object System.Collections.ArrayList
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$n = $data.Length
for ($i = 0; $i -lt ($n - 6); $i++) {
  $len = [BitConverter]::ToInt32($data, $i)
  if ($len -lt 2 -or $len -gt 20000) { continue }
  $endTxt = $i + 4 + $len
  if ($endTxt -ge $n) { continue }
  # Unity stores: int32 length + utf8 bytes + optional \0 + padding
  $realLen = $len
  while ($realLen -gt 1 -and $data[$i + 4 + $realLen - 1] -eq 0) { $realLen-- }
  if ($realLen -lt 2) { continue }
  $endReal = $i + 4 + $realLen
  if (-not $PRINT[$data[$endReal - 1]]) { continue }
  if ($PRINT[$data[$endReal]]) { continue }
  $ok = $true
  for ($k = $i + 4; $k -lt $endReal; $k++) { if (-not $PRINT[$data[$k]]) { $ok = $false; break } }
  if (-not $ok) { continue }
  $txt = [System.Text.Encoding]::UTF8.GetString($data, $i + 4, $realLen)
  if ($seen.Add($txt)) { [void]$strings.Add($txt) }
}

$runs = New-Object System.Collections.ArrayList
$seen2 = New-Object 'System.Collections.Generic.HashSet[string]'
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $n; $i++) {
  if ($PRINT[$data[$i]]) { [void]$sb.Append([char]$data[$i]) }
  else {
    if ($sb.Length -ge 3) { $t = $sb.ToString(); if ($seen2.Add($t)) { [void]$runs.Add($t) } }
    [void]$sb.Clear()
  }
}
if ($sb.Length -ge 3) { $t = $sb.ToString(); if ($seen2.Add($t)) { [void]$runs.Add($t) } }

$utf8 = New-Object System.Text.UTF8Encoding($false)
$f1 = Join-Path $out "01-strings.txt"
$f2 = Join-Path $out "02-runs.txt"
[System.IO.File]::WriteAllText($f1, ($strings -join [Environment]::NewLine), $utf8)
[System.IO.File]::WriteAllText($f2, ($runs -join [Environment]::NewLine), $utf8)

Log ""
Log "=========================================================="
Log ("  strings : " + $strings.Count)
Log ("  runs    : " + $runs.Count)
Log "=========================================================="

# --------------------------------------------------------------- auto upload
$links = New-Object System.Collections.ArrayList
foreach ($f in @($f1, $f2)) {
  $link = ""
  try {
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (-not (Test-Path $curl)) { $curl = "curl.exe" }
    $res = & $curl -s -m 120 -F "reqtype=fileupload" -F ("fileToUpload=@" + $f) "https://catbox.moe/user/api.php" 2>$null
    if ($res -and ($res -match "^https?://")) { $link = $res.Trim() }
  } catch { }
  if (-not $link) {
    try {
      $res2 = Invoke-RestMethod -Uri "https://catbox.moe/user/api.php" -Method Post -InFile $f -TimeoutSec 120
      if ($res2 -and ($res2 -match "^https?://")) { $link = $res2.Trim() }
    } catch { }
  }
  if ($link) { [void]$links.Add($link) } else { [void]$links.Add("(upload failed: " + (Split-Path $f -Leaf) + ")") }
}

Log ""
Log "=========================================================="
Log "  AUTO-UPLOAD RESULT - copy these links into the chat:"
Log "=========================================================="
foreach ($l in $links) { Log ("   " + $l) }
Log ""

Save-Report
try { Set-Content -Path (Join-Path $out "03-LINKS-TO-SEND.txt") -Value ($links -join [Environment]::NewLine) -Encoding UTF8 } catch { }
try { Start-Process explorer.exe -ArgumentList $out } catch { }
Write-Host ""
Write-Host "FINISHED - send the links above" -ForegroundColor Green
Read-Host "Press Enter to close"
