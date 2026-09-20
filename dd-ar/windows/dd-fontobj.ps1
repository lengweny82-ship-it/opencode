# =====================================================================
#  dd-fontobj.ps1  -  Double Dealers / sharedassets0.assets
#
#  sends the pieces the helper needs to build an arabic version of the
#  game's font (Nunito-ExtraBold SDF):
#    - the whole font asset object  (object #67)
#    - the headers of the other font objects (to compare the layout)
#    - the header + name of every texture object (to find the atlas)
#  READ ONLY - nothing on your PC is changed.
#
#  output -> Desktop\dd-fontobj\
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
    try { Add-Type -AssemblyName System.IO.Compression | Out-Null } catch { }
    try {
      $ms = New-Object System.IO.MemoryStream
      $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
      $gz.Write($data, 0, $data.Length)
      $gz.Close()
      $script:packMode = "GZIP"
      return ,$ms.ToArray()
    } catch { $script:packMode = "RAW"; return ,$data }
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
  try {
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (-not (Test-Path $curl)) { $curl = "curl.exe" }
    $res = & $curl -s -m 600 -F "reqtype=fileupload" -F ("fileToUpload=@" + $path) "https://catbox.moe/user/api.php" 2>$null
    if ($res -and ($res -match "^https?://")) { $link = $res.Trim() }
  } catch { }
  if (-not $link) {
    try {
      $res2 = Invoke-RestMethod -Uri "https://catbox.moe/user/api.php" -Method Post -InFile $path -TimeoutSec 600
      if ($res2 -and ($res2 -match "^https?://")) { $link = $res2.Trim() }
    } catch { }
  }
  return $link
}
function Finish([string]$msg) {
  Log ""
  Log "=========================================================="
  Log ("  " + $msg)
  Log "=========================================================="
  Set-Content -Path (Join-Path $out "00-REPORT.txt") -Value $script:report -Encoding UTF8
  $l = Upload-File (Join-Path $out "FONT-OBJECTS.txt")
  Write-Host ""
  if ($l) {
    Write-Host "SEND THIS LINK:" -ForegroundColor Green
    Write-Host $l
    try { Set-Content -Path (Join-Path $out "LINK-TO-SEND.txt") -Value $l -Encoding UTF8 } catch { }
  } else {
    Write-Host "upload failed - the file is here:" -ForegroundColor Yellow
    Write-Host (Join-Path $out "FONT-OBJECTS.txt")
  }
  try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
  Write-Host ""
  Write-Host "FINISHED" -ForegroundColor Green
  Read-Host "Press Enter to close"
}
function BE32([byte[]]$b, [int]$p) { return ([int64]$b[$p] -shl 24) + ([int64]$b[$p+1] -shl 16) + ([int64]$b[$p+2] -shl 8) + [int64]$b[$p+3] }
function BE64([byte[]]$b, [int]$p) { return ((BE32 $b $p) * 4294967296) + (BE32 $b ($p + 4)) }
function LE32([byte[]]$b, [int]$p) { return ([int64]$b[$p]) + ([int64]$b[$p+1] -shl 8) + ([int64]$b[$p+2] -shl 16) + ([int64]$b[$p+3] -shl 24) }
function LE64([byte[]]$b, [int]$p) { return ((LE32 $b $p) * 4294967296) + (LE32 $b ($p + 4)) }

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
Log "Double Dealers - font object extractor"
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

try {
  $ver = BE32 $bytes 8
  $metaSize = BE32 $bytes 20
  $fileSize = BE64 $bytes 24
  $dataOff = BE64 $bytes 32
  Log ("version " + $ver + "  metadata " + $metaSize + "  size " + $fileSize + "  data offset " + $dataOff)

  # object table is at a known place in this file (we measured it already)
  $objTable = 328
  $objCount = 76
  $objects = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $objCount; $i++) {
    $q = $objTable + $i * 24
    $opid = LE64 $bytes $q
    $rel = LE64 $bytes ($q + 8)
    $osz = LE32 $bytes ($q + 16)
    $otid = LE32 $bytes ($q + 20)
    [void]$objects.Add([pscustomobject]@{ Index = $i; PathId = $opid; Start = $rel + $dataOff; Size = $osz; Type = $otid })
  }
  Log ("objects : " + $objCount)

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("DDX4")
  [void]$sb.AppendLine("FILE sharedassets0.assets")
  [void]$sb.AppendLine("SIZE " + $bytes.Length)
  [void]$sb.AppendLine("DATAOFF " + $dataOff)
  [void]$sb.AppendLine("OBJTABLE " + $objTable + " " + $objCount)
  foreach ($o in $objects) {
    [void]$sb.AppendLine("OBJ " + $o.Index + " " + $o.PathId + " " + $o.Type + " " + $o.Start + " " + $o.Size)
  }

  # 1. the Nunito font asset object (index 67) - the whole thing
  $fontObj = $objects[67]
  Log ("font object : index 67  path " + $fontObj.PathId + "  start " + $fontObj.Start + "  size " + $fontObj.Size)
  $fo = New-Object 'byte[]' $fontObj.Size
  [Array]::Copy($bytes, $fontObj.Start, $fo, 0, $fontObj.Size)
  Write-Pack $sb "FONT67" $fo

  # 2. headers of the other font objects (66, 68, 69) - 1024 bytes each
  foreach ($ix in @(66, 68, 69)) {
    $o = $objects[$ix]
    $take = [Math]::Min(1024, $o.Size)
    $hb = New-Object 'byte[]' $take
    [Array]::Copy($bytes, $o.Start, $hb, 0, $take)
    Write-Pack $sb ("FONT" + $ix + "-HEAD") $hb
  }
  # also the small type-6 objects (61..64, 70..75) - they may be the TMP settings
  foreach ($ix in @(61, 62, 63, 64, 70, 71, 72, 73, 74, 75)) {
    $o = $objects[$ix]
    $hb = New-Object 'byte[]' $o.Size
    [Array]::Copy($bytes, $o.Start, $hb, 0, $o.Size)
    Write-Pack $sb ("OBJ" + $ix) $hb
  }

  # 3. every texture object: first 256 bytes (has m_Name) + the name text
  $texCount = 0
  Log ""
  Log "textures (type 2) :"
  foreach ($o in $objects) {
    if ($o.Type -ne 2) { continue }
    $take = [Math]::Min(256, $o.Size)
    $hb = New-Object 'byte[]' $take
    [Array]::Copy($bytes, $o.Start, $hb, 0, $take)
    Write-Pack $sb ("TEX" + $o.Index + "-HEAD") $hb
    # read the name
    $nm = ""
    $q = $o.Start + 28
    if ($q + 4 -lt $bytes.Length) {
      $len = LE32 $bytes $q
      if ($len -gt 0 -and $len -lt 120) {
        for ($k = 0; $k -lt $len; $k++) { $nm += [char]$bytes[$q + 4 + $k] }
      }
    }
    Log ("   index " + $o.Index + "  path " + $o.PathId + "  start " + $o.Start + "  size " + $o.Size + "   name '" + $nm + "'")
    $texCount++
  }
  Log ("   total textures : " + $texCount)

  $txt = $sb.ToString()
  $f = Join-Path $out "FONT-OBJECTS.txt"
  [System.IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($false)))
  Log ""
  Log ("packed file : " + $txt.Length + " chars")
} catch {
  Log ("[X] failed : " + $_.Exception.Message)
  Log ($_.ScriptStackTrace)
}

Finish "DONE"
exit 0
