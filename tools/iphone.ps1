# Helpers for talking to the jailbroken iPhone (rootless jailbreak: Dopamine, palera1n) over SSH (dot-source this file).
#   . .\tools\iphone.ps1
#   Invoke-IPhone 'uname -a'
#   Install-IPhonePackage -DebPath .\packages\com.samcejko.spot6_0.0.0_iphoneos-arm64.deb   (needs root)
#   Get-IPhoneSnapshot -Name home          # launches the app, asks it for a picture of its windows, fetches the PNG
#   Send-IPhoneCommand 'press?title=Chat'  # one of the app's debug URL commands (see the app delegate)
#   Get-IPhoneCrashLogs
# The address comes from tools/local.json ("iphone") or -IPhoneHost, the user from local.json ("iphoneUser", default
# root); the key is ~/.ssh/iphone (ssh-keygen -t ed25519, then append the .pub line to ~/.ssh/authorized_keys of that
# user on the phone: /var/jb/var/mobile/.ssh for mobile, /var/root/.ssh for root; the stock password is alpine).
# dpkg needs root; everything else (launching, snapshots, crash logs) works as mobile too.

$AppName = 'Spot6'
$AppBundleId = 'com.samcejko.spot6'
$AppUrlScheme = 'spot6'   # '' when the app has no URL scheme (no debug commands, no snapshots)

$script:IPhoneKey = Join-Path $env:USERPROFILE '.ssh\iphone'
$script:IPhoneDefaultHost = ''
$script:IPhoneUser = 'root'
$script:IPhoneLocalCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $script:IPhoneLocalCfg) {
    try {
        $c = Get-Content $script:IPhoneLocalCfg -Raw | ConvertFrom-Json
        if ($c.iphone) { $script:IPhoneDefaultHost = $c.iphone }
        if ($c.iphoneUser) { $script:IPhoneUser = $c.iphoneUser }
    } catch {}
}
# Preamble of every script: the jailbreak's tools on the PATH; uiopen talks to mobile's SpringBoard, so root runs it as mobile
$script:IPhonePath = @'
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:$PATH
if [ "$(id -u)" = 0 ]; then uiopen() { sudo -n -u mobile /var/jb/usr/bin/uiopen "$@"; }; fi
'@

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

function Resolve-IPhoneUser([string]$User) { if ($User) { $User } else { $script:IPhoneUser } }

# Runs one command line on the iPhone and returns stdout+stderr as plain strings (never throws on stderr output).
function Invoke-IPhone {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$IPhoneHost = '', [string]$User = '')
    $ErrorActionPreference = 'Continue'
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $User = Resolve-IPhoneUser $User
    $sshArgs = Get-IPhoneSshArgs
    & ssh.exe @sshArgs "$User@$IPhoneHost" $Command 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
}

# Runs a whole shell script on the iPhone (sent through stdin, so quotes and $ need no escaping). cmd does the redirect:
# a PowerShell pipe into ssh would prepend a UTF-8 BOM, which sh takes for a command name.
function Invoke-IPhoneScript {
    param([Parameter(Mandatory = $true)][string]$Script, [string]$IPhoneHost = '', [string]$User = '')
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $User = Resolve-IPhoneUser $User
    $tmp = Join-Path $env:TEMP ("iphone-" + [guid]::NewGuid().ToString('n') + ".sh")
    [IO.File]::WriteAllText($tmp, ($script:IPhonePath + "`n" + $Script).Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $keyArg = if (Test-Path $script:IPhoneKey) { "-i `"$($script:IPhoneKey)`" -oBatchMode=yes" } else { '' }
    try {
        cmd /c "ssh $keyArg -oStrictHostKeyChecking=accept-new -oConnectTimeout=10 -oLogLevel=ERROR $User@$IPhoneHost sh -s < `"$tmp`" 2>&1" | ForEach-Object { "$_" }
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Copy-ToIPhone {
    param([Parameter(Mandatory = $true)][string]$LocalPath, [Parameter(Mandatory = $true)][string]$RemotePath, [string]$IPhoneHost = '', [string]$User = '')
    $ErrorActionPreference = 'Continue'
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $User = Resolve-IPhoneUser $User
    $sshArgs = Get-IPhoneSshArgs
    & scp.exe -O @sshArgs $LocalPath "${User}@${IPhoneHost}:$RemotePath" 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $LocalPath" }
}

function Copy-FromIPhone {
    param([Parameter(Mandatory = $true)][string]$RemotePath, [Parameter(Mandatory = $true)][string]$LocalPath, [string]$IPhoneHost = '', [string]$User = '')
    $ErrorActionPreference = 'Continue'
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $User = Resolve-IPhoneUser $User
    $sshArgs = Get-IPhoneSshArgs
    & scp.exe -O @sshArgs -r "${User}@${IPhoneHost}:$RemotePath" $LocalPath 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $RemotePath" }
}

# Installs the arm64 .deb (rootless: /var/jb) with dpkg and tells the home screen about it. Root only: dpkg writes
# /var/jb/Applications, and SpringBoard launches nothing registered from a folder of mobile's.
function Install-IPhonePackage {
    param([Parameter(Mandatory = $true)][string]$DebPath, [string]$IPhoneHost = '')
    if (-not (Test-Path $DebPath)) { throw "no such file: $DebPath" }
    $IPhoneHost = Resolve-IPhoneHost $IPhoneHost
    $who = Invoke-IPhone -IPhoneHost $IPhoneHost -Command 'id -u' | Select-Object -Last 1
    if ("$who".Trim() -ne '0') { throw "Install-IPhonePackage needs root on the phone (got uid '$who'): authorize ~/.ssh/iphone.pub in /var/root/.ssh/authorized_keys and set iphoneUser to root" }
    $remote = "/tmp/$($AppName.ToLower()).deb"
    Write-Host "Installing $DebPath on $IPhoneHost ..."
    Copy-ToIPhone -IPhoneHost $IPhoneHost -LocalPath $DebPath -RemotePath $remote
    $out = Invoke-IPhoneScript -IPhoneHost $IPhoneHost -Script @"
killall $AppName 2>/dev/null
dpkg -i $remote 2>&1 && { uicache -p /var/jb/Applications/$AppName.app 2>/dev/null || uicache -a 2>/dev/null; echo DEB_OK; }
rm -f $remote
"@
    Write-Host ($out -join "`n")
    if (($out -join "`n") -notmatch 'DEB_OK') { throw 'dpkg failed' }
    Write-Host "Done. Tap the $AppName icon on the iPhone (or Start-IPhoneApp)."
}

# The app's data container (made at its first launch); '' when it never ran
function Get-IPhoneContainer {
    param([string]$IPhoneHost = '')
    $out = Invoke-IPhoneScript -IPhoneHost $IPhoneHost -Script @"
c=`$(uicache -i $AppBundleId 2>/dev/null | sed -n 's/^Container Path: //p')
if [ -n "`$c" ] && [ -d "`$c" ]; then echo "`$c"; else
  for d in /var/mobile/Containers/Data/Application/*; do
    grep -q '$AppBundleId' "`$d/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null && echo "`$d"
  done
fi
"@
    "$(@($out | Where-Object { $_ -like '/var/mobile/*' -or $_ -like '/private/var/mobile/*' } | Select-Object -Last 1))".Trim()
}

function Start-IPhoneApp {
    param([string]$IPhoneHost = '', [int]$WaitSeconds = 5)
    Invoke-IPhoneScript -IPhoneHost $IPhoneHost -Script "uiopen --bundleid $AppBundleId; sleep $WaitSeconds; ps -A -o pid,rss,comm | grep '/$AppName.app/' | grep -v grep || echo 'NOT RUNNING'"
}

function Stop-IPhoneApp { param([string]$IPhoneHost = '') Invoke-IPhone -IPhoneHost $IPhoneHost -Command "killall $AppName 2>/dev/null; echo stopped" }

function Test-IPhoneAppRunning {
    param([string]$IPhoneHost = '')
    $out = Invoke-IPhone -IPhoneHost $IPhoneHost -Command "ps -A -o comm | grep '/$AppName.app/' | grep -v grep | head -n 1"
    [bool](($out -join '') -match [regex]::Escape("$AppName.app"))
}

# Creates the "debug" file in the app's Documents, the switch for its URL commands (snapshot, press, tab, ...)
function Enable-IPhoneDebug {
    param([string]$IPhoneHost = '')
    $container = Get-IPhoneContainer -IPhoneHost $IPhoneHost
    if (-not $container) { throw "no data container for $AppBundleId yet: launch the app once (Start-IPhoneApp)" }
    $null = Invoke-IPhoneScript -IPhoneHost $IPhoneHost -Script "mkdir -p '$container/Documents'; [ -f '$container/Documents/debug' ] && echo had || { echo on > '$container/Documents/debug'; echo made; }"
    $container
}

# Sends one of the app's URL commands, e.g. 'press?title=Settings', 'tab?n=2', 'stats'
function Send-IPhoneCommand {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$IPhoneHost = '', [int]$WaitSeconds = 2)
    if (-not $AppUrlScheme) { throw "$AppName has no URL scheme" }
    Invoke-IPhoneScript -IPhoneHost $IPhoneHost -Script "uiopen --url '${AppUrlScheme}:$Command'; sleep $WaitSeconds; echo sent"
}

# A picture of the app's windows (its own snapshot command: <scheme>:snapshot writes tmp/screen.png in the container),
# saved as packages\shots-iphone\<Name>.png; launches the app and enables the debug switch when needed.
function Get-IPhoneSnapshot {
    param([string]$Name = 'shot', [string]$IPhoneHost = '', [string]$OutDir = '', [switch]$NoLaunch)
    if (-not $AppUrlScheme) { throw "$AppName has no URL scheme, so no snapshot command" }
    if (-not $OutDir) { $OutDir = Join-Path (Get-Location) 'packages\shots-iphone' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    if (-not $NoLaunch -and -not (Test-IPhoneAppRunning -IPhoneHost $IPhoneHost)) {
        $null = Start-IPhoneApp -IPhoneHost $IPhoneHost -WaitSeconds 6
    }
    $container = Get-IPhoneContainer -IPhoneHost $IPhoneHost
    if (-not $container) { throw "no data container for ${AppBundleId}: the app did not launch (check Get-IPhoneCrashLogs)" }
    $flag = Invoke-IPhoneScript -IPhoneHost $IPhoneHost -Script "[ -f '$container/Documents/debug' ] && echo had || { mkdir -p '$container/Documents'; echo on > '$container/Documents/debug'; echo made; }"
    if (($flag -join '') -match 'made') {
        # the app checks the file at each command, no relaunch needed; a moment for the first launch to settle
        Start-Sleep -Seconds 1
    }
    $out = Invoke-IPhoneScript -IPhoneHost $IPhoneHost -Script @"
rm -f '$container/tmp/screen.png'
uiopen --url '${AppUrlScheme}:snapshot'
i=0; while [ `$i -lt 20 ] && [ ! -f '$container/tmp/screen.png' ]; do sleep 0.25; i=`$((i+1)); done
sleep 0.5
ls -la '$container/tmp/screen.png' 2>&1
"@
    $local = Join-Path $OutDir "$Name.png"
    Remove-Item $local -ErrorAction SilentlyContinue
    if (($out -join '') -notmatch 'screen\.png' -or ($out -join '') -match 'No such file') { throw "no snapshot written: $($out -join ' | ') (is the app running? debug file at $container/Documents/debug)" }
    Copy-FromIPhone -IPhoneHost $IPhoneHost -RemotePath "$container/tmp/screen.png" -LocalPath $local
    Get-Item $local
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
