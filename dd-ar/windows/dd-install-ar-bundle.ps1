param([string]$Target, [switch]$Restore)

# =====================================================================
#  dd-install-ar-bundle.ps1   (v1)
#
#  Double Dealers - installs the arabic version of the GERMAN language
#  file, so the game itself shows arabic without any mod.
#
#  all automatic:
#    1. finds the game + the german localization file
#    2. downloads the ready arabic text file (made by the helper)
#    3. rebuilds the game file around it (same structure, checked)
#    4. reads the new file back to be sure it is valid
#    5. saves a backup of the original and installs the new file
#
#  run again with  -Restore  to put the original german file back.
#  Output + report -> Desktop\dd-ar-install\
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
#  part two - install the arabic version of the german bundle
# =====================================================================

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-install"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:links = New-Object System.Collections.ArrayList

$LEAF  = "localization-string-tables-german(de)_assets_all.bundle"
$URL   = "https://raw.githubusercontent.com/lengweny82-ship-it/opencode/arena/01a0bf68-opencode/dd-ar/prebuilt/payload-ar-german.b64.txt"
$WANT_PAYLOAD     = 65272
$WANT_PAYLOAD_SHA = "bbb2368356ab53abe82af28aee54134b4a9409f9a325d75c3e7191977e0cebec"
$ORIG_PAYLOAD_SHA16 = "31b35a7d0e6fa5a1"

function Save-Report { try { Set-Content -Path (Join-Path $out "00-INSTALL-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

function Upload-Report {
  $f = Join-Path $out "00-INSTALL-REPORT.txt"
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

function ShaHex([byte[]]$b) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = $sha.ComputeHash($b)
  $sb = New-Object System.Text.StringBuilder
  foreach ($x in $h) { [void]$sb.Append($x.ToString("x2")) }
  return $sb.ToString()
}
function Sha16Hex([byte[]]$b) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = $sha.ComputeHash($b)
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt 8; $i++) { [void]$sb.Append($h[$i].ToString("x2")) }
  return $sb.ToString()
}

# find the german bundle (same search as the other scripts)
function Find-BundleFile([string]$leaf, [string]$dir) {
  if ($dir) {
    $p = Join-Path $dir $leaf
    if (Test-Path $p) { return (Get-Item $p).FullName }
  }
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

function Read-Node0([byte[]]$tbl, [int]$entryMode, [bool]$hasHash, [bool]$be, [int]$blockCount) {
  # the file list sits right after the block list:  offset i64, size i64, flags u32, name (text)
  $entrySize = 10
  if ($entryMode -eq 6) { $entrySize = 6 }
  $entryBase = 4
  if ($hasHash) { $entryBase = 20 }
  $q = $entryBase + $blockCount * $entrySize
  $info = [pscustomobject]@{ Ok = $false; Count = 0; Off = 0; Size = 0; Flags = 0; Name = ""; PosSize = 0; PosOff = 0 }
  if (($q + 4) -gt $tbl.Length) { return $info }
  $nc = 0
  if ($be) { $nc = [int](Read-BE32 $tbl $q) } else { $nc = [int](Read-LE32 $tbl $q) }
  $info.Count = $nc
  $q = $q + 4
  if ($nc -le 0) { return $info }
  if (($q + 20) -gt $tbl.Length) { return $info }
  $info.PosOff = $q
  $info.PosSize = $q + 8
  if ($be) {
    $info.Off = Read-BE64 $tbl $q
    $info.Size = Read-BE64 $tbl ($q + 8)
    $info.Flags = [int](Read-BE32 $tbl ($q + 16))
  } else {
    $info.Off = Read-LE64 $tbl $q
    $info.Size = Read-LE64 $tbl ($q + 8)
    $info.Flags = [int](Read-LE32 $tbl ($q + 16))
  }
  $p2 = $q + 20
  $sb = New-Object System.Text.StringBuilder
  while ($p2 -lt $tbl.Length -and $tbl[$p2] -ne 0) { [void]$sb.Append([char]$tbl[$p2]); $p2++ }
  $info.Name = $sb.ToString()
  $info.Ok = $true
  return $info
}

# ---------------------------------------------------------------- start
$script:report = New-Object System.Collections.ArrayList
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Log "Double Dealers - arabic install"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""

$file = Find-BundleFile $LEAF $Target
if (-not $file) {
  Log "[X] the game file was not found:"
  Log ("    " + $LEAF)
  Log "    (is the game installed? you can pass the folder with  -Target)"
  Finish "STOPPED"
  exit 1
}
$dir = Split-Path $file -Parent
$bak = $file + ".original"
Log ("file    : " + $file)
Log ("size    : " + (Get-Item $file).Length + " bytes")
Log ("backup  : " + (Test-Path $bak))
Log ""

if ($Restore) {
  Log "RESTORE"
  if (-not (Test-Path $bak)) { Log "[X] no backup found - nothing to restore"; Finish "STOPPED"; exit 1 }
  try {
    Copy-Item -Force $bak $file
    Log ("  original put back : " + (Get-Item $file).Length + " bytes")
    Finish "DONE - the game is back to normal"
    exit 0
  } catch {
    Log ("[X] could not restore : " + $_.Exception.Message)
    Finish "STOPPED"
    exit 1
  }
}

# ---------------------------------------------------------------- download
Log "1) downloading the arabic file ..."
$b64Path = Join-Path $out "payload-ar-german.b64.txt"
$downloaded = $false
foreach ($attempt in @(1, 2)) {
  try {
    $u = $URL + "?v=" + $attempt
    Invoke-WebRequest -Uri $u -OutFile $b64Path -UseBasicParsing -TimeoutSec 180
    if ((Test-Path $b64Path) -and (Get-Item $b64Path).Length -gt 1000) { $downloaded = $true; break }
  } catch {
    Log ("   download error : " + $_.Exception.Message)
  }
}
if (-not $downloaded) { Log "[X] could not download the file - check the internet and try again"; Finish "STOPPED"; exit 1 }
$txt = [System.IO.File]::ReadAllText($b64Path)
$txt = $txt -replace "\s", ""
Log ("   downloaded : " + $txt.Length + " characters")
try { $gz = [Convert]::FromBase64String($txt) } catch { Log "[X] the downloaded file is damaged (base64)"; Finish "STOPPED"; exit 1 }
$payload = $null
try {
  $ms = New-Object System.IO.MemoryStream
  $ms.Write($gz, 0, $gz.Length)
  $ms.Position = 0
  $gz2 = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
  $ms2 = New-Object System.IO.MemoryStream
  $buf = [byte[]]::new(65536)
  while (($r = $gz2.Read($buf, 0, $buf.Length)) -gt 0) { $ms2.Write($buf, 0, $r) }
  $gz2.Close()
  $payload = $ms2.ToArray()
} catch {
  Log ("[X] could not unpack the downloaded file : " + $_.Exception.Message)
  Finish "STOPPED"
  exit 1
}
$psh = ShaHex $payload
Log ("   payload : " + $payload.Length + " bytes  sha256=" + $psh.Substring(0,16))
if ($payload.Length -ne $WANT_PAYLOAD -or $psh -ne $WANT_PAYLOAD_SHA) {
  Log "[X] the downloaded file does not match - stopping (nothing changed)"
  Finish "STOPPED"
  exit 1
}
Log "   OK"
Log ""

# ---------------------------------------------------------------- read the game file
Log "2) reading the game file ..."
$bOld = [System.IO.File]::ReadAllBytes($file)
$dbg = New-Object System.Text.StringBuilder
$pOld = Unpack-File $bOld "german" $dbg
if (($pOld.Data -isnot [byte[]]) -or ($pOld.Data.Length -lt 400)) {
  Log "[X] the game file could not be read"
  Log $dbg.ToString()
  Finish "STOPPED"
  exit 1
}
Log ("   unpacked : " + $pOld.Data.Length + " bytes  sha16=" + (Sha16Hex $pOld.Data))
Log ("   blocks : " + $pOld.Blocks.Count + "   mode=" + $pOld.Mode + "   endian=" + $(if ($pOld.Be) { "BE" } else { "LE" }) + "   hash=" + $pOld.HasHash + "   pad=" + $pOld.Pad)
if ((Sha16Hex $pOld.Data) -ne $ORIG_PAYLOAD_SHA16) {
  Log "[X] this is not the expected game version (the file inside is different) - stopping"
  Finish "STOPPED"
  exit 1
}
$node = Read-Node0 $pOld.Table $pOld.Mode $pOld.HasHash $pOld.Be $pOld.Blocks.Count
Log ("   file list : count=" + $node.Count + "  name=" + $node.Name + "  offset=" + $node.Off + "  size=" + $node.Size)
if (-not $node.Ok -or $node.Count -ne 1 -or $pOld.Blocks.Count -ne 1) {
  Log "[X] unexpected file layout - stopping (nothing changed)"
  Finish "STOPPED"
  exit 1
}
if ($node.Size -ne $pOld.Data.Length) {
  Log ("[X] size check failed (" + $node.Size + " vs " + $pOld.Data.Length + ") - stopping")
  Finish "STOPPED"
  exit 1
}
Log "   OK"
Log ""

# ---------------------------------------------------------------- build
Log "3) building the new file ..."
$tbl = [byte[]]::new($pOld.Table.Length)
[Array]::Copy($pOld.Table, $tbl, $pOld.Table.Length)
$entrySize = 10
if ($pOld.Mode -eq 6) { $entrySize = 6 }
$entryBase = 4
if ($pOld.HasHash) { $entryBase = 20 }
$newLen = $payload.Length
if ($pOld.Mode -eq 10) {
  Write-As $tbl $entryBase ([long]$newLen) $pOld.Be 4
  Write-As $tbl ($entryBase + 4) ([long]$newLen) $pOld.Be 4
  Write-As $tbl ($entryBase + 8) 0 $pOld.Be 2
} else {
  Write-As $tbl $entryBase ([long]$newLen) $pOld.Be 2
  Write-As $tbl ($entryBase + 2) ([long]$newLen) $pOld.Be 2
  Write-As $tbl ($entryBase + 4) 0 $pOld.Be 2
}
Write-As $tbl $node.PosOff ([long]0) $pOld.Be 8
Write-As $tbl $node.PosSize ([long]$newLen) $pOld.Be 8
$bipNew = $pOld.HeaderEnd
if ($pOld.Ver -ge 7) { $bipNew = Align16 $pOld.HeaderEnd }
$dataPosNew = $bipNew + $tbl.Length
if ($pOld.Pad) { $dataPosNew = Align16 $dataPosNew }
$totalNew = $dataPosNew + $newLen
$header = [byte[]]::new($pOld.HeaderEnd)
[Array]::Copy($bOld, 0, $header, 0, $pOld.HeaderEnd)
Write-As $header $pOld.SizeOff ([long]$totalNew) $pOld.Be 8
Write-As $header $pOld.CbiOff ([long]$tbl.Length) $pOld.Be 4
Write-As $header $pOld.UbiOff ([long]$tbl.Length) $pOld.Be 4
$newFlags = ($pOld.Flags -band 0xFFFFFFC0) -bor 0x40
Write-As $header $pOld.FlagsOff ([long]$newFlags) $pOld.Be 4
$newFile = [byte[]]::new($totalNew)
[Array]::Copy($header, 0, $newFile, 0, $header.Length)
[Array]::Copy($tbl, 0, $newFile, $bipNew, $tbl.Length)
[Array]::Copy($payload, 0, $newFile, $dataPosNew, $payload.Length)
Log ("   new size : " + $newFile.Length + " bytes  (old " + $bOld.Length + ")")
$newPath = Join-Path $out "arabic-german-bundle.bundle"
[System.IO.File]::WriteAllBytes($newPath, $newFile)
Log ("   saved    : " + $newPath)
Log ""

# ---------------------------------------------------------------- check
Log "4) checking the new file ..."
$dbg2 = New-Object System.Text.StringBuilder
$chk = Unpack-File $newFile "newfile" $dbg2
if (($chk.Data -isnot [byte[]]) -or ($chk.Data.Length -lt 400)) {
  Log "[X] the new file cannot be read back - not installed"
  Log $dbg2.ToString()
  Finish "STOPPED"
  exit 1
}
$chkSha = ShaHex $chk.Data
$node2 = Read-Node0 $chk.Table $chk.Mode $chk.HasHash $chk.Be $chk.Blocks.Count
Log ("   read back : " + $chk.Data.Length + " bytes  sha256=" + $chkSha.Substring(0,16))
Log ("   file list : count=" + $node2.Count + "  name=" + $node2.Name + "  size=" + $node2.Size)
$okAll = ($chkSha -eq $WANT_PAYLOAD_SHA) -and ($chk.Data.Length -eq $WANT_PAYLOAD)
if ($node2.Ok) { $okAll = $okAll -and ($node2.Size -eq $WANT_PAYLOAD) -and ($node2.Name -eq $node.Name) }
$arGroups = 0
for ($bi = 0; $bi -lt ($chk.Data.Length - 2); $bi++) {
  if ($chk.Data[$bi] -eq 0xEF -and $chk.Data[$bi+1] -ge 0xB9 -and $chk.Data[$bi+1] -le 0xBB) { $arGroups++ }
}
$deWords = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)
$chkTxt = $utf8.GetString($chk.Data)
foreach ($w in @("Einstellungen", "Kartenslot", "Preisbonus")) { if ($chkTxt.IndexOf($w) -ge 0) { $deWords++ } }
Log ("   arabic letter groups found : " + $arGroups + "     old german words left : " + $deWords + "/3")
if ($arGroups -lt 100) { $okAll = $false }
if (-not $okAll) { Log "[X] the check failed - not installed"; Log $dbg2.ToString(); Finish "STOPPED"; exit 1 }
Log "   OK - the new file is valid"
Log ""

# ---------------------------------------------------------------- install
Log "5) installing ..."
try {
  if (-not (Test-Path $bak)) {
    Copy-Item -Force $file $bak
    Log ("   backup of the original saved : " + $bak)
  } else {
    $bOldCheck = [System.IO.File]::ReadAllBytes($bak)
    $dbg3 = New-Object System.Text.StringBuilder
    $pChk = Unpack-File $bOldCheck "backupfile" $dbg3
    if (($pChk.Data -is [byte[]]) -and ((Sha16Hex $pChk.Data) -eq $ORIG_PAYLOAD_SHA16)) {
      Log "   backup already there (original confirmed)"
    } else {
      Log ("   backup is replaced (the old one was not the original)")
      Copy-Item -Force $file $bak
    }
  }
  Copy-Item -Force $newPath $file
  Log ("   installed : " + $file)
} catch {
  Log ("[X] could not write the file : " + $_.Exception.Message)
  Log "    (is the game running? close it and try again)"
  Finish "STOPPED"
  exit 1
}
try {
  $back = [System.IO.File]::ReadAllBytes($file)
  Log ("   file on disk is now : " + $back.Length + " bytes  sha256=" + (ShaHex $back).Substring(0,16))
  if ((ShaHex $back) -ne (ShaHex $newFile)) { Log "   [!] warning: the file on disk differs" }
} catch { }
Log ""

Log "extra info (for the helper):"
try {
  $aa = Join-Path $dir "..\.."
  $aa = [System.IO.Path]::GetFullPath($aa)
  $aaDir = Join-Path $dir ".."
  $aaDir = [System.IO.Path]::GetFullPath($aaDir)
  Log ("   folder : " + $dir)
  $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | Sort-Object Name
  foreach ($f2 in $files) { Log ("     " + $f2.Name + "  " + $f2.Length) }
  $cat = Get-ChildItem -Path $aaDir -Filter "catalog*" -Recurse -File -ErrorAction SilentlyContinue
  if ($cat -and $cat.Count -gt 0) {
    foreach ($c2 in $cat) { Log ("   catalog : " + $c2.FullName + "  " + $c2.Length + " bytes") }
  } else {
    Log "   catalog : none found"
  }
} catch {
  Log ("   (extra info failed : " + $_.Exception.Message + ")")
}
Log ""
Log "DONE"
Log ""
Log "  1) start the game"
Log "  2) Settings -> Language -> Deutsch   (the german slot is now arabic)"
Log "  3) the texts should appear in arabic"
Log ""
Log "  to undo everything: run the same command again with  -Restore"
Finish "DONE - the german slot is now arabic"
exit 0
