param([switch]$RunTests, [switch]$Network, [switch]$Discovery)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$avd = 'D:\AndroidTV\GoogleAVD'
$adb = Join-Path $avd 'sdk\platform-tools\adb.exe'
$serial = 'emulator-5554'
$hostIP = '192.168.1.250'
$router = 'root@192.168.1.1'
if (-not (Test-Path $adb)) { throw 'Android SDK adb not found' }
if ((& $adb -s $serial get-state) -ne 'device') { throw 'Start the Android TV emulator first' }
if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $hostIP -ErrorAction SilentlyContinue)) { throw 'VMnet1 test address missing' }
& ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 $router 'ubus list sponsorblocktv.live'
if ($LASTEXITCODE -ne 0) { throw 'Router RPC unavailable' }
foreach ($pair in @(@(18008,8008),@(18009,8009),@(18443,8443))) {
    $local = "tcp:$($pair[0])"; $remote = "tcp:$($pair[1])"
    $forwards = @(& $adb forward --list)
    $existing = @($forwards | Where-Object { $_ -match "\s$([regex]::Escape($local))\s" })
    if ($existing.Count -gt 0) {
        if ($existing.Count -ne 1 -or $existing[0].Trim() -ne "$serial $local $remote") { throw "Conflicting ADB forward $local" }
    } else {
        & $adb -s $serial forward --no-rebind $local $remote
        if ($LASTEXITCODE -ne 0) { throw "ADB forward failed: $local" }
    }
}
$info = Invoke-RestMethod 'http://127.0.0.1:18008/setup/eureka_info' -TimeoutSec 5
if (-not $info.ssdp_udn) { throw 'Emulator Cast identity unavailable' }
& python -c "import zeroconf"
if ($LASTEXITCODE -ne 0) { throw 'Host Python zeroconf missing' }
$bridge = Join-Path $avd 'GoogleTV-LAN-Bridge.py'
$processes = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -like "*GoogleTV-LAN-Bridge.py*" })
if ($processes.Count -gt 1) { throw 'Multiple LAN bridge processes; inspect before continuing' }
if ($processes.Count -eq 0) {
    $proc = Start-Process -FilePath (Get-Command python).Source -ArgumentList '-u', $bridge -WorkingDirectory $avd -RedirectStandardOutput (Join-Path $avd 'lan-bridge.stdout.log') -RedirectStandardError (Join-Path $avd 'lan-bridge.stderr.log') -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { throw 'LAN bridge exited; inspect stderr log' }
}
$ports = @(Get-NetTCPConnection -LocalAddress $hostIP -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort)
foreach ($port in @(8008,8009,8443)) { if ($port -notin $ports) { throw "Bridge not listening on $hostIP port $port" } }
Write-Host "READY: emulator=$serial, LAN=$hostIP, router=$router"
if ($RunTests) {
    $runnerArgs = @((Join-Path $repo 'scripts\test-all.py'))
    if ($Network) { $runnerArgs += '--network' }
    if ($Discovery) { $runnerArgs += '--discovery' }
    & python @runnerArgs
    exit $LASTEXITCODE
}
