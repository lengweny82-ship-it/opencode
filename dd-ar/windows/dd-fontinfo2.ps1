# =====================================================================
#  dd-fontinfo2.ps1  -  Double Dealers
#
#  reads the game's font asset (Nunito-ExtraBold SDF) and sends the small
#  pieces the helper needs to build an arabic version of that font.
#  READ ONLY - nothing on your PC is changed.
#
#  output + report -> Desktop\dd-fontinfo2\
# =====================================================================
$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-fontinfo2"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:links = New-Object System.Collections.ArrayList
$script:packMode = "RAW"
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report { try { Set-Content -Path (Join-Path $out "00-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

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
    $res = & $curl -s -m 300 -F "reqtype=fileupload" -F ("fileToUpload=@" + $path) "https://catbox.moe/user/api.php" 2>$null
    if ($res -and ($res -match "^https?://")) { $link = $res.Trim() }
  } catch { }
  if (-not $link) {
    try {
      $res2 = Invoke-RestMethod -Uri "https://catbox.moe/user/api.php" -Method Post -InFile $path -TimeoutSec 300
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
  Save-Report
  $l0 = Upload-File (Join-Path $out "00-REPORT.txt")
  if ($l0) { [void]$script:links.Add("report : " + $l0) }
  Write-Host ""
  if ($script:links.Count -gt 0) {
    Write-Host "SEND THESE LINKS:" -ForegroundColor Green
    foreach ($x in $script:links) { Write-Host $x }
    try { Set-Content -Path (Join-Path $out "LINKS-TO-SEND.txt") -Value ($script:links -join [Environment]::NewLine) -Encoding UTF8 } catch { }
  } else {
    Write-Host "upload failed - the files are here:" -ForegroundColor Yellow
    Write-Host $out
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
function Read-CStr([byte[]]$b, [ref]$pp) {
  $sb = New-Object System.Text.StringBuilder
  while ($pp.Value -lt $b.Length -and $b[$pp.Value] -ne 0) { [void]$sb.Append([char]$b[$pp.Value]); $pp.Value++ }
  $pp.Value = $pp.Value + 1
  return $sb.ToString()
}
function Find-Str([byte[]]$b, [string]$s, [int]$from, [int]$to) {
  if ($null -eq $s -or $s.Length -lt 2) { return -1 }
  $needle = [System.Text.Encoding]::ASCII.GetBytes($s)
  $end = [Math]::Min($b.Length, $to) - $needle.Length
  for ($i = [Math]::Max(0, $from); $i -le $end; $i++) {
    if ($b[$i] -ne $needle[0]) { continue }
    $ok = $true
    for ($k = 1; $k -lt $needle.Length; $k++) { if ($b[$i+$k] -ne $needle[$k]) { $ok = $false; break } }
    if ($ok) { return $i }
  }
  return -1
}

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
Log "Double Dealers - font reader (v2)"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""
if (-not $file) { Log "[X] the game was not found"; Finish "STOPPED"; exit 1 }
$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$sa = [System.IO.Path]::GetFullPath((Join-Path $aa ".."))
$data = [System.IO.Path]::GetFullPath((Join-Path $sa ".."))
Log ("data folder : " + $data)
Log ""

$target = Join-Path $data "sharedassets0.assets"
if (-not (Test-Path $target)) { Log "[X] sharedassets0.assets not found"; Finish "STOPPED"; exit 1 }
Log ("file : " + $target)
$bytes = [System.IO.File]::ReadAllBytes($target)
Log ("size : " + $bytes.Length + " bytes")
Log ""

try {
  $ver = BE32 $bytes 8
  $metaSize = BE32 $bytes 20
  $fileSize = BE64 $bytes 24
  $dataOff = BE64 $bytes 32
  Log ("serialized version " + $ver + "   metadata " + $metaSize + "   file size " + $fileSize + "   data offset " + $dataOff)
  if ($ver -ne 22) { Log "[X] unexpected version"; Finish "STOPPED"; exit 1 }

  $p = 48
  $uv = Read-CStr $bytes ([ref]$p)
  $platform = LE32 $bytes $p; $p += 4
  $hasTree = $bytes[$p]; $p += 1
  $typeCount = LE32 $bytes $p; $p += 4
  Log ("unity " + $uv + "   platform " + $platform + "   typetree byte " + $hasTree + "   types " + $typeCount)
  $typeStart = $p
  $typeList = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $typeCount; $i++) {
    $tStart = $p
    $cid = LE32 $bytes $p; $p += 4
    $stripped = $bytes[$p]; $p += 1
    $scriptIdx = ([int]$bytes[$p]) + ([int]$bytes[$p+1] -shl 8); $p += 2
    $scriptIdHex = ""
    if ($cid -eq 114) {
      $sbId = New-Object System.Text.StringBuilder
      for ($k = 0; $k -lt 16; $k++) { [void]$sbId.Append($bytes[$p+$k].ToString("x2")) }
      $scriptIdHex = $sbId.ToString()
      $p += 16
    }
    $hashSb = New-Object System.Text.StringBuilder
    for ($k = 0; $k -lt 16; $k++) { [void]$hashSb.Append($bytes[$p+$k].ToString("x2")) }
    $oldHash = $hashSb.ToString()
    $p += 16
    if ($hasTree -ne 0) {
      $nc = LE32 $bytes $p; $p += 4
      $ss = LE32 $bytes $p; $p += 4
      $p += 32 * $nc + $ss
      if ($ver -ge 21) { $dc = LE32 $bytes $p; $p += 4; $p += 4 * $dc }
    }
    [void]$typeList.Add([pscustomobject]@{ Index = $i; ClassId = $cid; Stripped = $stripped; ScriptIdx = $scriptIdx; ScriptId = $scriptIdHex; OldHash = $oldHash; Start = $tStart; End = $p })
  }
  $typeEnd = $p
  Log ("types section : " + $typeStart + " .. " + $typeEnd)
  Log "   index class stripped scriptIdx scriptId(oldHash)"
  foreach ($t in $typeList) {
    Log ("   " + $t.Index.ToString().PadLeft(3) + "  " + $t.ClassId.ToString().PadLeft(6) + "   " + $t.Stripped + "   " + $t.ScriptIdx.ToString().PadLeft(4) + "   " + $t.ScriptId + " " + $t.OldHash.Substring(0, 8))
  }

  $objCount = LE32 $bytes $p; $p += 4
  $objTableStart = $p
  Log ("objects : " + $objCount + "   table at " + $objTableStart)
  $objects = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $objCount; $i++) {
    while (($p % 4) -ne 0) { $p++ }
    $objPid = LE64 $bytes $p; $p += 8
    $bsRel = LE64 $bytes $p; $p += 8
    $bsz = LE32 $bytes $p; $p += 4
    $tid = LE32 $bytes $p; $p += 4
    [void]$objects.Add([pscustomobject]@{ PathId = $objPid; RelStart = $bsRel; ByteStart = $bsRel + $dataOff; Size = $bsz; TypeId = $tid })
  }
  $objTableEnd = $p
  Log ("object table ends at " + $objTableEnd)

  $sc = LE32 $bytes $p; $p += 4
  $scriptList = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $sc; $i++) {
    while (($p % 4) -ne 0) { $p++ }
    $fi = LE32 $bytes $p; $p += 4
    while (($p % 4) -ne 0) { $p++ }
    $li = LE64 $bytes $p; $p += 8
    [void]$scriptList.Add([pscustomobject]@{ FileIndex = $fi; IdInFile = $li })
  }
  $ec = LE32 $bytes $p; $p += 4
  $extList = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $ec; $i++) {
    $tmp = Read-CStr $bytes ([ref]$p)
    $guidSb = New-Object System.Text.StringBuilder
    for ($k = 0; $k -lt 16; $k++) { [void]$guidSb.Append($bytes[$p+$k].ToString("x2")) }
    $p += 16
    $etype = LE32 $bytes $p; $p += 4
    $path = Read-CStr $bytes ([ref]$p)
    [void]$extList.Add([pscustomobject]@{ Temp = $tmp; Guid = $guidSb.ToString(); Type = $etype; Path = $path })
  }
  Log ("scripts : " + $sc + "   externals : " + $ec)
  foreach ($e in $extList) { Log ("   ext : " + $e.Path + "   type " + $e.Type) }
  $refCount = 0
  if ($ver -ge 20) {
    $refCount = LE32 $bytes $p; $p += 4
    Log ("ref types : " + $refCount)
  }
  $userInfo = Read-CStr $bytes ([ref]$p)
  Log ("user info : '" + $userInfo + "'   metadata ends at " + (48 + $metaSize) + "   parser at " + $p)

  # ---- find the objects we need
  Log ""
  Log "objects that contain the font names :"
  $fontObj = $null; $atlasObj = $null; $matObj = $null
  foreach ($o in $objects) {
    if ($o.Size -lt 16 -or $o.ByteStart + $o.Size -gt $bytes.Length) { continue }
    $s = $o.ByteStart
    $e = $s + $o.Size
    $isMat = (Find-Str $bytes "Nunito-ExtraBold SDF Material" $s $e) -ge 0
    $isAtlas = (Find-Str $bytes "Nunito-ExtraBold SDF Atlas" $s $e) -ge 0
    $isFont = (-not $isMat) -and (-not $isAtlas) -and ((Find-Str $bytes "Nunito-ExtraBold SDF" $s $e) -ge 0)
    if ($isMat -or $isAtlas -or $isFont) {
      $what = "?"
      if ($isMat) { $what = "MATERIAL" }
      elseif ($isAtlas) { $what = "ATLAS-TEXTURE" }
      elseif ($isFont) { $what = "FONT-ASSET" }
      Log ("   " + $what + "  path " + $o.PathId + "  type " + $o.TypeId + "  start " + $o.ByteStart + "  size " + $o.Size)
      if ($isMat -and -not $matObj) { $matObj = $o }
      if ($isAtlas -and -not $atlasObj) { $atlasObj = $o }
      if ($isFont -and -not $fontObj) { $fontObj = $o }
    }
  }
  # also list every object of the same type as the font asset (the TMP types)
  if ($fontObj) {
    Log ""
    Log ("objects with the same type as the font asset (type " + $fontObj.TypeId + ") :")
    $n = 0
    foreach ($o in $objects) {
      if ($o.TypeId -ne $fontObj.TypeId) { continue }
      Log ("   path " + $o.PathId + "  start " + $o.ByteStart + "  size " + $o.Size)
      $n++
      if ($n -ge 30) { break }
    }
  }

  # ---- pack everything the helper needs
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("DDX3")
  [void]$sb.AppendLine("FILE sharedassets0.assets")
  [void]$sb.AppendLine("SIZE " + $bytes.Length)
  [void]$sb.AppendLine("DATAOFF " + $dataOff)
  [void]$sb.AppendLine("METASIZE " + $metaSize)
  [void]$sb.AppendLine("TYPESTART " + $typeStart)
  [void]$sb.AppendLine("TYPEEND " + $typeEnd)
  [void]$sb.AppendLine("OBJTABLE " + $objTableStart + " " + $objTableEnd + " " + $objCount)
  [void]$sb.AppendLine("SCRIPTCOUNT " + $sc)
  [void]$sb.AppendLine("EXTCOUNT " + $ec)

  Log ""
  Log "packing :"
  # the whole metadata block (types + tables + externals + strings) - small
  $metaLen = $typeEnd - $typeStart
  $metaBytes = New-Object 'byte[]' $metaLen
  [Array]::Copy($bytes, $typeStart, $metaBytes, 0, $metaLen)
  Write-Pack $sb ("META") $metaBytes
  # the object table
  $otLen = $objTableEnd - $objTableStart
  $otBytes = New-Object 'byte[]' $otLen
  [Array]::Copy($bytes, $objTableStart, $otBytes, 0, $otLen)
  Write-Pack $sb ("OBJTABLE") $otBytes
  # externals + scripts raw block (from after obj table to the user info start)
  if ($matObj) {
    $b = New-Object 'byte[]' $matObj.Size
    [Array]::Copy($bytes, $matObj.ByteStart, $b, 0, $matObj.Size)
    Write-Pack $sb ("MATERIAL") $b
  }
  if ($atlasObj) {
    $take = [Math]::Min($atlasObj.Size, 8192)
    $b = New-Object 'byte[]' $take
    [Array]::Copy($bytes, $atlasObj.ByteStart, $b, 0, $take)
    Write-Pack $sb ("ATLAS-HEAD") $b
  }
  if ($fontObj) {
    $take = [Math]::Min($fontObj.Size, 900000)
    $b = New-Object 'byte[]' $take
    [Array]::Copy($bytes, $fontObj.ByteStart, $b, 0, $take)
    Write-Pack $sb ("FONT-OBJECT") $b
  }

  $txt = $sb.ToString()
  $packPath = Join-Path $out "FONT-DATA.txt"
  [System.IO.File]::WriteAllText($packPath, $txt, (New-Object System.Text.UTF8Encoding($false)))
  Log ("   FONT-DATA.txt : " + $txt.Length + " chars")
  $lk = Upload-File $packPath
  if ($lk) { [void]$script:links.Add("font data : " + $lk); Log ("   uploaded : " + $lk) }
} catch {
  Log ("[X] failed : " + $_.Exception.Message)
  Log ($_.ScriptStackTrace)
}

Finish "DONE"
exit 0
