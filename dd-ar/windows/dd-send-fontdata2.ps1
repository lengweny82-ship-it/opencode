param([string]$Target)

# =====================================================================
#  dd-send-fontdata.ps1   (v1)
#
#  the game has four letter fonts inside sharedassets0.assets :
#     Nunito-ExtraBold   (we already put the arabic letters there)
#     NotoSansJP-ExtraBold / NotoSansSC-Medium / NotoSansKR-Medium
#  the menu buttons use one of the others, so the helper needs a copy of
#  those three fonts (and of the first letter picture of each one) to work
#  out where the arabic letters can go.
#
#  this script only reads.  it copies the needed pieces into one packed
#  file on the desktop and uploads that file (around 1 MB), so it can be
#  picked up byte for byte.
# =====================================================================

$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-ar-send"
New-Item -ItemType Directory -Force -Path $out | Out-Null

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

function Read-LE32([byte[]]$b, [int]$p) {
  return ([long]$b[$p]) + ([long]$b[$p+1] -shl 8) + ([long]$b[$p+2] -shl 16) + ([long]$b[$p+3] -shl 24)
}

function Pack-U32([System.Collections.Generic.List[byte]]$l, [long]$v) {
  $l.Add([byte]($v -band 0xFF))
  $l.Add([byte](($v -shr 8) -band 0xFF))
  $l.Add([byte](($v -shr 16) -band 0xFF))
  $l.Add([byte](($v -shr 24) -band 0xFF))
}
function NameAt([byte[]]$b, [int]$lenOff, [int]$nameOff) {
  $n = [int](Read-LE32 $b $lenOff)
  if ($n -lt 3 -or $n -gt 80 -or ($nameOff + $n) -gt $b.Length) { return "" }
  $s = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $n; $i++) { [void]$s.Append([char]$b[$nameOff + $i]) }
  return $s.ToString()
}
# find the name that sits at the start of an object without trusting one offset
function Find-ObjectName([byte[]]$b, [int]$start, [int]$limit) {
  $best = ""
  for ($p = $start; $p -lt ($start + $limit - 4); $p++) {
    $n = [int](Read-LE32 $b $p)
    if ($n -lt 4 -or $n -gt 80) { continue }
    if (($p + 4 + $n) -gt $b.Length) { continue }
    $ok = $true
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $n; $i++) {
      $c = [int]$b[$p + 4 + $i]
      if ($c -lt 32 -or $c -gt 126) { $ok = $false; break }
      [void]$sb.Append([char]$c)
    }
    if ($ok -and $sb.Length -gt $best.Length) { $best = $sb.ToString() }
  }
  return $best
}

Write-Host ""
Write-Host "Double Dealers  -  packing the three other fonts   (v3, reads the names automatically)" -ForegroundColor Cyan
Write-Host ""

$dataDir = Find-GameDataDir $Target
if (-not $dataDir) { Write-Host "[X] the game folder was not found" -ForegroundColor Red; Read-Host "Press Enter to close"; exit 1 }
$file = Join-Path $dataDir "sharedassets0.assets"
Write-Host ("file : " + $file)
$bytes = [System.IO.File]::ReadAllBytes($file)
Write-Host ("size : " + $bytes.Length)
if ($bytes.Length -ne 38165872) { Write-Host "[X] unexpected file size - stopping" -ForegroundColor Red; Read-Host "Press Enter to close"; exit 1 }

# name, at, offset, size, (lenOffset, nameOffset)
$specs = @(
  @("HEAD", 0,             0,       98304, 0, 0),
  @("FONT66", 0, 37042448, 418752, 28, 32),
  @("FONT68", 0, 37542800, 370832, 28, 32),
  @("FONT69", 0, 37913632, 251608, 28, 32),
  @("AT12", 0,    799200, 262288,  0,  4),
  @("AT29", 0,   7879552, 262284,  0,  4),
  @("AT32", 0,   8666416, 262284,  0,  4)
)

$pack = New-Object System.Collections.Generic.List[byte]
foreach ($c in @("D","D","A","F","D","A","T","A","1")) { $pack.Add([byte][char]$c) }
Pack-U32 $pack $specs.Count
foreach ($s in $specs) {
  $nm = [string]$s[0]; $at = [int]$s[2]; $sz = [int]$s[3]; $lo = [int]$s[4]; $no = [int]$s[5]
  $who = ""
  if ($lo -gt 0) { $who = NameAt $bytes ($at + $lo) ($at + $no) }
  $auto = Find-ObjectName $bytes $at 80
  if (-not $who -or ($auto -and $auto -ne $who -and $who.Length -lt 4)) { $who = $auto }
  if (-not $who) { $who = $auto }
  Write-Host ("  " + $nm.PadRight(7) + " at " + $at.ToString().PadLeft(9) + "  " + $sz.ToString().PadLeft(8) + "  '" + $who + "'  (name found automatically: '" + $auto + "')")
  $t2 = $who
  $want = "Nunito-ExtraBold SDF"
  if ($nm -eq "FONT66") { $want = "NotoSansSC-Medium SDF" }
  if ($nm -eq "FONT68") { $want = "NotoSansJP-ExtraBold SDF" }
  if ($nm -eq "FONT69") { $want = "NotoSansKR-Medium SDF" }
  if ($nm -eq "AT12") { $want = "NotoSansJP-ExtraBold SDF Atlas" }
  if ($nm -eq "AT29") { $want = "NotoSansSC-Medium SDF Atlas" }
  if ($nm -eq "AT32") { $want = "NotoSansKR-Medium SDF Atlas" }
  $badName = $false
  if ($nm -eq "HEAD") { $badName = $false }
  elseif ($nm -like "AT*") { if (-not $t2.StartsWith($want)) { $badName = $true } }
  elseif ($t2 -ne $want) { $badName = $true }
  if ($badName) {
    Write-Host ("     [!] the name is not '" + $want + "' - carrying on anyway (a copy does no harm)") -ForegroundColor Yellow
  }
  Pack-U32 $pack $at
  Pack-U32 $pack $sz
  $nb = [System.Text.Encoding]::ASCII.GetBytes($nm)
  Pack-U32 $pack $nb.Length
  foreach ($x in $nb) { $pack.Add($x) }
}
foreach ($s in $specs) {
  $at = [int]$s[2]; $sz = [int]$s[3]
  for ($i = 0; $i -lt $sz; $i++) { $pack.Add($bytes[$at + $i]) }
}
$raw = $pack.ToArray()
$rawPath = Join-Path $out "fontdata.bin"
[System.IO.File]::WriteAllBytes($rawPath, $raw)
$gzPath = Join-Path $out "fontdata.bin.gz"
try {
  $ms = New-Object System.IO.MemoryStream
  $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionLevel]::Optimal)
  $gz.Write($raw, 0, $raw.Length)
  $gz.Dispose()
  [System.IO.File]::WriteAllBytes($gzPath, $ms.ToArray())
} catch {
  Write-Host ("[X] could not compress : " + $_.Exception.Message) -ForegroundColor Red
  Copy-Item -Force $rawPath $gzPath
}
$gzb = [System.IO.File]::ReadAllBytes($gzPath)
Write-Host ""
Write-Host ("packed  : " + $raw.Length + " bytes")
Write-Host ("packed+ : " + $gzb.Length + " bytes")
Write-Host ("sha256  : " + (ShaHex $gzb))

Write-Host ""
Write-Host "uploading ..."
$curl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path $curl)) { $curl = "curl.exe" }
$links = New-Object System.Collections.ArrayList
try {
  $r = & $curl -s -m 300 -F "reqtype=fileupload" -F "time=72h" -F ("fileToUpload=@" + $gzPath) "https://litterbox.catbox.moe/resources/internals/api.php" 2>$null
  if ($r -and ($r -match "^https?://")) { [void]$links.Add("litterbox " + $r.Trim()); Write-Host ("  litterbox ok : " + $r.Trim()) }
} catch { }
try {
  $r = & $curl -s -m 300 -F ("files[]=@" + $gzPath) "https://uguu.se/upload?output=text" 2>$null
  if ($r -and ($r -match "^https?://")) { [void]$links.Add("uguu      " + $r.Trim()); Write-Host ("  uguu ok : " + $r.Trim()) }
} catch { }
try {
  $r = & $curl -s -m 300 -F "reqtype=fileupload" -F ("fileToUpload=@" + $gzPath) "https://catbox.moe/user/api.php" 2>$null
  if ($r -and ($r -match "^https?://")) { [void]$links.Add("catbox    " + $r.Trim()); Write-Host ("  catbox ok : " + $r.Trim()) }
} catch { }
Write-Host ""
if ($links.Count -gt 0) {
  Write-Host "  LINKS - copy them into the chat:" -ForegroundColor Green
  foreach ($l in $links) { Write-Host ("     " + $l) }
  Set-Content -Path (Join-Path $out "LINKS.txt") -Value $links -Encoding UTF8
} else {
  Write-Host "  [!] every upload failed - send me a screenshot of this window" -ForegroundColor Red
}
Write-Host ""
Write-Host "FINISHED" -ForegroundColor Green
try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
Read-Host "Press Enter to close"
