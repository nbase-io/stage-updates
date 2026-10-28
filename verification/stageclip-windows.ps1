param([string]$Version = '1.2.3')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid version' }
$root = 'C:\stageclip-update-test'
$evidence = "$root\evidence"
New-Item -ItemType Directory -Force $evidence | Out-Null
Start-Transcript "$evidence\verification.txt"
$base = 'https://github.com/nbase-io/stage-updates/releases/download'
$env:STAGECLIP_API_URL = 'http://127.0.0.1:1'
$install = "$env:LOCALAPPDATA\Programs\StageClip"
$app = "$install\StageClip.exe"
$updater = 'C:\Program Files\StageUpdater\StageUpdater.exe'

function Fetch($url, $destination) {
    Invoke-WebRequest $url -OutFile $destination
    if ((Get-Item $destination).Length -eq 0) { throw "Empty file: $url" }
}
function VersionOf($file) { return (Get-Item $file).VersionInfo.ProductVersion.Split('+')[0] }
function WaitFor($description, [scriptblock]$condition, $seconds = 120) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) {
        if (& $condition) { Write-Host "PASS: $description"; return }
        Start-Sleep 1
    }
    throw "Timed out: $description"
}
function StopClip {
    if (Test-Path $app) { Start-Process $app -ArgumentList '--stageupdater-quit' -Wait }
    WaitFor 'StageClip graceful shutdown' { -not (Get-Process StageClip -ErrorAction SilentlyContinue) } 40
    Start-Sleep 2
}
function RestoreBaseline {
    if (Test-Path $install) { Remove-Item $install -Recurse -Force }
    Expand-Archive "$root\baseline.zip" "$env:LOCALAPPDATA\Programs" -Force
    if ((VersionOf $app) -ne '1.2.2') { throw 'Baseline version mismatch' }
    # 1.2.2 saves NaN when quitting a never-shown window. Model an existing user's previously opened window.
    New-Item "$env:LOCALAPPDATA\StageClip" -ItemType Directory -Force | Out-Null
    '{"WindowBounds":{"Left":100,"Top":100,"Width":1100,"Height":760,"Maximized":false}}' |
        Set-Content "$env:LOCALAPPDATA\StageClip\settings.json"
}

try {
    Fetch "$base/stageclip-windows-v1.2.2/StageClip-1.2.2-win-x64.zip" "$root\baseline.zip"
    Fetch "$base/stageclip-windows-v$Version/StageClip-$Version-win-x64.zip" "$root\StageClip-$Version-win-x64.zip"
    Fetch "$base/stageclip-windows-v$Version/StageClip-$Version-win-x64-setup.exe" "$root\setup.exe"
    Fetch "$base/stageclip-windows-v$Version/stageclip-windows-update-test.feed.json" "$root\feed.json"
    Fetch "$base/stageupdater-windows-v1.0.2/StageUpdater-Setup-x64.exe" "$root\updater-setup.exe"

    # The fixture is signed with the production feed key; it contains only this product and local test assets.
    New-Item 'HKLM:\Software\StageUpdater' -Force | Out-Null
    Set-ItemProperty 'HKLM:\Software\StageUpdater' FeedUrl 'file:///C:/stageclip-update-test/feed.json'
    $setup = Start-Process "$root\updater-setup.exe" -ArgumentList '/S' -Wait -PassThru
    if ($setup.ExitCode -ne 0 -or -not (Test-Path $updater)) { throw 'Updater install failed' }
    WaitFor 'StageUpdater service running' { (Get-Service StageUpdater).Status -eq 'Running' } 30
    if (-not (Get-ItemProperty 'HKLM:\Software\Classes\stageupdater\shell\open\command')) { throw 'Missing protocol' }

    RestoreBaseline
    New-Item "$env:LOCALAPPDATA\StageClip" -ItemType Directory -Force | Out-Null
    Set-Content "$env:LOCALAPPDATA\StageClip\update-preservation-check.txt" 'preserve this data'
    $old = Start-Process $app -ArgumentList '--background' -PassThru
    Start-Sleep 5
    if ($old.HasExited) { throw 'Baseline did not stay running' }
    $event = $null
    $eventExists = [System.Threading.EventWaitHandle]::TryOpenExisting('StageClip.QuitForUpdate', [ref]$event)
    Write-Host "Baseline update quit event exists: $eventExists"
    if ($event) { $event.Dispose() }
    $quit = Start-Process $app -ArgumentList '--stageupdater-quit' -PassThru
    if (-not $quit.WaitForExit(30000)) { throw 'Quit command did not exit' }
    if (-not $old.WaitForExit(30000)) { throw 'Baseline does not honor the update quit request' }
    Write-Host 'PASS: old StageClip honors graceful update quit'
    $old = Start-Process $app -ArgumentList '--background' -PassThru
    Start-Sleep 5
    Start-Process $updater
    WaitFor 'signed-feed idle update installs new version' { (Test-Path $app) -and (VersionOf $app) -eq $Version }
    WaitFor 'updated StageClip restarts automatically' {
        @(Get-Process StageClip -ErrorAction SilentlyContinue | Where-Object Id -ne $old.Id).Count -gt 0
    }
    if (-not $old.HasExited) { throw 'Old StageClip still running' }
    Copy-Item "$env:LOCALAPPDATA\StageUpdater\state.json" "$evidence\idle-update-state.json"
    if ((Get-Content "$env:LOCALAPPDATA\StageClip\update-preservation-check.txt") -ne 'preserve this data') { throw 'App data lost' }

    # Also exercise the existing native-app fallback: setup waits for quit, replaces the app, and reopens it.
    Start-Process $updater -ArgumentList '--stageupdater-quit' -Wait
    StopClip
    RestoreBaseline
    $old = Start-Process $app -ArgumentList '--background' -PassThru
    Start-Sleep 5
    $setup = Start-Process "$root\setup.exe" -ArgumentList '/S', '/STAGECLIPUPDATE' -PassThru
    Start-Sleep 2
    Start-Process $app -ArgumentList '--stageupdater-quit' -Wait
    if (-not $old.WaitForExit(40000)) { throw 'Old StageClip did not quit for setup' }
    if (-not $setup.WaitForExit(120000)) { throw 'Setup timed out' }
    if ($setup.ExitCode -ne 0) { throw "Setup exit code $($setup.ExitCode)" }
    WaitFor 'setup installs requested version' { (Test-Path $app) -and (VersionOf $app) -eq $Version }
    WaitFor 'setup relaunches StageClip' { @(Get-Process StageClip -ErrorAction SilentlyContinue).Count -gt 0 }
    if ((Get-Content "$env:LOCALAPPDATA\StageClip\update-preservation-check.txt") -ne 'preserve this data') { throw 'App data lost' }
    @{ version = VersionOf $app; updaterService = (Get-Service StageUpdater).Status.ToString();
       idleUpdate = 'passed'; setupUpdate = 'passed'; dataPreserved = $true } |
        ConvertTo-Json | Set-Content "$evidence\result.json"
    Write-Host 'PASS: both real Windows update paths, restart, service and data preservation'
}
finally {
    Get-CimInstance Win32_Process | Where-Object Name -in 'StageClip.exe','StageUpdater.exe' |
        Select-Object ProcessId,CommandLine | ConvertTo-Json | Set-Content "$evidence\processes.json"
    Get-Process StageClip,StageUpdater -ErrorAction SilentlyContinue |
        Select-Object Id,MainWindowTitle,MainWindowHandle,Responding |
        ConvertTo-Json | Set-Content "$evidence\windows.json"
    if (Test-Path "$env:LOCALAPPDATA\StageUpdater\state.json") {
        Copy-Item "$env:LOCALAPPDATA\StageUpdater\state.json" "$evidence\final-state.json" -Force
    }
    Stop-Transcript
}
