param([string]$Game, [switch]$Restore)

# =====================================================================
#  dd-build-ar-bundle.ps1  -  Double Dealers: arabic in the german slot
#
#  What it does (all automatic):
#    1. finds the game folder (Steam libraries) and the aa bundle folder
#    2. reads the ENGLISH and the GERMAN localization bundles
#    3. unpacks both (LZ4) and lists every text inside them
#    4. pairs them (english text <-> german text) and downloads the
#       arabic file  _AutoTranslations.display-ready.ar.txt
#       (arabic letters shaped + ordered for an engine without arabic support)
#    5. writes an arabic copy of the GERMAN bundle (same file name)
#    6. reads the new file back to be sure it is valid
#    7. saves a backup of the original german file and puts the new one
#       in its place
#
#  Re-run the same command with   -Restore   to get the original back.
#  Nothing else in the game is touched.
# =====================================================================

$ErrorActionPreference = "Continue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-build"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:links = New-Object System.Collections.ArrayList
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Align16([int]$v) { return [int]([Math]::Ceiling($v / 16.0) * 16) }

$ARABIC_URL = "https://raw.githubusercontent.com/lengweny82-ship-it/opencode/arena/01a0bf68-opencode/dd-ar/translation/_AutoTranslations.display-ready.ar.txt"

# --------------------------------------------------------------- readers
function Read-BE32([byte[]]$b, [int]$p) {
  return ([long]$b[$p] -shl 24) + ([long]$b[$p+1] -shl 16) + ([long]$b[$p+2] -shl 8) + [long]$b[$p+3]
}
function Read-NullString([byte[]]$b, [ref]$p) {
  $sb = New-Object System.Text.StringBuilder
  while ($p.Value -lt $b.Length -and $b[$p.Value] -ne 0) { [void]$sb.Append([char]$b[$p.Value]); $p.Value++ }
  $p.Value = $p.Value + 1
  return $sb.ToString()
}
function Write-BE32([byte[]]$b, [int]$p, [long]$v) {
  $b[$p]   = [byte](($v -shr 24) -band 0xFF)
  $b[$p+1] = [byte](($v -shr 16) -band 0xFF)
  $b[$p+2] = [byte](($v -shr 8) -band 0xFF)
  $b[$p+3] = [byte]($v -band 0xFF)
}
function Write-LE32([byte[]]$b, [int]$p, [long]$v) {
  $b[$p]   = [byte]($v -band 0xFF)
  $b[$p+1] = [byte](($v -shr 8) -band 0xFF)
  $b[$p+2] = [byte](($v -shr 16) -band 0xFF)
  $b[$p+3] = [byte](($v -shr 24) -band 0xFF)
}
function Write-BE16([byte[]]$b, [int]$p, [int]$v) {
  $b[$p]   = [byte](($v -shr 8) -band 0xFF)
  $b[$p+1] = [byte]($v -band 0xFF)
}
function Write-LE16([byte[]]$b, [int]$p, [int]$v) {
  $b[$p]   = [byte]($v -band 0xFF)
  $b[$p+1] = [byte](($v -shr 8) -band 0xFF)
}
function Write-BE64([byte[]]$b, [int]$p, [long]$v) {
  for ($k = 0; $k -lt 8; $k++) { $b[$p + $k] = [byte](($v -shr (8 * (7 - $k))) -band 0xFF) }
}
function Write-LE64([byte[]]$b, [int]$p, [long]$v) {
  for ($k = 0; $k -lt 8; $k++) { $b[$p + $k] = [byte](($v -shr (8 * $k)) -band 0xFF) }
}

$PRINT = [bool[]]::new(256)
for ($x = 0; $x -lt 256; $x++) { $PRINT[$x] = (($x -ge 32 -and $x -ne 127) -or $x -ge 128) }

# --------------------------------------------------------------- LZ4 reader
$script:lastErr = ""
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
    } catch { $script:lastErr = $_.Exception.Message }
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

# --------------------------------------------------------------- block table
function Parse-Blocks([byte[]]$bi, [int]$entryMode, [bool]$hasHash, [bool]$be) {
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
      $usOff = $q
      if ($be) { $us = [int](Read-BE32 $bi $q) } else { $us = [int](Read-LE32 $bi $q) }
      $q += 4
      $csOff = $q
      if ($be) { $cs = [int](Read-BE32 $bi $q) } else { $cs = [int](Read-LE32 $bi $q) }
      $q += 4
      $flOff = $q
      if ($be) { $fl = [int](Read-BE32 $bi $q) -band 0xFFFF } else { $fl = [int](Read-LE32 $bi $q) -band 0xFFFF }
      $q += 2
    } else {
      $usOff = $q
      if ($be) { $us = [int](Read-BE32 $bi $q) -band 0xFFFF } else { $us = [int](Read-LE32 $bi $q) -band 0xFFFF }
      $q += 2
      $csOff = $q
      if ($be) { $cs = [int](Read-BE32 $bi $q) -band 0xFFFF } else { $cs = [int](Read-LE32 $bi $q) -band 0xFFFF }
      $q += 2
      $flOff = $q
      if ($be) { $fl = [int](Read-BE32 $bi $q) -band 0xFFFF } else { $fl = [int](Read-LE32 $bi $q) -band 0xFFFF }
      $q += 2
    }
    if ($us -le 0 -or $us -gt 200000000 -or $cs -le 0 -or $cs -gt 200000000) { throw ("bad block size us=" + $us + " cs=" + $cs) }
    [void]$list.Add([pscustomobject]@{ U = $us; C = $cs; F = $fl; CsOff = $csOff; FlOff = $flOff; Mode = $entryMode })
  }
  $nc = 0
  if (($q + 4) -le $bi.Length) {
    if ($be) { $nc = [int](Read-BE32 $bi $q) } else { $nc = [int](Read-LE32 $bi $q) }
    $q += 4
  }
  return ,@($list.ToArray(), $nc)
}

# --------------------------------------------------------------- full parse
function Parse-Bundle([byte[]]$bytes) {
  $res = [pscustomobject]@{ Ok = $false; Why = "" }
  $p = 0
  $sig = Read-NullString $bytes ([ref]$p)
  if ($sig -ne "UnityFS") { $res.Why = "not a UnityFS bundle"; return $res }
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
  $comp = $flags -band 0x3F
  $atEnd = (($flags -band 0x80) -ne 0)
  $pad = (($flags -band 0x200) -ne 0)
  $dataStart = $p
  if ($ver -ge 7) { $dataStart = Align16 $p }
  $bip = $dataStart
  if ($atEnd) { $bip = $bytes.Length - $cbi }

  foreach ($be in @($true, $false)) {
    foreach ($entryMode in @(10, 6)) {
      foreach ($hasHash in @($true, $false)) {
        try {
          $biRaw = [byte[]]::new($cbi)
          [Array]::Copy($bytes, $bip, $biRaw, 0, $cbi)
          if ($cbi -eq $ubi) { $table = $biRaw } else { $table = Decompress-Chunk $biRaw $ubi $comp }
          $pr = Parse-Blocks $table $entryMode $hasHash $be
          $blocks = $pr[0]
          $totalC = 0
          foreach ($blk in $blocks) { $totalC += $blk.C }
          $dataPos = $bip + $cbi
          if (-not $atEnd) { if ($pad) { $dataPos = Align16 $dataPos } }
          if (($dataPos + $totalC) -gt $bytes.Length) { throw "data past end" }
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
          if ($arr.Length -lt 400) { throw "payload too small" }
          $res.Ok = $true
          $res.Ver = $ver; $res.Unity = $ur; $res.Cbi = $cbi; $res.Ubi = $ubi
          $res.Flags = $flags; $res.Comp = $comp; $res.AtEnd = $atEnd; $res.Pad = $pad
          $res.HeaderEnd = $p; $res.SizeOff = $sizeOff; $res.CbiOff = $cbiOff
          $res.UbiOff = $ubiOff; $res.FlagsOff = $flagsOff
          $res.Bip = $bip; $res.Table = $table; $res.Blocks = $blocks
          $res.Data = $arr; $res.DataPos = $dataPos; $res.Mode = $entryMode
          $res.Be = $be; $res.HasHash = $hasHash
          return $res
        } catch { }
      }
    }
  }
  $res.Why = "could not unpack"
  return $res
}

# --------------------------------------------------------------- text finder
function Extract-All([byte[]]$data) {
  $list = New-Object System.Collections.ArrayList
  $n = $data.Length
  for ($i = 0; $i -lt ($n - 6); $i++) {
    $len = [BitConverter]::ToInt32($data, $i)
    if ($len -lt 2 -or $len -gt 20000) { continue }
    $endTxt = $i + 4 + $len
    if ($endTxt -ge $n) { continue }
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

# --------------------------------------------------------------- game folder
function Find-Game {
  $cands = New-Object System.Collections.ArrayList
  if ($Game) { [void]$cands.Add($Game) }
  try {
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { $steam = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath }
    if ($steam) {
      $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
      if (Test-Path $vdf) {
        try { $txt = Get-Content -Raw -Path $vdf } catch { $txt = "" }
        if ($txt) {
          foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
            $lib = $m.Groups[1].Value -replace '\\\\', '\'
            [void]$cands.Add((Join-Path $lib "steamapps\common\Double Dealers Demo"))
          }
        }
      }
      [void]$cands.Add((Join-Path $steam "steamapps\common\Double Dealers Demo"))
    }
  } catch { }
  foreach ($d in @("C:", "D:", "E:", "F:", "G:", "H:")) {
    foreach ($s in @("\SteamLibrary", "\Steam", "\Games\Steam", "\Games\SteamLibrary", "\Program Files (x86)\Steam")) {
      $cands.Add(($d + $s + "\steamapps\common\Double Dealers Demo")) | Out-Null
    }
  }
  foreach ($c in $cands) { try { if ($c -and (Test-Path $c)) { return $c } } catch { } }
  return ""
}
function Find-AaDir([string]$root) {
  foreach ($d in (Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue)) {
    $p = Join-Path $d.FullName "StreamingAssets\aa\StandaloneWindows64"
    if (Test-Path $p) { return $p }
    $p2 = Join-Path $d.FullName "StreamingAssets\aa"
    if (Test-Path $p2) { return $p2 }
  }
  $deep = Get-ChildItem -Path $root -Recurse -Filter "localization-string-tables-english*" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($deep) { return $deep.DirectoryName }
  return ""
}
function Pick-One($files, [string]$rx) {
  foreach ($f in $files) { if ($f.Name -match $rx) { return $f } }
  return $null
}

function Upload-Report {
  $f = Join-Path $out "00-BUILD-REPORT.txt"
  try { Set-Content -Path $f -Value $script:report -Encoding UTF8 } catch { return }
  if (-not $script:links) {
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
  Write-Host "FINISHED - send the link above." -ForegroundColor Green
  Read-Host "Press Enter to close"
}

# =============================================================== main
Log "=========================================================="
Log "  Double Dealers - arabic bundle builder"
Log "=========================================================="
Log ""

$game = Find-Game
if (-not $game) { Log "[X] game folder not found"; Finish "STOPPED" ; exit 1 }
Log ("game : " + $game)
$aa = Find-AaDir $game
if (-not $aa) { Log "[X] aa folder not found"; Finish "STOPPED"; exit 1 }
Log ("aa   : " + $aa)
Log ""

$files = @(Get-ChildItem -Path $aa -Filter "localization-*.bundle" -ErrorAction SilentlyContinue)
$fDe = Pick-One $files "german"
$fEn = Pick-One $files "english"
if ((-not $fDe) -or (-not $fEn)) { Log "[X] german or english bundle missing"; Finish "STOPPED"; exit 1 }

$bak = $fDe.FullName + ".original"
if ($Restore) {
  if (Test-Path $bak) {
    Copy-Item -Force $bak $fDe.FullName
    Log "[+] original german bundle restored:"
    Log ("    " + $fDe.FullName)
  } else { Log "[X] no backup found (" + $bak + ")" }
  Finish "RESTORE DONE"
  exit 0
}

Log ("german  : " + $fDe.Name + "  (" + $fDe.Length + " bytes)")
Log ("english : " + $fEn.Name + "  (" + $fEn.Length + " bytes)")
Log ""

$bDe = [System.IO.File]::ReadAllBytes($fDe.FullName)
$bEn = [System.IO.File]::ReadAllBytes($fEn.FullName)

Log "unpacking both bundles ..."
$pDe = Parse-Bundle $bDe
$pEn = Parse-Bundle $bEn
if (-not $pDe.Ok) { Log ("[X] german bundle: " + $pDe.Why); Finish "STOPPED"; exit 1 }
if (-not $pEn.Ok) { Log ("[X] english bundle: " + $pEn.Why); Finish "STOPPED"; exit 1 }
Log ("  german  payload : " + $pDe.Data.Length + " bytes")
Log ("  english payload : " + $pEn.Data.Length + " bytes")
Log ("  layout : ver=" + $pDe.Ver + " tableMode=" + $pDe.Mode + " be=" + $pDe.Be + " atEnd=" + $pDe.AtEnd + " pad=" + $pDe.Pad + " fileComp=" + $pDe.Comp)
if ($pDe.AtEnd) { Log "[X] unexpected layout (info at end) - stopping"; Finish "STOPPED"; exit 1 }

Log ""
Log "listing the texts inside both ..."
$allDe = Extract-All $pDe.Data
$allEn = Extract-All $pEn.Data
$uniqDe = Get-Unique $allDe
$uniqEn = Get-Unique $allEn
Log ("  german  : " + $allDe.Count + " texts / " + $uniqDe.Count + " different")
Log ("  english : " + $allEn.Count + " texts / " + $uniqEn.Count + " different")

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
if ($pairsRaw -lt 100) { Log "[X] could not download the arabic file (check internet)"; Finish "STOPPED"; exit 1 }

$found = 0
foreach ($e in $uniqEn) { if ($pairs.ContainsKey($e)) { $found++ } }
Log ("  english texts with a translation : " + $found + " of " + $pairsRaw)
if ($found -lt [int]($pairsRaw * 0.8)) { Log "[X] the english list does not match - stopping"; Finish "STOPPED"; exit 1 }
$miss = 0
$missList = New-Object System.Collections.ArrayList
foreach ($k in $pairs.Keys) { if (-not $uniqEn.Contains($k)) { $miss++; if ($missList.Count -lt 8) { [void]$missList.Add($k) } } }
Log ("  translations whose english text was not found : " + $miss)
foreach ($m in $missList) { Log ("      ? " + $m) }

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
    if ($samples.Count -lt 6) { [void]$samples.Add($e + "  ->  " + $d) }
    $digE = -join ([regex]::Matches($e, "\d") | ForEach-Object { $_.Value })
    $digD = -join ([regex]::Matches($d, "\d") | ForEach-Object { $_.Value })
    if ($digE -eq $digD) { $digitOk++ } else { $digitBad++; if ($badSamples.Count -lt 5) { [void]$badSamples.Add($e + "  ->  " + $d) } }
  }
  $i++; $j++
}
Log ("  identical spots (alignment anchors) : " + $anchors)
Log ("  german texts ready to be arabic     : " + $mapDe.Count)
Log ("  pairs whose numbers match           : " + $digitOk + " ok / " + $digitBad + " different")
foreach ($sm in $samples) { Log ("      sample: " + $sm) }
if ($digitBad -gt 0) { foreach ($bs in $badSamples) { Log ("      check:  " + $bs) } }
$badLimit = [int]($digitOk / 3) + 5
if ($anchors -lt 20 -or $mapDe.Count -lt 300) { Log "[X] alignment looks wrong - stopping"; Finish "STOPPED"; exit 1 }
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

Log ""
Log "building the new bundle ..."
$tbl = [byte[]]::new($pDe.Table.Length)
[Array]::Copy($pDe.Table, $tbl, $pDe.Table.Length)
foreach ($blk in $pDe.Blocks) {
  if ($blk.Mode -eq 10) {
    if ($pDe.Be) { Write-BE32 $tbl $blk.CsOff ([long]$blk.U) } else { Write-LE32 $tbl $blk.CsOff ([long]$blk.U) }
  } else {
    if ($pDe.Be) { Write-BE16 $tbl $blk.CsOff $blk.U } else { Write-LE16 $tbl $blk.CsOff $blk.U }
  }
  if ($pDe.Be) { Write-BE16 $tbl $blk.FlOff 0 } else { Write-LE16 $tbl $blk.FlOff 0 }
}
$headerLen = $pDe.HeaderEnd
$bipNew = $headerLen
if ($pDe.Ver -ge 7) { $bipNew = Align16 $headerLen }
$dataPosNew = $bipNew + $tbl.Length
if ($pDe.Pad) { $dataPosNew = Align16 $dataPosNew }
$totalNew = $dataPosNew + $pDe.Data.Length

$header = [byte[]]::new($headerLen)
[Array]::Copy($bDe, 0, $header, 0, $headerLen)
$newFlags = [int]($pDe.Flags -band 0xFFFFFFC0)
if ($pDe.Be) {
  Write-BE64 $header $pDe.SizeOff ([long]$totalNew)
  Write-BE32 $header $pDe.CbiOff ([long]$tbl.Length)
  Write-BE32 $header $pDe.UbiOff ([long]$tbl.Length)
  Write-BE32 $header $pDe.FlagsOff ([long]$newFlags)
} else {
  Write-LE64 $header $pDe.SizeOff ([long]$totalNew)
  Write-LE32 $header $pDe.CbiOff ([long]$tbl.Length)
  Write-LE32 $header $pDe.UbiOff ([long]$tbl.Length)
  Write-LE32 $header $pDe.FlagsOff ([long]$newFlags)
}
$newFile = [byte[]]::new($totalNew)
[Array]::Copy($header, 0, $newFile, 0, $header.Length)
[Array]::Copy($tbl, 0, $newFile, $bipNew, $tbl.Length)
[Array]::Copy($pDe.Data, 0, $newFile, $dataPosNew, $pDe.Data.Length)
$newPath = Join-Path $out "localization-string-tables-german(de)_assets_all.bundle"
[System.IO.File]::WriteAllBytes($newPath, $newFile)
Log ("  new size : " + $newFile.Length + " bytes (original " + $bDe.Length + ")")
Log ("  file     : " + $newPath)

Log ""
Log "checking the new file ..."
$chk = Parse-Bundle ([System.IO.File]::ReadAllBytes($newPath))
if (-not $chk.Ok) { Log "[X] the new file is not readable - not installed"; Finish "STOPPED"; exit 1 }
$hits = 0
$tested = 0
$chkText = [System.Text.Encoding]::UTF8.GetString($chk.Data)
foreach ($key in $mapDe.Keys) {
  $tested++
  if ($tested -gt 400) { break }
  if ($chkText.IndexOf($mapDe[$key]) -ge 0) { $hits++ }
}
Log ("  read back OK : " + $chk.Data.Length + " bytes, arabic found for " + $hits + " of " + $tested + " checked texts")
if ($hits -lt 50) { Log "[X] verification failed - not installed"; Finish "STOPPED"; exit 1 }

if (-not (Test-Path $bak)) { Copy-Item -Force $fDe.FullName $bak; Log ("  backup of the original saved: " + $bak) }
Copy-Item -Force $newPath $fDe.FullName
Log ("  installed    : " + $fDe.FullName)
Log ""
Log "  1) start the game"
Log "  2) Settings -> Language -> Deutsch (the german slot)"
Log "  3) the texts appear in arabic"
Log "  to undo: run the same command again with  -Restore"
Finish "DONE - the german slot is now arabic"
exit 0
