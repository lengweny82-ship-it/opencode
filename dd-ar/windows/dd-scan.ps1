# =====================================================================
#  dd-scan.ps1  -  Double Dealers: what fonts does the game use?
#  (read-only - nothing on your PC is changed)
# =====================================================================
$ErrorActionPreference = "Continue"
$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-scan"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:report = New-Object System.Collections.ArrayList
function Log([string]$m) { Write-Host $m; [void]$script:report.Add($m) }
function Save-Report { try { Set-Content -Path (Join-Path $out "00-SCAN-REPORT.txt") -Value $script:report -Encoding UTF8 } catch { } }

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
  $l = Upload-File (Join-Path $out "00-SCAN-REPORT.txt")
  Write-Host ""
  if ($l) {
    Write-Host "SEND THIS LINK:" -ForegroundColor Green
    Write-Host $l
    try { Set-Content -Path (Join-Path $out "LINK-TO-SEND.txt") -Value $l -Encoding UTF8 } catch { }
  } else {
    Write-Host "upload failed - the report is here:" -ForegroundColor Yellow
    Write-Host (Join-Path $out "00-SCAN-REPORT.txt")
  }
  try { Start-Process explorer.exe -ArgumentList $out | Out-Null } catch { }
  Write-Host ""
  Write-Host "FINISHED" -ForegroundColor Green
  Read-Host "Press Enter to close"
}
function BE32([byte[]]$b, [int]$p) { return ([int64]$b[$p] -shl 24) + ([int64]$b[$p+1] -shl 16) + ([int64]$b[$p+2] -shl 8) + [int64]$b[$p+3] }
function BE64([byte[]]$b, [int]$p) { return ((BE32 $b $p) * 4294967296) + (BE32 $b ($p + 4)) }
function LE32([byte[]]$b, [int]$p) { return ([int64]$b[$p]) + ([int64]$b[$p+1] -shl 8) + ([int64]$b[$p+2] -shl 16) + ([int64]$b[$p+3] -shl 24) }
function L64([byte[]]$b, [int]$p) { return ((LE32 $b $p) * 4294967296) + (LE32 $b ($p + 4)) }

$FONTMAGIC = @(
  @(0x4F, 0x54, 0x54, 0x4F),            # OTTO (otf)
  @(0x00, 0x01, 0x00, 0x00),            # ttf
  @(0x74, 0x72, 0x75, 0x65),            # true
  @(0x74, 0x74, 0x63, 0x66)             # ttcf
)
function Find-FontMagic([byte[]]$b, [int]$max) {
  $res = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt ($b.Length - 4); $i++) {
    $x = $b[$i]
    if ($x -ne 0 -and $x -ne 0x4F -and $x -ne 0x74) { continue }
    foreach ($m in $FONTMAGIC) {
      if ($x -eq $m[0] -and $b[$i+1] -eq $m[1] -and $b[$i+2] -eq $m[2] -and $b[$i+3] -eq $m[3]) {
        [void]$res.Add($i)
        if ($res.Count -ge $max) { return ,$res }
        break
      }
    }
  }
  return ,$res
}
function Get-Strings([byte[]]$b, [int]$from, [int]$len, [int]$minLen, [string[]]$keys, [int]$max) {
  $res = New-Object System.Collections.ArrayList
  $sb = New-Object System.Text.StringBuilder
  $end = [Math]::Min($b.Length, $from + $len)
  for ($i = $from; $i -lt $end; $i++) {
    $c = $b[$i]
    if ($c -ge 32 -and $c -lt 127) { [void]$sb.Append([char]$c); continue }
    if ($sb.Length -ge $minLen) {
      $s = $sb.ToString()
      if ($keys.Count -eq 0) { [void]$res.Add($s) } else { foreach ($k in $keys) { if ($s.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$res.Add($s); break } } }
    }
    [void]$sb.Clear()
    if ($res.Count -ge $max) { return ,$res }
  }
  return ,$res
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
Log "Double Dealers - file / font scan"
Log ("date : " + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
Log ""
if (-not $file) { Log "[X] the game was not found"; Finish "STOPPED"; exit 1 }

$dir = Split-Path $file -Parent
$aa = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
$sa = [System.IO.Path]::GetFullPath((Join-Path $aa ".."))
$data = [System.IO.Path]::GetFullPath((Join-Path $sa ".."))
$root = [System.IO.Path]::GetFullPath((Join-Path $data ".."))
Log ("game folder : " + $root)
Log ("data folder : " + $data)
Log ""

# ---------------------------------------------------------------- 1. folders
$all = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending
Log ("1) files in total : " + $all.Count)
Log "   ---- the 30 biggest ----"
$k = 0
foreach ($f in $all) {
  if ($k -ge 30) { break }
  Log ("   " + $f.Length.ToString().PadLeft(12) + "   " + $f.FullName.Substring($root.Length))
  $k++
}
Log "   ---- totals by extension ----"
$grp = $all | Group-Object { $_.Extension.ToLower() }
foreach ($g in $grp) {
  $sum = ($g.Group | Measure-Object Length -Sum).Sum
  Log ("   " + $g.Name.PadRight(12) + " count " + $g.Count.ToString().PadLeft(5) + "   total " + $sum)
}
Log ""

# ---------------------------------------------------------------- 2. scan the files
$keys = @("Font", "TMP", "SDF", "Liberation", "Arial", "Noto", "Amiri", "DejaVu", "Arabic", "Cairo", "Tahoma", "Antique", "Gothic", "Serif")
$targets = @()
$targets += (Get-ChildItem -Path $data -File -Filter "*.assets" -ErrorAction SilentlyContinue)
$targets += (Get-ChildItem -Path $data -File -Filter "*.resource" -ErrorAction SilentlyContinue)
$targets += (Get-ChildItem -Path $data -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.*" -and $_.Name -like "*assets*" })
$targets += (Get-ChildItem -Path (Join-Path $data "StreamingAssets") -Recurse -File -ErrorAction SilentlyContinue)
$targets = $targets | Sort-Object Length -Descending
Log ("2) looking into " + $targets.Count + " game files ...")
Log ""

foreach ($t in $targets) {
  $rel = $t.FullName.Substring($root.Length)
  Log ("   ==== " + $rel)
  Log ("        size " + $t.Length + " bytes")
  if ($t.Length -gt 60MB) { Log "        (big file - only the header is reported)"; continue }
  $bytes = $null
  try { $bytes = [System.IO.File]::ReadAllBytes($t.FullName) } catch { Log ("        (could not read : " + $_.Exception.Message + ")"); continue }

  # header info (unity serialized file)
  $signature = [System.Text.Encoding]::ASCII.GetString($bytes[0..5])
  if ($signature -eq "UnityF") {
    Log "        (a unity bundle)"
    $p = $signature.Length + 1 + 4
    while ($p -lt 300 -and $bytes[$p] -ne 0) { $p++ }
    $p2 = $p + 1
    $uv = ""
    while ($p2 -lt 300 -and $bytes[$p2] -ne 0) { $uv += [char]$bytes[$p2]; $p2++ }
    Log ("        unity version " + $uv)
  } else {
    $ver = BE32 $bytes 8
    $meta = BE32 $bytes 20
    $fsize = BE64 $bytes 24
    if ($ver -ge 5 -and $ver -le 30 -and $fsize -eq $t.Length) { Log ("        (unity serialized file, version " + $ver + ")") }
    else { Log ("        (not a unity serialized file)" ) }
  }

  # font magic inside
  $magic = Find-FontMagic $bytes 12
  if ($magic.Count -gt 0) {
    Log ("        FONT DATA FOUND at byte(s): " + ($magic -join ", "))
    foreach ($m in $magic) {
      $around = ""
      for ($q = $m; $q -lt [Math]::Min($bytes.Length, $m + 24); $q++) {
        if ($bytes[$q] -ge 32 -and $bytes[$q] -lt 127) { $around += [char]$bytes[$q] } else { $around += "." }
      }
      Log ("           at " + $m + " : " + $around)
      # ttf name table is near the end of the font; look for a readable name within 4mb after
      $nm = Get-Strings $bytes $m ([Math]::Min(6000000, $bytes.Length - $m)) 4 @("") 60
      $nice = @($nm | Where-Object { $_ -match "^[A-Za-z][A-Za-z0-9 \-]{3,30}$" } | Select-Object -First 8)
      if ($nice.Count -gt 0) { Log ("              names near it : " + ($nice -join " | ")) }
    }
  }

  # fonts by name
  $found = Get-Strings $bytes 0 $bytes.Length 5 $keys 400
  $uniq = New-Object System.Collections.ArrayList
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($s in $found) {
    $clean = $s.Trim()
    if ($clean.Length -gt 70) { $clean = $clean.Substring(0, 70) + "..." }
    if ($seen.Add($clean)) { [void]$uniq.Add($clean) }
    if ($uniq.Count -ge 30) { break }
  }
  if ($uniq.Count -eq 0) { Log "        (no font related text)" }
  foreach ($s in $uniq) { Log ("        txt: " + $s) }
}
Log ""

# ---------------------------------------------------------------- 3. the game log
try {
  $logs = Get-ChildItem -Path (Join-Path $env:USERPROFILE "AppData\LocalLow") -Filter "Player*.log" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
  if ($logs -and $logs.Count -gt 0) {
    $lg = $logs[0]
    Log ("3) game log : " + $lg.FullName + "  (" + $lg.Length + " bytes)")
    $txt = ""
    try {
      $fs = [System.IO.File]::Open($lg.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      $sr = New-Object System.IO.StreamReader($fs)
      $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
    } catch { }
    if ($txt.Length -gt 0) {
      $alll = $txt -split "`r?`n"
      Log ("   lines : " + $alll.Count)
      $hit = @($alll | Where-Object { $_ -match "font|Font|TMP|glyph|Glyph|character|Character|missing" })
      Log ("   font related lines : " + $hit.Count)
      $n = 0
      foreach ($l in $hit) { if ($n -ge 40) { break }; Log ("      " + $l); $n++ }
    }
  } else { Log "3) game log : not found" }
} catch { Log ("3) game log failed : " + $_.Exception.Message) }

# ---------------------------------------------------------------- 4. small files for the helper
Log ""
Log "4) sending the small game files to the helper ..."
$small = New-Object System.Collections.ArrayList
$smallList = @()
$smallList += (Get-ChildItem -Path (Join-Path $data "StreamingAssets") -Recurse -File -Filter "*monoscripts*" -ErrorAction SilentlyContinue)
$smallList += (Get-ChildItem -Path (Join-Path $data "StreamingAssets") -Recurse -File -Filter "localization-assets-shared*" -ErrorAction SilentlyContinue)
$smallList += (Get-ChildItem -Path (Join-Path $data "StreamingAssets") -Recurse -File -Filter "localization-locales*" -ErrorAction SilentlyContinue)
foreach ($sm in $smallList) {
  if ($sm.Length -gt 200000) { continue }
  $txtName = Join-Path $out ($sm.Name + ".b64.txt")
  $data2 = [System.IO.File]::ReadAllBytes($sm.FullName)
  $b64 = [Convert]::ToBase64String($data2)
  [System.IO.File]::WriteAllText($txtName, $b64, (New-Object System.Text.UTF8Encoding($false)))
  Log ("   " + $sm.Name + "  " + $sm.Length + " bytes")
}
# one file with everything (name + base64 lines)
$combined = Join-Path $out "small-bundles.txt"
$lines2 = New-Object System.Collections.ArrayList
foreach ($sm in $smallList) {
  if ($sm.Length -gt 200000) { continue }
  [void]$lines2.Add("FILE " + $sm.Name + " " + $sm.Length)
  $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($sm.FullName))
  $i3 = 0
  while ($i3 -lt $b64.Length) { $n3 = [Math]::Min(6000, $b64.Length - $i3); [void]$lines2.Add($b64.Substring($i3, $n3)); $i3 += $n3 }
  [void]$lines2.Add("ENDFILE")
}
[System.IO.File]::WriteAllText($combined, ($lines2 -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
$l2 = Upload-File $combined
if ($l2) { Log ("   SMALL FILES LINK : " + $l2) }
Log ""

Finish "DONE - the report is on its way"
exit 0
