# =====================================================================
#  dd-fontobj2.ps1  -  Double Dealers / sharedassets0.assets
#
#  READ ONLY - nothing on your PC is changed.
#  Collects what the helper needs to build an arabic version of the
#  game font (Nunito-ExtraBold SDF):
#    - the whole font asset object  (#67)
#    - the first 512 bytes of every object (names + headers)
#  output -> Desktop\dd-fontobj\  (FONT-OBJECTS.txt)
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
function Upload-File([string]$path) {
  $link = ""
  if (-not (Test-Path $path)) { return "" }
  $curl = Join-Path $env:SystemRoot "System32\curl.exe"
  if (-not (Test-Path $curl)) { $curl = "curl.exe" }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $res = & $curl -s -m 600 -F "reqtype=fileupload" -F ("fileToUpload=@" + $path) "https://catbox.moe/user/api.php" 2>$null
      if ($res -and ($res -match "^https?://")) { $link = $res.Trim(); break }
    } catch { }
    Start-Sleep -Seconds 3
  }
  return $link
}
function Finish([string]$msg) {
  Log ""
  Log "=========================================================="
  Log ("  " + $msg)
  Log "=========================================================="
  try { Set-Content -Path (Join-Path $out "00-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { }
  $l = Upload-File (Join-Path $out "FONT-OBJECTS.txt")
  Write-Host ""
  if ($l) {
    Write-Host "SEND THIS LINK:" -ForegroundColor Green
    Write-Host $l
  } else {
    Write-Host "upload failed - the file is here:" -ForegroundColor Yellow
    Write-Host (Join-Path $out "FONT-OBJECTS.txt")
  }
  try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
  Write-Host ""
  Write-Host "FINISHED" -ForegroundColor Green
  try { Read-Host "Press Enter to close" } catch { }
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
function NameIn([byte[]]$b, [int]$limit) {
  for ($q = 0; ($q + 6) -lt $limit; $q += 2) {
    $len = [int](LE32 $b $q)
    if ($len -lt 3 -or $len -gt 48) { continue }
    if (($q + 4 + $len) -ge $b.Length) { continue }
    $s = New-Object System.Text.StringBuilder
    $good = $true
    $letters = 0
    for ($k = 0; $k -lt $len; $k++) {
      $c = $b[$q + 4 + $k]
      if ($c -lt 32 -or $c -gt 126) { $good = $false; break }
      if (($c -ge 65 -and $c -le 90) -or ($c -ge 97 -and $c -le 122)) { $letters++ }
      [void]$s.Append([char]$c)
    }
    if ($good -and $letters -ge 3) { return $s.ToString() }
  }
  return ""
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
Log "Double Dealers - font object extractor  (v2)"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""
if (-not $file) { Log "[X] the game was not found"; Finish "STOPPED"; exit 1 }
$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$sa = [System.IO.Path]::GetFullPath((Join-Path $aa ".."))
$data = [System.IO.Path]::GetFullPath((Join-Path $sa ".."))
$target = Join-Path $data "sharedassets0.assets"
if (-not (Test-Path $target)) { Log "[X] sharedassets0.assets not found"; Finish "STOPPED"; exit 1 }
Log ("file : " + $target)
$bytes = [System.IO.File]::ReadAllBytes($target)
Log ("size : " + $bytes.Length)
Log ""

$sb = New-Object System.Text.StringBuilder
try {
  $ver = [int](BE32 $bytes 8)
  $metaSize = [int](BE32 $bytes 20)
  $dataOff = [int](BE64 $bytes 32)
  Log ("version " + $ver + "  metadata " + $metaSize + "  data offset " + $dataOff)

  # ---- object table (verified layout : pathID 8 / relStart 8 / size 4 / type 4)
  $objTable = -1
  $objCount = 0
  $probe = 328
  $ok = $true
  for ($i = 0; $i -lt 4; $i++) {
    if ((LE64 $bytes ($probe + $i * 24)) -ne ($i + 1)) { $ok = $false }
  }
  if ($ok) {
    $objTable = $probe
  } else {
    for ($p = 64; $p -lt 8192; $p++) {
      if ((LE64 $bytes $p) -eq 1 -and (LE64 $bytes ($p + 24)) -eq 2 -and (LE64 $bytes ($p + 48)) -eq 3) { $objTable = $p; break }
    }
  }
  if ($objTable -lt 0) { throw "the object table was not found" }
  for ($i = 0; $i -lt 4000; $i++) {
    if ((LE64 $bytes ($objTable + $i * 24)) -ne ($i + 1)) { break }
    $objCount++
  }
  Log ("object table : " + $objTable + "   objects : " + $objCount)

  $objects = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $objCount; $i++) {
    $q = $objTable + $i * 24
    $opid = LE64 $bytes $q
    $rel = [int](LE64 $bytes ($q + 8))
    $osz = [int](LE32 $bytes ($q + 16))
    $otid = [int](LE32 $bytes ($q + 20))
    $abs = $rel + $dataOff
    [void]$objects.Add([pscustomobject]@{ Index = $i; PathId = $opid; Start = $abs; Size = $osz; Type = $otid })
  }

  [void]$sb.AppendLine("DDX5")
  [void]$sb.AppendLine("FILE sharedassets0.assets")
  [void]$sb.AppendLine("SIZE " + $bytes.Length)
  [void]$sb.AppendLine("DATAOFF " + $dataOff)
  [void]$sb.AppendLine("OBJTABLE " + $objTable + " " + $objCount)
  foreach ($o in $objects) {
    [void]$sb.AppendLine("OBJ " + $o.Index + " " + $o.PathId + " " + $o.Type + " " + $o.Start + " " + $o.Size)
  }

  # ---- the font asset : the object that carries the name, index 67
  $fontIdx = 67
  if ($fontIdx -ge $objCount) { $fontIdx = -1 }
  if ($fontIdx -ge 0 -and $objects[$fontIdx].Type -ne 8) { $fontIdx = -1 }
  if ($fontIdx -lt 0) {
    foreach ($o in $objects) { if ($o.Type -eq 8 -and $o.Size -lt 200000) { $fontIdx = $o.Index } }
  }
  if ($fontIdx -lt 0) { throw "the font object was not found" }
  $fo = $objects[$fontIdx]
  Log ""
  Log ("font object : index " + $fontIdx + "  path " + $fo.PathId + "  start " + $fo.Start + "  size " + $fo.Size)
  $fontBytes = Grab $bytes $fo.Start $fo.Size
  Write-Pack $sb ("FONT" + $fontIdx) $fontBytes

  # ---- first 512 bytes of every object (names + headers)
  Write-Host "reading object headers..."
  $maxName = 512
  foreach ($o in $objects) {
    try {
      $take = [Math]::Min($maxName, $o.Size)
      $hb = Grab $bytes $o.Start $take
      Write-Pack $sb ("HEAD" + $o.Index) $hb
      $nm = NameIn $hb $take
      if ($nm) { [void]$sb.AppendLine("NAME " + $o.Index + " " + $nm) }
    } catch {
      Log ("   head " + $o.Index + " skipped : " + $_.Exception.Message)
    }
  }

  $txt = $sb.ToString()
  $f = Join-Path $out "FONT-OBJECTS.txt"
  [System.IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($false)))
  Log ""
  Log ("packed file : " + $txt.Length + " chars")
} catch {
  Log ("[X] failed : " + $_.Exception.Message)
  Log ($_.ScriptStackTrace)
  try {
    $txt2 = $sb.ToString()
    [System.IO.File]::WriteAllText((Join-Path $out "FONT-OBJECTS.txt"), $txt2, (New-Object System.Text.UTF8Encoding($false)))
    Log ("partial file written : " + $txt2.Length + " chars")
  } catch { }
}

Finish "DONE"
exit 0
