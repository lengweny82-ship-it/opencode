param([string]$Target, [switch]$Restore)

# =====================================================================
#  dd-install-ar-font.ps1   (v1)
#
#  Double Dealers  -  adds the arabic letters to the game font.
#
#  the game font lives in  <game>_Data\sharedassets0.assets .
#  this script does NOT touch the file size or any layout : it only
#  replaces a small part of two objects (the font letters and the
#  letters picture), exactly the same number of bytes.  There is no
#  addressables catalog entry for this file, so nothing else changes.
#
#  all automatic :
#    1. finds the game and the sharedassets0.assets file
#    2. checks that the font inside it is exactly the one this patch
#       was built for (sha256 of the original object)
#    3. downloads the ready patch, checks its own sha256
#    4. saves a backup (once) and writes the new letters
#    5. reads everything back and verifies the result
#
#  run again with  -Restore  to put the original file back.
#  Output + report -> Desktop\dd-ar-font\
# =====================================================================

$ErrorActionPreference = "Continue"

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-font"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:links = New-Object System.Collections.ArrayList

function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report { try { Set-Content -Path (Join-Path $out "00-FONT-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

function Upload-Report {
  $f = Join-Path $out "00-FONT-REPORT.txt"
  try { Set-Content -Path $f -Value $script:report -Encoding UTF8 } catch { return }
  if ($script:links.Count -gt 0) { return }
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
function ShaSlice([byte[]]$b, [int]$off, [int]$len) {
  $s = New-Object byte[] $len
  [Array]::Copy($b, $off, $s, 0, $len)
  return (ShaHex $s)
}
function LE32([byte[]]$b, [int]$p) {
  return ([long]$b[$p]) + ([long]$b[$p+1] -shl 8) + ([long]$b[$p+2] -shl 16) + ([long]$b[$p+3] -shl 24)
}
# 1:1 byte->char view, so .IndexOf finds raw byte offsets quickly
function AsLatin1([byte[]]$b) {
  return [System.Text.Encoding]::GetEncoding(28591).GetString($b)
}

# ------------------------------------------------------------------ find the game
#  every steam folder the machine knows about
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

# ------------------------------------------------------------------ the patch
$URL       = "https://github.com/lengweny82-ship-it/opencode/raw/arena/01a0bf68-opencode/dd-ar/prebuilt/arabic-font-patch.bin.gz"
$WANT_GZ_SHA  = "b0a90b3ee9712d1ae4e5c61bfad28be9b63360e10c7e984e0ade9616bbdb91a5"
$WANT_GZ_LEN  = 243380
$FONT_SIZE    = 81600
$ATLAS_SIZE   = 4194444
$ATLAS_BASE   = 124

Log ""
Log "=========================================================="
Log "   Double Dealers  -  arabic letters for the game font"
Log "=========================================================="
Log ""

# ------------------------------------------------------------------ step 1
Log "1) looking for the game ..."
foreach ($lib in (Get-SteamLibraryRoots)) { Log ("   steam folder : " + $lib) }
$dataDir = Find-GameDataDir $Target
if (-not $dataDir) {
  Log "[X] the game folder was not found."
  Log "    folders looked at :"
  $shown = 0
  foreach ($c in (Get-CommonDirs)) {
    if ($shown -ge 80) { break }
    if (Test-Path $c) {
      Log ("      " + $c)
      foreach ($g in (Get-ChildItem -Path $c -Directory -ErrorAction SilentlyContinue)) {
        if ($shown -ge 80) { break }
        Log ("         - " + $g.Name)
        $shown++
      }
    }
  }
  Log ""
  Log "   you can paste the path instead :"
  Log "     steam -> right click the game -> Manage -> Browse local files"
  Log "     then copy the path from the window that opens"
  Log ""
  $manual = Read-Host "   paste it here and press Enter (or just Enter to stop)"
  if ($manual) {
    $dataDir = Resolve-Manual $manual
    if ($dataDir) { Log ("   found it : " + $dataDir) }
  }
  if (-not $dataDir) {
    Log "[X] the game folder was not found - stopping (nothing was changed)."
    Finish "STOPPED"
    exit 1
  }
}
$file = Join-Path $dataDir "sharedassets0.assets"
$bak  = Join-Path $dataDir "sharedassets0.assets.original"
Log ("   game data : " + $dataDir)
Log ("   font file : " + $file)

if (-not (Test-Path $file)) {
  Log "[X] the font file is missing."
  Finish "STOPPED"
  exit 1
}

try {
  $bytes = [System.IO.File]::ReadAllBytes($file)
} catch {
  Log ("[X] could not read the file : " + $_.Exception.Message)
  Log "    (is the game running? close it and try again)"
  Finish "STOPPED"
  exit 1
}
Log ("   size : " + $bytes.Length + " bytes   sha256=" + (ShaHex $bytes).Substring(0,16))

# ------------------------------------------------------------------ step 2  restore
if ($Restore) {
  Log ""
  Log "RESTORE"
  if (-not (Test-Path $bak)) {
    Log "[X] no backup was found - nothing to restore."
    Finish "STOPPED"
    exit 1
  }
  try {
    Copy-Item -Force $bak $file
    $back = [System.IO.File]::ReadAllBytes($file)
    Log ("   restored : " + $file)
    Log ("   now      : " + $back.Length + " bytes   sha256=" + (ShaHex $back).Substring(0,16))
  } catch {
    Log ("[X] could not restore : " + $_.Exception.Message)
    Finish "STOPPED"
    exit 1
  }
  Log ""
  Log "DONE - the game file is back to the original."
  Finish "DONE - restored"
  exit 0
}

# ------------------------------------------------------------------ step 3  download
Log ""
Log "2) downloading the arabic font patch ..."
$tmp = Join-Path $out "arabic-font-patch.bin.gz"
$bin = Join-Path $out "arabic-font-patch.bin"
try {
  Invoke-WebRequest -Uri $URL -OutFile $tmp -UseBasicParsing -TimeoutSec 300
} catch {
  Log ("[X] download failed : " + $_.Exception.Message)
  Finish "STOPPED"
  exit 1
}
$gzBytes = [System.IO.File]::ReadAllBytes($tmp)
Log ("   downloaded : " + $gzBytes.Length + " bytes")
if ($WANT_GZ_LEN -gt 0 -and $gzBytes.Length -ne $WANT_GZ_LEN) {
  Log ("[X] wrong download size (expected " + $WANT_GZ_LEN + ")")
  Finish "STOPPED"
  exit 1
}
if ((ShaHex $gzBytes) -ne $WANT_GZ_SHA) {
  Log "[X] the download is corrupted (sha256 does not match)."
  Finish "STOPPED"
  exit 1
}
Log "   download verified"
try {
  $ms  = New-Object System.IO.MemoryStream(,$gzBytes)
  $gz  = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
  $ms2 = New-Object System.IO.MemoryStream
  $gz.CopyTo($ms2)
  $gz.Dispose()
  $patch = $ms2.ToArray()
  [System.IO.File]::WriteAllBytes($bin, $patch)
} catch {
  Log ("[X] could not unpack the patch : " + $_.Exception.Message)
  Finish "STOPPED"
  exit 1
}
Log ("   patch : " + $patch.Length + " bytes")

# ------------------------------------------------------------------ step 4  parse the patch
#  magic DDAF | ver | em | w | h | pixelbase | atlasobj | fontobj | nchars
#  nwrites | res | 4 x sha256 | len(font) | len(head) | font | writes | sha256(all)
$o = 4
$ver = LE32 $patch $o; $o += 4
$em  = LE32 $patch $o; $o += 4
$aw  = LE32 $patch $o; $o += 4
$ah  = LE32 $patch $o; $o += 4
$pbase = LE32 $patch $o; $o += 4
$atlasObjSize = LE32 $patch $o; $o += 4
$fontObjSize  = LE32 $patch $o; $o += 4
$nchars = LE32 $patch $o; $o += 4
$nw     = LE32 $patch $o; $o += 4
$o += 4
function HexAt([byte[]]$b, [int]$p) {
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt 32; $i++) { [void]$sb.Append($b[$p+$i].ToString("x2")) }
  return $sb.ToString()
}
$fontBefore  = HexAt $patch $o; $o += 32
$fontAfter   = HexAt $patch $o; $o += 32
$headBefore  = HexAt $patch $o; $o += 32
$pixelsAfter = HexAt $patch $o; $o += 32
$flen = LE32 $patch $o; $o += 4
$hlen = LE32 $patch $o; $o += 4
if ($ver -ne 2) { Log "[X] unknown patch version"; Finish "STOPPED"; exit 1 }
if ($flen -lt 1000 -or $flen -gt 4000000) { Log "[X] bad patch"; Finish "STOPPED"; exit 1 }
$fontNew = New-Object byte[] $flen
[Array]::Copy($patch, $o, $fontNew, 0, $flen)
$o += $flen
if ((ShaHex $fontNew) -ne $fontAfter) { Log "[X] the font part of the patch is damaged"; Finish "STOPPED"; exit 1 }
$writes = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $nw; $i++) {
  $woff = LE32 $patch $o; $o += 4
  $ww   = LE32 $patch $o; $o += 4
  $wh   = LE32 $patch $o; $o += 4
  $wlen = $ww * $wh
  if ($ww -lt 1 -or $wh -lt 1 -or $woff -lt $ATLAS_BASE -or
      ($woff + ($wh - 1) * $aw + $ww) -gt ($ATLAS_SIZE - 16) -or ($ww -gt $aw)) {
    Log "[X] the patch asks for a write outside the picture - refused"
    Finish "STOPPED"
    exit 1
  }
  $wb = New-Object byte[] $wlen
  [Array]::Copy($patch, $o, $wb, 0, $wlen)
  $o += $wlen
  [void]$writes.Add([pscustomobject]@{ Off = $woff; W = $ww; H = $wh; Data = $wb })
}
$allSha = HexAt $patch $o
$calcAll = ShaSlice $patch 0 $o
if ($allSha -ne $calcAll) { Log "[X] the patch checksum does not match"; Finish "STOPPED"; exit 1 }
$pixTotal = 0
foreach ($w in $writes) { $pixTotal += $w.Data.Length }
Log ("   patch says : font " + $flen + " bytes, characters " + $nchars + ", picture writes " + $nw + " (" + $pixTotal + " pixels)")
Log ("   font : before " + $fontBefore.Substring(0,16) + "  after " + $fontAfter.Substring(0,16))
Log ("   picture : head " + $headBefore.Substring(0,16))
if ($flen -ne $FONT_SIZE) { Log "[X] unexpected font object size"; Finish "STOPPED"; exit 1 }
if ($atlasObjSize -ne $ATLAS_SIZE -or $pbase -ne $ATLAS_BASE) { Log "[X] unexpected picture layout"; Finish "STOPPED"; exit 1 }

# ------------------------------------------------------------------ step 5  find the objects
Log ""
Log "3) checking the font inside the game file ..."
$text = AsLatin1 $bytes

# the picture object : name "Nunito-ExtraBold SDF Atlas" right at its start
$atlasName = "Nunito-ExtraBold SDF Atlas"
$atlasOff = -1
$pos = 0
while ($true) {
  $pos = $text.IndexOf($atlasName, $pos)
  if ($pos -lt 0) { break }
  $start = $pos - 4
  if ($start -ge 0 -and (LE32 $bytes $start) -eq $atlasName.Length) {
    if ((ShaSlice $bytes $start $hlen) -eq $headBefore) { $atlasOff = $start; break }
  }
  $pos = $pos + 1
}
if ($atlasOff -lt 0) {
  Log "[X] the letters picture inside the game file is not the one this patch was built for."
  Log "    (the game may have been updated - ask for a new patch)"
  Finish "STOPPED"
  exit 1
}
$awFile = LE32 $bytes ($atlasOff + 36)
$ahFile = LE32 $bytes ($atlasOff + 40)
$sizeFile = LE32 $bytes ($atlasOff + 44)
$fmtFile = LE32 $bytes ($atlasOff + 56)
Log ("   picture : at " + $atlasOff + "  " + $awFile + " x " + $ahFile + "  format " + $fmtFile)
if ($awFile -ne $aw -or $ahFile -ne $ah -or $sizeFile -ne ($aw * $ah)) {
  Log "[X] the picture has an unexpected size - refused."
  Finish "STOPPED"
  exit 1
}

# the font object : name "Nunito-ExtraBold SDF", then the whole object must hash right
$fontName = "Nunito-ExtraBold SDF"
$fontOff = -1
$pos = 0
while ($true) {
  $pos = $text.IndexOf($fontName, $pos)
  if ($pos -lt 0) { break }
  $start = $pos - 32
  if ($start -ge 0 -and (LE32 $bytes ($start + 28)) -eq $fontName.Length -and
      (($start + $FONT_SIZE) -le $bytes.Length)) {
    if ((ShaSlice $bytes $start $FONT_SIZE) -eq $fontBefore) { $fontOff = $start; break }
  }
  $pos = $pos + 1
}
if ($fontOff -lt 0) {
  Log "[X] the font inside the game file is not the one this patch was built for."
  Log "    (the game may have been updated - ask for a new patch)"
  Finish "STOPPED"
  exit 1
}
Log ("   font    : at " + $fontOff + "  " + $FONT_SIZE + " bytes  (sha256 matches)")
Log ("   picture : sha256 of the first " + $hlen + " bytes matches")
Log "   the game file is exactly the expected one"

# ------------------------------------------------------------------ step 6  install
Log ""
Log "4) installing ..."
if (-not (Test-Path $bak)) {
  try {
    Copy-Item -Force $file $bak
    Log ("   backup of the original saved : " + $bak)
  } catch {
    Log ("[X] could not save the backup : " + $_.Exception.Message)
    Finish "STOPPED"
    exit 1
  }
} else {
  Log "   backup already there"
}
try {
  [Array]::Copy($fontNew, 0, $bytes, $fontOff, $FONT_SIZE)
  foreach ($w in $writes) {
    for ($r = 0; $r -lt $w.H; $r++) {
      [Array]::Copy($w.Data, ($r * $w.W), $bytes, ($atlasOff + $w.Off + $r * $aw), $w.W)
    }
  }
  [System.IO.File]::WriteAllBytes($file, $bytes)
  Log ("   written : " + $file)
} catch {
  Log ("[X] could not write the file : " + $_.Exception.Message)
  Log "    (is the game running? close it and try again)"
  Finish "STOPPED"
  exit 1
}

# ------------------------------------------------------------------ step 7  verify
Log ""
Log "5) reading it back to be sure ..."
$back = [System.IO.File]::ReadAllBytes($file)
$ok = $true
if ((ShaSlice $back $fontOff $FONT_SIZE) -ne $fontAfter) { Log "[X] the font does not read back"; $ok = $false }
$bad = 0
foreach ($w in $writes) {
  $tmp = New-Object byte[] ($w.W * $w.H)
  for ($r = 0; $r -lt $w.H; $r++) {
    [Array]::Copy($back, ($atlasOff + $w.Off + $r * $aw), $tmp, ($r * $w.W), $w.W)
  }
  if ((ShaHex $tmp) -ne (ShaHex $w.Data)) { $bad++ }
}
if ($bad -gt 0) { Log ("[X] " + $bad + " of the letter pictures do not read back"); $ok = $false }
if ($ok) {
  Log "   font letters verified"
  Log ("   " + $writes.Count + " letter pictures verified")
  Log ("   file on disk : " + $back.Length + " bytes  (same size as before : " + ($back.Length -eq $bytes.Length) + ")")
} else {
  Log "   restoring the original ..."
  Copy-Item -Force $bak $file
  Finish "STOPPED - the original was put back"
  exit 1
}

Log ""
Log "extra info (for the helper):"
Log ("   file   : " + $file)
Log ("   size   : " + $back.Length)
Log ("   sha256 : " + (ShaHex $back))
Log ("   font at " + $fontOff + " , picture at " + $atlasOff)
Log ""
Log "DONE"
Log ""
Log "  1) start the game"
Log "  2) Settings -> Language -> Deutsch   (the german slot is arabic)"
Log "  3) the arabic text should now be readable"
Log ""
Log "  to undo everything: run the same command again with  -Restore"
Finish "DONE - the game font now has the arabic letters"
exit 0
