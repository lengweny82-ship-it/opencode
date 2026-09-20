param([string]$Target)

# =====================================================================
#  dd-dump.ps1  -  Double Dealers localization string extractor (v2.1)
#
#  Reads the game's localization .bundle, decompresses it (UnityFS:
#  none / LZ4 / LZ4HC) and writes the English strings as plain text.
#
#  Output -> Desktop\dd-strings2\ :
#     00-REPORT2.txt    status report (screenshot this if it fails)
#     01-strings.txt    the clean string list    <-- send this one
#     02-runs.txt       backup list              <-- send this one too
# =====================================================================

$ErrorActionPreference = "Continue"

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-strings2"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:lastLz4Error = ""

function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report { Set-Content -Path (Join-Path $out "00-REPORT2.txt") -Value $script:report -Encoding UTF8 }

function Read-BE32([byte[]]$b, [int]$p) {
  return ([long]$b[$p] -shl 24) + ([long]$b[$p+1] -shl 16) + ([long]$b[$p+2] -shl 8) + [long]$b[$p+3]
}
function Read-BE64([byte[]]$b, [int]$p) {
  return ((Read-BE32 $b $p) * 4294967296) + (Read-BE32 $b ($p + 4))
}
function Read-NullString([byte[]]$b, [ref]$p) {
  $sb = New-Object System.Text.StringBuilder
  while ($p.Value -lt $b.Length -and $b[$p.Value] -ne 0) { [void]$sb.Append([char]$b[$p.Value]); $p.Value++ }
  $p.Value = $p.Value + 1
  return $sb.ToString()
}

# --------------------------------------------------------------- printable table
$PRINT = New-Object bool[] 256
for ($x = 0; $x -lt 256; $x++) {
  $PRINT[$x] = (($x -ge 32 -and $x -ne 127) -or $x -ge 128)
}

# --------------------------------------------------------------- LZ4 block
function Decompress-LZ4([byte[]]$src, [int]$expected) {
  foreach ($usePrefix in @($true, $false)) {
    try {
      $start = 0
      $declared = -1
      if ($usePrefix) {
        if ($src.Length -lt 4) { continue }
        $declared = [BitConverter]::ToInt32($src, 0)
        $start = 4
      }
      $outB = New-Object byte[] $expected
      $op = 0
      $i = $start
      $n = $src.Length
      while ($i -lt $n) {
        $token = [int]$src[$i]; $i++
        $lit = $token -shr 4
        if ($lit -eq 15) {
          while ($true) { $b = [int]$src[$i]; $i++; $lit += $b; if ($b -ne 255) { break } }
        }
        if ($lit -gt 0) {
          [Array]::Copy($src, $i, $outB, $op, $lit)
          $op += $lit
          $i += $lit
        }
        if ($i -ge $n) { break }
        $offset = [int]$src[$i] + ([int]$src[$i+1] -shl 8); $i += 2
        $mlen = $token -band 0x0F
        if ($mlen -eq 15) {
          while ($true) { $b = [int]$src[$i]; $i++; $mlen += $b; if ($b -ne 255) { break } }
        }
        $mlen += 4
        $from = $op - $offset
        if ($from -lt 0 -or $offset -le 0) { throw "bad match offset" }
        while ($mlen -gt 0) {
          $chunk = [Math]::Min($offset, $mlen)
          [Array]::Copy($outB, $from, $outB, $op, $chunk)
          $op += $chunk
          $mlen -= $chunk
        }
      }
      if ($declared -ge 0 -and $declared -ne $op) { throw "declared size mismatch" }
      if ($op -ne $expected) { throw "size mismatch" }
      return $outB
    } catch {
      $script:lastLz4Error = $_.Exception.Message
    }
  }
  throw ("LZ4 failed: " + $script:lastLz4Error)
}

function Decompress-Block([byte[]]$src, [int]$expected, [int]$comp) {
  if ($comp -eq 0) {
    if ($src.Length -ne $expected) { throw "raw block size mismatch" }
    return $src
  }
  if ($comp -eq 2 -or $comp -eq 3) { return (Decompress-LZ4 $src $expected) }
  throw ("unsupported compression " + $comp)
}

# --------------------------------------------------------------- find file
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
Log "  Double Dealers - localization dumper"
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
      $found = Get-ChildItem -Path $manual -Filter "localization-string-tables-english(en)_assets_all.bundle" -Recurse -File -ErrorAction SilentlyContinue
      if ($found -and $found.Count -gt 0) { $file = $found[0].FullName }
    }
  }
}
if ((-not $file) -or (-not (Test-Path $file))) { Log "[X] File not found."; Save-Report; Read-Host "Enter"; exit 1 }

Log ("[+] File  : " + $file)
$bytes = [System.IO.File]::ReadAllBytes($file)
Log ("    bytes : " + $bytes.Length)

$p = 0
$sig = Read-NullString $bytes ([ref]$p)
$ver = Read-BE32 $bytes $p; $p += 4
$unityVer = Read-NullString $bytes ([ref]$p)
$unityRev = Read-NullString $bytes ([ref]$p)
$hsize = Read-BE64 $bytes $p; $p += 8
$cbiSize = [int](Read-BE32 $bytes $p); $p += 4
$ubiSize = [int](Read-BE32 $bytes $p); $p += 4
$flags = [int](Read-BE32 $bytes $p); $p += 4

$comp = $flags -band 0x3F
$atEnd = (($flags -band 0x80) -ne 0)
$padStart = (($flags -band 0x200) -ne 0)

Log ("    sig   : " + $sig + "  fmt=" + $ver + "  unity=" + $unityRev)
Log ("    comp  : " + $comp + "  (0=none 1=lzma 2=lz4 3=lz4hc)")
Log ("    blocks: " + $cbiSize + " -> " + $ubiSize + "  atEnd=" + $atEnd + " padStart=" + $padStart)

if ($sig -ne "UnityFS") { Log "[X] Not a UnityFS bundle."; Save-Report; Read-Host "Enter"; exit 1 }
if ($comp -eq 1) { Log "[X] LZMA detected - tell the agent."; Save-Report; Read-Host "Enter"; exit 1 }

$dataStart = $p
if ($padStart) { $dataStart = [int](([Math]::Ceiling($dataStart / 16.0)) * 16) }
$bip = $dataStart
if ($atEnd) { $bip = $bytes.Length - $cbiSize }

$biRaw = New-Object byte[] $cbiSize
[Array]::Copy($bytes, $bip, $biRaw, 0, $cbiSize)

$blocksInfo = $null
try {
  $blocksInfo = Decompress-Block $biRaw $ubiSize $comp
  Log "    block table: OK"
} catch {
  Log ("[X] block table failed: " + $_.Exception.Message)
  Save-Report; Read-Host "Enter"; exit 1
}

function Parse-Blocks([byte[]]$bi, [int]$entryMode, [int]$version) {
  $q = 0
  if ($version -ge 7) { $q += 16 }
  if (($q + 4) -gt $bi.Length) { throw "short block table" }
  $bc = [int](Read-BE32 $bi $q); $q += 4
  if ($bc -le 0 -or $bc -gt 5000) { throw "bad block count" }
  $blocks = @()
  for ($i = 0; $i -lt $bc; $i++) {
    if (($q + 12) -gt $bi.Length) { throw "short block entry" }
    if ($entryMode -eq 10) {
      $us = [int](Read-BE32 $bi $q); $q += 4
      $cs = [int](Read-BE32 $bi $q); $q += 4
      $q += 2
    } else {
      $us = [int]((([int]$bi[$q] -shl 8) + [int]$bi[$q+1])); $q += 2
      $cs = [int]((([int]$bi[$q] -shl 8) + [int]$bi[$q+1])); $q += 2
      $q += 2
    }
    if ($us -le 0 -or $us -gt 200000000 -or $cs -le 0 -or $cs -gt 200000000) { throw "bad block size" }
    $blocks += ,@($us, $cs)
  }
  return $blocks
}

$data = $null
foreach ($mode in @(10, 6)) {
  try {
    $blocks = Parse-Blocks $blocksInfo $mode $ver
    $totalC = 0
    foreach ($b in $blocks) { $totalC += $b[1] }
    if ($totalC -gt ($bytes.Length - $dataStart + 64)) { throw "sizes exceed file" }
    $cursor = $dataStart
    $buf = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($b in $blocks) {
      if (($cursor + $b[1]) -gt $bytes.Length) { throw "read past end" }
      $chunk = New-Object byte[] $b[1]
      [Array]::Copy($bytes, $cursor, $chunk, 0, $b[1])
      $cursor += $b[1]
      $dec = Decompress-Block $chunk $b[0] $comp
      $buf.AddRange($dec)
    }
    $cand = $buf.ToArray()
    if ($cand.Length -lt 20) { throw "too small" }
    $metaSize = Read-BE32 $cand 0
    $fileSize = Read-BE32 $cand 4
    $sfVer = Read-BE32 $cand 8
    if ($fileSize -ne $cand.Length) { throw ("size field " + $fileSize + " != " + $cand.Length) }
    if ($sfVer -lt 5 -or $sfVer -gt 40) { throw ("implausible format version " + $sfVer) }
    $data = $cand
    Log ("    layout: " + $(if ($mode -eq 10) { "u32/u32/u16" } else { "u16/u16/u16" }) + "  blocks=" + $blocks.Count)
    Log ("    unpacked: " + $data.Length + " bytes (meta=" + $metaSize + " ver=" + $sfVer + ")")
    break
  } catch {
    Log ("    trial failed: " + $_.Exception.Message)
  }
}

if ($null -eq $data) { Log "[X] Could not unpack asset data."; Save-Report; Read-Host "Enter"; exit 1 }

# --------------------------------------------------------------- strings
$strings = New-Object System.Collections.ArrayList
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$n = $data.Length
for ($i = 0; $i -lt ($n - 6); $i++) {
  $len = [BitConverter]::ToInt32($data, $i)
  if ($len -lt 2 -or $len -gt 20000) { continue }
  $endTxt = $i + 4 + $len
  if ($endTxt -ge $n) { continue }
  if (-not $PRINT[$data[$endTxt - 1]]) { continue }
  if ($PRINT[$data[$endTxt]]) { continue }
  $ok = $true
  for ($k = $i + 4; $k -lt $endTxt; $k++) {
    if (-not $PRINT[$data[$k]]) { $ok = $false; break }
  }
  if (-not $ok) { continue }
  $txt = [System.Text.Encoding]::UTF8.GetString($data, $i + 4, $len)
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
[System.IO.File]::WriteAllLines((Join-Path $out "01-strings.txt"), $strings.ToArray(), $utf8)
[System.IO.File]::WriteAllLines((Join-Path $out "02-runs.txt"), $runs.ToArray(), $utf8)

Log ""
Log "=========================================================="
Log ("  strings found : " + $strings.Count)
Log ("  runs found    : " + $runs.Count)
Log "=========================================================="
Log ""
Log "DONE. Now: open the Desktop folder  dd-strings2  and upload"
Log "these two files to https://catbox.moe :"
Log "       01-strings.txt"
Log "       02-runs.txt"
Log "Then paste the two links in the chat."
Log ""
Log ("Saved in: " + $out)

Save-Report
try { Start-Process explorer.exe -ArgumentList $out } catch { }
Write-Host ""
Write-Host "FINISHED - folder dd-strings2 opened on your Desktop" -ForegroundColor Green
Read-Host "Press Enter to close"
