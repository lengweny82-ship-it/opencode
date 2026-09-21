param([string]$Report)

# =====================================================================
#  dd-send-summary.ps1   (v1)
#
#  takes the survey report that dd-scan-fonts.ps1 already wrote on the
#  desktop, keeps only the useful lines, and uploads that small summary
#  to four different file hosts, so at least one link works.
#
#  nothing in the game folder is touched (this is only about the report).
# =====================================================================

$ErrorActionPreference = "Continue"

$desk = [Environment]::GetFolderPath("Desktop")
$outDir = Join-Path $desk "dd-ar-scan2"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# ---- find the report
$rep = ""
if ($Report -and (Test-Path $Report)) {
  $rep = (Get-Item $Report).FullName
} else {
  $cand = Join-Path $outDir "00-SCAN-REPORT.txt"
  if (Test-Path $cand) { $rep = $cand }
}
if (-not $rep) {
  $hits = @(Get-ChildItem -Path $desk -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*SCAN*REPORT*" -or $_.Name -like "00-*.txt" } |
            Sort-Object LastWriteTime -Descending)
  if ($hits.Count -gt 0) { $rep = $hits[0].FullName }
}
Write-Host ""
Write-Host "Double Dealers - send the survey summary" -ForegroundColor Cyan
Write-Host ""
if (-not $rep) {
  Write-Host "[X] the survey report was not found on the desktop." -ForegroundColor Red
  Write-Host "    run the survey script again first (dd35), then run this one."
  Read-Host "Press Enter to close"
  exit 1
}
Write-Host ("report : " + $rep)
Write-Host ("size   : " + (Get-Item $rep).Length + " bytes")

# ---- keep only what matters
$lines = @(Get-Content -Path $rep -ErrorAction SilentlyContinue)
$keep = New-Object System.Collections.ArrayList
foreach ($ln in $lines) {
  $t = [string]$ln
  if ($t -match '^\s*$') { [void]$keep.Add(""); continue }
  if ($t -match '^(DDX9|date|game|data|files in)') { [void]$keep.Add($t); continue }
  if ($t -match '^\s*(DATA |BIG |HIT |FONT |FONTATLAS |ASSETPATH |INNER |NODE )') { [void]$keep.Add($t); continue }
  if ($t -match '^\s*(BUNDLE |BUNDLEFILE )') {
    if ($t -match '(?i)font|locale|localization|sharedassets|catalog') { [void]$keep.Add($t) }
    continue
  }
  if ($t -match '^\s*\(strings shown') { continue }
  if ($t -match '^\s*STR ') {
    if ($t -match '(?i)bundle|locale|font|atlas') { [void]$keep.Add($t) }
    continue
  }
  if ($t -match '(?i)(font object at|sharedassets0\.assets :|catalog :|DONE|stopped|\[X\])') { [void]$keep.Add($t); continue }
}

$sum = Join-Path $outDir "01-SUMMARY.txt"
$head = @(
  "DDX10 - survey summary (kept lines only)",
  ("source : " + $rep),
  ("lines  : " + $lines.Count + " -> " + $keep.Count),
  ""
)
Set-Content -Path $sum -Value ($head + $keep) -Encoding UTF8
$sz = (Get-Item $sum).Length
Write-Host ("summary: " + $sum)
Write-Host ("         " + $keep.Count + " lines, " + $sz + " bytes")
Write-Host ""

# ---- show it on screen too (so a screenshot works if every upload fails)
Write-Host "----------- SUMMARY (same text as the file) -----------" -ForegroundColor Yellow
foreach ($l in ($head + $keep)) { Write-Host $l }
Write-Host "----------- END OF SUMMARY -----------" -ForegroundColor Yellow
Write-Host ""

# ---- upload to four hosts
$curl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path $curl)) { $curl = "curl.exe" }
$links = New-Object System.Collections.ArrayList

Write-Host "uploading ..."
try {
  $r = & $curl -s -m 120 -F "reqtype=fileupload" -F ("fileToUpload=@" + $sum) "https://catbox.moe/user/api.php" 2>$null
  if ($r -and ($r -match "^https?://")) { [void]$links.Add("catbox    " + $r.Trim()); Write-Host ("  catbox ok : " + $r.Trim()) }
} catch { }
try {
  $r = & $curl -s -m 120 -F "reqtype=fileupload" -F "time=72h" -F ("fileToUpload=@" + $sum) "https://litterbox.catbox.moe/resources/internals/api.php" 2>$null
  if ($r -and ($r -match "^https?://")) { [void]$links.Add("litterbox " + $r.Trim()); Write-Host ("  litterbox ok : " + $r.Trim()) }
} catch { }
try {
  $r = & $curl -s -m 120 -F ("files[]=@" + $sum) "https://uguu.se/upload?output=text" 2>$null
  if ($r -and ($r -match "^https?://")) { [void]$links.Add("uguu      " + $r.Trim()); Write-Host ("  uguu ok : " + $r.Trim()) }
} catch { }
try {
  $r = & $curl -s -m 120 -F ("file=@" + $sum) "https://0x0.st" 2>$null
  if ($r -and ($r -match "^https?://")) { [void]$links.Add("0x0       " + $r.Trim()); Write-Host ("  0x0 ok : " + $r.Trim()) }
} catch { }

Write-Host ""
if ($links.Count -gt 0) {
  Write-Host "  REPORT LINKS - copy them into the chat:" -ForegroundColor Green
  foreach ($l in $links) { Write-Host ("     " + $l) }
  Set-Content -Path (Join-Path $outDir "02-LINKS-TO-SEND.txt") -Value $links -Encoding UTF8
} else {
  Write-Host "  [!] every upload failed." -ForegroundColor Red
  Write-Host "      take a screenshot of the SUMMARY above and send it in the chat."
}
try { Start-Process explorer.exe -ArgumentList $outDir | Out-Null } catch { }
Write-Host ""
Write-Host "FINISHED" -ForegroundColor Green
Read-Host "Press Enter to close"
