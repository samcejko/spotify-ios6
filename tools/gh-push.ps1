# Pushes the working tree to GitHub through the REST API (no local git needed).
# Usage: .\tools\gh-push.ps1 [-Repo owner/name] [-Token ghp_xxx] -Message "commit message" [-DryRun]
# Repo and token default to tools/local.json ({"repo": "...", "token": "...", "ipad": "..."}).
# -DryRun only lists what would change. Files that look like they contain a token or a private key
# stop the push before anything is uploaded.
param(
    [string]$Repo = '',
    [string]$Token = $env:GH_TOKEN,
    [string]$Branch = '',
    [string]$Message = 'Update',
    [string]$Root = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$localCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $localCfg) {
    $cfg = Get-Content $localCfg -Raw | ConvertFrom-Json
    if (-not $Repo -and $cfg.repo) { $Repo = $cfg.repo }
    if (-not $Token -and $cfg.token) { $Token = $cfg.token }
}
if (-not $Repo) { throw "Missing repo: pass -Repo or set it in tools/local.json" }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Token) { throw "Missing token: pass -Token or set GH_TOKEN" }

$Headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'spotify-ios6-push'
}
$Api = "https://api.github.com/repos/$Repo"

function Invoke-GH {
    param([string]$Method, [string]$Path, $Body)
    $params = @{ Method = $Method; Uri = "$Api$Path"; Headers = $Headers; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $Body) { $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress)) }
    # Freshly created fine-grained tokens return sporadic 403s while permissions propagate; retry those.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod @params
        } catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            $retryable = ($status -eq 403 -or $status -eq 502 -or $status -eq 503 -or $status -eq 0)
            if ($status -eq 403 -and $_.ErrorDetails.Message -match 'rate limit') { $retryable = $true }
            if (-not $retryable -or $attempt -ge 8) { throw }
            Start-Sleep -Seconds ([Math]::Min(3 * $attempt, 20))
        }
    }
}

function Test-Ignored([string]$rel) {
    $r = $rel -replace '\\', '/'
    if ($r -like '.theos/*' -or $r -like 'obj/*' -or $r -like 'packages/*' -or $r -like 'vendor/mbedtls/*' -or $r -like '.git/*') { return $true }
    if ($r -like 'Resources/Icon*.png' -or $r -like 'Resources/Default*.png' -or $r -eq 'Resources/cacert.pem' -or $r -like 'Resources/licenses/*') { return $true }
    if ($r -like '*.ipa' -or $r -like '*.deb' -or $r -like '*.DS_Store' -or $r -like '*.log') { return $true }
    # Local settings with the token, wherever they are; .env files of any name never leave the machine either
    $name = ($r -split '/')[-1]
    if ($name -eq 'local.json' -or $name -eq '.env' -or $name -like '*.env' -or $name -like '.env.*') { return $true }
    return $false
}

# GitHub, OpenRouter and Google tokens, private keys. Checked on every file before anything is uploaded.
$SecretPattern = 'github_pat_[A-Za-z0-9_]{30,}|gh[pousr]_[A-Za-z0-9]{36,}|sk-or-v1-[0-9a-f]{32,}|GOCSPX-[A-Za-z0-9_-]{20,}|ya29\.[A-Za-z0-9_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

function Get-GitBlobSha([byte[]]$bytes) {
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = New-Object byte[] ($header.Length + $bytes.Length)
    [Array]::Copy($header, 0, $all, 0, $header.Length)
    [Array]::Copy($bytes, 0, $all, $header.Length, $bytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    return ([BitConverter]::ToString($sha1.ComputeHash($all)) -replace '-', '').ToLower()
}

# 0. Default branch when none was given
if (-not $Branch) {
    $repoInfo = Invoke-GH GET ""
    $Branch = $repoInfo.default_branch
    if (-not $Branch) { $Branch = 'main' }
    Write-Host "Using branch '$Branch'"
}

# 1. Current head (initialise an empty repository through the contents API if needed)
$headSha = $null
try {
    $ref = Invoke-GH GET "/git/ref/heads/$Branch"
    $headSha = $ref.object.sha
} catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    if ($status -eq 409) {
        Write-Host "Repository is empty; creating the initial commit via the contents API"
        $readme = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("# spotify-ios6`n"))
        Invoke-GH PUT "/contents/README.md" @{ message = 'Initial commit'; content = $readme; branch = $Branch } | Out-Null
    } elseif ($status -eq 404) {
        Write-Host "Branch '$Branch' does not exist; creating it from the default branch"
        $def = (Invoke-GH GET "").default_branch
        $dref = Invoke-GH GET "/git/ref/heads/$def"
        Invoke-GH POST "/git/refs" @{ ref = "refs/heads/$Branch"; sha = $dref.object.sha } | Out-Null
    } else {
        throw
    }
    $ref = Invoke-GH GET "/git/ref/heads/$Branch"
    $headSha = $ref.object.sha
}
$commit = Invoke-GH GET "/git/commits/$headSha"
$baseTree = $commit.tree.sha
$remote = @{}
$tree = Invoke-GH GET "/git/trees/$baseTree`?recursive=1"
foreach ($e in $tree.tree) { if ($e.type -eq 'blob') { $remote[$e.path] = $e.sha } }
Write-Host "Head $($headSha.Substring(0,7)), $($remote.Count) remote files"

# 2. Local files: read and check everything first, upload afterwards
$rootFull = (Resolve-Path $Root).Path
# A folder that is itself a copy of the project (some tools copy a workspace into the folder) is never pushed.
$nestedCopies = @(Get-ChildItem -Path $rootFull -Directory -Force |
    Where-Object { (Test-Path (Join-Path $_.FullName 'control')) -and (Test-Path (Join-Path $_.FullName 'Makefile')) } |
    ForEach-Object { $_.Name })
foreach ($n in $nestedCopies) { Write-Warning "Skipping '$n/': it looks like a copy of the project inside itself" }

$local = New-Object System.Collections.ArrayList
Get-ChildItem -Path $rootFull -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
    if (Test-Ignored $rel) { return }
    if ($nestedCopies -contains ($rel -split '/')[0]) { return }
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    if ([regex]::IsMatch([Text.Encoding]::ASCII.GetString($bytes), $SecretPattern)) {
        throw "Refusing to push '$rel': it looks like it contains a token or a private key. Nothing was uploaded."
    }
    [void]$local.Add(@{ rel = $rel; bytes = $bytes; sha = (Get-GitBlobSha $bytes) })
}

$entries = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($f in $local) {
    $seen[$f.rel] = $true
    if ($remote.ContainsKey($f.rel) -and $remote[$f.rel] -eq $f.sha) { continue }
    Write-Host "  + $($f.rel)"
    if ($DryRun) { [void]$entries.Add(@{ path = $f.rel }); continue }
    $blob = Invoke-GH POST "/git/blobs" @{ content = [Convert]::ToBase64String($f.bytes); encoding = 'base64' }
    if ($blob.sha -ne $f.sha) { Write-Warning "sha mismatch for $($f.rel) (local $($f.sha), remote $($blob.sha))" }
    [void]$entries.Add(@{ path = $f.rel; mode = '100644'; type = 'blob'; sha = $blob.sha })
}
foreach ($p in $remote.Keys) {
    if (-not $seen.ContainsKey($p) -and -not (Test-Ignored $p)) {
        [void]$entries.Add(@{ path = $p; mode = '100644'; type = 'blob'; sha = $null })
        Write-Host "  - $p"
    }
}
if ($entries.Count -eq 0) { Write-Host "Nothing to push."; exit 0 }
if ($DryRun) { Write-Host "Dry run: $($entries.Count) changes, nothing was pushed."; exit 0 }

# 3. Tree, commit, ref
$newTree = Invoke-GH POST "/git/trees" @{ base_tree = $baseTree; tree = $entries.ToArray() }
$newCommit = Invoke-GH POST "/git/commits" @{ message = $Message; tree = $newTree.sha; parents = @($headSha) }
Invoke-GH PATCH "/git/refs/heads/$Branch" @{ sha = $newCommit.sha; force = $false } | Out-Null
Write-Host "Pushed $($entries.Count) changes as $($newCommit.sha.Substring(0,7)): https://github.com/$Repo/commit/$($newCommit.sha)"
