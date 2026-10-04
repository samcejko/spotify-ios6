# Publishes a GitHub release through the REST API: tag v<Version> at <Sha>, the CHANGELOG section as the notes,
# the IPA and DEB of a downloaded CI run (packages\run-<id>) as assets, with their SHA-256 sums in the notes.
# Usage: .\tools\gh-release.ps1 -RunDir .\packages\run-123 -Sha <commit> [-Version 0.1.0] [-Repo owner/name] [-Token ghp_xxx] [-DryRun]
# Repo and token default to tools/local.json. -DryRun prints what would be published and uploads nothing.
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)][string]$Sha,
    [string]$Version = '',
    [string]$Repo = '',
    [string]$Token = $env:GH_TOKEN,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$localCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $localCfg) {
    $cfg = Get-Content $localCfg -Raw | ConvertFrom-Json
    if (-not $Repo -and $cfg.repo) { $Repo = $cfg.repo }
    if (-not $Token -and $cfg.token) { $Token = $cfg.token }
}
if (-not $Repo) { throw 'No repository (-Repo or tools/local.json)' }
if (-not $Token) { throw 'No token (-Token, GH_TOKEN or tools/local.json)' }
if (-not $Version) {
    $control = Get-Content (Join-Path $root 'control') | Where-Object { $_ -match '^Version:\s*(.+)$' } | Select-Object -First 1
    if ($control -match '^Version:\s*(.+)$') { $Version = $Matches[1].Trim() } else { throw 'Version not found in control' }
}
$tag = "v$Version"

# the assets
$assets = @(Get-ChildItem $RunDir -File | Where-Object { $_.Extension -in '.ipa', '.deb' })
if (-not $assets) { throw "No .ipa/.deb in $RunDir" }

# the notes: the CHANGELOG section of this version, then the checksums
$changelog = Get-Content (Join-Path $root 'CHANGELOG.md') -Raw
$section = ''
if ($changelog -match "(?s)## $([regex]::Escape($Version))[^\n]*\n(.*?)(\n## |\z)") { $section = $Matches[1].Trim() }
# (ASCII only in this file: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page)
$sums = $assets | ForEach-Object { "- ``$($_.Name)`` - SHA-256 ``$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())``" }
$install = '**Installation (jailbroken iOS 6):** the IPA through `ipainstaller -f Spot6-{0}.ipa` (AppSync Unified), or the DEB through `dpkg -i` followed by `su mobile -c uicache`. Either works; do not keep both installed at once. **Logging in** needs Spotify Premium: open Spot6, then pick "Spot6 (iPad)" in the Spotify app on your phone (same Wi-Fi). Spot6 is an unofficial app, not made by Spotify.' -f $Version
$notes = ($section, '', $install, '', '**Checksums**', ($sums -join "`n")) -join "`n"

Write-Host "Release $tag of $Repo at $($Sha.Substring(0, [Math]::Min(7, $Sha.Length)))"
Write-Host "Assets: $(($assets | ForEach-Object { $_.Name }) -join ', ')"
Write-Host "--- notes ---`n$notes`n-------------"
if ($DryRun) { Write-Host 'Dry run: nothing published.'; exit 0 }

$headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'Spot6-tools'; 'X-GitHub-Api-Version' = '2022-11-28' }
$api = "https://api.github.com/repos/$Repo"

# an existing release of this tag is reused (assets of the same name are replaced)
$release = $null
try { $release = Invoke-RestMethod -Uri "$api/releases/tags/$tag" -Headers $headers -TimeoutSec 60 } catch { $release = $null }
if (-not $release) {
    $body = @{ tag_name = $tag; target_commitish = $Sha; name = "Spot6 $Version"; body = $notes; draft = $false; prerelease = $false } | ConvertTo-Json
    $release = Invoke-RestMethod -Method Post -Uri "$api/releases" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    Write-Host "Created release $($release.id)"
} else {
    $body = @{ body = $notes; name = "Spot6 $Version" } | ConvertTo-Json
    $release = Invoke-RestMethod -Method Patch -Uri "$api/releases/$($release.id)" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    Write-Host "Updated release $($release.id)"
}

$existing = @(Invoke-RestMethod -Uri "$api/releases/$($release.id)/assets" -Headers $headers -TimeoutSec 60)
foreach ($asset in $assets) {
    $old = $existing | Where-Object { $_.name -eq $asset.Name }
    if ($old) { Invoke-RestMethod -Method Delete -Uri "$api/releases/assets/$($old.id)" -Headers $headers -TimeoutSec 60 | Out-Null }
    $uploadUrl = ($release.upload_url -replace '\{\?name,label\}', '') + "?name=$([uri]::EscapeDataString($asset.Name))"
    $uploaded = Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $headers -ContentType 'application/octet-stream' -InFile $asset.FullName -TimeoutSec 600
    Write-Host "Uploaded $($uploaded.name) ($([math]::Round($uploaded.size / 1KB)) KB)"
}
Write-Host "Done: $($release.html_url)"
