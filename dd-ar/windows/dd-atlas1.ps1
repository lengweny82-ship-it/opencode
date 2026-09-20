# =====================================================================
#  dd-atlas1.ps1  -  Double Dealers arabic helper
#
#  READ ONLY - nothing on your PC is changed.
#  takes small pieces of the game font picture (the SDF atlas) so the
#  helper can measure the exact pixel format before it builds the
#  arabic letters.
#  output -> Desktop\dd-fontobj\ATLAS-DUMP.txt   (about 80 KB)
# =====================================================================
$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-fontobj"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:packMode = "RAW"
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Sha16([byte[]]$b) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = $sha.ComputeHash($b)
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt 8; $i++) { [void]$sb.Append($h[$i].ToString("x2")) }
  return $sb.ToString()
}
function Sha6([byte[]]$b) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = $sha.ComputeHash($b)
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt 3; $i++) { [void]$sb.Append($h[$i].ToString("x2")) }
  return $sb.ToString()
}
function Pack-Bytes([byte[]]$data) {
  try {
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gz.Write($data, 0, $data.Length)
    $gz.Close()
    $script:packMode = "GZIP"
    return ,$ms.ToArray()
  } catch {
    $script:packMode = "RAW"
    return ,$data
  }
}
function Write-Pack($sb, [string]$name, [byte[]]$payload) {
  if ($null -eq $payload -or $payload.Length -eq 0) { return }
  $packed = Pack-Bytes $payload
  [void]$sb.AppendLine("ITEM " + $name)
  [void]$sb.AppendLine("MODE " + $script:packMode)
  [void]$sb.AppendLine("RAW " + $payload.Length)
  [void]$sb.AppendLine("SHA " + (Sha16 $payload))
  $b64 = [Convert]::ToBase64String($packed)
  $lineChars = 304
  $idx = 0
  for ($k = 0; $k -lt $b64.Length; $k += $lineChars) {
    $take = [Math]::Min($lineChars, $b64.Length - $k)
    $piece = $b64.Substring($k, $take)
    $bytes = [Convert]::FromBase64String($piece)
    [void]$sb.AppendLine("L " + $idx.ToString("0000") + " " + (Sha6 $bytes) + " " + $piece)
    $idx++
  }
  [void]$sb.AppendLine("END " + $name)
  Log ("   " + $name + " : raw " + $payload.Length + " -> " + $packed.Length + " packed, " + $idx + " lines")
}
function BE32([byte[]]$b, [int]$p) { return ([int64]$b[$p] -shl 24) + ([int64]$b[$p+1] -shl 16) + ([int64]$b[$p+2] -shl 8) + [int64]$b[$p+3] }
function BE64([byte[]]$b, [int]$p) { return ((BE32 $b $p) * 4294967296) + (BE32 $b ($p + 4)) }
function LE32([byte[]]$b, [int]$p) { return ([int64]$b[$p]) + ([int64]$b[$p+1] -shl 8) + ([int64]$b[$p+2] -shl 16) + ([int64]$b[$p+3] -shl 24) }
function LE64([byte[]]$b, [int]$p) { return ((LE32 $b ($p + 4)) * 4294967296) + (LE32 $b $p) }
function Grab([byte[]]$b, [int]$off, [int]$len) {
  if ($off -lt 0) { throw ("offset " + $off + " is negative") }
  if (($off + $len) -gt $b.Length) { throw ("read past the end of the file") }
  $buf = New-Object 'byte[]' $len
  [System.Buffer]::BlockCopy($b, $off, $buf, 0, $len)
  return ,$buf
}
function StrAt([byte[]]$b, [int]$off, [int]$len) {
  $s = New-Object System.Text.StringBuilder
  for ($k = 0; $k -lt $len; $k++) { [void]$s.Append([char]$b[$off + $k]) }
  return $s.ToString()
}

# ---------------------------------------------------------------- find the game
$leaf = "localization-string-tables-german(de)_assets_all.bundle"
$file = ""
$letters2 = @("C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")
$subs = @(":\SteamLibrary","\SteamLibrary2","\SteamLibrary3",":\Steam","\Games\Steam","\Games\SteamLibrary","\Program Files (x86)\Steam","\Program Files\Steam")
foreach ($d in $letters2) {
  foreach ($s in $subs) {
    $base = $d + $s + "\steamapps\common"
    if (-not (Test-Path $base)) { continue }
    $hits = Get-ChildItem -Path $base -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue
    if ($hits -and $hits.Count -gt 0) { $file = $hits[0].FullName; break }
  }
  if ($file) { break }
}
Log "Double Dealers - font picture extractor  (v1)"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""
if (-not $file) { Log "[X] the game was not found"; exit 1 }
$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$sa = [System.IO.Path]::GetFullPath((Join-Path $aa ".."))
$data = [System.IO.Path]::GetFullPath((Join-Path $sa ".."))
$target = Join-Path $data "sharedassets0.assets"
if (-not (Test-Path $target)) { Log "[X] sharedassets0.assets not found"; exit 1 }
Log ("file : " + $target)
$bytes = [System.IO.File]::ReadAllBytes($target)
Log ("size : " + $bytes.Length)
Log ""

$sb = New-Object System.Text.StringBuilder
try {
  $ver = [int](BE32 $bytes 8)
  $dataOff = [int](BE64 $bytes 32)
  Log ("version " + $ver + "  data offset " + $dataOff)
  $objTable = -1
  $probe = 328
  $ok = $true
  for ($i = 0; $i -lt 4; $i++) { if ((LE64 $bytes ($probe + $i * 24)) -ne ($i + 1)) { $ok = $false } }
  if ($ok) { $objTable = $probe } else {
    for ($p = 64; $p -lt 8192; $p++) {
      if ((LE64 $bytes $p) -eq 1 -and (LE64 $bytes ($p + 24)) -eq 2 -and (LE64 $bytes ($p + 48)) -eq 3) { $objTable = $p; break }
    }
  }
  if ($objTable -lt 0) { throw "the object table was not found" }
  $objCount = 0
  for ($i = 0; $i -lt 4000; $i++) {
    if ((LE64 $bytes ($objTable + $i * 24)) -ne ($i + 1)) { break }
    $objCount++
  }
  Log ("object table : " + $objTable + "   objects : " + $objCount)

  # ---- the font picture : object path 21
  $tex = $null
  for ($i = 0; $i -lt $objCount; $i++) {
    $q = $objTable + $i * 24
    if ((LE64 $bytes $q) -eq 21) {
      $rel = [int](LE64 $bytes ($q + 8))
      $osz = [int](LE32 $bytes ($q + 16))
      $tex = [pscustomobject]@{ Index = $i; Start = ($rel + $dataOff); Size = $osz }
    }
  }
  if ($null -eq $tex) { throw "the font picture object was not found" }
  Log ("picture object : index " + $tex.Index + "  start " + $tex.Start + "  size " + $tex.Size)

  # ---- header (width / height / format / pixel start)
  $nlen = [int](LE32 $bytes $tex.Start)
  $nm = StrAt $bytes ($tex.Start + 4) $nlen
  $w = [int](LE32 $bytes ($tex.Start + 40))
  $h = [int](LE32 $bytes ($tex.Start + 44))
  $imgSize = [int](LE32 $bytes ($tex.Start + 48))
  $fmt = [int](LE32 $bytes ($tex.Start + 56))
  $pix = $tex.Size - $imgSize
  Log ("picture : '" + $nm + "'  " + $w + " x " + $h + "  format " + $fmt + "  pixels at +" + $pix + "  image " + $imgSize)
  if ($w -ne 2048 -or $h -ne 2048) { throw "the picture is not 2048 x 2048" }
  if ($imgSize -ne ($w * $h)) { throw "the picture size does not match 2048 x 2048" }
  if ($pix -lt 8 -or $pix -gt 400) { throw "unexpected header size" }
  [void]$sb.AppendLine("DDX6")
  [void]$sb.AppendLine("FILE sharedassets0.assets")
  [void]$sb.AppendLine("SIZE " + $bytes.Length)
  [void]$sb.AppendLine("ATLAS start " + $tex.Start + " size " + $tex.Size + " header " + $pix + " W " + $w + " H " + $h + " FMT " + $fmt)
  [void]$sb.AppendLine("NAME " + $nm)

  # ---- small pieces of the picture, one block per letter
  $crops = @(
  @("dot", 46, 670, 405, 23, 23)
  @("comma", 44, 793, 1684, 23, 40)
  @("excl", 33, 1468, 548, 23, 93)
  @("ell", 108, 1374, 1561, 36, 94)
  @("o", 111, 1623, 866, 68, 67)
  @("A", 65, 1131, 672, 93, 94)
  @("S", 83, 1379, 563, 74, 94)
  @("g", 103, 1623, 761, 68, 90)
  @("udiaeresis", 252, 743, 1909, 61, 96)
  @("W", 87, 868, 1453, 136, 94)
  @("x", 120, 1963, 1878, 60, 65)
  @("colon", 58, 1990, 279, 23, 65)
  )
  foreach ($c in $crops) {
    $cn = [string]($c[0]); $cx = [int]($c[2]); $cy = [int]($c[3]); $cw = [int]($c[4]); $ch = [int]($c[5])
    if (($cx + $cw) -gt $w -or ($cy + $ch) -gt $h) { Log ("   " + $cn + " skipped : outside the picture"); continue }
    $buf = New-Object 'byte[]' ($cw * $ch)
    for ($row = 0; $row -lt $ch; $row++) {
      $src = $tex.Start + $pix + (($cy + $row) * $w) + $cx
      [System.Buffer]::BlockCopy($bytes, $src, $buf, ($row * $cw), $cw)
    }
    Write-Pack $sb ("RECT_" + $cn + "_x" + $cx + "_y" + $cy + "_w" + $cw + "_h" + $ch) $buf
  }
  $txt = $sb.ToString()
  $f = Join-Path $out "ATLAS-DUMP.txt"
  [System.IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($false)))
  Log ""
  Log ("packed file : " + $txt.Length + " chars")
} catch {
  Log ("[X] failed : " + $_.Exception.Message)
  Log ($_.ScriptStackTrace)
}

# ---------------------------------------------------------------- upload + check
$f = Join-Path $out "ATLAS-DUMP.txt"
Log ""
Log "=========================================================="
Log "  DONE"
Log "=========================================================="
try { Set-Content -Path (Join-Path $out "00-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { }
$curl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path $curl)) { $curl = "curl.exe" }
$fb = [System.IO.File]::ReadAllBytes($f)
$sha = [System.Security.Cryptography.SHA256]::Create()
$hh = $sha.ComputeHash($fb)
$sbb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 8; $i++) { [void]$sbb.Append($hh[$i].ToString("x2")) }
$hash = $sbb.ToString()
$tmp = Join-Path $env:TEMP ("dd-verify-" + $hash + ".txt")
function Fixed-Link([string]$link) { return $link }
function Verified([string]$link) {
  try {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    & $curl -s -L -m 900 -o $tmp $link 2>$null | Out-Null
    if (-not (Test-Path $tmp)) { return $false }
    $got = [System.IO.File]::ReadAllBytes($tmp)
    if ($got.Length -ne $fb.Length) { return $false }
    $sha2 = [System.Security.Cryptography.SHA256]::Create()
    $h2 = $sha2.ComputeHash($got)
    $sb2 = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 8; $i++) { [void]$sb2.Append($h2[$i].ToString("x2")) }
    return ($sb2.ToString() -eq $hash)
  } catch { return $false }
}
function Link-Of([string]$raw) {
  if (-not $raw) { return "" }
  $m = [regex]::Match($raw, "https?://[A-Za-z0-9\.\-/_%\?=&\+]+")
  if ($m.Success) { return $m.Value }
  return ""
}
$specs = @(
  @{ n = "litterbox"; a = @("-F", "reqtype=fileupload", "-F", "time=72h", "-F", ("fileToUpload=@" + $f), "https://litterbox.catbox.moe/resources/internals/api.php") },
  @{ n = "paste.rs";  a = @("--data-binary", ("@" + $f), "https://paste.rs") },
  @{ n = "uguu";      a = @("-F", ("files[]=@" + $f), "https://uguu.se/upload?output=text") }
)
$good = New-Object System.Collections.ArrayList
foreach ($sp in $specs) {
  $name = $sp.n
  $argl = $sp.a
  Write-Host ("uploading via " + $name + " ...")
  try {
    $raw = & $curl -s -m 600 @argl 2>$null | Out-String
    $link = Link-Of $raw
    if (-not $link) {
      $t = $raw.Trim()
      if ($t.Length -gt 100) { $t = $t.Substring(0, 100) }
      Write-Host ("   refused : " + $t)
    } else {
      $link = Fixed-Link $link
      Write-Host ("   link : " + $link)
      if (Verified $link) {
        Write-Host "   checked : OK" -ForegroundColor Green
        [void]$good.Add($name + "  " + $link)
      } else {
        Write-Host "   checked : link did not work" -ForegroundColor Yellow
      }
    }
  } catch { Write-Host "   error" }
}
Write-Host ""
Write-Host "=========================================================="
if ($good.Count -gt 0) {
  Write-Host "SEND THESE LINKS:" -ForegroundColor Green
  foreach ($g in $good) { Write-Host $g }
  Write-Host ("size  : " + $fb.Length + " bytes")
  Write-Host ("sha16 : " + $hash)
  try { Set-Content -Path (Join-Path $out "LINK-TO-SEND.txt") -Value $good -Encoding UTF8 } catch { }
} else {
  Write-Host "all uploads failed - the file is here:" -ForegroundColor Yellow
  Write-Host $f
}
try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
Write-Host ""
Write-Host "FINISHED" -ForegroundColor Green
try { Read-Host "Press Enter to close" } catch { }
