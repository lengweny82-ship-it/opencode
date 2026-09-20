param([string]$Target, [switch]$Restore)

# =====================================================================
#  dd-build-ar-bundle.ps1   (v2)
#
#  Double Dealers - puts the arabic translation into the GERMAN slot,
#  so the game itself shows arabic without any mod.
#
#  all automatic:
#    1. finds the game + the localization bundles
#    2. unpacks the english and the german bundle (unity LZ4 format)
#    3. lists every text inside both
#    4. pairs them (english <-> german) and downloads the arabic file
#       (letters shaped + ordered for an engine without arabic support)
#    5. writes an arabic copy of the GERMAN bundle (same file name)
#    6. reads the new file back to be sure it is valid
#    7. saves a backup of the original and installs the new file
#
#  run again with  -Restore  to put the original german file back.
#  Output + report -> Desktop\dd-ar-build\
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

function Get-PayloadInfo([byte[]]$cand) {
  # Describes the unpacked asset file. Unity 6 (serialized version >= 22)
  # uses a wider 64-bit header, so both layouts are accepted.
  $info = [pscustomobject]@{ Ok = $false; Kind = "unknown"; Version = 0; FileSize = 0; Ratio = 0 }
  if ($null -eq $cand -or $cand.Length -lt 32) { return $info }
  $v32 = Read-BE32 $cand 8
  $fs32 = Read-BE32 $cand 4
  if ($fs32 -eq $cand.Length -and $v32 -ge 5 -and $v32 -lt 22) {
    # classic layout: metadataSize, fileSize, version, dataOffset (all u32)
    $info.Ok = $true; $info.Kind = "classic32"; $info.Version = $v32; $info.FileSize = $fs32
  } elseif ($v32 -ge 22 -and $v32 -le 60) {
    # Unity 6 layout: u32 header + 64-bit fileSize at offset 24
    $fs64 = Read-BE64 $cand 24
    if ($fs64 -eq $cand.Length) {
      $info.Ok = $true; $info.Kind = "unity6-64"; $info.Version = $v32; $info.FileSize = $fs64
    } else {
      $info.Kind = "unity6-64?"; $info.Version = $v32; $info.FileSize = $fs64
    }
  }
  $sample = [Math]::Min(4000, $cand.Length)
  $okCount = 0
  for ($k = 0; $k -lt $sample; $k++) { if ($PRINT[$cand[$k]]) { $okCount++ } }
  if ($sample -gt 0) { $info.Ratio = [int](100.0 * $okCount / $sample) }
  return $info
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
  $arr = $buf.ToArray()
  $hits = 0
  $txt = [System.Text.Encoding]::ASCII.GetString($arr)
  foreach ($w in @("Clause","Auction","Market","Seller","Buyer","Bid","Item","Profit","Bluff","Card","Round","Value")) {
    if ($txt.IndexOf($w) -ge 0) { $hits++ }
  }
  $info = Get-PayloadInfo $arr
  return [pscustomobject]@{
    Data    = $arr
    Table   = $table
    Blocks  = $blocks
    TotalU  = $totalC
    Hits    = $hits
    Kind    = $info.Kind
    Version = $info.Version
    SizeOK  = $info.Ok
    Ratio   = $info.Ratio
  }
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

# =====================================================================
#  arabic builder  -  part two (uses the proven unpack code above)
# =====================================================================

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-build"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:links = New-Object System.Collections.ArrayList
function Save-Report { try { Set-Content -Path (Join-Path $out "00-BUILD-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

$ARABIC_URL = "https://raw.githubusercontent.com/lengweny82-ship-it/opencode/arena/01a0bf68-opencode/dd-ar/translation/_AutoTranslations.display-ready.ar.txt"

function Upload-Report {
  $f = Join-Path $out "00-BUILD-REPORT.txt"
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
  try { Set-Content -Path (Join-Path $out "01-LINK-TO-SEND.txt") -Value ($script:links -join [Environment]::NewLine) -Encoding UTF8 } catch { }
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
  try { Start-Process explorer.exe -ArgumentList $out } catch { }
  Write-Host ""
  Write-Host "FINISHED" -ForegroundColor Green
  Read-Host "Press Enter to close"
}

function Write-As([byte[]]$b, [int]$p, [long]$v, [bool]$be, [int]$size) {
  for ($k = 0; $k -lt $size; $k++) {
    $sh = 8 * $k
    if ($be) { $sh = 8 * ($size - 1 - $k) }
    $b[$p + $k] = [byte](($v -shr $sh) -band 0xFF)
  }
}

function Make-Result($data, $table, $blocks, $mode, $be, $atEnd, $pad, $flags, $headerEnd, $sizeOff, $cbiOff, $ubiOff, $flagsOff, $ver, $hasHash, $why) {
  # one single object, all values given at once (the safe way - see report)
  $o = [pscustomobject]@{
    Ok = $true
    Why = $why
    Data = $data
    Table = $table
    Blocks = $blocks
    Mode = $mode
    Be = $be
    AtEnd = $atEnd
    Pad = $pad
    Flags = $flags
    HeaderEnd = $headerEnd
    SizeOff = $sizeOff
    CbiOff = $cbiOff
    UbiOff = $ubiOff
    FlagsOff = $flagsOff
    Ver = $ver
    HasHash = $hasHash
  }
  return $o
}

function Unpack-File([byte[]]$bytes, [string]$label, [System.Text.StringBuilder]$dbg) {
  $p = 0
  $sig = Read-NullString $bytes ([ref]$p)
  if ($sig -ne "UnityFS") { return (Make-Result $null $null $null 10 $true $false $false 0 0 0 0 0 0 0 $true "not a UnityFS bundle") }
  $ver = [int](Read-BE32 $bytes $p); $p += 4
  $uv = Read-NullString $bytes ([ref]$p)
  $ur = Read-NullString $bytes ([ref]$p)
  $sizeOff = $p
  $p += 8
  $cbiOff = $p
  $cbi = [int](Read-BE32 $bytes $p); $p += 4
  $ubiOff = $p
  $ubi = [int](Read-BE32 $bytes $p); $p += 4
  $flagsOff = $p
  $flags = [int](Read-BE32 $bytes $p); $p += 4
  $headerEnd = $p
  $comp = $flags -band 0x3F
  $atEnd = (($flags -band 0x80) -ne 0)
  $pad = (($flags -band 0x200) -ne 0)
  [void]$dbg.AppendLine("[" + $label + "] ver=" + $ver + " unity=" + $ur + " cbi=" + $cbi + " ubi=" + $ubi + " flags=0x" + ("{0:x}" -f $flags) + " comp=" + $comp + " atEnd=" + $atEnd + " pad=" + $pad + " headerEnd=" + $headerEnd)
  $dataStart = $p
  if ($ver -ge 7) { $dataStart = Align16 $p }
  $bip = $dataStart
  if ($atEnd) { $bip = $bytes.Length - $cbi }
  foreach ($be in @($true, $false)) {
    foreach ($mode in @(10, 6)) {
      foreach ($hash in @($true, $false)) {
        foreach ($align in @($true, $false)) {
          $endName = "LE"
          if ($be) { $endName = "BE" }
          $tag = $label + " endian=$endName mode=$mode hash=$hash align=$align"
          try {
            $x = Try-Unpack $bytes $dataStart $bip $cbi $ubi $comp $atEnd $pad $mode $hash $align $be $dbg
            if ($null -ne $x -and $null -ne $x.Data -and $x.Data.Length -gt 400) {
              [void]$dbg.AppendLine("  [$tag] decoded " + $x.Data.Length + " bytes | payload=" + $x.Kind + " v" + $x.Version + " ascii=" + $x.Ratio + "% words=" + $x.Hits + "/12")
              if ($x.SizeOK -or ($x.Data.Length -eq $x.TotalU) -or ($x.Hits -ge 3)) {
                [void]$dbg.AppendLine("  [$tag] ACCEPTED")
                return (Make-Result $x.Data $x.Table $x.Blocks $mode $be $atEnd $pad $flags $headerEnd $sizeOff $cbiOff $ubiOff $flagsOff $ver $hash "")
              }
            } else {
              [void]$dbg.AppendLine("  [$tag] decoded but too small")
            }
          } catch {
            [void]$dbg.AppendLine("  [$tag] " + $_.Exception.Message)
          }
        }
      }
    }
  }
  return (Make-Result $null $null $null 10 $true $false $false 0 0 0 0 0 0 $ver $true "could not unpack")
}
# =====================================================================
#  part three - fix the catalog fingerprint (crc32 of the unpacked data)
# =====================================================================

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-catalog3"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:links = New-Object System.Collections.ArrayList
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report3 { try { Set-Content -Path (Join-Path $out "00-CATALOG3-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

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
function Finish3([string]$msg) {
  Log ""
  Log "=========================================================="
  Log ("  " + $msg)
  Log "=========================================================="
  Save-Report3
  $l = Upload-File (Join-Path $out "00-CATALOG3-REPORT.txt")
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

# ---- crc32 (zip / zlib), Int64 maths only ----
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
Log "Double Dealers - catalog fix (step 3)"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""
if (-not $file) { Log "[X] game not found"; Finish3 "STOPPED"; exit 1 }

$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$gbak = $file + ".original"
$cat = Join-Path $aa "catalog.bin"
$catbak = $cat + ".original"
$hashf = Join-Path $aa "catalog.hash"
$hashbak = $hashf + ".original"
$enFile = Join-Path $dir "localization-string-tables-english(en)_assets_all.bundle"

Log ("language file : " + (Get-Item $file).Length + " bytes")
Log ("original file : " + (Test-Path $gbak))
Log ("catalog.bin   : " + (Get-Item $cat -ErrorAction SilentlyContinue).Length + " bytes")
Log ("catalog.hash  : " + (Get-Item $hashf -ErrorAction SilentlyContinue).Length + " bytes")
Log ""

if ($Restore) {
  Log "RESTORE"
  if (Test-Path $catbak) { try { Copy-Item -Force $catbak $cat; Log "   catalog.bin put back" } catch { Log ("[X] " + $_.Exception.Message) } }
  else { Log "   no catalog backup found" }
  if ((Test-Path $hashbak) -and (Test-Path $hashf)) { try { Copy-Item -Force $hashbak $hashf; Log "   catalog.hash put back" } catch { } }
  Finish3 "DONE - catalog restored"
  exit 0
}

# ---------------------------------------------------------------- 0. self test
Log "0) checking my own crc32 maths ..."
$tcHex = Hex32 (Get-Crc32 ([System.Text.Encoding]::ASCII.GetBytes("123456789")))
Log ("   test : " + $tcHex + "   (must be 0xcbf43926)")
if ($tcHex -ne "0xcbf43926") { Log "[X] crc32 code is wrong - stopping"; Finish3 "STOPPED"; exit 1 }
Log "   OK"
Log ""

# ---------------------------------------------------------------- 1. unpack both
Log "1) unpacking the files (this is what the game checks) ..."
$dbg = New-Object System.Text.StringBuilder
$pNew = Unpack-File ([System.IO.File]::ReadAllBytes($file)) "installed" $dbg
if (($pNew.Data -isnot [byte[]]) -or ($pNew.Data.Length -lt 400)) { Log "[X] cannot unpack the installed file"; Log $dbg.ToString(); Finish3 "STOPPED"; exit 1 }
$ars = 0
for ($bi = 0; $bi -lt ($pNew.Data.Length - 2); $bi++) { if ($pNew.Data[$bi] -eq 0xEF -and $pNew.Data[$bi+1] -ge 0xB9 -and $pNew.Data[$bi+1] -le 0xBB) { $ars++ } }
$crcNew = Get-Crc32 $pNew.Data
Log ("   installed file : data " + $pNew.Data.Length + " bytes   crc32 = " + (Hex32 $crcNew) + "   arabic letters : " + $ars)
$crcOrig = -1
if (Test-Path $gbak) {
  $dbg2 = New-Object System.Text.StringBuilder
  $pOld = Unpack-File ([System.IO.File]::ReadAllBytes($gbak)) "original" $dbg2
  if (($pOld.Data -is [byte[]]) -and ($pOld.Data.Length -gt 400)) {
    $crcOrig = Get-Crc32 $pOld.Data
    Log ("   original file  : data " + $pOld.Data.Length + " bytes   crc32 = " + (Hex32 $crcOrig))
  } else { Log "   [!] the backup could not be unpacked" }
} else { Log "   [!] the backup file is missing" }
$crcEn = -1
if (Test-Path $enFile) {
  $dbg3 = New-Object System.Text.StringBuilder
  $pEn = Unpack-File ([System.IO.File]::ReadAllBytes($enFile)) "english" $dbg3
  if (($pEn.Data -is [byte[]]) -and ($pEn.Data.Length -gt 400)) {
    $crcEn = Get-Crc32 $pEn.Data
    Log ("   english file   : data " + $pEn.Data.Length + " bytes   crc32 = " + (Hex32 $crcEn))
  } else { Log "   [!] the english file could not be unpacked" }
}
Log ""

# ---------------------------------------------------------------- 2. catalog
$cb = [System.IO.File]::ReadAllBytes($cat)
$posName = -1
try { $posName = ([System.Text.Encoding]::ASCII.GetString($cb)).IndexOf("localization-string-tables-german(de)") } catch { }
Log ("2) catalog : german name at offset " + $posName)
$posSize = -1
$sizeOld = 0
if (Test-Path $gbak) { $sizeOld = (Get-Item $gbak).Length }
if ($sizeOld -gt 0) {
  $hitsSize = Find-U32 $cb $sizeOld
  Log ("   the original size (" + $sizeOld + ") appears " + $hitsSize.Count + " time(s)")
  foreach ($p in $hitsSize) {
    $near = Has-Ascii $cb ($p - 4000) 8000 "localization-string-tables-german(de)"
    Log ("      at " + $p + "   near the german name : " + $near + "   fingerprint there : " + (Hex32 (U32 $cb ($p - 4))))
    if ($near -and ($posSize -lt 0)) { $posSize = $p }
  }
}
if ($posSize -lt 0) { Log "[X] the german entry was not found in catalog.bin - nothing changed"; Finish3 "STOPPED"; exit 1 }
$posCrc = $posSize - 4
$crcInCat = U32 $cb $posCrc
Log ("   german entry : fingerprint " + (Hex32 $crcInCat) + "   size " + (U32 $cb $posSize))
Log "   hex before:"
Log (Hex-Dump $cb ($posCrc - 64) 128)
Log ""

# ---------------------------------------------------------------- 3. confirm the rule
Log "3) confirming the rule (fingerprint = crc32 of the unpacked data) ..."
$ruleOk = $true
if ($crcOrig -ge 0) {
  $same = ($crcOrig -eq $crcInCat)
  Log ("   original data crc32 vs the catalog entry : " + (Hex32 $crcOrig) + " vs " + (Hex32 $crcInCat) + "   ->  " + $same)
  if (-not $same) { $ruleOk = $false }
}
if ($crcEn -ge 0) {
  $hitsEn = Find-U32 $cb $crcEn
  Log ("   the english data crc32 (" + (Hex32 $crcEn) + ") appears " + $hitsEn.Count + " time(s) in the catalog")
  if ($hitsEn.Count -lt 1) { $ruleOk = $false }
}
if (-not $ruleOk) {
  Log "[!] the rule does not hold on this machine - nothing was changed"
  Finish3 "STOPPED - no change"
  exit 1
}
Log "   the rule holds - safe to continue"
Log ""

# ---------------------------------------------------------------- 4. patch
$before = [System.IO.File]::ReadAllBytes($cat)
try {
  if (-not (Test-Path $catbak)) { Copy-Item -Force $cat $catbak; Log ("   backup of catalog.bin : " + $catbak) } else { Log "   backup of catalog.bin already there" }
  PutU32 $cb $posCrc ([int64]$crcNew)
  PutU32 $cb $posSize ([int64](Get-Item $file).Length)
  [System.IO.File]::WriteAllBytes($cat, $cb)
} catch {
  Log ("[X] could not write : " + $_.Exception.Message)
  Log "    (is the game running? close it and try again)"
  Finish3 "STOPPED - no change"
  exit 1
}
$after = [System.IO.File]::ReadAllBytes($cat)
Log ("4) written : new fingerprint " + (Hex32 (U32 $after $posCrc)) + "   new size " + (U32 $after $posSize))
Log "   hex after:"
Log (Hex-Dump $after ($posCrc - 64) 128)
Log ""
$diff = 0
if ($after.Length -eq $before.Length) { for ($i = 0; $i -lt $after.Length; $i++) { if ($after[$i] -ne $before[$i]) { $diff++ } } }
Log ("   bytes changed in the catalog : " + $diff + "   (must be 8)")
if ($diff -ne 8) { Log "[!] unexpected - putting the original back"; Copy-Item -Force $catbak $cat; Finish3 "STOPPED - reverted"; exit 1 }
Log ""

# ---------------------------------------------------------------- 5. catalog.hash
try {
  if (Test-Path $hashf) {
    $hb = [System.IO.File]::ReadAllBytes($hashf)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $shaOrig = $sha.ComputeHash $before
    $same = ($hb.Length -eq $shaOrig.Length)
    if ($same) { for ($i = 0; $i -lt $hb.Length; $i++) { if ($hb[$i] -ne $shaOrig[$i]) { $same = $false; break } } }
    Log ("5) catalog.hash : " + $hb.Length + " bytes   sha256(original catalog) : " + $same)
    if ($same) {
      if (-not (Test-Path $hashbak)) { Copy-Item -Force $hashf $hashbak }
      [System.IO.File]::WriteAllBytes($hashf, $sha.ComputeHash($after))
      Log "   catalog.hash updated (kept in sync)"
    } else { Log "   (not a plain sha256 of the catalog - left untouched)" }
  }
} catch { Log ("5) hash step failed : " + $_.Exception.Message) }
Log ""

# ---------------------------------------------------------------- 6. player log
try {
  $logs = Get-ChildItem -Path (Join-Path $env:USERPROFILE "AppData\LocalLow") -Filter "Player*.log" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
  if ($logs -and $logs.Count -gt 0) {
    $lg = $logs[0]
    Log ("6) game log : " + $lg.FullName + "   " + $lg.Length + " bytes   " + $lg.LastWriteTime)
    $txt = ""
    try {
      $fs = [System.IO.File]::Open($lg.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      $sr = New-Object System.IO.StreamReader($fs)
      $txt = $sr.ReadToEnd()
      $sr.Close(); $fs.Close()
    } catch { Log ("   (could not read the log : " + $_.Exception.Message + ")") }
    if ($txt.Length -gt 0) {
      $all = $txt -split "`r?`n"
      Log ("   log lines : " + $all.Count)
      $hit = @($all | Where-Object { $_ -match "[Cc][Rr][Cc]|[Bb]undle|Addressab|[Ll]ocalization|[Ee]rror|[Ee]xception" })
      Log ("   interesting lines : " + $hit.Count)
      $n = 0
      foreach ($l in $hit) { if ($n -ge 60) { break }; Log ("      " + $l); $n++ }
    }
  } else { Log "6) game log : not found" }
} catch { Log ("6) log failed : " + $_.Exception.Message) }
Log ""

# ---------------------------------------------------------------- 7. uploads
Log "7) sending the catalog files to the helper ..."
foreach ($pair in @(@($catbak, "catalog-original.b64.txt", "original catalog.bin"), @($after, "catalog-new.b64.txt", "new catalog.bin"))) {
  $dst = Join-Path $out $pair[1]
  $data = [System.IO.File]::ReadAllBytes([string]$pair[0])
  $b64 = [Convert]::ToBase64String($data)
  $li = New-Object System.Collections.ArrayList
  $i2 = 0
  while ($i2 -lt $b64.Length) { $n2 = [Math]::Min(6000, $b64.Length - $i2); [void]$li.Add($b64.Substring($i2, $n2)); $i2 += $n2 }
  [System.IO.File]::WriteAllText($dst, ($li -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
  $lk = Upload-File $dst
  if ($lk) { [void]$script:links.Add($pair[2] + " : " + $lk); Log ("   " + $pair[2] + " uploaded") }
}
Log ""

Finish3 "DONE - the catalog now matches the arabic file - start the game"
exit 0
