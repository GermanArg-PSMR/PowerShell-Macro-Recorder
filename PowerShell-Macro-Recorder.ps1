# ==============================================================================
# POWERSHELL MACRO RECORDER & PLAYER (Pure Clicks Edition)
# ==============================================================================
# This script records mouse clicks (Left/Right) relative to a target window
# and generates a reproducible PowerShell script to replay those actions.
# Includes a modern UI, process filtering, and clean console cancellation (Ctrl+C).
#
# NEW FEATURE: Console logging is now completely silent by default unless
# executed with the -v or -Verbose switch.
# ==============================================================================

param(
    [Alias("Verbose")]
    [switch]$v
)

# Store the parameter in the script scope so it can be accessed reliably inside GUI event handlers
$script:v = $v

# Load required .NET assemblies for building the Graphical User Interface (GUI)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- GLOBAL STATE VARIABLES ---
$global:Recording = $false                         # Tracks if the recorder is currently capturing clicks
$global:Events = New-Object System.Collections.ArrayList # Stores captured click events in memory

$script:IgnoreNextClick = $false
$script:Executable = ""
$script:Arguments = ""

# --- MAIN GRAPHICAL INTERFACE CONFIGURATION (WinForms) ---
$form = New-Object Windows.Forms.Form
$form.Text = "PowerShell Macro Recorder"
$form.Size = New-Object Drawing.Size(700,500)
$form.StartPosition = "CenterScreen"
$form.BackColor = [Drawing.Color]::FromArgb(235, 236, 240) # Styled classic Neumorphic light-gray background
$form.Font = New-Object Drawing.Font("Segoe UI", 9)
$form.FormBorderStyle = "FixedSingle"                      # Prevents window resizing
$form.MaximizeBox = $false                                 # Disables maximize button

# Shared font style for primary action buttons
$fontButtons = New-Object Drawing.Font("Segoe UI Black", 10, [Drawing.FontStyle]::Bold)

# Label for Executable path input
$lblExe = New-Object Windows.Forms.Label
$lblExe.Text = "Executable:"
$lblExe.Location = New-Object Drawing.Point(15,70)
$lblExe.AutoSize = $true
$lblExe.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
$lblExe.ForeColor = [Drawing.Color]::FromArgb(50, 50, 50)

# TextBox where the user enters the target executable (e.g., notepad.exe)
$txtExe = New-Object Windows.Forms.TextBox
$txtExe.Location = New-Object Drawing.Point(95,67)
$txtExe.Size = New-Object Drawing.Size(515,23)
$txtExe.Text = "notepad.exe"

# Browse button to look up local .exe files on disk
$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = "..."
$btnBrowse.Location = New-Object Drawing.Point(620,65)
$btnBrowse.Size = New-Object Drawing.Size(45,25)
$btnBrowse.FlatStyle = [Windows.Forms.FlatStyle]::Standard

$form.Controls.AddRange(@($lblExe, $txtExe, $btnBrowse))

# ListView layout to display recorded actions in real time
$list = New-Object Windows.Forms.ListView
$list.View = "Details"
$list.FullRowSelect = $true
$list.GridLines = $true
$list.Location = New-Object Drawing.Point(15,110)
$list.Size = New-Object Drawing.Size(650,330)
$list.BorderStyle = [Windows.Forms.BorderStyle]::Fixed3D

# Configure columns for the logged macro actions
$list.Columns.Add("Time (ms)", 100) | Out-Null
$list.Columns.Add("Action", 120) | Out-Null
$list.Columns.Add("X", 80) | Out-Null
$list.Columns.Add("Y", 80) | Out-Null
$list.Columns.Add("Window Title", 260) | Out-Null
$list.Columns.Add("Win Size", 120) | Out-Null

$form.Controls.Add($list)

# Record button (Carmine Red)
$btnRecord = New-Object Windows.Forms.Button
$btnRecord.Text = "RECORD"
$btnRecord.Location = New-Object Drawing.Point(15,15)
$btnRecord.Size = New-Object Drawing.Size(110,38)
$btnRecord.FlatStyle = [Windows.Forms.FlatStyle]::Popup
$btnRecord.BackColor = [Drawing.Color]::FromArgb(214, 48, 49) 
$btnRecord.ForeColor = [Drawing.Color]::White
$btnRecord.Font = $fontButtons

# Export button (Forest Green)
$btnExport = New-Object Windows.Forms.Button
$btnExport.Text = "EXPORT"
$btnExport.Location = New-Object Drawing.Point(135,15)
$btnExport.Size = New-Object Drawing.Size(110,38)
$btnExport.FlatStyle = [Windows.Forms.FlatStyle]::Popup
$btnExport.BackColor = [Drawing.Color]::FromArgb(38, 166, 91) 
$btnExport.ForeColor = [Drawing.Color]::White
$btnExport.Font = $fontButtons

$form.Controls.AddRange(@($btnRecord, $btnExport))

$script:StartTime = Get-Date # Base time to calculate relative event delays
$script:LastButtons = 0      # Track previous mouse state to catch transitions

# --- HELPER FUNCTIONS ---

# Adds a newly recorded click event to both the global memory list and the GUI ListView
function Add-EventRow($Action, $X, $Y, $Window, $Process) {
    $elapsed = [math]::Round(((Get-Date) - $script:StartTime).TotalMilliseconds)
    
    # Store internal representation for code generator
    $obj = [PSCustomObject]@{
        Time    = $elapsed
        Action  = $Action
        Process = $Process
        Window  = $Window
        X       = $X
        Y       = $Y
        Width   = 0
        Height  = 0
    }
    $global:Events.Add($obj) | Out-Null

    # Visual representation inside the UI
    $item = New-Object Windows.Forms.ListViewItem($elapsed.ToString())
    [void]$item.SubItems.Add($Action)
    [void]$item.SubItems.Add($X.ToString())
    [void]$item.SubItems.Add($Y.ToString())
    [void]$item.SubItems.Add($Window)
    [void]$item.SubItems.Add("") # Placeholder for window dimensions

    $list.Items.Add($item) | Out-Null
}

# --- EVENT HANDLERS ---

# Triggers OpenFileDialog to browse and select a local executable path
$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*"
    if($dlg.ShowDialog() -eq "OK") { $txtExe.Text = $dlg.FileName }
})

# Starts recording: launches target process (if specified), resets states, and displays stop prompt
$btnRecord.Add_Click({
    $global:Events.Clear()
    $list.Items.Clear()

    $script:StartTime = Get-Date
    $global:Recording = $true

    # Launch target program prior to recording if a value is supplied
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
            [System.Windows.Forms.MessageBox]::Show("Could not start execution of:`n`n$($txtExe.Text)`n`n$($_.Exception.Message)")
            return
        }
    }

    # Thread-blocking Message Box behaves as an intuitive "Pause/Stop" trigger
    [System.Windows.Forms.MessageBox]::Show(
        "Recording...`r`n`r`nPress OK to stop recording.",
        "Macro Recorder"
    )
	
    $global:Recording = $false
    Start-Sleep -Milliseconds 200
    $script:LastButtons = [System.Windows.Forms.Control]::MouseButtons
})

# --- PS1 FILE GENERATOR (EXPORT) ---
# Compiles recorded clicks into a standalone self-contained execution script (.ps1)
$btnExport.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter="PowerShell (*.ps1)|*.ps1"

    if($dlg.ShowDialog() -eq "OK") {
        $out = New-Object System.Collections.Generic.List[string]

        # Standard file headers
        $out.Add('# Generated by PowerShell Macro Recorder')
        $out.Add('')
        
        # ADD PARAMETER BLOCK FOR THE EXPORTED SCRIPT (-v / -Verbose)
        $out.Add('param(')
        $out.Add('    [Alias("Verbose")]')
        $out.Add('    [switch]$v')
        $out.Add(')')
        $out.Add('')
        
        $out.Add('Add-Type -AssemblyName System.Windows.Forms')
        $out.Add('Add-Type -AssemblyName System.Drawing')
        $out.Add('')
        
        # Output auto-launch code if executable is configured
        if ($txtExe.Text.Trim() -ne "") {
            $out.Add("# Launch the application automatically")
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

        # Embed a self-contained, highly stable C# native compiler for mouse playbacks inside the target .ps1 script.
        # This bypasses native PowerShell speed limitations, and safely queries coordinates relative to targeted window handles.
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
            // Locate process by executable name
            foreach(var p in System.Diagnostics.Process.GetProcesses()) {
                if(!string.IsNullOrEmpty(processName) && string.Equals(p.ProcessName + ".exe", processName, StringComparison.OrdinalIgnoreCase)) {
                    hwnd = p.MainWindowHandle;
                    if(hwnd != IntPtr.Zero) break;
                }
                // Locate process by matching window title
                if(!string.IsNullOrEmpty(title) && p.MainWindowTitle.Contains(title)) {
                    hwnd = p.MainWindowHandle;
                    if(hwnd != IntPtr.Zero) break;
                }
            }
        } catch {}

        if(hwnd == IntPtr.Zero && !string.IsNullOrEmpty(title))
            hwnd = FindWindow(null, title);

        // Fetch current coordinates of target application window (Handles resolution-independent dragging/moving)
        RECT r = new RECT { Left = 0, Top = 0 };
        if (hwnd != IntPtr.Zero) {
            GetWindowRect(hwnd, out r);
        }

        // Translate relative coordinates (from record time) to actual hardware screen pixels
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

        # Iterate and write events preserving precise millisecond-accurate delays between actions
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
        
        # Script footer that drives the timing, checks the -v / -Verbose flag and plays back macro steps
        $out.Add(@'
foreach($event in $macroEvents) {
    if($event.Delay -gt 0) {
        Start-Sleep -Milliseconds $event.Delay
    }
    
    # Conditional output in the generated script: only log steps if executed with -v or -Verbose
    if ($v) {
        Write-Host "PLAYBACK -> Executing Action: [$($event.Action)] on Process: [$($event.Process)] (Window: [$($event.Window)]) at X:$($event.X) Y:$($event.Y)" -ForegroundColor Yellow
    }
    
    [MacroPlayer]::ExecuteAction($event.Action, $event.Process, $event.Window, $event.X, $event.Y) | Out-Null
}
'@)

        [System.IO.File]::WriteAllLines($dlg.FileName, $out, [System.Text.Encoding]::UTF8)
        [System.Windows.Forms.MessageBox]::Show("Macro exported successfully.")
    }
})

# --- COMPILACIÓN OF NATIVE C# HELPERS (RECORD TIME) ---
# Generates helper structures for real-time mouse query coordinates, processes, and parent window bounds.
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

    const uint GA_ROOT = 2; // Fetches parent window, preventing capture from getting stuck inside child subcomponents

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

# --- TIMER CAPTURE BUCKET LOOP ---
# Rapidly samples mouse state to capture click downs instantaneously
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20 # 20ms ensures high responsiveness without CPU overload

$timer.Add_Tick({
    if(-not $global:Recording){ return }

    $buttons = [System.Windows.Forms.Control]::MouseButtons

    # Handle transitions (button states have changed since the last tick)
    if($buttons -ne $script:LastButtons){
        $script:LastButtons = $buttons
		
        if($buttons -eq [System.Windows.Forms.MouseButtons]::Left -or $buttons -eq [System.Windows.Forms.MouseButtons]::Right){
            $p = [System.Windows.Forms.Cursor]::Position
            $proc = [WinInfo]::ProcessUnderMouse($p.X,$p.Y)
            $title = [WinInfo]::WindowUnderMouse($p.X,$p.Y)

            # Log transition detection metadata to console ONLY if verbose switch ($v) is active
            if ($script:v) {
                Write-Host "Click detected -> Current Process: [$proc] | Window: [$title]" -ForegroundColor Cyan
            }

            # Target filter logic: checks if click fits executable constraints (Standard .exe vs Windows App Store Package)
            if ($txtExe.Text.Trim() -ne "") {
                if ($txtExe.Text.ToLower().StartsWith("shell:")) {
                    if ($proc.ToLower() -ne "applicationframehost.exe" -or [string]::IsNullOrWhiteSpace($title) -or $title -eq "PowerShell Macro Recorder") {
                        return 
                    }
                } else {
                    $targetTargetExe = [System.IO.Path]::GetFileName($txtExe.Text).ToLower()
                    if ($proc.ToLower() -ne $targetTargetExe) {
                        return
                    }
                }
            }

            # Gather bounds and execute relative offset calculation
            $pos = [WinInfo]::WindowPosition($p.X,$p.Y)
            $action = if($buttons -eq [System.Windows.Forms.MouseButtons]::Left) { "LeftDown" } else { "RightDown" }

            # Print feedback to system console on successful filter validation ONLY if verbose switch ($v) is active
            if ($script:v) {
                Write-Host "RECORDED SUCCESSFULLY! -> [$action] at X:$($p.X-$pos[0]) Y:$($p.Y-$pos[1])" -ForegroundColor Green
            }

            # Record event properties
            Add-EventRow $action ($p.X-$pos[0]) ($p.Y-$pos[1]) $title $proc

            # Update size dimensions on visual ListView
            $last = $global:Events[$global:Events.Count-1]
            $last.Width = $pos[2]
            $last.Height = $pos[3]
            $list.Items[$list.Items.Count-1].SubItems[5].Text = "$($pos[2])x$($pos[3])"
        }
    }
})

# --- NATIVE CONSOLE CANCELLATION & FormClosing PIPELINES ---

# Event handler: Stops execution loop gracefully if visual Form window is closed by standard window interactions
$form.Add_FormClosing({
    $timer.Stop()
    $timer.Dispose()
    $global:Recording = $false
})

# Native Console Interceptor: Maps Ctrl+C to close and release form thread loops gracefully instead of hanging
[System.Console]::TreatControlCAsInput = $false
$sub = [ConsoleCancelEventHandler] {
    param([object]$sender, [ConsoleCancelEventArgs]$e)
    $e.Cancel = $true # Intercept crash thread
    
    if ($form -and $form.Visible) {
        $form.FormNoClose = $false
        $form.Invoke([Action]{ 
            $timer.Stop()
            $timer.Dispose()
            $form.Close() 
        })
    }
}
[System.Console]::add_CancelKeyPress($sub)

# --- PROGRAM ENTRYPOINT ---
$timer.Start()
$form.Add_Shown({$form.Activate()})
[void]$form.ShowDialog()

# Clean up registration bindings upon program teardown
[System.Console]::remove_CancelKeyPress($sub)
