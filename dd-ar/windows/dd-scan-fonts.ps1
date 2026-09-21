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
function Get-SteamLibraryRoots {
  $libs = New-Object System.Collections.ArrayList
  foreach ($k in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam")) {
    try {
      $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
      if ($p) {
        if ($p.SteamPath)    { [void]$libs.Add($p.SteamPath) }
        if ($p.InstallPath)  { [void]$libs.Add($p.InstallPath) }
      }
    } catch { }
  }
  $extra = New-Object System.Collections.ArrayList
  foreach ($root in $libs) {
    try {
      $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
      if (Test-Path $vdf) {
        $txt = Get-Content -Path $vdf -Raw -ErrorAction SilentlyContinue
        foreach ($m in [regex]::Matches([string]$txt, '"path"\s*"([^"]+)"')) {
          [void]$extra.Add($m.Groups[1].Value.Replace('\\', '\'))
        }
      }
    } catch { }
  }
  foreach ($e in $extra) { [void]$libs.Add($e) }
  return $libs
}

function Get-CommonDirs {
  $list = New-Object System.Collections.ArrayList
  foreach ($lib in (Get-SteamLibraryRoots)) {
    if ($lib) { [void]$list.Add((Join-Path $lib "steamapps\common")) }
  }
  $letters = @("C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")
  $subs = @(":\SteamLibrary","\SteamLibrary2","\SteamLibrary3","\Steam","\Games\Steam","\Games\SteamLibrary","\Program Files (x86)\Steam","\Program Files\Steam")
  foreach ($d in $letters) { foreach ($s in $subs) { [void]$list.Add($d + $s + "\steamapps\common") } }
  return $list
}

function Resolve-Manual([string]$p) {
  if (-not $p) { return "" }
  $p = $p.Trim()
  $p = $p.Trim('"')
  if (-not (Test-Path $p)) { return "" }
  if (Test-Path (Join-Path $p "sharedassets0.assets")) { return (Get-Item $p).FullName }
  $d = Join-Path $p "Double Dealers Demo_Data"
  if (Test-Path (Join-Path $d "sharedassets0.assets")) { return (Get-Item $d).FullName }
  foreach ($x in (Get-ChildItem -Path $p -Directory -ErrorAction SilentlyContinue)) {
    if ($x.Name -like "*_Data" -and (Test-Path (Join-Path $x.FullName "sharedassets0.assets"))) { return $x.FullName }
  }
  return ""
}

function Find-GameDataDir([string]$dir) {
  $cands = New-Object System.Collections.ArrayList
  if ($dir) {
    [void]$cands.Add($dir)
    [void]$cands.Add((Join-Path $dir "Double Dealers Demo"))
  }
  foreach ($c in (Get-CommonDirs)) { [void]$cands.Add($c) }
  $leaf = "localization-string-tables-german(de)_assets_all.bundle"
  $seen = @{}
  foreach ($c in $cands) {
    $key = ([string]$c).ToLower()
    if ($seen[$key]) { continue }
    $seen[$key] = 1
    if (-not (Test-Path $c)) { continue }
    # 1) the folder right there
    $here = Join-Path $c "sharedassets0.assets"
    if (Test-Path $here) { return (Get-Item $c).FullName }
    # 2) the game folder by name
    $games = Get-ChildItem -Path $c -Directory -ErrorAction SilentlyContinue
    foreach ($gm in $games) {
      if ($gm.Name -like "*Double*Dealer*") {
        $subs2 = Get-ChildItem -Path $gm.FullName -Directory -ErrorAction SilentlyContinue
        foreach ($x in $subs2) {
          if ($x.Name -like "*_Data" -and (Test-Path (Join-Path $x.FullName "sharedassets0.assets"))) { return $x.FullName }
        }
      }
    }
    # 3) the proven way : find the language file, then three folders up
    $hits = Get-ChildItem -Path $c -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue
    if ($hits -and $hits.Count -gt 0) {
      $data = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $hits[0].FullName -Parent) "..\..\.."))
      if (Test-Path (Join-Path $data "sharedassets0.assets")) { return $data }
    }
  }
  return ""
}

# =====================================================================
#  dd-scan-fonts.ps1   (v1)   -   read only survey
#
#  the game has several letter fonts (Nunito for the latin letters, Noto
#  for japanese, chinese, korean).  we patched the Nunito one, and the menu
#  buttons still show squares, so this script finds out
#    - which files the game is made of
#    - which files contain a copy of each font
#    - what is inside every bundle (its inner file list)
#  it only reads.  nothing is written to the game folder.
# =====================================================================

$ErrorActionPreference = "Continue"

$out2 = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-scan2"
New-Item -ItemType Directory -Force -Path $out2 | Out-Null
$script:rep = New-Object System.Collections.ArrayList
$script:links2 = New-Object System.Collections.ArrayList

function Log2([string]$m) { Write-Host $m; [void]$script:rep.Add($m) }
function Save2 { try { Set-Content -Path (Join-Path $out2 "00-SCAN-REPORT.txt") -Value $script:rep -Encoding UTF8 } catch { } }
function Upload2 {
  $f = Join-Path $out2 "00-SCAN-REPORT.txt"
  Save2
  if ($script:links2.Count -gt 0) { return }
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
  if ($link) { [void]$script:links2.Add($link) }
}
function Finish2([string]$msg) {
  Log2 ""
  Log2 ("  " + $msg)
  Log2 ""
  Upload2
  if ($script:links2.Count -gt 0) {
    Log2 "  REPORT LINK - copy it into the chat:"
    foreach ($l in $script:links2) { Log2 ("     " + $l) }
  }
  Log2 ""
  try { Start-Process explorer.exe -ArgumentList $out2 | Out-Null } catch { }
  Write-Host ""
  Write-Host "FINISHED" -ForegroundColor Green
  Read-Host "Press Enter to close"
}
function L1([byte[]]$b) { return [System.Text.Encoding]::GetEncoding(28591).GetString($b) }
function ShaHex16([byte[]]$b) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = $sha.ComputeHash($b)
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt 8; $i++) { [void]$sb.Append($h[$i].ToString("x2")) }
  return $sb.ToString()
}
function ShaSlice16([byte[]]$b, [int]$off, [int]$len) {
  $s = New-Object byte[] $len
  [Array]::Copy($b, $off, $s, 0, $len)
  return (ShaHex16 $s)
}
function Count-Name([string]$t, [string]$n) {
  $c = 0; $p = 0; $first = -1
  while ($true) {
    $p = $t.IndexOf($n, $p)
    if ($p -lt 0) { break }
    if ($first -lt 0) { $first = $p }
    $c++
    $p = $p + 1
    if ($c -gt 50) { break }
  }
  return @($c, $first)
}
function Get-BundleHeader2([byte[]]$b) {
  try {
    $p = 0
    $sig = Read-NullString $b ([ref]$p)
    if ($sig -ne "UnityFS") { return $null }
    $ver = [int](Read-BE32 $b $p); $p += 4
    $uv  = Read-NullString $b ([ref]$p)
    $ur  = Read-NullString $b ([ref]$p)
    $size = 0
    if (($p + 8) -le $b.Length) { $size = Read-BE64 $b $p }
    $p += 8
    if (($p + 12) -gt $b.Length) { return $null }
    $cbi = [int](Read-BE32 $b $p); $p += 4
    $ubi = [int](Read-BE32 $b $p); $p += 4
    $flags = [int](Read-BE32 $b $p); $p += 4
    if ($cbi -le 0 -or $cbi -gt 8000000 -or $ubi -le 0 -or $ubi -gt 8000000) { return $null }
    return [pscustomobject]@{ Ver = $ver; Unity = $ur; Size = $size; Cbi = $cbi; Ubi = $ubi; Flags = $flags; HeaderEnd = $p }
  } catch { return $null }
}
function Get-BundleTable2([byte[]]$b, $h) {
  $comp  = $h.Flags -band 0x3F
  $atEnd = (($h.Flags -band 0x80) -ne 0)
  $bip = $h.HeaderEnd
  if ($h.Ver -ge 7) { $bip = [int]([Math]::Ceiling($h.HeaderEnd / 16.0) * 16) }
  if ($atEnd) { $bip = $b.Length - $h.Cbi }
  if ($bip -lt 0 -or ($bip + $h.Cbi) -gt $b.Length) { return $null }
  $raw = New-Object byte[] $h.Cbi
  [Array]::Copy($b, $bip, $raw, 0, $h.Cbi)
  if ($h.Cbi -eq $h.Ubi) { return ,$raw }
  if ($comp -ne 0) {
    try { return ,(Decompress-Chunk $raw $h.Ubi $comp) } catch { }
  }
  try { return ,(Decompress-LZ4 $raw $h.Ubi) } catch { }
  return $null
}
function Parse-Nodes2([byte[]]$t) {
  foreach ($be in @($true, $false)) {
    foreach ($mode in @(10, 6)) {
      foreach ($hash in @($true, $false)) {
        try {
          $res = Parse-Blocks $t $mode $hash $be
          $blocks = $res[0]
          if ($null -eq $blocks -or $blocks.Count -lt 1 -or $blocks.Count -gt 3000) { continue }
          $bad = $false
          foreach ($blk in $blocks) { if ($blk.C -le 0 -or $blk.U -le 0 -or $blk.C -gt 60000000 -or $blk.U -gt 60000000) { $bad = $true } }
          if ($bad) { continue }
          $entrySize = 10
          if ($mode -eq 6) { $entrySize = 6 }
          $q = 0
          if ($hash) { $q += 16 }
          $q += 4
          $q += $blocks.Count * $entrySize
          if (($q + 4) -gt $t.Length) { continue }
          if ($be) { $nc = [int](Read-BE32 $t $q) } else { $nc = [int](Read-LE32 $t $q) }
          $q += 4
          if ($nc -lt 1 -or $nc -gt 2000) { continue }
          $nodes = New-Object System.Collections.ArrayList
          $ok = $true
          for ($i = 0; $i -lt $nc; $i++) {
            if (($q + 20) -gt $t.Length) { $ok = $false; break }
            if ($be) { $off = Read-BE64 $t $q } else { $off = Read-LE64 $t $q }
            $q += 8
            if ($be) { $sz = Read-BE64 $t $q } else { $sz = Read-LE64 $t $q }
            $q += 8
            if ($be) { $fl = Read-BE32 $t $q } else { $fl = Read-LE32 $t $q }
            $q += 4
            $nm = Read-NullString $t ([ref]$q)
            while (($q % 4) -ne 0) { $q++ }
            if ($sz -lt 0 -or $sz -gt 400000000) { $ok = $false; break }
            [void]$nodes.Add([pscustomobject]@{ Off = $off; Size = $sz; Flags = $fl; Path = $nm })
          }
          if (-not $ok -or $nodes.Count -lt 1) { continue }
          $totalU = 0
          foreach ($b2 in $blocks) { $totalU += $b2.U }
          return [pscustomobject]@{ Mode = $mode; Be = $be; Hash = $hash; Blocks = $blocks; Nodes = $nodes; TotalU = $totalU }
        } catch { }
      }
    }
  }
  return $null
}


function Get-BundlePayload2([byte[]]$b, $h, $info) {
  $cbi = $h.Cbi
  $atEnd = (($h.Flags -band 0x80) -ne 0)
  $bip = $h.HeaderEnd
  if ($h.Ver -ge 7) { $bip = [int]([Math]::Ceiling($h.HeaderEnd / 16.0) * 16) }
  if ($atEnd) { $bip = $b.Length - $cbi }
  $starts = New-Object System.Collections.ArrayList
  if ($atEnd) {
    $d1 = $h.HeaderEnd
    if ($h.Ver -ge 7) { $d1 = [int]([Math]::Ceiling($h.HeaderEnd / 16.0) * 16) }
    [void]$starts.Add($d1)
    [void]$starts.Add($h.HeaderEnd)
  } else {
    [void]$starts.Add($bip + $cbi)
    [void]$starts.Add([int]([Math]::Ceiling(($bip + $cbi) / 16.0) * 16))
  }
  $hcomp = $h.Flags -band 0x3F
  foreach ($start in $starts) {
    $total = 0
    foreach ($blk in $info.Blocks) { $total += $blk.C }
    if ($start -lt 0 -or ($start + $total) -gt $b.Length) { continue }
    try {
      $buf = New-Object 'System.Collections.Generic.List[byte]'
      $cur = $start
      $okAll = $true
      foreach ($blk in $info.Blocks) {
        $chunk = New-Object byte[] $blk.C
        [Array]::Copy($b, $cur, $chunk, 0, $blk.C)
        $cur += $blk.C
        $c = $blk.F -band 0x3F
        if ($c -eq 0) { $c = $hcomp }
        $dec = Decompress-Chunk $chunk $blk.U $c
        if ($null -eq $dec) { $okAll = $false; break }
        $buf.AddRange($dec)
      }
      if (-not $okAll) { continue }
      $arr = $buf.ToArray()
      if ($arr.Length -eq $info.TotalU) { return ,$arr }
    } catch { }
  }
  return $null
}

Log2 "DDX9 - Double Dealers file survey"
Log2 ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log2 ""

$dataDir = Find-GameDataDir ""
if (-not $dataDir) { Log2 "[X] the game folder was not found"; Finish2 "STOPPED"; exit 1 }
$gameRoot = Split-Path $dataDir -Parent
Log2 ("game : " + $gameRoot)
Log2 ("data : " + $dataDir)
Log2 ""

Log2 "--- files in the game data folder ---"
foreach ($f in (Get-ChildItem -Path $dataDir -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
  Log2 ("DATA " + $f.Length.ToString().PadLeft(11) + "  " + $f.Name)
}
Log2 ""

$all = @(Get-ChildItem -Path $gameRoot -Recurse -File -ErrorAction SilentlyContinue)
Log2 ("files in the whole game folder : " + $all.Count)
Log2 "--- 25 biggest ---"
foreach ($f in ($all | Sort-Object Length -Descending | Select-Object -First 25)) {
  Log2 ("BIG " + $f.Length.ToString().PadLeft(11) + "  " + $f.FullName.Substring($gameRoot.Length + 1))
}
Log2 ""

$bundles = @($all | Where-Object { $_.Extension.ToLower() -eq ".bundle" } | Sort-Object FullName)
Log2 ("--- every bundle : " + $bundles.Count + " (the names show all the languages) ---")
foreach ($f in $bundles) {
  Log2 ("BUNDLEFILE " + $f.Length.ToString().PadLeft(11) + "  " + $f.FullName.Substring($gameRoot.Length + 1))
}
Log2 ""

$names = @("Nunito-ExtraBold SDF", "NotoSansJP-ExtraBold SDF", "NotoSansSC-Medium SDF", "NotoSansKR-Medium SDF")
$atlasNames = @("Nunito-ExtraBold SDF Atlas", "NotoSansJP-ExtraBold SDF Atlas")

Log2 "--- font names inside the plain (not packed) files ---"
$scanExt = @(".assets", ".resource", ".resS", ".unity3d", ".data", "")
foreach ($f in $all) {
  if ($f.Length -lt 40000 -or $f.Length -gt 90000000) { continue }
  $e = $f.Extension.ToLower()
  if ($e -eq ".bundle") { continue }
  if (-not ($scanExt -contains $e)) { continue }
  try { $b = [System.IO.File]::ReadAllBytes($f.FullName) } catch { continue }
  $t = L1 $b
  $rel = $f.FullName.Substring($gameRoot.Length + 1)
  foreach ($n in $names) {
    $r = Count-Name $t $n
    if ($r[0] -gt 0) { Log2 ("HIT " + $rel + "  '" + $n + "' x" + $r[0] + " first at " + $r[1]) }
  }
  foreach ($n in $atlasNames) {
    $r = Count-Name $t $n
    if ($r[0] -gt 0) { Log2 ("HIT " + $rel + "  '" + $n + "' x" + $r[0] + " first at " + $r[1]) }
  }
}
Log2 ""

Log2 "--- what is inside every bundle ---"
foreach ($f in $bundles) {
  $rel = $f.FullName.Substring($gameRoot.Length + 1)
  try {
  if ($f.Length -gt 40000000) { Log2 ("BUNDLE " + $rel + " : too big (" + $f.Length + ")"); continue }
  try { $b = [System.IO.File]::ReadAllBytes($f.FullName) } catch { Log2 ("BUNDLE " + $rel + " : could not read"); continue }
  $h = Get-BundleHeader2 $b
  if ($null -eq $h) {
    Log2 ("BUNDLE " + $rel + " " + $f.Length + " : not packed")
    $t2 = L1 $b
    foreach ($n in $names) { $r = Count-Name $t2 $n; if ($r[0] -gt 0) { Log2 ("   HIT '" + $n + "' x" + $r[0] + " first at " + $r[1]) } }
    continue
  }
  $t = Get-BundleTable2 $b $h
  $info = $null
  if ($null -ne $t) { $info = Parse-Nodes2 $t }
  if ($null -eq $info) {
    Log2 ("BUNDLE " + $rel + " " + $f.Length + " : unity " + $h.Unity + " flags=0x" + ("{0:x}" -f $h.Flags) + " inner list not readable")
    continue
  }
  $layout = "front"
  if ((($h.Flags -band 0x80) -ne 0)) { $layout = "end" }
  $padTxt = "no"
  if ((($h.Flags -band 0x200) -ne 0)) { $padTxt = "yes" }
  Log2 ("BUNDLE " + $rel + " " + $f.Length + " : unity " + $h.Unity + " flags=0x" + ("{0:x}" -f $h.Flags) + " tableAt=" + $layout + " pad=" + $padTxt + " unpacked " + $info.TotalU + " blocks " + $info.Blocks.Count + " inner files " + $info.Nodes.Count)
  foreach ($nd in $info.Nodes) {
    Log2 ("   NODE " + $nd.Size.ToString().PadLeft(11) + "  " + $nd.Path)
  }
  $pay = Get-BundlePayload2 $b $h $info
  if ($null -eq $pay) {
    Log2 "   (inner data could not be opened - the names above still tell the story)"
  } else {
    Log2 ("   opened : " + $pay.Length + " bytes")
    $pt = L1 $pay
    foreach ($n in $names) {
      $r = Count-Name $pt $n
      if ($r[0] -gt 0) { Log2 ("   FONT '" + $n + "' x" + $r[0] + " at " + $r[1]) }
    }
    foreach ($n in $atlasNames) {
      $r = Count-Name $pt $n
      if ($r[0] -gt 0) { Log2 ("   FONTATLAS '" + $n + "' x" + $r[0] + " at " + $r[1]) }
    }
    $m2 = [regex]::Matches($pt, "CAB-[0-9a-f]{32}")
    foreach ($x in $m2) { Log2 ("   INNER " + $x.Value) }
    $m3 = [regex]::Matches($pt, "Assets/[-_/A-Za-z0-9 .]{4,80}")
    $shown2 = 0
    foreach ($x in $m3) {
      if ($shown2 -ge 30) { break }
      Log2 ("   ASSETPATH " + $x.Value)
      $shown2++
    }
  }
  } catch { Log2 ("   (this bundle could not be read : " + $_.Exception.Message + ")") }
}
Log2 ""

Log2 "--- is the patched Nunito font still inside sharedassets0.assets ? ---"
$sa = Join-Path $dataDir "sharedassets0.assets"
if (Test-Path $sa) {
  try {
    $sb = [System.IO.File]::ReadAllBytes($sa)
    Log2 ("sharedassets0.assets : " + $sb.Length + " bytes")
    $st = L1 $sb
    $needle = "Nunito-ExtraBold SDF"
    $pos = 0
    $found = 0
    while ($true) {
      $pos = $st.IndexOf($needle, $pos)
      if ($pos -lt 0) { break }
      $start = $pos - 32
      if ($start -ge 0 -and (($start + 81600) -le $sb.Length)) {
        if ((Read-LE32 $sb ($start + 28)) -eq 20) {
          $found++
          Log2 ("   font object at " + $start + "  first 16 of sha256=" + (ShaSlice16 $sb $start 81600) + "   (unedited b036c9041a53b40c , arabic 9e85298769836002)")
        }
      }
      $pos = $pos + 1
      if ($pos -gt $st.Length) { break }
    }
    if ($found -eq 0) { Log2 "   font object not found by name" }
  } catch { Log2 ("   could not read : " + $_.Exception.Message) }
} else { Log2 "   sharedassets0.assets is missing" }
Log2 ""

Log2 "--- the catalog ---"
$aaRoot = Split-Path $dataDir -Parent
foreach ($c in (Get-ChildItem -Path $aaRoot -Filter "catalog*" -Recurse -File -ErrorAction SilentlyContinue)) {
  Log2 ("catalog : " + $c.FullName + "  " + $c.Length + " bytes")
  try {
    $cb = [System.IO.File]::ReadAllBytes($c.FullName)
    $cs = L1 $cb
    $m = [regex]::Matches($cs, "[ -~]{6,}")
    $shown = 0
    foreach ($x in $m) {
      if ($shown -ge 400) { break }
      Log2 ("   STR " + $x.Value)
      $shown++
    }
    Log2 ("   (strings shown " + $shown + " of " + $m.Count + ")")
  } catch { }
}

Log2 ""
Finish2 "DONE - survey finished (nothing was changed)"
exit 0
