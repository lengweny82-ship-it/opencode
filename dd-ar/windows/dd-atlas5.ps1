# =====================================================================
#  dd-atlas2.ps1  -  Double Dealers arabic helper
#
#  READ ONLY - nothing on your PC is changed.
#  copies small pieces (12 letters) of the game font picture so the
#  font file, so the helper can copy the layout exactly.
#
#  output -> Desktop\dd-fontobj\ATLAS-DUMP.txt   (about 80 KB)
# =====================================================================
$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-fontobj"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:packMode = "RAW"
$script:problem = ""
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
  Write-Host ("   " + $name + " : raw " + $payload.Length + " -> " + $packed.Length + " packed, " + $idx + " lines")
}
function BE32([byte[]]$b, [int]$p) { return ([int64]$b[$p] -shl 24) + ([int64]$b[$p+1] -shl 16) + ([int64]$b[$p+2] -shl 8) + [int64]$b[$p+3] }
function BE64([byte[]]$b, [int]$p) { return ((BE32 $b $p) * 4294967296) + (BE32 $b ($p + 4)) }
function LE32([byte[]]$b, [int]$p) { return ([int64]$b[$p]) + ([int64]$b[$p+1] -shl 8) + ([int64]$b[$p+2] -shl 16) + ([int64]$b[$p+3] -shl 24) }
function LE64([byte[]]$b, [int]$p) { return ((LE32 $b ($p + 4)) * 4294967296) + (LE32 $b $p) }
function Grab-Bytes([byte[]]$b, [int]$off, [int]$len) {
  if (($off + $len) -gt $b.Length) { throw "read past the end of the file" }
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
Log "Double Dealers - font picture prober  (v5)"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""
$target = ""
if ($file) {
  $dir = Split-Path $file -Parent
  $aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
  $sa = [System.IO.Path]::GetFullPath((Join-Path $aa ".."))
  $data = [System.IO.Path]::GetFullPath((Join-Path $sa ".."))
  $target = Join-Path $data "sharedassets0.assets"
}
$bytes = $null
if ($target -and (Test-Path $target)) {
  Log ("file : " + $target)
  $bytes = [System.IO.File]::ReadAllBytes($target)
  Log ("size : " + $bytes.Length)
} else {
  $script:problem = "sharedassets0.assets was not found"
  Log "[X] sharedassets0.assets was not found"
}
Log ""

$sb = New-Object System.Text.StringBuilder
$made = 0
if ($bytes) {
  [void]$sb.AppendLine("DDX6")
  [void]$sb.AppendLine("FILE sharedassets0.assets")
  [void]$sb.AppendLine("SIZE " + $bytes.Length)
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

    $texStart = -1
    $texSize = 0
    for ($i = 0; $i -lt $objCount; $i++) {
      $q = $objTable + $i * 24
      if ((LE64 $bytes $q) -eq 21) {
        $rel = [int](LE64 $bytes ($q + 8))
        $texStart = $rel + $dataOff
        $texSize = [int](LE32 $bytes ($q + 16))
      }
    }
    if ($texStart -lt 0) { throw "the font picture object was not found" }
    Log ("picture object : start " + $texStart + "  size " + $texSize)

    $nlen = [int](LE32 $bytes $texStart)
    $nm = StrAt $bytes ($texStart + 4) $nlen
    # find the width / height / image size triple (w == h, size == w * h)
    $w = 0
    $h = 0
    $imgSize = 0
    $fmt = [int](LE32 $bytes ($texStart + 56))
    $woff = -1
    for ($p = 32; $p -le 80; $p += 4) {
      $a = [int](LE32 $bytes ($texStart + $p))
      $b = [int](LE32 $bytes ($texStart + $p + 4))
      $c = [int](LE32 $bytes ($texStart + $p + 8))
      if ($a -eq $b -and $a -ge 256 -and $a -le 4096 -and $c -eq ($a * $b)) {
        $woff = $p; $w = $a; $h = $b; $imgSize = $c; break
      }
    }
    if ($woff -lt 0) { throw "the picture size fields were not found" }
    $pix = $texSize - $imgSize
    Log ("size fields at +" + $woff + "  format at +56")
    Log ("picture : " + $nm + "  " + $w + " x " + $h + "  format " + $fmt + "  header " + $pix + "  image " + $imgSize)
    if ($w -ne 2048 -or $h -ne 2048) { throw "the picture is not 2048 x 2048" }
    if ($imgSize -ne ($w * $h)) { throw "the picture size does not match 2048 x 2048" }
    if ($pix -lt 8 -or $pix -gt 400) { throw "unexpected header size" }
    [void]$sb.AppendLine("ATLAS start " + $texStart + " size " + $texSize + " header " + $pix + " W " + $w + " H " + $h + " FMT " + $fmt)
    [void]$sb.AppendLine("NAME " + $nm)
    [void]$sb.AppendLine("FIELDS at +" + $woff)
    Write-Pack $sb "HEADER" (Grab-Bytes $bytes $texStart 160)

    $cropText = "MEM_A,1131,672,93,94|FLIP_A,1131,1282,93,94|MEM_W,868,1453,136,94|FLIP_W,868,501,136,94|MEM_g,1623,761,68,90|FLIP_g,1623,1197,68,90|MEM_udiaeresis,743,1909,61,96|FLIP_udiaeresis,743,43,61,96|MEM_p,1973,924,67,90|FLIP_p,1973,1034,67,90|MEM_j,247,1694,37,119|FLIP_j,247,835,37,119|MEM_five,1538,8,66,93|FLIP_five,1538,1947,66,93|MEM_y,1575,1353,65,89|FLIP_y,1575,606,65,89|MEM_Q,255,1424,90,119|FLIP_Q,255,505,90,119|MEM_at,587,843,110,114|FLIP_at,587,1091,110,114|WIN1,0,0,384,384|WIN2,1024,1024,384,384"
    foreach ($spec in $cropText.Split("|")) {
      if (-not $spec) { continue }
      try {
        $p = $spec.Split(",")
        $cn = [string]$p[0]
        $cx = [int]$p[1]
        $cy = [int]$p[2]
        $cw = [int]$p[3]
        $chh = [int]$p[4]
        if (($cx + $cw) -gt $w -or ($cy + $chh) -gt $h) { Log ("   " + $cn + " skipped : outside the picture"); continue }
        $buf = New-Object 'byte[]' ($cw * $chh)
        for ($row = 0; $row -lt $chh; $row++) {
          $src = $texStart + $pix + (($cy + $row) * $w) + $cx
          [System.Buffer]::BlockCopy($bytes, $src, $buf, ($row * $cw), $cw)
        }
        Write-Pack $sb ("RECT_" + $cn + "_x" + $cx + "_y" + $cy + "_w" + $cw + "_h" + $chh) $buf
        $made++
      } catch {
        Log ("   " + $spec + " failed : " + $_.Exception.Message)
      }
    }
    Log ("blocks written : " + $made + " of 22")
    # ---- the original Nunito font file (path 58)
    for ($i = 0; $i -lt $objCount; $i++) {
      $q = $objTable + $i * 24
      if ((LE64 $bytes $q) -eq 58) {
        $frel = [int](LE64 $bytes ($q + 8))
        $fsz = [int](LE32 $bytes ($q + 16))
        Log ("font file : start " + ($frel + $dataOff) + "  size " + $fsz)
        Write-Pack $sb "NUNITO" (Grab-Bytes $bytes ($frel + $dataOff) $fsz)
      }
    }
  } catch {
    $script:problem = $_.Exception.Message
    Log ("[X] failed : " + $_.Exception.Message)
  }
}

$txt = $sb.ToString()
$f = Join-Path $out "ATLAS-DUMP.txt"
try { [System.IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($false))) } catch { }
Log ""
Log ("file written : " + $txt.Length + " chars  (" + $made + " blocks)")
try { Set-Content -Path (Join-Path $out "00-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { }

# ---------------------------------------------------------------- upload + check
Log ""
Log "=========================================================="
Log "  DONE"
Log "=========================================================="
Write-Host ""
if ($script:problem) { Write-Host ("PROBLEM : " + $script:problem) -ForegroundColor Red }
Write-Host ("blocks  : " + $made + " of 22")
Write-Host ("file    : " + $f)
if ((-not (Test-Path $f)) -or ($made -eq 0)) {
  Write-Host "nothing was collected - nothing to send" -ForegroundColor Red
  Write-Host ("PROBLEM : " + $script:problem) -ForegroundColor Red
  Write-Host "open the Desktop folder dd-fontobj and send me a photo of 00-REPORT.txt" -ForegroundColor Yellow
  try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
  Write-Host ""
  Write-Host "FINISHED" -ForegroundColor Green
  try { Read-Host "Press Enter to close" } catch { }
  exit 1
}
$fb = [System.IO.File]::ReadAllBytes($f)
$sha = [System.Security.Cryptography.SHA256]::Create()
$hh = $sha.ComputeHash($fb)
$sbb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 8; $i++) { [void]$sbb.Append($hh[$i].ToString("x2")) }
$hash = $sbb.ToString()
Write-Host ("size    : " + $fb.Length + " bytes")
Write-Host ("sha16   : " + $hash)
Write-Host ""
$curl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path $curl)) { $curl = "curl.exe" }
$tmp = Join-Path $env:TEMP ("dd-verify-" + $hash + ".txt")
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
  if ($script:problem) { Write-Host ("PROBLEM : " + $script:problem) -ForegroundColor Red }
  try { Set-Content -Path (Join-Path $out "LINK-TO-SEND.txt") -Value $good -Encoding UTF8 } catch { }
} else {
  Write-Host "all uploads failed - the file is here:" -ForegroundColor Yellow
  Write-Host $f
}
try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
Write-Host ""
Write-Host "FINISHED" -ForegroundColor Green
try { Read-Host "Press Enter to close" } catch { }
