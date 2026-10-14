# Waits for the latest GitHub Actions run, prints errors on failure, downloads the packages on success
# (both builds: armv7 for iOS 6 and arm64 for iOS 14-17) and optionally installs them over SSH:
# the armv7 IPA/deb on the iPad, the arm64 deb on the iPhone (rootless jailbreak).
# Usage: .\tools\gh-build.ps1 [-Repo owner/name] [-Token ghp_xxx] [-Trigger] [-Download] [-Install] [-IPadHost <address>]
#                             [-InstallIPhone] [-IPhoneHost <address>] [-Arch all|armv7|arm64] [-HeadSha <commit>]
# Repo, token and device addresses default to tools/local.json ("repo", "token", "ipad", "iphone").
param(
    [string]$Repo = '',
    [string]$Token = $env:GH_TOKEN,
    [string]$Branch = '',
    [switch]$Trigger,
    [switch]$Download,
    [switch]$Install,
    [switch]$InstallIPhone,
    [string]$IPadHost = '',
    [string]$IPhoneHost = '',
    [ValidateSet('all', 'armv7', 'arm64')][string]$Arch = 'all',
    [string]$OutDir = '',
    [int]$TimeoutSec = 1800,
    [long]$AfterRunId = 0,
    [string]$HeadSha = ''
)

$AppName = 'Spot6'

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'packages' }
$localCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $localCfg) {
    $cfg = Get-Content $localCfg -Raw | ConvertFrom-Json
    if (-not $Repo -and $cfg.repo) { $Repo = $cfg.repo }
    if (-not $Token -and $cfg.token) { $Token = $cfg.token }
    if (-not $IPadHost -and $cfg.ipad) { $IPadHost = $cfg.ipad }
    if (-not $IPhoneHost -and $cfg.iphone) { $IPhoneHost = $cfg.iphone }
}
if ($Install -and -not $IPadHost) { throw "Missing iPad address: pass -IPadHost or set `"ipad`" in tools/local.json" }
if ($InstallIPhone -and -not $IPhoneHost) { throw "Missing iPhone address: pass -IPhoneHost or set `"iphone`" in tools/local.json" }
if (-not $Repo) { throw "Missing repo: pass -Repo or set it in tools/local.json" }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Token) { throw "Missing token: pass -Token or set GH_TOKEN" }

$Headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = "$($AppName.ToLower())-ios6-build"
}
$Api = "https://api.github.com/repos/$Repo"

function Invoke-GH {
    param([string]$Method, [string]$Path, $Body)
    $params = @{ Method = $Method; Uri = "$Api$Path"; Headers = $Headers; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $Body) { $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress)) }
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod @params
        } catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            $retryable = ($status -eq 403 -or $status -eq 502 -or $status -eq 503 -or $status -eq 0)
            if (-not $retryable -or $attempt -ge 8) { throw }
            Start-Sleep -Seconds ([Math]::Min(3 * $attempt, 20))
        }
    }
}

function Download-GH([string]$Url, [string]$Dest) {
    # curl follows the redirect to blob storage and drops the Authorization header across hosts.
    for ($i = 1; $i -le 6; $i++) {
        & curl.exe -sSL -f -H "Authorization: Bearer $Token" -H "Accept: application/vnd.github+json" -o $Dest $Url
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds (3 * $i)
    }
    throw "download failed: $Url"
}

if (-not $Branch) {
    $repoInfo = Invoke-GH GET ""
    $Branch = $repoInfo.default_branch
    if (-not $Branch) { $Branch = 'main' }
}

if ($Trigger) {
    if ($AfterRunId -eq 0) {
        $prev = Invoke-GH GET "/actions/runs?branch=$Branch&per_page=1"
        if ($prev.workflow_runs) { $AfterRunId = [long]$prev.workflow_runs[0].id }
    }
    Invoke-GH POST "/actions/workflows/build.yml/dispatches" @{ ref = $Branch } | Out-Null
    Write-Host "Triggered workflow_dispatch on $Branch"
    Start-Sleep -Seconds 8
}

# Latest run on the branch (optionally newer than a given id)
$run = $null
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ($true) {
    $runs = Invoke-GH GET "/actions/runs?branch=$Branch&per_page=5"
    $candidates = $runs.workflow_runs | Where-Object { $_.id -gt $AfterRunId }
    if ($HeadSha) { $candidates = $candidates | Where-Object { $_.head_sha -like "$HeadSha*" } }
    $run = $candidates | Sort-Object -Property id -Descending | Select-Object -First 1
    if ($run) { break }
    if ((Get-Date) -gt $deadline) { throw "No workflow run found" }
    Start-Sleep -Seconds 10
}
Write-Host "Run #$($run.run_number) id=$($run.id) status=$($run.status) ($($run.html_url))"

while ($run.status -ne 'completed') {
    if ((Get-Date) -gt $deadline) { throw "Timed out waiting for run $($run.id)" }
    Start-Sleep -Seconds 20
    $run = Invoke-GH GET "/actions/runs/$($run.id)"
    Write-Host "  $(Get-Date -Format HH:mm:ss) $($run.status)"
}
Write-Host "Conclusion: $($run.conclusion)"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# The two builds are separate jobs: a failed one is reported, a successful one still downloaded
$jobs = Invoke-GH GET "/actions/runs/$($run.id)/jobs"
$failed = @()
foreach ($job in $jobs.jobs) {
    if ($job.conclusion -eq 'success' -or $job.conclusion -eq 'skipped') { continue }
    $failed += $job.name
    Write-Host "== Job '$($job.name)' -> $($job.conclusion)"
    foreach ($step in $job.steps) { Write-Host "   step '$($step.name)': $($step.conclusion)" }
    $logPath = Join-Path $OutDir "job-$($job.id).log"
    try { Download-GH "$Api/actions/jobs/$($job.id)/logs" $logPath } catch { Write-Warning $_; continue }
    $lines = Get-Content $logPath
    $interesting = $lines | Where-Object { $_ -match 'error:|Error |fatal|undefined|No such file|failed|\*\*\* ' } | Select-Object -First 80
    Write-Host "---- errors ($logPath) ----"
    $interesting | ForEach-Object { Write-Host $_ }
    Write-Host "---- last 40 lines ----"
    $lines | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
}
if ($failed.Count -gt 0 -and -not $Download -and -not $Install -and -not $InstallIPhone) { exit 1 }
if (-not $Download -and -not $Install -and -not $InstallIPhone) { exit 0 }

$wanted = @()
if ($Arch -ne 'arm64') { $wanted += "$AppName-packages" }
if ($Arch -ne 'armv7') { $wanted += "$AppName-packages-arm64" }
$arts = Invoke-GH GET "/actions/runs/$($run.id)/artifacts"
$extract = Join-Path $OutDir "run-$($run.id)"
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
New-Item -ItemType Directory -Force -Path $extract | Out-Null
$got = 0
foreach ($name in $wanted) {
    $pkg = $arts.artifacts | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $pkg) { Write-Warning "No $name artifact in run $($run.id)"; continue }
    $zip = Join-Path $OutDir "$name-$($run.id).zip"
    Download-GH "$Api/actions/artifacts/$($pkg.id)/zip" $zip
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $got++
}
if ($got -eq 0) { throw "Nothing downloaded" }
$files = Get-ChildItem $extract -File
$files | ForEach-Object { Write-Host "Downloaded: $($_.FullName) ($([math]::Round($_.Length/1KB)) KB)" }

if ($Install) {
    . (Join-Path $PSScriptRoot 'ipad.ps1')
    $ipa = $files | Where-Object { $_.Extension -eq '.ipa' -and $_.Name -notlike '*arm64*' } | Select-Object -First 1
    $deb = $files | Where-Object { $_.Extension -eq '.deb' -and $_.Name -like '*_iphoneos-arm.deb' } | Select-Object -First 1
    if (-not $ipa -and -not $deb) { throw "No armv7 packages to install on the iPad" }
    Install-IPadPackage -IPadHost $IPadHost -IpaPath $(if ($ipa) { $ipa.FullName } else { '' }) -DebPath $(if ($deb) { $deb.FullName } else { '' })
}

if ($InstallIPhone) {
    . (Join-Path $PSScriptRoot 'iphone.ps1')
    $deb = $files | Where-Object { $_.Extension -eq '.deb' -and $_.Name -like '*_iphoneos-arm64.deb' } | Select-Object -First 1
    if (-not $deb) { throw "No arm64 .deb to install on the iPhone" }
    Install-IPhonePackage -IPhoneHost $IPhoneHost -DebPath $deb.FullName
}

if ($failed.Count -gt 0) { Write-Warning "Failed jobs: $($failed -join ', ')"; exit 1 }
