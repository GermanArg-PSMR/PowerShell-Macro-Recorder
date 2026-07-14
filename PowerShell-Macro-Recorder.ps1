Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$global:Recording = $false
$global:Events = New-Object System.Collections.ArrayList

$script:IgnoreNextClick = $false
$script:Executable = ""
$script:Arguments = ""

# --- MAIN INTERFACE CONFIGURATION ---
$form = New-Object Windows.Forms.Form
$form.Text = "PowerShell Macro Recorder"
$form.Size = New-Object Drawing.Size(700,500)
$form.StartPosition = "CenterScreen"
$form.BackColor = [Drawing.Color]::FromArgb(235, 236, 240) # Styled classic gray background
$form.Font = New-Object Drawing.Font("Segoe UI", 9)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

# Common button font style
$fontButtons = New-Object Drawing.Font("Segoe UI Black", 10, [Drawing.FontStyle]::Bold)

$lblExe = New-Object Windows.Forms.Label
$lblExe.Text = "Executable:"
$lblExe.Location = New-Object Drawing.Point(15,70)
$lblExe.AutoSize = $true
$lblExe.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
$lblExe.ForeColor = [Drawing.Color]::FromArgb(50, 50, 50)

$txtExe = New-Object Windows.Forms.TextBox
$txtExe.Location = New-Object Drawing.Point(95,67)
$txtExe.Size = New-Object Drawing.Size(515,23)
$txtExe.Text = "notepad.exe"

$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = "..."
$btnBrowse.Location = New-Object Drawing.Point(620,65)
$btnBrowse.Size = New-Object Drawing.Size(45,25)
$btnBrowse.FlatStyle = [Windows.Forms.FlatStyle]::Standard

$form.Controls.AddRange(@($lblExe, $txtExe, $btnBrowse))

$list = New-Object Windows.Forms.ListView
$list.View = "Details"
$list.FullRowSelect = $true
$list.GridLines = $true
$list.Location = New-Object Drawing.Point(15,110)
$list.Size = New-Object Drawing.Size(650,330)
$list.BorderStyle = [Windows.Forms.BorderStyle]::Fixed3D

$list.Columns.Add("Time",100) | Out-Null
$list.Columns.Add("Action",120) | Out-Null
$list.Columns.Add("X",80) | Out-Null
$list.Columns.Add("Y",80) | Out-Null
$list.Columns.Add("Window",260) | Out-Null
$list.Columns.Add("Size",120) | Out-Null

$form.Controls.Add($list)

$btnRecord = New-Object Windows.Forms.Button
$btnRecord.Text = "RECORD"
$btnRecord.Location = New-Object Drawing.Point(15,15)
$btnRecord.Size = New-Object Drawing.Size(110,38)
$btnRecord.FlatStyle = [Windows.Forms.FlatStyle]::Popup
$btnRecord.BackColor = [Drawing.Color]::FromArgb(214, 48, 49) # Carmine Red
$btnRecord.ForeColor = [Drawing.Color]::White
$btnRecord.Font = $fontButtons

$btnExport = New-Object Windows.Forms.Button
$btnExport.Text = "EXPORT"
$btnExport.Location = New-Object Drawing.Point(135,15)
$btnExport.Size = New-Object Drawing.Size(110,38)
$btnExport.FlatStyle = [Windows.Forms.FlatStyle]::Popup
$btnExport.BackColor = [Drawing.Color]::FromArgb(38, 166, 91) # Forest Green
$btnExport.ForeColor = [Drawing.Color]::White
$btnExport.Font = $fontButtons

$form.Controls.AddRange(@($btnRecord,$btnExport))

$script:StartTime = Get-Date
$script:LastButtons = 0

function Add-EventRow($Action,$X,$Y,$Window,$Process){
    $elapsed = [math]::Round(((Get-Date)-$script:StartTime).TotalMilliseconds)
    $obj = [PSCustomObject]@{
        Time=$elapsed
        Action=$Action
        Process=$Process
        Window=$Window
        X=$X
        Y=$Y
        Width=0
        Height=0
    }

    $global:Events.Add($obj) | Out-Null

    $item = New-Object Windows.Forms.ListViewItem($elapsed.ToString())
    [void]$item.SubItems.Add($Action)
    [void]$item.SubItems.Add($X.ToString())
    [void]$item.SubItems.Add($Y.ToString())
    [void]$item.SubItems.Add($Window)
    [void]$item.SubItems.Add("")

    $list.Items.Add($item) | Out-Null
}

$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*"
    if($dlg.ShowDialog() -eq "OK") { $txtExe.Text = $dlg.FileName }
})

# --- RECORD BUTTON ---
$btnRecord.Add_Click({
    $global:Events.Clear()
    $list.Items.Clear()

    $script:StartTime = Get-Date
    $global:Recording = $true

    if($txtExe.Text.Trim() -ne "")
    {
        try
        {
            if ($txtExe.Text.StartsWith("shell:")) {
                Start-Process "explorer.exe" -ArgumentList $txtExe.Text
            } else {
                if([string]::IsNullOrWhiteSpace($script:Arguments)) {
                    Start-Process -FilePath $txtExe.Text
                } else {
                    Start-Process -FilePath $txtExe.Text -ArgumentList $script:Arguments
                }
            }
        }
        catch
        {
            $global:Recording = $false
            [System.Windows.Forms.MessageBox]::Show("Could not start:`n`n$($txtExe.Text)`n`n$($_.Exception.Message)")
            return
        }
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Recording...`r`n`r`nPress OK to stop recording.",
        "Macro Recorder"
    )
	
    $global:Recording = $false
    Start-Sleep -Milliseconds 200
    $script:LastButtons = [System.Windows.Forms.Control]::MouseButtons
})

# --- EXPORTER ---
$btnExport.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter="PowerShell (*.ps1)|*.ps1"

    if($dlg.ShowDialog() -eq "OK") {
        $out = New-Object System.Collections.Generic.List[string]

        $out.Add('# Generated by PowerShell Macro Recorder')
        $out.Add('Add-Type -AssemblyName System.Windows.Forms')
        $out.Add('Add-Type -AssemblyName System.Drawing')
        $out.Add('')
        
        if ($txtExe.Text.Trim() -ne "") {
            $out.Add("# Start the application automatically")
            $exePath = $txtExe.Text.Replace('"', '""')
            if ($exePath.StartsWith("shell:")) {
                $out.Add("Start-Process ""explorer.exe"" -ArgumentList ""$exePath""")
            } else {
                if ([string]::IsNullOrWhiteSpace($script:Arguments)) {
                    $out.Add("Start-Process -FilePath ""$exePath""")
                } else {
                    $args = $script:Arguments.Replace('"', '""')
                    $out.Add("Start-Process -FilePath ""$exePath"" -ArgumentList ""$args""")
                }
            }
            $out.Add('')
        }

        $out.Add(@'
Add-Type @"
using System;
using System.Text;
using System.Drawing;
using System.Runtime.InteropServices;

public class MacroPlayer
{
    [DllImport("user32.dll")]
    static extern bool SetCursorPos(int X,int Y);

    [DllImport("user32.dll")]
    static extern void mouse_event(int flags,int dx,int dy,int data,int extra);

    [DllImport("user32.dll")]
    static extern IntPtr FindWindow(string lpClassName,string lpWindowName);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd,out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    const int LEFTDOWN = 0x02;
    const int LEFTUP   = 0x04;
    const int RIGHTDOWN = 0x08;
    const int RIGHTUP   = 0x10;

    public static void LeftClick(int x,int y)
    {
        SetCursorPos(x,y);
        mouse_event(LEFTDOWN,0,0,0,0);
        mouse_event(LEFTUP,0,0,0,0);
    }

    public static void RightClick(int x,int y)
    {
        SetCursorPos(x,y);
        mouse_event(RIGHTDOWN,0,0,0,0);
        mouse_event(RIGHTUP,0,0,0,0);
    }

    public static bool ExecuteAction(string action, string processName, string title, int x, int y)
    {
        IntPtr hwnd = IntPtr.Zero;
        try {
            foreach(var p in System.Diagnostics.Process.GetProcesses()) {
                if(!string.IsNullOrEmpty(processName) && string.Equals(p.ProcessName + ".exe", processName, StringComparison.OrdinalIgnoreCase)) {
                    hwnd = p.MainWindowHandle;
                    if(hwnd != IntPtr.Zero) break;
                }
                if(!string.IsNullOrEmpty(title) && p.MainWindowTitle.Contains(title)) {
                    hwnd = p.MainWindowHandle;
                    if(hwnd != IntPtr.Zero) break;
                }
            }
        } catch {}

        if(hwnd == IntPtr.Zero && !string.IsNullOrEmpty(title))
            hwnd = FindWindow(null, title);

        RECT r = new RECT { Left = 0, Top = 0 };
        if (hwnd != IntPtr.Zero) {
            GetWindowRect(hwnd, out r);
        }

        if(action == "LeftDown") {
            LeftClick(r.Left + x, r.Top + y);
        } else if(action == "RightDown") {
            RightClick(r.Left + x, r.Top + y);
        }
        return true;
    }
}
"@
'@)

        $out.Add('')
        $out.Add('$macroEvents = @(')

        $previousTime = 0
        foreach($e in $global:Events) {
            $delay = $e.Time - $previousTime
            if($delay -lt 0) { $delay = 0 }
            $previousTime = $e.Time

            $window = $e.Window.Replace('"', '""')
            $process = $e.Process.Replace('"', '""')

            $out.Add("    [PSCustomObject]@{Delay=$delay; Action=""$($e.Action)""; Process=""$process""; Window=""$window""; X=$($e.X); Y=$($e.Y)}")
        }
        $out.Add(')')
        $out.Add('')
        
        $out.Add(@'
foreach($event in $macroEvents) {
    if($event.Delay -gt 0) {
        Start-Sleep -Milliseconds $event.Delay
    }
    [MacroPlayer]::ExecuteAction($event.Action, $event.Process, $event.Window, $event.X, $event.Y) | Out-Null
}
'@)

        [System.IO.File]::WriteAllLines($dlg.FileName, $out, [System.Text.Encoding]::UTF8)
        [System.Windows.Forms.MessageBox]::Show("Macro exported successfully.")
    }
})

# --- NATIVE HELPER COMPILATION ---
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Drawing;

public class WinInfo
{
    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(Point Point);

    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
	
    [DllImport("user32.dll")]
    static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

    const uint GA_ROOT = 2;

    public static string WindowUnderMouse(int x, int y)
    {
        var hwnd = WindowFromPoint(new Point(x,y));
        if(hwnd != IntPtr.Zero) hwnd = GetAncestor(hwnd, GA_ROOT);

        var sb = new StringBuilder(512);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static int[] WindowPosition(int x, int y)
    {
        var hwnd = WindowFromPoint(new Point(x,y));
        if(hwnd != IntPtr.Zero) hwnd = GetAncestor(hwnd, GA_ROOT);

        RECT r;
        if(GetWindowRect(hwnd, out r)) {
            return new int[] { r.Left, r.Top, r.Right-r.Left, r.Bottom-r.Top };
        }
        return new int[] {0,0,0,0};
    }
	
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static string ProcessUnderMouse(int x, int y)
    {
        var hwnd = WindowFromPoint(new Point(x,y));
        if(hwnd != IntPtr.Zero) hwnd = GetAncestor(hwnd, GA_ROOT);

        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try {
            return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName + ".exe";
        } catch { return ""; }
    }
}
"@

# --- TIMER CAPTURE LOOP ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20

$timer.Add_Tick({
    if(-not $global:Recording){ return }

    $buttons = [System.Windows.Forms.Control]::MouseButtons

    if($buttons -ne $script:LastButtons){
        $script:LastButtons = $buttons
		
        if($buttons -eq [System.Windows.Forms.MouseButtons]::Left -or $buttons -eq [System.Windows.Forms.MouseButtons]::Right){
            $p = [System.Windows.Forms.Cursor]::Position
            $proc = [WinInfo]::ProcessUnderMouse($p.X,$p.Y)
            $title = [WinInfo]::WindowUnderMouse($p.X,$p.Y)

            Write-Host "Click detected -> Current Process: [$proc] | Window: [$title]" -ForegroundColor Cyan

            if ($txtExe.Text.Trim() -ne "") {
                if ($txtExe.Text.ToLower().StartsWith("shell:")) {
                    if ($proc.ToLower() -ne "applicationframehost.exe" -or [string]::IsNullOrWhiteSpace($title) -or $title -eq "Macro Recorder") {
                        return 
                    }
                } else {
                    $targetTargetExe = [System.IO.Path]::GetFileName($txtExe.Text).ToLower()
                    if ($proc.ToLower() -ne $targetTargetExe) {
                        return
                    }
                }
            }

            $pos = [WinInfo]::WindowPosition($p.X,$p.Y)
            $action = if($buttons -eq [System.Windows.Forms.MouseButtons]::Left) { "LeftDown" } else { "RightDown" }

            Write-Host "RECORDED SUCCESSFULLY! -> [$action] at X:$($p.X-$pos[0]) Y:$($p.Y-$pos[1])" -ForegroundColor Green

            Add-EventRow $action ($p.X-$pos[0]) ($p.Y-$pos[1]) $title $proc

            $last = $global:Events[$global:Events.Count-1]
            $last.Width = $pos[2]
            $last.Height = $pos[3]
            $list.Items[$list.Items.Count-1].SubItems[5].Text = "$($pos[2])x$($pos[3])"
        }
    }
})

# --- CLEAN EXIT CONTROL (HANDLING CTRL+C AND FORM CLOSING) ---

# 1. When the UI is closed, stop the Timer and exit cleanly.
$form.Add_FormClosing({
    $timer.Stop()
    $timer.Dispose()
    $global:Recording = $false
})

# 2. Capture if the user presses CTRL + C in the PowerShell console to close the app.
[System.Console]::TreatControlCAsInput = $false
$sub = [ConsoleCancelEventHandler] {
    param([object]$sender, [ConsoleCancelEventArgs]$e)
    $e.Cancel = $true # Cancel the native abrupt interruption so we can close cleanly
    
    # Safely close the form from the UI thread
    if ($form -and $form.Visible) {
        $form.Invoke([Action]{ 
            $timer.Stop()
            $timer.Dispose()
            $form.Close() 
        })
    }
}
[System.Console]::add_CancelKeyPress($sub)

# --- PROGRAM START ---
$timer.Start()
$form.Add_Shown({$form.Activate()})
[void]$form.ShowDialog()

# Unsubscribe from the event on exit to avoid leaking into the active console session
[System.Console]::remove_CancelKeyPress($sub)
