# =====================================================================
#  dd-send-file.ps1  -  Double Dealers arabic helper
#
#  takes the file that dd-fontobj2.ps1 already wrote :
#      Desktop\dd-fontobj\FONT-OBJECTS.txt
#  uploads it to several free hosts and CHECKS every link by downloading
#  it back and comparing the fingerprint.  only a working link is shown.
#  READ ONLY - nothing on the PC is changed.
# =====================================================================
$ErrorActionPreference = "Continue"
$cands = New-Object System.Collections.ArrayList
[void]$cands.Add((Join-Path ([Environment]::GetFolderPath("Desktop")) "dd-fontobj\FONT-OBJECTS.txt"))
[void]$cands.Add((Join-Path $env:USERPROFILE "Desktop\dd-fontobj\FONT-OBJECTS.txt"))
[void]$cands.Add((Join-Path $env:USERPROFILE "OneDrive\Desktop\dd-fontobj\FONT-OBJECTS.txt"))
$file = ""
foreach ($c in $cands) { if (Test-Path $c) { $file = $c; break } }
if (-not $file) {
  Write-Host ""
  Write-Host "FONT-OBJECTS.txt was not found." -ForegroundColor Yellow
  Write-Host "run the dd22 command again first, then run this one."
  try { Read-Host "Press Enter to close" } catch { }
  exit 1
}
$bytes = [System.IO.File]::ReadAllBytes($file)
$sha = [System.Security.Cryptography.SHA256]::Create()
$h = $sha.ComputeHash($bytes)
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 8; $i++) { [void]$sb.Append($h[$i].ToString("x2")) }
$hash = $sb.ToString()
$head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 40)
Write-Host ""
Write-Host ("file  : " + $file)
Write-Host ("size  : " + $bytes.Length + " bytes")
Write-Host ("sha16 : " + $hash)
Write-Host ("start : " + $head.Replace("`r", " ").Replace("`n", " | "))
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
    if ($got.Length -ne $bytes.Length) { return $false }
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
function Try-Upload([string]$what, [string[]]$args2) {
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    Write-Host ("uploading via " + $what + " (try " + $attempt + ") ...")
    try {
      $raw = & $curl -s -m 900 @args2 2>$null | Out-String
      $link = Link-Of $raw
      if ($link) {
        Write-Host ("   link : " + $link)
        if (Verified $link) {
          Write-Host "   checked : OK" -ForegroundColor Green
          return $link
        }
        Write-Host "   checked : link did not work" -ForegroundColor Yellow
      } else {
        $t = $raw.Trim()
        if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
        Write-Host ("   refused : " + $t)
      }
    } catch { }
    Start-Sleep -Seconds 3
  }
  return ""
}
$specs = @(
  @{ n = "catbox";    a = @("-F", "reqtype=fileupload", "-F", ("fileToUpload=@" + $file), "https://catbox.moe/user/api.php") },
  @{ n = "litterbox"; a = @("-F", "reqtype=fileupload", "-F", "time=72h", "-F", ("fileToUpload=@" + $file), "https://litterbox.catbox.moe/resources/internals/api.php") },
  @{ n = "0x0";       a = @("-A", "Mozilla/5.0", "-F", ("file=@" + $file), "https://0x0.st") },
  @{ n = "uguu";      a = @("-F", ("files[]=@" + $file), "https://uguu.se/upload?output=text") },
  @{ n = "uguu2";     a = @("-F", ("files[]=@" + $file), "https://uguu.se/upload.php") }
)
$link = ""
foreach ($sp in $specs) {
  if ($link) { break }
  $link = Try-Upload $sp.n $sp.a
}

$out = Join-Path (Split-Path $file -Parent) "LINK-TO-SEND.txt"
Write-Host ""
Write-Host "=========================================================="
if ($link) {
  Write-Host "SEND THIS LINK:" -ForegroundColor Green
  Write-Host $link
  Write-Host ("sha16 : " + $hash)
  try { Set-Content -Path $out -Value $link -Encoding UTF8 } catch { }
} else {
  Write-Host "all uploads failed - the file is here:" -ForegroundColor Yellow
  Write-Host $file
  try { Set-Content -Path $out -Value ("upload failed - size " + $bytes.Length + " sha16 " + $hash) -Encoding UTF8 } catch { }
}
Write-Host "=========================================================="
Write-Host ""
Write-Host "FINISHED" -ForegroundColor Green
try { Read-Host "Press Enter to close" } catch { }
exit 0
