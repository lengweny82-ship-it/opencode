# =====================================================================
#  dd-fontinfo.ps1  -  Double Dealers
#
#  finds the game font asset (Nunito-ExtraBold SDF) inside the game files
#  and sends the small pieces the helper needs to build an arabic version
#  of that font.   READ ONLY - nothing is changed.
#
#  output + report -> Desktop\dd-fontinfo\
# =====================================================================
$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-fontinfo"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
$script:links = New-Object System.Collections.ArrayList
$script:packMode = "RAW"
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report { try { Set-Content -Path (Join-Path $out "00-FONTINFO-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

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
  Log ("   " + $name + " : " + $packed.Length + " bytes packed / " + $idx + " lines  (raw " + $payload.Length + ")")
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
  $rep = Join-Path $out "00-FONTINFO-REPORT.txt"
  $l0 = Upload-File $rep
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

# ---------------------------------------------------------------- byte helpers
function BE32([byte[]]$b, [int]$p) { return ([int64]$b[$p] -shl 24) + ([int64]$b[$p+1] -shl 16) + ([int64]$b[$p+2] -shl 8) + [int64]$b[$p+3] }
function BE64([byte[]]$b, [int]$p) { return ((BE32 $b $p) * 4294967296) + (BE32 $b ($p + 4)) }
function LE32([byte[]]$b, [int]$p) { return ([int64]$b[$p]) + ([int64]$b[$p+1] -shl 8) + ([int64]$b[$p+2] -shl 16) + ([int64]$b[$p+3] -shl 24) }
function LE64([byte[]]$b, [int]$p) { return ((LE32 $b $p) * 4294967296) + (LE32 $b ($p + 4)) }
function Find-Str([byte[]]$b, [string]$s, [int]$from, [int]$to) {
  $needle = [System.Text.Encoding]::ASCII.GetBytes($s)
  $end = [Math]::Min($b.Length, $to) - $needle.Length
  for ($i = $from; $i -le $end; $i++) {
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
Log "Double Dealers - font info collector"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""
if (-not $file) { Log "[X] the game was not found"; Finish "STOPPED"; exit 1 }

$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$sa = [System.IO.Path]::GetFullPath((Join-Path $aa ".."))
$data = [System.IO.Path]::GetFullPath((Join-Path $sa ".."))
Log ("data folder : " + $data)
Log ""

# target files: the ones that hold the font
$targets = @()
foreach ($nm in @("sharedassets0.assets", "sharedassets1.assets", "sharedassets2.assets")) {
  $p = Join-Path $data $nm
  if (Test-Path $p) { $targets += (Get-Item $p) }
}
if ($targets.Count -eq 0) { Log "[X] the game data files were not found"; Finish "STOPPED"; exit 1 }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("DDX3")

foreach ($t in $targets) {
  Log ("file : " + $t.Name + "   " + $t.Length + " bytes")
  $bytes = $null
  try { $bytes = [System.IO.File]::ReadAllBytes($t.FullName) } catch { Log ("   could not read : " + $_.Exception.Message); continue }

  # is it a v22 serialized file?
  $ver = BE32 $bytes 8
  $fsize = BE64 $bytes 24
  $doff = BE64 $bytes 32
  $meta = BE32 $bytes 20
  Log ("   serialized version " + $ver + "   file size " + $fsize + "   metadata " + $meta + "   data offset " + $doff)
  if ($ver -ne 22 -or $fsize -ne $t.Length) { Log "   (not the expected format - skipped)"; continue }

  # ---- read the types section
  $p = 48
  $uv = ""
  while ($bytes[$p] -ne 0) { $uv += [char]$bytes[$p]; $p++ }
  $p++
  $platform = LE32 $bytes $p; $p += 4
  $hasTree = $bytes[$p]; $p += 1
  $typeCount = LE32 $bytes $p; $p += 4
  Log ("   unity " + $uv + "   platform " + $platform + "   typetree " + $hasTree + "   types " + $typeCount)
  $typeInfo = @()
  for ($i = 0; $i -lt $typeCount; $i++) {
    $tstart = $p
    $cid = LE32 $bytes $p; $p += 4
    $stripped = $bytes[$p]; $p += 1
    $scriptIdx = 0
    if ($ver -ge 17) { $scriptIdx = ([int]$bytes[$p]) + ([int]$bytes[$p+1] -shl 8); $p += 2 }
    $scriptId = $null
    if ($cid -eq 114) { $scriptId = $bytes[$p..($p+15)]; $p += 16 }
    $oldHash = $p; $p += 16
    $nodeCount = LE32 $bytes $p; $p += 4
    $strSize = LE32 $bytes $p; $p += 4
    $nodesStart = $p
    $p += 32 * $nodeCount
    $strStart = $p
    $p += $strSize
    $depCount = 0
    if ($ver -ge 21) { $depCount = LE32 $bytes $p; $p += 4; $p += 4 * $depCount }
    $typeInfo += [pscustomobject]@{
      Index = $i; ClassId = $cid; Stripped = $stripped; ScriptIdx = $scriptIdx
      ScriptId = $scriptId; OldHashPos = $oldHash
      NodesStart = $nodesStart; NodeCount = $nodeCount; StrStart = $strStart; StrSize = $strSize
      DepCount = $depCount; Start = $tstart; End = $p
    }
  }

  # ---- objects
  $objCount = LE32 $bytes $p; $p += 4
  $objects = @()
  for ($i = 0; $i -lt $objCount; $i++) {
    while (($p % 4) -ne 0) { $p++ }
    $pid = LE64 $bytes $p; $p += 8
    $bsRel = LE64 $bytes $p; $p += 8
    $bsz = LE32 $bytes $p; $p += 4
    $tid = LE32 $bytes $p; $p += 4
    $objects += [pscustomobject]@{ PathId = $pid; ByteStart = $bsRel + $doff; Size = $bsz; TypeId = $tid; DataPos = $p - 12 }
  }
  Log ("   objects : " + $objCount + "   (object table ends at " + $p + ")")

  # ---- scripts + externals
  $sc = LE32 $bytes $p; $p += 4
  $scripts = @()
  for ($i = 0; $i -lt $sc; $i++) {
    while (($p % 4) -ne 0) { $p++ }
    $fi = LE32 $bytes $p; $p += 4
    while (($p % 4) -ne 0) { $p++ }
    $li = LE64 $bytes $p; $p += 8
    $scripts += [pscustomobject]@{ FileIndex = $fi; IdInFile = $li }
  }
  $ec = LE32 $bytes $p; $p += 4
  $exts = @()
  for ($i = 0; $i -lt $ec; $i++) {
    $tmp = ""
    while ($bytes[$p] -ne 0) { $tmp += [char]$bytes[$p]; $p++ }
    $p++
    $guid = $bytes[$p..($p+15)]; $p += 16
    $etype = LE32 $bytes $p; $p += 4
    $path = ""
    while ($bytes[$p] -ne 0) { $path += [char]$bytes[$p]; $p++ }
    $p++
    $exts += [pscustomobject]@{ Path = $path; Type = $etype; Guid = ($guid | ForEach-Object { $_.ToString("x2") }) -join "" }
  }
  Log ("   scripts : " + $sc + "   externals : " + $ec)

  # ---- look for the font strings
  $keys = @("Nunito-ExtraBold SDF", "Nunito-ExtraBold SDF Atlas", "Nunito-ExtraBold SDF Material")
  foreach ($k in $keys) {
    $pos = -1
    $count = 0
    while ($true) {
      $pos = Find-Str $bytes $k ($pos + 1) $bytes.Length
      if ($pos -lt 0) { break }
      $count++
      # which object holds it?
      $owner = $null
      foreach ($o in $objects) {
        if ($pos -ge $o.ByteStart -and $pos -lt ($o.ByteStart + $o.Size)) { $owner = $o; break }
      }
      if ($owner) {
        Log ("   [" + $k + "] at byte " + $pos + "  -> object path_id " + $owner.PathId + " type " + $owner.TypeId + " start " + $owner.ByteStart + " size " + $owner.Size)
      } else {
        Log ("   [" + $k + "] at byte " + $pos + "  -> (not inside any object)")
      }
      if ($count -ge 6) { break }
    }
    if ($count -eq 0) { Log ("   [" + $k + "] not found") }
  }

  # ---- dump the object that holds the plain font name (the font asset)
  $fontObj = $null
  $texObj = $null
  $matObj = $null
  foreach ($o in $objects) {
    if ($o.Size -lt 16 -or $o.Size -gt 4000000) { continue }
    $s = $o.ByteStart
    $e = $s + $o.Size
    if (-not $fontObj) {
      if ((Find-Str $bytes "Nunito-ExtraBold SDF" $s $e) -ge 0) {
        # must not be the material/nor atlas one
        if ((Find-Str $bytes "SDF Material" $s $e) -lt 0 -and (Find-Str $bytes "SDF Atlas" $s $e) -lt 0) { $fontObj = $o }
      }
    }
    if (-not $matObj) { if ((Find-Str $bytes "Nunito-ExtraBold SDF Material" $s $e) -ge 0) { $matObj = $o } }
    if (-not $texObj) { if ((Find-Str $bytes "Nunito-ExtraBold SDF Atlas" $s $e) -ge 0) { $texObj = $o } }
  }

  if ($fontObj) {
    Log ""
    Log ("   >>> FONT ASSET object : path " + $fontObj.PathId + " type " + $fontObj.TypeId + " size " + $fontObj.Size)
    $ti = $typeInfo | Where-Object { $_.Index -eq $fontObj.TypeId }
    Log ("       its type : class " + $ti.ClassId + " script index " + $ti.ScriptIdx + " nodes " + $ti.NodeCount + " strings " + $ti.StrSize)
    # which script? (that tells us the exact class name)
    if ($ti.ClassId -eq 114 -and $ti.ScriptIdx -ge 0 -and $ti.ScriptIdx -lt $scripts.Count) {
      $sref = $scripts[$ti.ScriptIdx]
      if ($sref.FileIndex -eq 0) {
        Log ("       script id (in file) : " + $sref.IdInFile)
      } else {
        Log ("       script in external file " + $sref.FileIndex + " : " + $exts[$sref.FileIndex - 1].Path)
      }
    }
    # dump the object + its typetree
    $len = [Math]::Min($fontObj.Size, 150000)
    $objBytes = New-Object 'byte[]' $len
    [Array]::Copy($bytes, $fontObj.ByteStart, $objBytes, 0, $len)
    Write-Pack $sb ("FONT-OBJECT") $objBytes
    $treeLen = $ti.End - $ti.Start
    $treeBytes = New-Object 'byte[]' ($treeLen + 8)
    [Array]::Copy($bytes, $ti.Start, $treeBytes, 0, $treeLen)
    # add the script id for reference at the end
    Write-Pack $sb ("FONT-TYPE") $treeBytes
    # the object table info
    [void]$sb.AppendLine("FONT-OBJ-INFO path=" + $fontObj.PathId + " type=" + $fontObj.TypeId + " start=" + $fontObj.ByteStart + " size=" + $fontObj.Size + " clipped=" + $len)
  } else {
    Log "   >>> the font asset object was NOT found"
  }

  if ($texObj) {
    Log ("   >>> ATLAS TEXTURE object : path " + $texObj.PathId + " type " + $texObj.TypeId + " size " + $texObj.Size)
    $len = [Math]::Min($texObj.Size, 1024)
    $tb = New-Object 'byte[]' $len
    [Array]::Copy($bytes, $texObj.ByteStart, $tb, 0, $len)
    Write-Pack $sb ("TEX-OBJECT-HEAD") $tb
    $ti2 = $typeInfo | Where-Object { $_.Index -eq $texObj.TypeId }
    Log ("       its type : class " + $ti2.ClassId + " nodes " + $ti2.NodeCount + " strings " + $ti2.StrSize)
    $treeLen2 = $ti2.End - $ti2.Start
    $treeBytes2 = New-Object 'byte[]' $treeLen2
    [Array]::Copy($bytes, $ti2.Start, $treeBytes2, 0, $treeLen2)
    Write-Pack $sb ("TEX-TYPE") $treeBytes2
    # is the pixel data stored beside the file?
    $resS = $t.FullName + ".resS"
    if (Test-Path $resS) { Log ("       side file : " + $resS + "  " + (Get-Item $resS).Length + " bytes") }
    else { Log "       no .resS side file - the pixels are inside this object" }
  } else {
    Log "   >>> the atlas texture object was NOT found"
  }

  if ($matObj) { Log ("   >>> MATERIAL object : path " + $matObj.PathId + " type " + $matObj.TypeId + " size " + $matObj.Size) }

  # also list all font-ish objects (so the helper sees the whole picture)
  Log ""
  Log "   all objects that hold a 'SDF' name (first 40) :"
  $n = 0
  foreach ($o in $objects) {
    if ($o.Size -lt 16 -or $o.Size -gt 2000000) { continue }
    $s = $o.ByteStart
    if ((Find-Str $bytes "Nunito-ExtraBold SDF" $s ($s + $o.Size)) -lt 0) { continue }
    Log ("      path " + $o.PathId + "  type " + $o.TypeId + "  size " + $o.Size)
    $n++
    if ($n -ge 40) { break }
  }
  Log ""
}

$txt = $sb.ToString()
$packPath = Join-Path $out "FONT-INFO.txt"
[System.IO.File]::WriteAllText($packPath, $txt, (New-Object System.Text.UTF8Encoding($false)))
$lk = Upload-File $packPath
if ($lk) { [void]$script:links.Add("font info : " + $lk); Log ("   font info uploaded : " + $lk) }

Finish "DONE - the links are above"
exit 0
