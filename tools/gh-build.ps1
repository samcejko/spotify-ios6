# Waits for the latest GitHub Actions run, prints errors on failure, downloads the packages on success
# and optionally installs them on the iPad over SSH.
# Usage: .\tools\gh-build.ps1 [-Repo owner/name] [-Token ghp_xxx] [-Trigger] [-Download] [-Install] [-IPadHost <address>] [-HeadSha <commit>]
# Repo, token and iPad address default to tools/local.json.
param(
    [string]$Repo = '',
    [string]$Token = $env:GH_TOKEN,
    [string]$Branch = '',
    [switch]$Trigger,
    [switch]$Download,
    [switch]$Install,
    [string]$IPadHost = '',
    [string]$OutDir = '',
    [int]$TimeoutSec = 1800,
    [long]$AfterRunId = 0,
    [string]$HeadSha = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'packages' }
$localCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $localCfg) {
    $cfg = Get-Content $localCfg -Raw | ConvertFrom-Json
    if (-not $Repo -and $cfg.repo) { $Repo = $cfg.repo }
    if (-not $Token -and $cfg.token) { $Token = $cfg.token }
    if (-not $IPadHost -and $cfg.ipad) { $IPadHost = $cfg.ipad }
}
if ($Install -and -not $IPadHost) { throw "Missing iPad address: pass -IPadHost or set `"ipad`" in tools/local.json" }
if (-not $Repo) { throw "Missing repo: pass -Repo or set it in tools/local.json" }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Token) { throw "Missing token: pass -Token or set GH_TOKEN" }

$Headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'spotify-ios6-build'
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

if ($run.conclusion -ne 'success') {
    $jobs = Invoke-GH GET "/actions/runs/$($run.id)/jobs"
    foreach ($job in $jobs.jobs) {
        if ($job.conclusion -eq 'success' -or $job.conclusion -eq 'skipped') { continue }
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
    exit 1
}

if (-not $Download -and -not $Install) { exit 0 }

$arts = Invoke-GH GET "/actions/runs/$($run.id)/artifacts"
$pkg = $arts.artifacts | Where-Object { $_.name -eq 'Spot6-packages' } | Select-Object -First 1
if (-not $pkg) { throw "No Spot6-packages artifact" }
$zip = Join-Path $OutDir "Spot6-packages-$($run.id).zip"
Download-GH "$Api/actions/artifacts/$($pkg.id)/zip" $zip
$extract = Join-Path $OutDir "run-$($run.id)"
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
Expand-Archive -Path $zip -DestinationPath $extract -Force
$files = Get-ChildItem $extract -File
$files | ForEach-Object { Write-Host "Downloaded: $($_.FullName) ($([math]::Round($_.Length/1KB)) KB)" }

if ($Install) {
    . (Join-Path $PSScriptRoot 'ipad.ps1')
    $ipa = $files | Where-Object { $_.Extension -eq '.ipa' } | Select-Object -First 1
    $deb = $files | Where-Object { $_.Extension -eq '.deb' } | Select-Object -First 1
    Install-IPadPackage -IPadHost $IPadHost -IpaPath $ipa.FullName -DebPath $deb.FullName
}
