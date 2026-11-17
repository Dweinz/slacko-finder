# Bygger "Installera Slacko Finder.cmd": en fil som vänner dubbelklickar på.
# Addonet ligger inbakat (base64-zip), så inget behöver laddas ner.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = $PSScriptRoot
$zip = Join-Path ([IO.Path]::GetTempPath()) 'SlackoFinder-build.zip' # funkar även på Linux (GitHub Actions)
Remove-Item $zip -ErrorAction SilentlyContinue
[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $root 'SlackoFinder'), $zip, 'Optimal', $true)
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
Remove-Item $zip

$payload = @'
$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host '  Installerar Slacko Finder...' -ForegroundColor Cyan
$cands = @()
try { # Battle.net vet var WoW ligger
  $db = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("$env:ProgramData\Battle.net\Agent\product.db"))
  $cands += [regex]::Matches($db, '[A-Za-z]:[\\/][^\x00-\x1f"]*World of Warcraft') | ForEach-Object { $_.Value }
} catch {}
$cands += 'C:\Program Files (x86)\World of Warcraft', 'C:\Program Files\World of Warcraft', 'D:\World of Warcraft', 'D:\Games\World of Warcraft', 'E:\World of Warcraft'
$wow = $cands | Where-Object { Test-Path (Join-Path $_ '_forever_') } | Select-Object -First 1
while (-not $wow) {
  $in = (Read-Host '  Hittade inte WoW Forever. Klistra in sökvägen till din World of Warcraft-mapp').Trim('" ')
  if (Test-Path (Join-Path $in '_forever_')) { $wow = $in } else { Write-Host '  Ingen _forever_-mapp där, försök igen.' -ForegroundColor Yellow }
}
$addons = Join-Path $wow '_forever_\Interface\AddOns'
New-Item -ItemType Directory -Force $addons | Out-Null
$zip = Join-Path $env:TEMP 'SlackoFinder.zip'
[IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead($zip)
foreach ($e in $z.Entries) {
  $dest = Join-Path $addons $e.FullName
  New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
  [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
}
$z.Dispose()
Remove-Item $zip
Write-Host "  Klart! Installerat i $addons" -ForegroundColor Green
Write-Host '  Starta om WoW och skriv /sf (eller klicka på skelettet vid minimappen).' -ForegroundColor Green
Write-Host ''
'@

$cmd = "@echo off`r`n" +
  "powershell -NoProfile -ExecutionPolicy Bypass -Command `"`$c = Get-Content -Raw -Encoding UTF8 -LiteralPath '%~f0'; `$m = '#PS#' + 'START'; iex (`$c.Substring(`$c.IndexOf(`$m) + `$m.Length))`"`r`n" +
  "pause`r`nexit /b`r`n" +
  "#PS#START`r`n" +
  "`$b64 = '$b64'`r`n" + $payload

$out = Join-Path $root 'Installera Slacko Finder.cmd'
[IO.File]::WriteAllText($out, $cmd, (New-Object Text.UTF8Encoding $false))
Write-Host "Byggd: $out"
