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

function Unpack-File([byte[]]$bytes, [string]$label, [System.Text.StringBuilder]$dbg) {
  $r = [pscustomobject]@{
    Ok = $false; Why = ""; Data = $null; Table = $null; Blocks = $null
    Mode = 10; Be = $true; AtEnd = $false; Pad = $false; Flags = 0
    HeaderEnd = 0; SizeOff = 0; CbiOff = 0; UbiOff = 0; FlagsOff = 0; Ver = 0
    HasHash = $true
  }
  $p = 0
  $sig = Read-NullString $bytes ([ref]$p)
  if ($sig -ne "UnityFS") { $r.Why = "not a UnityFS bundle"; return $r }
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
                $r.Ok = $true
                $r.Data = $x.Data
                $r.Table = $x.Table
                $r.Blocks = $x.Blocks
                $r.Mode = $mode
                $r.Be = $be
                $r.HasHash = $hash
                $r.AtEnd = $atEnd
                $r.Pad = $pad
                $r.Flags = $flags
                $r.HeaderEnd = $headerEnd
                $r.SizeOff = $sizeOff
                $r.CbiOff = $cbiOff
                $r.UbiOff = $ubiOff
                $r.FlagsOff = $flagsOff
                $r.Ver = $ver
                [void]$dbg.AppendLine("  [$tag] ACCEPTED")
                return $r
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
  $r.Why = "could not unpack"
  return $r
}

function Extract-All([byte[]]$data) {
  $list = New-Object System.Collections.ArrayList
  $n = $data.Length
  for ($i = 0; $i -lt ($n - 6); $i++) {
    $len = [BitConverter]::ToInt32($data, $i)
    if ($len -lt 2 -or $len -gt 20000) { continue }
    if (($i + 4 + $len) -ge $n) { continue }
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
    [void]$list.Add([pscustomobject]@{ Off = $i + 4; Len = $realLen; Text = $txt })
  }
  return ,$list
}
function Get-Unique([System.Collections.ArrayList]$all) {
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $uniq = New-Object System.Collections.ArrayList
  foreach ($it in $all) { if ($seen.Add($it.Text)) { [void]$uniq.Add($it.Text) } }
  return ,$uniq
}

# =============================================================== main
Log "=========================================================="
Log "  Double Dealers - arabic bundle builder (v2)"
Log "=========================================================="
Log ""

$fileEn = ""
if ($Target) { $fileEn = $Target }
if ((-not $fileEn) -or (-not (Test-Path $fileEn))) { $fileEn = Find-Bundle }
if ((-not $fileEn) -or (-not (Test-Path $fileEn))) {
  Log "[X] the english bundle was not found."
  Log "    paste the game folder path below (example: E:\SteamLibrary\steamapps\common\Double Dealers Demo)"
  $manual = Read-Host "game folder"
  if ($manual) {
    $manual = $manual.Trim('"')
    $hits = Get-ChildItem -Path $manual -Filter "localization-string-tables-english*" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hits) { $fileEn = $hits.FullName }
  }
}
if ((-not $fileEn) -or (-not (Test-Path $fileEn))) { Log "[X] still not found - stopping"; Finish "STOPPED"; exit 1 }

$aaDir = Split-Path $fileEn -Parent
Log ("aa folder : " + $aaDir)
$all = @(Get-ChildItem -Path $aaDir -Filter "localization-*.bundle" -ErrorAction SilentlyContinue)
$fDe = $null
foreach ($f in $all) { if ($f.Name -match "german") { $fDe = $f } }
if (-not $fDe) { Log "[X] the german bundle is not in that folder"; Finish "STOPPED"; exit 1 }
Log ("german    : " + $fDe.Name + "  (" + $fDe.Length + " bytes)")
Log ("english   : " + (Split-Path $fileEn -Leaf) + "  (" + (Get-Item $fileEn).Length + " bytes)")

$bak = $fDe.FullName + ".original"
if ($Restore) {
  if (Test-Path $bak) {
    Copy-Item -Force $bak $fDe.FullName
    Log "[+] the original german file is back."
  } else { Log "[X] no backup found (" + $bak + ")" }
  Finish "RESTORE"
  exit 0
}

$dbg = New-Object System.Text.StringBuilder
$bDe = [System.IO.File]::ReadAllBytes($fDe.FullName)
$bEn = [System.IO.File]::ReadAllBytes($fileEn)

Log ""
Log "unpacking both bundles ..."
$pDe = Unpack-File $bDe "german" $dbg
$pEn = Unpack-File $bEn "english" $dbg
if ((-not $pDe.Ok) -or ($pDe.Data -isnot [byte[]]) -or ($pDe.Data.Length -lt 400)) {
  Log "[X] could not unpack the german bundle. details:"
  Log $dbg.ToString()
  Finish "STOPPED"
  exit 1
}
if ((-not $pEn.Ok) -or ($pEn.Data -isnot [byte[]]) -or ($pEn.Data.Length -lt 400)) {
  Log "[X] could not unpack the english bundle. details:"
  Log $dbg.ToString()
  Finish "STOPPED"
  exit 1
}
foreach ($ln in ($dbg.ToString() -split "`r?`n")) { if ($ln -match "ACCEPTED") { Log ("  " + $ln.Trim()) } }
Log ("  german  payload : " + $pDe.Data.Length + " bytes  (type=" + $pDe.Data.GetType().Name + " ok=" + $pDe.Ok + ")")
Log ("  english payload : " + $pEn.Data.Length + " bytes  (ok=" + $pEn.Ok + ")")
Log ("  layout : ver=" + $pDe.Ver + " mode=" + $pDe.Mode + " be=" + $pDe.Be + " atEnd=" + $pDe.AtEnd + " pad=" + $pDe.Pad + " fileComp=" + ($pDe.Flags -band 0x3F) + " blocks=" + $pDe.Blocks.Count + " tableLen=" + $pDe.Table.Length)
if ($pDe.AtEnd) { Log "[X] unexpected layout (info at the end) - stopping"; Finish "STOPPED"; exit 1 }

Log ""
Log "listing the texts inside both ..."
$allDe = Extract-All $pDe.Data
$allEn = Extract-All $pEn.Data
$uniqDe = Get-Unique $allDe
$uniqEn = Get-Unique $allEn
Log ("  german  : " + $allDe.Count + " texts / " + $uniqDe.Count + " different")
Log ("  english : " + $allEn.Count + " texts / " + $uniqEn.Count + " different")
if ($uniqEn.Count -lt 100) { Log "[X] no texts found - stopping"; Finish "STOPPED"; exit 1 }

Log ""
Log "downloading the arabic file ..."
$pairs = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$pairsRaw = 0
try {
  $wc = New-Object System.Net.WebClient
  $txt = $wc.DownloadString($ARABIC_URL)
  foreach ($line in ($txt -split "`n")) {
    $l = $line.TrimEnd("`r")
    if (-not $l) { continue }
    if ($l.StartsWith("#")) { continue }
    $idx = $l.IndexOf("=")
    if ($idx -lt 1) { continue }
    $k = $l.Substring(0, $idx)
    $v = $l.Substring($idx + 1)
    if ($k -and $v -and (-not $pairs.ContainsKey($k))) { $pairs[$k] = $v; $pairsRaw++ }
  }
} catch { }
Log ("  arabic entries : " + $pairsRaw)
if ($pairsRaw -lt 100) { Log "[X] could not download the arabic file (internet?)"; Finish "STOPPED"; exit 1 }

$found = 0
foreach ($e in $uniqEn) { if ($pairs.ContainsKey($e)) { $found++ } }
Log ("  english texts with a translation : " + $found + " of " + $pairsRaw)
$miss = 0
$missList = New-Object System.Collections.ArrayList
foreach ($k in $pairs.Keys) { if (-not $uniqEn.Contains($k)) { $miss++; if ($missList.Count -lt 8) { [void]$missList.Add($k) } } }
Log ("  translations whose english text was not found : " + $miss)
foreach ($m in $missList) { Log ("      ? " + $m) }
if ($found -lt 100) { Log "[X] the english list does not match - stopping"; Finish "STOPPED"; exit 1 }

Log ""
Log "pairing english <-> german ..."
$mapDe = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$enN = $uniqEn.Count
$deN = $uniqDe.Count
$i = 0
$j = 0
$anchors = 0
$skipped = 0
$digitOk = 0
$digitBad = 0
$samples = New-Object System.Collections.ArrayList
$badSamples = New-Object System.Collections.ArrayList
while ($i -lt $enN -and $j -lt $deN) {
  $e = $uniqEn[$i]
  $d = $uniqDe[$j]
  $isPair = $pairs.ContainsKey($e)
  if ($e -ceq $d) {
    $anchors++
    if ($isPair) { if (-not $mapDe.ContainsKey($d)) { $mapDe[$d] = $pairs[$e] } }
    $i++; $j++
    continue
  }
  if (($i + 1 -lt $enN) -and ($uniqEn[$i+1] -ceq $d) -and (-not $pairs.ContainsKey($d))) { $i++; $skipped++; continue }
  if (($j + 1 -lt $deN) -and ($e -ceq $uniqDe[$j+1]) -and (-not $pairs.ContainsKey($e))) { $j++; $skipped++; continue }
  if ($isPair) {
    if (-not $mapDe.ContainsKey($d)) { $mapDe[$d] = $pairs[$e] }
    if ($samples.Count -lt 6) { [void]$samples.Add($e + "   ->   " + $d) }
    $digE = -join ([regex]::Matches($e, "\d") | ForEach-Object { $_.Value })
    $digD = -join ([regex]::Matches($d, "\d") | ForEach-Object { $_.Value })
    if ($digE -eq $digD) { $digitOk++ } else { $digitBad++; if ($badSamples.Count -lt 5) { [void]$badSamples.Add($e + "   ->   " + $d) } }
  }
  $i++; $j++
}
Log ("  identical spots (alignment anchors) : " + $anchors)
Log ("  german texts ready to be arabic     : " + $mapDe.Count)
Log ("  pairs whose numbers match           : " + $digitOk + " ok / " + $digitBad + " different")
foreach ($sm in $samples) { Log ("      sample: " + $sm) }
foreach ($bs in $badSamples) { Log ("      check : " + $bs) }
if ($anchors -lt 20 -or $mapDe.Count -lt 250) { Log "[X] alignment looks wrong - stopping"; Finish "STOPPED"; exit 1 }
$badLimit = [int]($digitOk / 3) + 5
if ($digitBad -gt $badLimit) { Log "[X] english and german lists are not in the same order - stopping"; Finish "STOPPED"; exit 1 }

Log ""
Log "writing the arabic texts ..."
$utf8 = New-Object System.Text.UTF8Encoding($false)
$patched = 0
$tooLong = New-Object System.Collections.ArrayList
foreach ($it in $allDe) {
  if (-not $mapDe.ContainsKey($it.Text)) { continue }
  $ar = $mapDe[$it.Text]
  $bytesAr = $utf8.GetBytes($ar)
  if ($bytesAr.Length -gt $it.Len) { [void]$tooLong.Add($it.Text); continue }
  for ($k = 0; $k -lt $it.Len; $k++) {
    if ($k -lt $bytesAr.Length) { $pDe.Data[$it.Off + $k] = $bytesAr[$k] } else { $pDe.Data[$it.Off + $k] = 32 }
  }
  $patched++
}
Log ("  texts written in arabic : " + $patched)
if ($tooLong.Count -gt 0) {
  Log ("  skipped (german slot too small) : " + $tooLong.Count)
  $n = 0
  foreach ($t in $tooLong) { if ($n -ge 10) { break }; Log ("      - " + $t); $n++ }
}
if ($patched -lt 200) { Log "[X] too few texts written - stopping"; Finish "STOPPED"; exit 1 }

Log ""
Log "building the new bundle ..."
$tbl = [byte[]]::new($pDe.Table.Length)
[Array]::Copy($pDe.Table, $tbl, $pDe.Table.Length)
$entrySize = 10
if ($pDe.Mode -eq 6) { $entrySize = 6 }
$entryBase = 4
if ($pDe.HasHash) { $entryBase = 20 }
$k2 = 0
foreach ($blk in $pDe.Blocks) {
  $eStart = $entryBase + $k2 * $entrySize
  if ($pDe.Mode -eq 10) {
    Write-As $tbl ($eStart + 4) ([long]$blk.U) $pDe.Be 4
    Write-As $tbl ($eStart + 8) 0 $pDe.Be 2
  } else {
    Write-As $tbl ($eStart + 2) ([long]$blk.U) $pDe.Be 2
    Write-As $tbl ($eStart + 4) 0 $pDe.Be 2
  }
  $k2++
}
$bipNew = $pDe.HeaderEnd
if ($pDe.Ver -ge 7) { $bipNew = Align16 $pDe.HeaderEnd }
$dataPosNew = $bipNew + $tbl.Length
if ($pDe.Pad) { $dataPosNew = Align16 $dataPosNew }
$totalNew = $dataPosNew + $pDe.Data.Length
$header = [byte[]]::new($pDe.HeaderEnd)
[Array]::Copy($bDe, 0, $header, 0, $pDe.HeaderEnd)
Write-As $header $pDe.SizeOff ([long]$totalNew) $pDe.Be 8
Write-As $header $pDe.CbiOff ([long]$tbl.Length) $pDe.Be 4
Write-As $header $pDe.UbiOff ([long]$tbl.Length) $pDe.Be 4
$newFlags = $pDe.Flags -band 0xFFFFFFC0
Write-As $header $pDe.FlagsOff ([long]$newFlags) $pDe.Be 4
$newFile = [byte[]]::new($totalNew)
[Array]::Copy($header, 0, $newFile, 0, $header.Length)
[Array]::Copy($tbl, 0, $newFile, $bipNew, $tbl.Length)
[Array]::Copy($pDe.Data, 0, $newFile, $dataPosNew, $pDe.Data.Length)
$newPath = Join-Path $out "arabic-german-bundle.bundle"
[System.IO.File]::WriteAllBytes($newPath, $newFile)
Log ("  new size : " + $newFile.Length + " bytes (original " + $bDe.Length + ")")
Log ("  saved to : " + $newPath)

Log ""
Log "checking the new file ..."
$c2 = [System.IO.File]::ReadAllBytes($newPath)
$dbg2 = New-Object System.Text.StringBuilder
$chk = Unpack-File $c2 "newfile" $dbg2
if ((-not $chk.Ok) -or ($chk.Data -isnot [byte[]]) -or ($chk.Data.Length -lt 400)) {
  Log "[X] the new file cannot be read back - not installed"
  Log $dbg2.ToString()
  Finish "STOPPED"
  exit 1
}
$chkText = [System.Text.Encoding]::UTF8.GetString($chk.Data)
$hits = 0
$tested = 0
foreach ($key in $mapDe.Keys) {
  $tested++
  if ($tested -gt 400) { break }
  if ($chkText.IndexOf($mapDe[$key]) -ge 0) { $hits++ }
}
Log ("  read back OK : " + $chk.Data.Length + " bytes, arabic found for " + $hits + " of " + $tested + " checked texts")
if ($hits -lt 50) { Log "[X] verification failed - not installed"; Finish "STOPPED"; exit 1 }

if (-not (Test-Path $bak)) { Copy-Item -Force $fDe.FullName $bak; Log ("  backup of the original : " + $bak) }
Copy-Item -Force $newPath $fDe.FullName
Log ("  installed in the game  : " + $fDe.FullName)
Log ""
Log "  1) start the game"
Log "  2) Settings -> Language -> Deutsch (the german slot)"
Log "  3) the texts appear in arabic"
Log "  to undo: run the same command again with  -Restore"
Finish "DONE - the german slot is now arabic"
exit 0
