# Helpers for talking to the jailbroken iPhone (rootless jailbreak: palera1n, Dopamine) over SSH (dot-source this file).
#   . .\tools\iphone.ps1
#   Invoke-IPhone 'uname -a'
#   Install-IPhonePackage -DebPath .\packages\com.samcejko.aichat_0.3.0_iphoneos-arm64.deb
#   Get-IPhoneCrashLogs
# The address comes from tools/local.json ("iphone") or -IPhoneHost; the key is ~/.ssh/iphone (ssh-keygen -t ed25519,
# then append the .pub line to /var/root/.ssh/authorized_keys on the phone; the stock password is alpine).

$AppName = 'Spot6'

$script:IPhoneKey = Join-Path $env:USERPROFILE '.ssh\iphone'
$script:IPhoneDefaultHost = ''
$script:IPhoneLocalCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $script:IPhoneLocalCfg) {
    try {
        $c = Get-Content $script:IPhoneLocalCfg -Raw | ConvertFrom-Json
        if ($c.iphone) { $script:IPhoneDefaultHost = $c.iphone }
    } catch {}
}

function Get-IPhoneSshArgs {
    $args = @('-oStrictHostKeyChecking=accept-new', '-oConnectTimeout=10', '-oLogLevel=ERROR', '-oServerAliveInterval=5', '-oServerAliveCountMax=4')
    if (Test-Path $script:IPhoneKey) { $args += @('-i', $script:IPhoneKey, '-oBatchMode=yes') }
    $args
}

function Resolve-IPhoneHost([string]$IPhoneHost) {
    if (-not $IPhoneHost) { $IPhoneHost = $script:IPhoneDefaultHost }
    if (-not $IPhoneHost) { throw 'No iPhone address: pass -IPhoneHost or set "iphone" in tools/local.json' }
    $IPhoneHost
}

# Runs a command on the iPhone and returns stdout+stderr as plain strings (never throws on stderr output).
function Invoke-IPhone {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$IPhoneHost = '')
    $ErrorActionPreference = 'Continue'
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $sshArgs = Get-IPhoneSshArgs
    & ssh.exe @sshArgs "root@$IPhoneHost" $Command 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
}

function Copy-ToIPhone {
    param([Parameter(Mandatory = $true)][string]$LocalPath, [Parameter(Mandatory = $true)][string]$RemotePath, [string]$IPhoneHost = '')
    $ErrorActionPreference = 'Continue'
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $sshArgs = Get-IPhoneSshArgs
    & scp.exe -O @sshArgs $LocalPath "root@${IPhoneHost}:$RemotePath" 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $LocalPath" }
}

function Copy-FromIPhone {
    param([Parameter(Mandatory = $true)][string]$RemotePath, [Parameter(Mandatory = $true)][string]$LocalPath, [string]$IPhoneHost = '')
    $ErrorActionPreference = 'Continue'
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $sshArgs = Get-IPhoneSshArgs
    & scp.exe -O @sshArgs -r "root@${IPhoneHost}:$RemotePath" $LocalPath 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $RemotePath" }
}

# Installs the arm64 .deb (rootless: /var/jb) with dpkg and tells the home screen about it
function Install-IPhonePackage {
    param([Parameter(Mandatory = $true)][string]$DebPath, [string]$IPhoneHost = '')
    if (-not (Test-Path $DebPath)) { throw "no such file: $DebPath" }
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $remote = "/tmp/$($AppName.ToLower()).deb"
    Write-Host "Installing $DebPath on $IPhoneHost ..."
    Invoke-IPhone -IPhoneHost $IPhoneHost -Command "killall $AppName 2>/dev/null; echo stopped" | Out-Null
    Copy-ToIPhone -IPhoneHost $IPhoneHost -LocalPath $DebPath -RemotePath $remote
    $out = Invoke-IPhone -IPhoneHost $IPhoneHost -Command "export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:`$PATH; dpkg -i $remote 2>&1 && { uicache -p /var/jb/Applications/$AppName.app 2>/dev/null || uicache -a 2>/dev/null; echo DEB_OK; }" | Out-String
    Write-Host $out
    if ($out -notmatch 'DEB_OK') { throw 'dpkg failed' }
    Write-Host "Done. Tap the $AppName icon on the iPhone."
}

function Get-IPhoneCrashLogs {
    param([string]$IPhoneHost = '', [string]$OutDir = '')
    if (-not $OutDir) { $OutDir = Join-Path (Get-Location) 'packages\crashlogs-iphone' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $list = Invoke-IPhone -IPhoneHost $IPhoneHost -Command "ls -t /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep -i $AppName | sed -n '1,5p'"
    foreach ($f in (@($list) -join "`n" -split "`n" | Where-Object { $_.Trim() })) {
        $name = $f.Trim()
        Copy-FromIPhone -IPhoneHost $IPhoneHost -RemotePath "/var/mobile/Library/Logs/CrashReporter/$name" -LocalPath (Join-Path $OutDir $name)
        Write-Host "Fetched $name"
    }
    Get-ChildItem $OutDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# The app's NSLog lines of the last minutes (the unified log: oslog or log from the jailbreak's packages)
function Get-IPhoneLog {
    param([int]$Minutes = 5, [string]$IPhoneHost = '')
    Invoke-IPhone -IPhoneHost $IPhoneHost -Command "export PATH=/var/jb/usr/bin:/var/jb/bin:`$PATH; if command -v log >/dev/null 2>&1; then log show --last ${Minutes}m --predicate 'process == `"$AppName`"' --style compact 2>&1 | tail -n 200; elif command -v oslog >/dev/null 2>&1; then oslog 2>&1 | grep -i $AppName | tail -n 200; else echo 'no log tool: install oslog (procursus) on the phone'; fi"
}
