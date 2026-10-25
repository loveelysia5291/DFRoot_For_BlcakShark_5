# DFRoot LSPosed white-screen diagnostics over ADB.
#
# Usage (PowerShell, phone connected and USB debugging authorized):
#   .\debug-lsposed-adb.ps1
#   .\debug-lsposed-adb.ps1 -Serial 1234567890
#
# The phone must have root (Magisk/KernelSU) and `su` available.

param(
    [string]$Serial = ""
)

$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "debug-lsposed.sh"
if (!(Test-Path $script)) {
    throw "debug-lsposed.sh not found next to this script: $script"
}

$adbCmd = Get-Command adb -ErrorAction SilentlyContinue
if ($null -eq $adbCmd) {
    throw "adb not found in PATH. Install Android platform-tools or run the .sh script on the phone."
}

$adbArgs = @()
if ($Serial -ne "") {
    $adbArgs += @("-s", $Serial)
}

Write-Host "[*] adb devices"
& adb @adbArgs devices

Write-Host "[*] pushing diagnostic script"
& adb @adbArgs push $script /data/local/tmp/debug-lsposed.sh

Write-Host "[*] running diagnostic script as root (may take 30-60s)"
& adb @adbArgs shell "su -c 'sh /data/local/tmp/debug-lsposed.sh'"

Write-Host "[*] locating newest archive"
$remote = ((& adb @adbArgs shell "ls -t /sdcard/Download/lsposed-debug-*.tar.gz 2>/dev/null | head -n 1") -join "`n").Trim()
if ($remote -ne "") {
    $dest = Join-Path $PSScriptRoot (Split-Path $remote -Leaf)
    Write-Host "[*] pulling $remote"
    & adb @adbArgs pull $remote $dest
    Write-Host "[*] archive: $dest"
} else {
    $remoteDir = ((& adb @adbArgs shell "ls -td /sdcard/Download/lsposed-debug-* 2>/dev/null | head -n 1") -join "`n").Trim()
    if ($remoteDir -ne "") {
        $dest = Join-Path $PSScriptRoot (Split-Path $remoteDir -Leaf)
        Write-Host "[*] archive missing; pulling folder $remoteDir"
        & adb @adbArgs pull $remoteDir $dest
        Write-Host "[*] folder: $dest"
    } else {
        throw "No diagnostic output found on the phone."
    }
}

Write-Host "[*] done. Share the pulled archive/folder."
