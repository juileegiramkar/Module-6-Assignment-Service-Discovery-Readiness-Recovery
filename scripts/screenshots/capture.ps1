param(
    [Parameter(Mandatory)] [string[]]$Scenes,       # e.g. replicas  or  watch,delete
    [Parameter(Mandatory)] [string[]]$OutFiles,     # one PNG per scene, same order
    [int[]]$Rows = @(),
    [int]$Cols = 120,
    [int]$DelayBetween = 0                          # seconds between starting windows
)
# Opens a real console window (conhost + Windows PowerShell) per scene, waits until
# the scene has finished running its kubectl commands, then saves a PNG of exactly
# that window via PrintWindow (works even if another window overlaps it).
#
# Windows only. Scenes run in this order (each one changes the cluster state):
#   .\capture.ps1 -Scenes replicas        -OutFiles ..\..\screenshots\01-both-replicas.png -Rows 44
#   .\capture.ps1 -Scenes unready         -OutFiles ..\..\screenshots\02-readiness-failure.png
#   .\capture.ps1 -Scenes unready-traffic -OutFiles ..\..\screenshots\03-unready-pod-gets-no-traffic.png
#   .\capture.ps1 -Scenes recovery        -OutFiles ..\..\screenshots\04-readiness-recovery.png
#   .\capture.ps1 -Scenes watch,delete    -OutFiles ..\..\screenshots\05b-pod-watch-during-deletion.png,..\..\screenshots\05-pod-deletion-and-replacement.png -Rows 20,46 -DelayBetween 2
#   .\capture.ps1 -Scenes client          -OutFiles ..\..\screenshots\06-client-kept-working.png
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
}
"@
[Win]::SetProcessDPIAware() | Out-Null

$here = Split-Path $MyInvocation.MyCommand.Path
$started = @()
for ($i = 0; $i -lt $Scenes.Count; $i++) {
    $scene = $Scenes[$i]
    $marker = Join-Path $here "marker-$scene.txt"
    Remove-Item $marker -ErrorAction SilentlyContinue
    $r = if ($Rows.Count -gt $i) { $Rows[$i] } else { 46 }
    $argLine = "powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$here\scene.ps1`" -Scene $scene -Marker `"$marker`" -Cols $Cols -Rows $r"
    $p = Start-Process conhost.exe -ArgumentList $argLine -PassThru
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    if (-not (Test-Path $marker)) { throw "scene $scene did not finish" }
    $outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFiles[$i])
    $started += [pscustomobject]@{ Scene = $scene; Proc = $p; Hwnd = [IntPtr][long](Get-Content $marker); Out = $outPath }
    if ($DelayBetween) { Start-Sleep -Seconds $DelayBetween }
}
Start-Sleep -Seconds 2   # let the last output and the prompt paint

foreach ($s in $started) {
    $h = $s.Hwnd
    [Win]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x0001 -bor 0x0004) | Out-Null   # move to 0,0, keep size
    Start-Sleep -Milliseconds 500
    $wr = New-Object Win+RECT; [Win]::GetWindowRect($h, [ref]$wr) | Out-Null
    $fr = New-Object Win+RECT; [Win]::DwmGetWindowAttribute($h, 9, [ref]$fr, 16) | Out-Null   # visible frame
    $w = $wr.Right - $wr.Left; $hgt = $wr.Bottom - $wr.Top
    $bmp = New-Object System.Drawing.Bitmap($w, $hgt)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc(); [Win]::PrintWindow($h, $hdc, 2) | Out-Null; $g.ReleaseHdc($hdc); $g.Dispose()
    $crop = New-Object System.Drawing.Rectangle(($fr.Left - $wr.Left), ($fr.Top - $wr.Top), ($fr.Right - $fr.Left), ($fr.Bottom - $fr.Top))
    $out = $bmp.Clone($crop, $bmp.PixelFormat)
    $out.Save($s.Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $out.Dispose(); $bmp.Dispose()
    "saved $($s.Out)  ($($crop.Width)x$($crop.Height))"
}
foreach ($s in $started) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($s.Proc.Id)" | ForEach-Object {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($_.ProcessId)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $s.Proc.Id -Force -ErrorAction SilentlyContinue
}
