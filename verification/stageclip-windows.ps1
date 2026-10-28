param([string]$Version = '1.2.4', [ValidateSet('x64','arm64')][string]$Arch = 'x64', [switch]$PublicFeed)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid version' }
$root = 'C:\stageclip-update-test'
$evidence = "$root\evidence"
New-Item -ItemType Directory -Force $evidence | Out-Null
Start-Transcript "$evidence\verification.txt"
$nativeArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if ($nativeArch -ne $Arch) { throw "Expected native $Arch, got $nativeArch" }
Write-Host "Native Windows architecture: $nativeArch"
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
function VerifyMachine($file) {
    $bytes = [IO.File]::ReadAllBytes($file)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    $machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
    $expected = if ($Arch -eq 'arm64') { 0xAA64 } else { 0x8664 }
    if ($machine -ne $expected) { throw "Wrong executable architecture: $file ($machine)" }
}
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
    Fetch "$base/stageclip-windows-v1.2.2/StageClip-1.2.2-win-$Arch.zip" "$root\baseline.zip"
    if (-not $PublicFeed) {
        Fetch "$base/stageclip-windows-v$Version/StageClip-$Version-win-$Arch.zip" "$root\StageClip-$Version-win-$Arch.zip"
        Fetch "$base/stageclip-windows-v$Version/stageclip-windows-update-test-$Arch.feed.json" "$root\feed.json"
    }
    Fetch "$base/stageclip-windows-v$Version/StageClip-$Version-win-$Arch-setup.exe" "$root\setup.exe"
    Fetch "$base/stageupdater-windows-v1.0.2/StageUpdater-Setup-$Arch.exe" "$root\updater-setup.exe"

    # The fixture is signed with the production feed key; it contains only this product and local test assets.
    New-Item 'HKLM:\Software\StageUpdater' -Force | Out-Null
    $feedUrl = if ($PublicFeed) { 'https://nbase-io.github.io/stage-updates/feed.json' } else { 'file:///C:/stageclip-update-test/feed.json' }
    Set-ItemProperty 'HKLM:\Software\StageUpdater' FeedUrl $feedUrl
    Write-Host "Update feed: $feedUrl"
    $setup = Start-Process "$root\updater-setup.exe" -ArgumentList '/S' -Wait -PassThru
    if ($setup.ExitCode -ne 0 -or -not (Test-Path $updater)) { throw 'Updater install failed' }
    WaitFor 'StageUpdater service running' { (Get-Service StageUpdater).Status -eq 'Running' } 30
    VerifyMachine $updater
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
    VerifyMachine $app
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
    VerifyMachine $app
    WaitFor 'setup relaunches StageClip' { @(Get-Process StageClip -ErrorAction SilentlyContinue).Count -gt 0 }
    if ((Get-Content "$env:LOCALAPPDATA\StageClip\update-preservation-check.txt") -ne 'preserve this data') { throw 'App data lost' }
    if ([version]$Version -ge [version]'1.2.4') {
        StopClip
        Remove-Item "$env:LOCALAPPDATA\StageClip\settings.json" -ErrorAction SilentlyContinue
        $cold = Start-Process $app -ArgumentList '--background' -PassThru
        Start-Sleep 5
        Start-Process $app -ArgumentList '--stageupdater-quit' -Wait
        if (-not $cold.WaitForExit(30000)) { throw 'Never-shown new app did not quit' }
        Write-Host 'PASS: fresh background launch quits without saving undefined window coordinates'

        # The setup can also recover a 1.2.2 login-only installation affected by the old quit bug.
        RestoreBaseline
        Remove-Item "$env:LOCALAPPDATA\StageClip\settings.json" -ErrorAction SilentlyContinue
        $legacy = Start-Process $app -ArgumentList '--background' -PassThru
        Start-Sleep 5
        $repair = Start-Process "$root\setup.exe" -ArgumentList '/S', '/STAGECLIPUPDATE' -PassThru
        if (-not $repair.WaitForExit(120000) -or $repair.ExitCode -ne 0) { throw 'Legacy cold-start setup recovery failed' }
        if (-not $legacy.HasExited) { throw 'Legacy app remains after setup recovery' }
        WaitFor 'setup recovers old never-shown app and relaunches fixed version' {
            (VersionOf $app) -eq $Version -and @(Get-Process StageClip -ErrorAction SilentlyContinue).Count -gt 0
        }
        if ((Get-Content "$env:LOCALAPPDATA\StageClip\update-preservation-check.txt") -ne 'preserve this data') { throw 'App data lost during recovery' }
    }
    @{ version = VersionOf $app; architecture = $nativeArch; updaterService = (Get-Service StageUpdater).Status.ToString();
       idleUpdate = 'passed'; setupUpdate = 'passed'; dataPreserved = $true; publicFeed = [bool]$PublicFeed } |
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
