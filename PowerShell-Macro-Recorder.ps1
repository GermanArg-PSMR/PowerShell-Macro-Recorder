# ==============================================================================
# POWERSHELL MACRO RECORDER & PLAYER (Clicks + Keystrokes Edition)
# ==============================================================================
# This script records mouse clicks (Left/Right) and keyboard keystrokes relative 
# to a target window and generates an automated PowerShell script to replay them.
# Includes a modern UI, process filtering, and clean console cancellation (Ctrl+C).
#
# NEW FEATURES:
# - Optional Keyboarding: Toggle on "Record Keys" via a checkbox.
# - Verbose Logging: Completely silent by default unless run with -v or -Verbose.
# ==============================================================================

param(
    [Alias("Verbose")]
    [switch]$v
)

# Store parameter in script scope for access inside event loops
$script:v = $v

# Load Windows Graphical User Interface assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- GLOBAL STATE VARIABLES ---
$global:Recording = $false
$global:Events = New-Object System.Collections.ArrayList
$global:KeyboardHook = [IntPtr]::Zero
$global:HookDelegate = $null

$script:IgnoreNextClick = $false
$script:Executable = ""
$script:Arguments = ""

# --- MAIN GRAPHICAL INTERFACE CONFIGURATION ---
$form = New-Object Windows.Forms.Form
$form.Text = "PowerShell Macro Recorder"
$form.Size = New-Object Drawing.Size(700,530)
$form.StartPosition = "CenterScreen"
$form.BackColor = [Drawing.Color]::FromArgb(235, 236, 240) # Neumorphic light-gray
$form.Font = New-Object Drawing.Font("Segoe UI", 9)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$fontButtons = New-Object Drawing.Font("Segoe UI Black", 10, [Drawing.FontStyle]::Bold)

# Executable Path Input Elements
$lblExe = New-Object Windows.Forms.Label
$lblExe.Text = "Executable:"
$lblExe.Location = New-Object Drawing.Point(15,70)
$lblExe.AutoSize = $true
$lblExe.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
$lblExe.ForeColor = [Drawing.Color]::FromArgb(50, 50, 50)

$txtExe = New-Object Windows.Forms.TextBox
$txtExe.Location = New-Object Drawing.Point(95,67)
$txtExe.Size = New-Object Drawing.Size(410,23)
$txtExe.Text = "notepad.exe"

# Checkbox to Toggle Keyboard Keystroke Recording
$chkKeys = New-Object Windows.Forms.CheckBox
$chkKeys.Text = "Record Keys"
$chkKeys.Location = New-Object Drawing.Point(515, 68)
$chkKeys.AutoSize = $true
$chkKeys.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
$chkKeys.Checked = $true

$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = "..."
$btnBrowse.Location = New-Object Drawing.Point(620,65)
$btnBrowse.Size = New-Object Drawing.Size(45,25)

$form.Controls.AddRange(@($lblExe, $txtExe, $chkKeys, $btnBrowse))

# Events display list
$list = New-Object Windows.Forms.ListView
$list.View = "Details"
$list.FullRowSelect = $true
$list.GridLines = $true
$list.Location = New-Object Drawing.Point(15,110)
$list.Size = New-Object Drawing.Size(650,350)
$list.BorderStyle = [Windows.Forms.BorderStyle]::Fixed3D

$list.Columns.Add("Time (ms)", 100) | Out-Null
$list.Columns.Add("Action", 120) | Out-Null
$list.Columns.Add("X / Key", 80) | Out-Null
$list.Columns.Add("Y", 80) | Out-Null
$list.Columns.Add("Window Title", 260) | Out-Null
$list.Columns.Add("Win Size", 120) | Out-Null

$form.Controls.Add($list)

# Styled Buttons
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

# --- HELPER FUNCTIONS ---

# Adds mouse or keystroke rows to memory and list UI
function Add-EventRow($Action, $X, $Y, $Window, $Process) {
    $elapsed = [math]::Round(((Get-Date) - $script:StartTime).TotalMilliseconds)
    
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

    $item = New-Object Windows.Forms.ListViewItem($elapsed.ToString())
    [void]$item.SubItems.Add($Action)
    [void]$item.SubItems.Add($X.ToString())
    [void]$item.SubItems.Add($Y.ToString())
    [void]$item.SubItems.Add($Window)
    [void]$item.SubItems.Add("")

    $list.Items.Add($item) | Out-Null
}

# --- NATIVE WINDOWS API DEFINITIONS (FOR HOOKS & QUERIES) ---
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
    public static extern IntPtr GetForegroundWindow();

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

    public static string ActiveWindowTitle()
    {
        var hwnd = GetForegroundWindow();
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

    public static string ActiveProcessName()
    {
        var hwnd = GetForegroundWindow();
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try {
            return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName + ".exe";
        } catch { return ""; }
    }
}

public class KeyboardHookManager
{
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
}
"@

# --- EVENT HANDLERS ---

$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*"
    if($dlg.ShowDialog() -eq "OK") { $txtExe.Text = $dlg.FileName }
})

# Native Windows Low-Level Keyboard Hook Handler
function Install-KeyboardHook {
    $hookID = 13 # WH_KEYBOARD_LL
    $global:HookDelegate = [KeyboardHookManager+HookProc] {
        param($nCode, $wParam, $lParam)
        
        # 0x0100 = WM_KEYDOWN
        if ($nCode -ge 0 -and $wParam -eq 256) {
            $vkCode = [System.Runtime.InteropServices.Marshal]::ReadInt32($lParam)
            $key = [System.Windows.Forms.Keys]$vkCode
            
            if ($global:Recording) {
                $proc = [WinInfo]::ActiveProcessName()
                $title = [WinInfo]::ActiveWindowTitle()

                # Verify target process matching before logging the keystroke
                $isMatch = $true
                if ($txtExe.Text.Trim() -ne "") {
                    if ($txtExe.Text.ToLower().StartsWith("shell:")) {
                        if ($proc.ToLower() -ne "applicationframehost.exe" -or [string]::IsNullOrWhiteSpace($title) -or $title -eq "PowerShell Macro Recorder") {
                            $isMatch = $false
                        }
                    } else {
                        $targetExe = [System.IO.Path]::GetFileName($txtExe.Text).ToLower()
                        if ($proc.ToLower() -ne $targetExe) {
                            $isMatch = $false
                        }
                    }
                }

                if ($isMatch -and $title -ne "PowerShell Macro Recorder") {
                    if ($script:v) {
                        Write-Host "Key detected -> Code: [$vkCode] | Key: [$key]" -ForegroundColor Magenta
                    }
                    
                    # Convert to string equivalent for visual list and player
                    $keyString = $key.ToString()
                    
                    # Prevent keystrokes from recording while user triggers the record stop box
                    if ($keyString -ne "Return" -and $keyString -ne "Enter" -and $keyString -ne "Space") {
                        Add-EventRow "KeyPress" $keyString "" $title $proc
                    }
                }
            }
        }
        return [KeyboardHookManager]::CallNextHookEx($global:KeyboardHook, $nCode, $wParam, $lParam)
    }

    $mod = [KeyboardHookManager]::GetModuleHandle([System.Diagnostics.Process]::GetCurrentProcess().MainModule.ModuleName)
    $global:KeyboardHook = [KeyboardHookManager]::SetWindowsHookEx($hookID, $global:HookDelegate, $mod, 0)
}

function Remove-KeyboardHook {
    if ($global:KeyboardHook -ne [IntPtr]::Zero) {
        [KeyboardHookManager]::UnhookWindowsHookEx($global:KeyboardHook) | Out-Null
        $global:KeyboardHook = [IntPtr]::Zero
    }
}

# START RECORDING
$btnRecord.Add_Click({
    $global:Events.Clear()
    $list.Items.Clear()

    $script:StartTime = Get-Date
    $global:Recording = $true

    # Start Keyboard Hook if toggle is checked
    if ($chkKeys.Checked) {
        Install-KeyboardHook
    }

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
            Remove-KeyboardHook
            [System.Windows.Forms.MessageBox]::Show("Could not start execution of:`n`n$($txtExe.Text)`n`n$($_.Exception.Message)")
            return
        }
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Recording...`r`n`r`nPress OK to stop recording.",
        "Macro Recorder"
    )
	
    $global:Recording = $false
    Remove-KeyboardHook
    Start-Sleep -Milliseconds 200
    $script:LastButtons = [System.Windows.Forms.Control]::MouseButtons
})

# --- PS1 FILE GENERATOR (EXPORT) ---
$btnExport.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter="PowerShell (*.ps1)|*.ps1"

    if($dlg.ShowDialog() -eq "OK") {
        $out = New-Object System.Collections.Generic.List[string]

        $out.Add('# Generated by PowerShell Macro Recorder')
        $out.Add('')
        
        $out.Add('param(')
        $out.Add('    [Alias("Verbose")]')
        $out.Add('    [switch]$v')
        $out.Add(')')
        $out.Add('')
        
        $out.Add('Add-Type -AssemblyName System.Windows.Forms')
        $out.Add('Add-Type -AssemblyName System.Drawing')
        $out.Add('')
        
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

        # --- FIX: We define the C# MacroPlayer structure outside as a clean string block to prevent nested Here-String parsing issues ---
        $playerCode = @'
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

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

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

    public static bool ExecuteAction(string action, string processName, string title, string valX, int y)
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

        if (hwnd != IntPtr.Zero) {
            SetForegroundWindow(hwnd);
        }

        if (action == "KeyPress") {
            string keyStroke = valX;
            if (keyStroke == "Return" || keyStroke == "Enter") keyStroke = "{ENTER}";
            else if (keyStroke == "Back") keyStroke = "{BACKSPACE}";
            else if (keyStroke == "Tab") keyStroke = "{TAB}";
            else if (keyStroke == "Escape") keyStroke = "{ESC}";
            else if (keyStroke.Length > 1) keyStroke = "{" + keyStroke.ToUpper() + "}";

            try {
                System.Windows.Forms.SendKeys.SendWait(keyStroke);
            } catch {}
            return true;
        }

        RECT r = new RECT { Left = 0, Top = 0 };
        if (hwnd != IntPtr.Zero) {
            GetWindowRect(hwnd, out r);
        }

        int x = 0;
        int.TryParse(valX, out x);

        if(action == "LeftDown") {
            LeftClick(r.Left + x, r.Top + y);
        } else if(action == "RightDown") {
            RightClick(r.Left + x, r.Top + y);
        }
        return true;
    }
}
'@

        # Inject the compilation call for C# player
        $out.Add("Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'")
        $out.Add($playerCode)
        $out.Add("'@")
        $out.Add('')

        $out.Add('$macroEvents = @(')

        $previousTime = 0
        foreach($e in $global:Events) {
            $delay = $e.Time - $previousTime
            if($delay -lt 0) { $delay = 0 }
            $previousTime = $e.Time

            $window = $e.Window.Replace('"', '""')
            $process = $e.Process.Replace('"', '""')

            # FIX: Properly format coordinates and strings, ensuring Y is written as an empty string "" instead of leaving it blank.
            $valX = if ($e.X -ne $null) { $e.X.ToString() } else { "" }
            $valY = if ($e.Y -ne $null -and $e.Y -ne "") { $e.Y } else { '""' }

            $out.Add("    [PSCustomObject]@{Delay=$delay; Action=""$($e.Action)""; Process=""$process""; Window=""$window""; X=""$valX""; Y=$valY}")
        }
        $out.Add(')')
        $out.Add('')
        
        # Adding Playback loop
        $out.Add('foreach($event in $macroEvents) {')
        $out.Add('    if($event.Delay -gt 0) {')
        $out.Add('        Start-Sleep -Milliseconds $event.Delay')
        $out.Add('    }')
        $out.Add('    ')
        $out.Add('    if ($v) {')
        $out.Add('        if ($event.Action -eq "KeyPress") {')
        $out.Add('            Write-Host "PLAYBACK -> Key pressed: [$($event.X)] on Process: [$($event.Process)]" -ForegroundColor Yellow')
        $out.Add('        } else {')
        $out.Add('            Write-Host "PLAYBACK -> Clicked Action: [$($event.Action)] on Process: [$($event.Process)] at X:$($event.X) Y:$($event.Y)" -ForegroundColor Yellow')
        $out.Add('        }')
        $out.Add('    }')
        $out.Add('    ')
        $out.Add('    [MacroPlayer]::ExecuteAction($event.Action, $event.Process, $event.Window, $event.X, $event.Y) | Out-Null')
        $out.Add('}')

        [System.IO.File]::WriteAllLines($dlg.FileName, $out, [System.Text.Encoding]::UTF8)
        [System.Windows.Forms.MessageBox]::Show("Macro exported successfully.")
    }
})

# --- TIMER CAPTURE BUCKET LOOP ---
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

            if ($script:v) {
                Write-Host "Click detected -> Current Process: [$proc] | Window: [$title]" -ForegroundColor Cyan
            }

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

            $pos = [WinInfo]::WindowPosition($p.X,$p.Y)
            $action = if($buttons -eq [System.Windows.Forms.MouseButtons]::Left) { "LeftDown" } else { "RightDown" }

            if ($script:v) {
                Write-Host "RECORDED SUCCESSFULLY! -> [$action] at X:$($p.X-$pos[0]) Y:$($p.Y-$pos[1])" -ForegroundColor Green
            }

            Add-EventRow $action ($p.X-$pos[0]) ($p.Y-$pos[1]) $title $proc

            $last = $global:Events[$global:Events.Count-1]
            $last.Width = $pos[2]
            $last.Height = $pos[3]
            $list.Items[$list.Items.Count-1].SubItems[5].Text = "$($pos[2])x$($pos[3])"
        }
    }
})

# --- CLEAN EXIT CONTROL ---

$form.Add_FormClosing({
    $timer.Stop()
    $timer.Dispose()
    Remove-KeyboardHook
    $global:Recording = $false
})

[System.Console]::TreatControlCAsInput = $false
$sub = [ConsoleCancelEventHandler] {
    param([object]$sender, [ConsoleCancelEventArgs]$e)
    $e.Cancel = $true
    
    if ($form -and $form.Visible) {
        $form.FormNoClose = $false
        $form.Invoke([Action]{ 
            $timer.Stop()
            $timer.Dispose()
            Remove-KeyboardHook
            $form.Close() 
        })
    }
}
[System.Console]::add_CancelKeyPress($sub)

# --- PROGRAM ENTRYPOINT ---
$timer.Start()
$form.Add_Shown({$form.Activate()})
[void]$form.ShowDialog()

[System.Console]::remove_CancelKeyPress($sub)
