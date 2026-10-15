# HERMES-CONSOLE bridge: visible console window on the server that Hermes drives.
# Injects keystrokes via WriteConsoleInput and reads the screen via ReadConsoleOutput.
# Default: listens on 127.0.0.1:18799. Protocol: one JSON per line, reply = screen text + terminator.
#
# ---- CONFIG (manual bind/port override — e.g. when the tunnel is realized differently) ----
# Priority: env vars > hermes_console.cfg (next to this script) > defaults.
#   hermes_console.cfg lines are "KEY=value":
#     BIND=127.0.0.1      address to listen on (any local address is allowed: loopback is the
#                         safe default; set a Tailscale/LAN IP only if you know why)
#     PORT=18799          TCP port
#     WORKDIR=E:\AI       console working directory
#   Env overrides: HERMES_BIND / HERMES_PORT / HERMES_WORKDIR.
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'HERMES-CONSOLE'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function CfgVal($name, $default) {
  $v = [Environment]::GetEnvironmentVariable('HERMES_' + $name)
  if ($v) { return $v }
  $f = Join-Path $here 'hermes_console.cfg'
  if (Test-Path $f) {
    foreach ($l in (Get-Content $f -ErrorAction SilentlyContinue)) {
      if ($l -match '^\s*([A-Za-z_]+)\s*=\s*(.+)$' -and $matches[1].ToUpper() -eq $name) { return $matches[2].Trim() }
    }
  }
  return $default
}
$port = [int] (CfgVal 'PORT' 18799)
$bindStr = [string] (CfgVal 'BIND' '127.0.0.1')
$workDir = [string] (CfgVal 'WORKDIR' 'E:\AI')
$log = Join-Path $here 'hermes_bridge.log'   # logs/next to the script: deployable anywhere
# hygiene: cap log growth — rotate once at startup (bridge restarts are rare), keep .old for triage
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 1MB)) {
  Move-Item $log ($log + '.old') -Force -ErrorAction SilentlyContinue
}
function Log($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $m) -ErrorAction SilentlyContinue }
Log ('bridge: start, Add-Type... bind=' + $bindStr + ':' + $port)
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Force -Path $workDir | Out-Null }
Set-Location $workDir

$WinConSrc = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class WinCon {
  [StructLayout(LayoutKind.Sequential)]
  public struct COORD { public short X, Y; public COORD(short x, short y){X=x;Y=y;} }
  [StructLayout(LayoutKind.Sequential)]
  public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  public struct CONSOLE_SCREEN_BUFFER_INFO {
    public COORD dwSize; public COORD dwCursorPosition;
    public ushort wAttributes; public SMALL_RECT window;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct KEY_EVENT_RECORD {
    public int bKeyDown; public ushort wRepeatCount;
    public ushort wVirtualKeyCode; public ushort wVirtualScanCode;
    public char UnicodeChar; public uint dwControlKeyState;
  }
  [StructLayout(LayoutKind.Explicit, Size=20)]
  public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
  }
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] rec, int len, out int written);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true)]
  public static extern bool ReadConsoleOutputCharacterW(IntPtr h, StringBuilder buf, int len, COORD from, out int read);
  // History restore after a bridge restart: write text straight into the screen buffer (no echo,
  // no execution) and park the cursor — the new console looks like the old one never died.
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true)]
  public static extern bool WriteConsoleW(IntPtr h, string buf, int len, out int written, IntPtr attrs);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool SetConsoleCursorPosition(IntPtr h, COORD pos);
  public static void WriteText(string s) { int w; WriteConsoleW(Out, s, s.Length, out w, IntPtr.Zero); }
  public static void Home() { SetConsoleCursorPosition(Out, new COORD(0, 0)); }
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
  [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmdShow);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("kernel32.dll")] public static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
  public static string PosStr() {
    var h = GetConsoleWindow();
    if (h == IntPtr.Zero) return "NO-HWND";
    RECT r; GetWindowRect(h, out r);
    return "POS " + r.Left + "x" + r.Top + " (" + (r.Right - r.Left) + "x" + (r.Bottom - r.Top) + "px)";
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint MapVirtualKeyW(uint code, uint mapType);
  public static IntPtr In = GetStdHandle(-10);
  public static IntPtr Out = GetStdHandle(-11);
  public static void Send(string s) {
    var list = new List<INPUT_RECORD>();
    foreach (char c in s) {
      ushort vk = 0; uint ctrl = 0;
      if (c == '\r') { vk = 0x0D; }
      else if (c == '\b') { vk = 0x08; }
      else if (c == '\t') { vk = 0x09; }
      else if (c == '\u0003') { vk = 0x43; ctrl = 0x0002; }
      else if (c == '\u001b') { vk = 0x1B; }
      else { vk = ToVk(c); }
      uint sc = MapVirtualKeyW(vk, 0);
      var ir = new INPUT_RECORD { EventType = 1 };
      ir.KeyEvent = new KEY_EVENT_RECORD {
        bKeyDown = 1, wRepeatCount = 1, wVirtualKeyCode = vk,
        wVirtualScanCode = (ushort)sc, UnicodeChar = c, dwControlKeyState = ctrl };
      list.Add(ir);
      ir.KeyEvent.bKeyDown = 0;
      list.Add(ir);
    }
    int w;
    WriteConsoleInput(In, list.ToArray(), list.Count, out w);
  }
  static ushort ToVk(char c) {
    if (c >= 'A' && c <= 'Z') return (ushort)c;
    if (c >= 'a' && c <= 'z') return (ushort)(c - 32);
    if (c >= '0' && c <= '9') return (ushort)c;
    return 0;
  }
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool SetConsoleScreenBufferSize(IntPtr h, COORD size);
  [DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr h, bool bRevert);
  [DllImport("user32.dll")] public static extern bool DeleteMenu(IntPtr hMenu, uint uid, uint flags);
  [DllImport("user32.dll")] public static extern bool EnableMenuItem(IntPtr hMenu, uint uid, uint flags);
  // Deep scrollback: `mode con: lines=40` also shrinks the BUFFER to 40, so history older than the
  // window is destroyed. Keep a 9999-line buffer and a 40-line window: records survive.
  public static bool SetBufferSize(int w, int h) { return SetConsoleScreenBufferSize(Out, new COORD((short)w, (short)h)); }
  // ---- console appearance defaults (user-specified from the Properties dialog screenshots) ----
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool SetConsoleWindowInfo(IntPtr h, bool bAbsolute, [In] ref SMALL_RECT rect);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool SetConsoleScreenBufferInfo(IntPtr h, ref CONSOLE_SCREEN_BUFFER_INFO info);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CONSOLE_FONT_INFOEX {
    public int cbSize; public int nFont; public COORD dwFontSize;
    public int FontFamily; public int FontWeight;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string FaceName;
  }
  [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)]
  public static extern bool GetCurrentConsoleFontEx(IntPtr h, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX f);
  [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)]
  public static extern bool SetCurrentConsoleFontEx(IntPtr h, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX f);
  // dwFontSize is in PIXELS: Lucida Console size 10 -> 6x10 (matches "Размер знаков" in Properties)
  public static bool ApplyFont(string face, int pxW, int pxH) {
    var f = new CONSOLE_FONT_INFOEX();
    f.cbSize = Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
    GetCurrentConsoleFontEx(Out, false, ref f);
    f.dwFontSize = new COORD((short)pxW, (short)pxH);
    f.FontFamily = 0x0030;   // FF_MODERN (fixed-pitch TrueType)
    f.FontWeight = 400;      // no bold (checkbox unchecked in the screenshot)
    f.FaceName = face;
    return SetCurrentConsoleFontEx(Out, false, ref f);
  }
  public static string FontInfo() {
    var f = new CONSOLE_FONT_INFOEX();
    f.cbSize = Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
    if (!GetCurrentConsoleFontEx(Out, false, ref f)) return "n/a";
    return f.FaceName + " " + f.dwFontSize.X + "x" + f.dwFontSize.Y + "px";
  }
  public static bool SetWindow(int w, int h) {
    SMALL_RECT r = new SMALL_RECT();
    r.Left = 0; r.Top = 0; r.Right = (short)(w - 1); r.Bottom = (short)(h - 1);
    return SetConsoleWindowInfo(Out, true, ref r);
  }
  // NOTE: the Ex color APIs (Get/SetConsoleScreenBufferInfoEx) were REMOVED on purpose:
  // probe-verified that this conhost fails GetConsoleScreenBufferInfoEx outright. Default colors
  // are set reliably via the cmd built-in `color 1f` typed at startup (see startup below).
  public static string AttrHex() {
    CONSOLE_SCREEN_BUFFER_INFO i;
    GetConsoleScreenBufferInfo(Out, out i);
    return "0x" + i.wAttributes.ToString("X2");
  }
  // The X button / Alt+F4 must NOT destroy the supervised session: drop SC_CLOSE from the system menu.
  // Closing/hiding is done through the tray icon (Hide / Quit) instead.
  public static bool LockClose(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return false;
    IntPtr menu = GetSystemMenu(hwnd, false);
    if (menu == IntPtr.Zero) return false;
    bool a = DeleteMenu(menu, 0xF060, 0);        // SC_CLOSE, MF_BYCOMMAND
    bool b = EnableMenuItem(menu, 0xF060, 3);    // MF_GRAYED|MF_DISABLED
    return a || b;
  }
  // Report whether SC_CLOSE is really gone/disabled (fact-check for the X lock).
  // returns: 3 = absent (deleted), 2 = disabled/grayed, 0 = still closable, -1 = no menu
  [DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
  static extern bool GetMenuItemInfoW(IntPtr hMenu, uint uid, bool byPos, ref MENUITEMINFO info);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct MENUITEMINFO {
    public uint cbSize; public uint fMask; public uint fType; public uint fState; public uint wID;
    public IntPtr hSubMenu; public IntPtr hbmpChecked; public IntPtr hbmpUnchecked;
    public IntPtr dwItemData; public string dwTypeData; public uint cch; public IntPtr hbmpItem;
  }
  public static int CloseState(IntPtr hwnd) {
    IntPtr menu = GetSystemMenu(hwnd, false);
    if (menu == IntPtr.Zero) return -1;
    var mii = new MENUITEMINFO();
    mii.cbSize = (uint)Marshal.SizeOf(typeof(MENUITEMINFO));
    mii.fMask = 0x10;   // MIIM_STATE
    if (!GetMenuItemInfoW(menu, 0xF060, false, ref mii)) return 3;
    if ((mii.fState & 3) != 0) return 2;
    return 0;
  }
  // Last N rows of the whole buffer (not just the visible window) — lets records be counted by fact.
  public static string History(int maxLines) {
    CONSOLE_SCREEN_BUFFER_INFO i;
    GetConsoleScreenBufferInfo(Out, out i);
    int bottom = i.dwCursorPosition.Y;
    int top = Math.Max(0, bottom - maxLines + 1);
    int width = i.dwSize.X;
    var sb = new StringBuilder();
    for (int y = top; y <= bottom; y++) {
      StringBuilder line = new StringBuilder(width + 1);
      int n;
      ReadConsoleOutputCharacterW(Out, line, width, new COORD(0, (short)y), out n);
      sb.AppendLine(line.ToString().TrimEnd());
    }
    sb.AppendLine("CURSOR " + i.dwCursorPosition.X + " " + i.dwCursorPosition.Y +
                  " SIZE " + i.dwSize.X + "x" + i.dwSize.Y +
                  " WINDOW " + (i.window.Right - i.window.Left + 1) + "x" + (i.window.Bottom - i.window.Top + 1) +
                  " ATTR 0x" + i.wAttributes.ToString("X2"));
    return sb.ToString();
  }
  public static string Screen() {
    CONSOLE_SCREEN_BUFFER_INFO i;
    GetConsoleScreenBufferInfo(Out, out i);
    var sb = new StringBuilder();
    int width = i.window.Right - i.window.Left + 1;
    for (short y = i.window.Top; y <= i.window.Bottom; y++) {
      StringBuilder line = new StringBuilder(width + 1);
      int n;
      ReadConsoleOutputCharacterW(Out, line, width, new COORD(i.window.Left, y), out n);
      sb.AppendLine(line.ToString().TrimEnd());
    }
    sb.AppendLine("CURSOR " + i.dwCursorPosition.X + " " + i.dwCursorPosition.Y +
                  " SIZE " + i.dwSize.X + "x" + i.dwSize.Y +
                  " WINDOW " + (i.window.Right - i.window.Left + 1) + "x" + (i.window.Bottom - i.window.Top + 1) +
                  " ATTR 0x" + i.wAttributes.ToString("X2"));
    return sb.ToString();
  }
}
'@

Add-Type -Language CSharp -TypeDefinition $WinConSrc

# ---- history persistence (user rule: after a bridge restart the new console must show the
# previous records, several screens back, "as if nothing happened"). Plain rolling UTF-8 file:
# no SQLite dependency, survives any crash, atomic-enough for a single writer. ----
$histFile = Join-Path $here 'hermes_history.txt'
$HIST_KEEP = 400          # lines kept in the file (~25 screens of 16 rows)
function Save-History {
  try {
    $txt = [WinCon]::History($HIST_KEEP)
    # strip the trailer line ("CURSOR ...") — it is diagnostics, not console content
    $lines = ($txt -split "`r?`n") | Where-Object { $_ -notmatch '^CURSOR ' }
    [System.IO.File]::WriteAllLines($histFile, $lines, [System.Text.UTF8Encoding]::new($false))
  } catch { Log ('hist-save failed: ' + $_.Exception.Message) }
}
function Restore-History {
  if (-not (Test-Path $histFile)) { Log 'hist-restore: no history file (fresh install)'; return }
  try {
    $lines = [System.IO.File]::ReadAllLines($histFile)
    if ($lines.Count -eq 0) { return }
    [WinCon]::Home()
    [WinCon]::WriteText(($lines -join "`r`n") + "`r`n")
    Log ('hist-restore: replayed ' + $lines.Count + ' lines into the new console')
  } catch { Log ('hist-restore failed: ' + $_.Exception.Message) }
}
try { $bindIp = [System.Net.IPAddress]::Parse($bindStr) }
catch { $bindIp = ([System.Net.Dns]::GetHostAddresses($bindStr) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1) }
if (-not $bindIp) { $bindIp = [System.Net.IPAddress]::Loopback }
$listener = New-Object System.Net.Sockets.TcpListener($bindIp, $port)
$listener.Start()
# CRITICAL: sockets here are handle-inheritable; the child cmd.exe would inherit the listen socket
# and keep port 18799 occupied after the bridge dies (zombie listener, restarts fail).
[WinCon]::SetHandleInformation($listener.Server.Handle, 1, 0) | Out-Null   # clear HANDLE_FLAG_INHERIT
Log 'bridge: port bound + socket non-inheritable, console setup...'
# The tray applet (hermes_tray.ps1) owns visibility; this bridge stays HIDDEN unless the user opened
# the window from the tray icon. conhost re-shows a hidden console on input — the keys op re-hides.
# User-specified console defaults (from his Properties-dialog screenshots):
#   font Lucida Console size 10 (6x10 px), buffer 87x9999, window 87x16, wrap-on-resize (default on),
#   auto window position (default), colors white-on-blue as in his preview.
# Order matters: window must fit the buffer and vice versa — shrink window, resize buffer, set window.
# CRITICAL: conhost must be VISIBLE while these apply — SetCurrentConsoleFontEx blocks waiting for a
# conhost reply and HANGS the bridge forever if the window is hidden at that moment.
$hSetup = [WinCon]::GetConsoleWindow()
if ($hSetup -ne [IntPtr]::Zero) { [WinCon]::ShowWindow($hSetup, 5) | Out-Null }   # SW_SHOW
try {
  Log 'setup: window 87x16 (1st)'
  [WinCon]::SetWindow(87, 16) | Out-Null
  Log 'setup: buffer 87x9999'
  [WinCon]::SetBufferSize(87, 9999) | Out-Null   # deep scrollback: history must not scroll away
  Log 'setup: window 87x16 (2nd)'
  [WinCon]::SetWindow(87, 16) | Out-Null
  Log 'setup: font Lucida Console 6x10'
  [WinCon]::ApplyFont('Lucida Console', 6, 10) | Out-Null
  # Window position on the monitor — user-specified exact top-left corner: 1366 x 844 px.
  # SetWindowPos keeps the current size (SWP_NOSIZE); clamp so a corner never lands off-screen.
  $px = 1366; $py = 844
  $vsL = [WinCon]::GetSystemMetrics(76); $vsT = [WinCon]::GetSystemMetrics(77)   # virtual-screen origin
  $vsR = $vsL + [WinCon]::GetSystemMetrics(78) - 1; $vsB = $vsT + [WinCon]::GetSystemMetrics(79) - 1
  $r = New-Object WinCon+RECT
  [WinCon]::GetWindowRect($hSetup, [ref]$r) | Out-Null
  $px = [Math]::Max($vsL, [Math]::Min($px, $vsR - 40))
  $py = [Math]::Max($vsT, [Math]::Min($py, $vsB - 40))
  [WinCon]::SetWindowPos($hSetup, [IntPtr]::Zero, $px, $py, 0, 0, 0x0001) | Out-Null   # SWP_NOSIZE
  Log ('setup: position ' + [WinCon]::PosStr())
  # Colors: SetConsoleScreenBufferInfoEx FAILS on this conhost (Get itself returns false — probe-verified).
  # The reliable equivalent of the Colors tab is the cmd built-in: `color 1f` sets the default
  # attributes (white on blue) and they persist across cls. Done in the startup sequence below.
} catch { Log ('setup: FAILED: ' + $_.Exception.Message) }
if ($hSetup -ne [IntPtr]::Zero) { [WinCon]::ShowWindow($hSetup, 0) | Out-Null }   # back to SW_HIDE
Log ('bridge: console setup done -> ' + [WinCon]::FontInfo() + ', expect SIZE 87x9999')
$h0 = [WinCon]::GetConsoleWindow()
[WinCon]::LockClose($h0) | Out-Null   # X is disabled on purpose: closing = tray Hide/Quit
if ($h0 -ne [IntPtr]::Zero) { [WinCon]::ShowWindow($h0, 0) | Out-Null }   # SW_HIDE
Write-Host "HERMES-CONSOLE bridge up on 127.0.0.1:$port - Hermes drives this window. CWD: $workDir"
Write-Host "Console hidden - open it from the HERMES tray icon (near the clock)."
$Host.UI.RawUI.WindowTitle = 'HERMES-CONSOLE'
$child = Start-Process -FilePath cmd.exe -WorkingDirectory $workDir -NoNewWindow -PassThru
Log 'bridge: child cmd started, entering accept loop'
$script:hidden = $true   # visibility policy owned by the bridge; tray toggles it via TCP
# User rules: after the FIRST launch the console must be clean AND colored like his Properties
# preview (white on blue). cmd has just started, so wait for its banner, then type through the same
# input injection used for agent commands: `color 1f` (sets default attrs; persists across cls),
# then cls. Deliberately NOT counted in opCount: not agent activity, the tray must not blink.
Start-Sleep -Milliseconds 1500
[WinCon]::Send("color 1f`r")
Start-Sleep -Milliseconds 400
if (Test-Path $histFile) {
  # restart, not a fresh install: replay the saved records into the buffer — "as if nothing happened"
  Restore-History
} else {
  [WinCon]::Send("cls`r")
  Start-Sleep -Milliseconds 600
}
$hc = [WinCon]::GetConsoleWindow()
if ($script:hidden -and $hc -ne [IntPtr]::Zero) { [WinCon]::ShowWindow($hc, 0) | Out-Null }
Log ('bridge: startup color+cls done, attr=' + [WinCon]::AttrHex())
$script:lastActivity = $null
$script:opCount = 0   # console WORK ops served (keys/screen/show/hide/state) — drives the tray blink

# ---- Protocol v2: unique, unmistakable line prefixes (never confuse with stray traffic) ----
# Request  : HERMES-REQ:<json>            (lines without this prefix are ignored)
# Response : HERMES-RES:<line>  x N       (payload, one prefixed line per line)
# End      : HERMES-DONE:<op>             (exactly one per request)
$REQ = 'HERMES-REQ-8F27:'; $RES = 'HERMES-RES-8F27:'; $DONE = 'HERMES-DONE-8F27:'
function Reply($ns, [string]$s) {
  $out = ''
  foreach ($l in (($s -split "`r?`n") -join "`n" -split "`n")) { $out += $RES + $l + "`n" }
  $b = [System.Text.Encoding]::UTF8.GetBytes($out)
  $ns.Write($b, 0, $b.Length); $ns.Flush()
}
function Done($ns, [string]$op) {
  $b = [System.Text.Encoding]::UTF8.GetBytes($DONE + $op + "`n")
  $ns.Write($b, 0, $b.Length); $ns.Flush()
}
while ($true) {
 try {   # a dying client mid-write must NEVER kill the bridge (unhandled Reply() throw = dead bridge)
  $c = $listener.AcceptTcpClient()
  Log 'loop: client accepted'
  $ns = $c.GetStream()
  $ns.ReadTimeout = 20000
  $pending = ''
  # NOTE: PowerShell is case-INsensitive: the loop flag must NOT be named $done ($DONE is the protocol prefix)
  $endConn = $false
  while (-not $endConn) {
    $buf = New-Object byte[] 8192
    try { $n = $ns.Read($buf, 0, $buf.Length) } catch { Log 'loop: read error/timeout'; break }
    if ($n -le 0) { break }
    $pending += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
    while ($pending.Contains("`n")) {
      $idx = $pending.IndexOf("`n")
      $line = $pending.Substring(0, $idx).Trim()
      $pending = $pending.Substring($idx + 1)
      if ($line -eq '') { continue }
      if (-not $line.StartsWith($REQ)) { Log ('loop: non-protocol line ignored: ' + $line); continue }
      Log ('loop: line=' + $line)
      try { $op = $line.Substring($REQ.Length) | ConvertFrom-Json } catch { Reply $ns 'ERR bad json'; Done $ns 'err'; continue }
      # Agent activity marker for the tray icon blink. Counts WORK ops only: the tray pings and
      # polls `activity` every second, so counting those would keep the icon blinking forever.
      if ($op.op -in @('keys','screen','history','show','hide','state')) { $script:lastActivity = Get-Date; $script:opCount++ }
      if ($op.op -eq 'keys') {
        if ($child.HasExited) { $child = Start-Process -FilePath cmd.exe -WorkingDirectory $workDir -NoNewWindow -PassThru }
        # User rule: the bridge NEVER sleeps. Inject and answer in milliseconds, always.
        # Long commands: the caller polls `screen` — the bridge stays rock-solid for hb and tray.
        # Enter rule: 'keys' means TYPE AND RUN. A missing trailing CR is appended here so EVERY
        # caller (client, agent raw JSON, seam) actually executes; pass "enter":0 to type without
        # running. Without this, text only sits on the input line and screen-grep checks match
        # the typed command instead of its output — a false-positive validation trap.
        $txt = [string] $op.text
        if ($op.PSObject.Properties.Name -notcontains 'enter' -or [int] $op.enter -ne 0) {
          if (-not $txt.EndsWith("`r")) { $txt += "`r" }
        }
        $hwnd = [WinCon]::GetConsoleWindow()
        [WinCon]::Send($txt)
        if ($script:hidden -and $hwnd -ne [IntPtr]::Zero) { [WinCon]::ShowWindow($hwnd, 0) | Out-Null }
        Reply $ns ([WinCon]::Screen()); Done $ns 'keys'
      } elseif ($op.op -eq 'screen') {
        Reply $ns ([WinCon]::Screen()); Done $ns 'screen'
      } elseif ($op.op -eq 'ping') {
        Reply $ns 'pong'; Done $ns 'ping'
      } elseif ($op.op -eq 'show') {
        $hwnd = [WinCon]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
          [WinCon]::ShowWindow($hwnd, 9) | Out-Null          # SW_RESTORE
          [WinCon]::SetForegroundWindow($hwnd) | Out-Null
          # conhost moves the window back on restore — re-assert the user position 1366x844.
          $vsL = [WinCon]::GetSystemMetrics(76); $vsT = [WinCon]::GetSystemMetrics(77)
          $vsR = $vsL + [WinCon]::GetSystemMetrics(78) - 1; $vsB = $vsT + [WinCon]::GetSystemMetrics(79) - 1
          $r = New-Object WinCon+RECT
          [WinCon]::GetWindowRect($hwnd, [ref]$r) | Out-Null
          $nx = [Math]::Max($vsL, [Math]::Min(1366, $vsR - 40))
          $ny = [Math]::Max($vsT, [Math]::Min(844,  $vsB - 40))
          [WinCon]::SetWindowPos($hwnd, [IntPtr]::Zero, $nx, $ny, 0, 0, 0x0001) | Out-Null   # SWP_NOSIZE
        }
        $script:hidden = $false
        Log ('loop: show (user opened from tray) ' + [WinCon]::PosStr())
        Reply $ns ('shown ' + [WinCon]::PosStr()); Done $ns 'show'
      } elseif ($op.op -eq 'hide') {
        $hwnd = [WinCon]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { [WinCon]::ShowWindow($hwnd, 0) | Out-Null }   # SW_HIDE
        $script:hidden = $true
        Log 'loop: hide (user hid from tray)'
        Reply $ns 'hidden'; Done $ns 'hide'
      } elseif ($op.op -eq 'state') {
        Reply $ns $(if ($script:hidden) { 'HIDDEN' } else { 'VISIBLE' }); Done $ns 'state'
      } elseif ($op.op -eq 'history') {
        # whole scrollback (up to N lines), not just the visible window; clamp so a bad
        # parameter can never throw inside the op handler (a throw here would drop the client)
        $n = 400
        if ($op.lines) { try { $n = [int]$op.lines } catch { $n = 400 } }
        if ($n -lt 1) { $n = 1 }
        if ($n -gt 9999) { $n = 9999 }   # buffer height cap
        Reply $ns ([WinCon]::History($n)); Done $ns 'history'
      } elseif ($op.op -eq 'sysmenu') {
        # fact-check of the X lock: 3=SC_CLOSE absent, 2=disabled, 0=still closable, -1=no menu
        Reply $ns ([string]([WinCon]::CloseState([WinCon]::GetConsoleWindow()))); Done $ns 'sysmenu'
      } elseif ($op.op -eq 'activity') {
        # seconds since last console work op (user-facing: tray blinks while the agent works)
        $s = -1
        if ($script:lastActivity) { $s = [int]((Get-Date) - $script:lastActivity).TotalSeconds }
        Reply $ns $s; Done $ns 'activity'
      } elseif ($op.op -eq 'hb') {
        # heartbeat for the tray: liveness + activity + visibility in ONE round trip
        # ("pong <secs> <opCount> <VISIBLE|HIDDEN>") — the tray worker polls this and never blocks UI
        $s = -1
        if ($script:lastActivity) { $s = [int]((Get-Date) - $script:lastActivity).TotalSeconds }
        $vis = if ($script:hidden) { 'HIDDEN' } else { 'VISIBLE' }
        Reply $ns ('pong ' + $s + ' ' + $script:opCount + ' ' + $vis); Done $ns 'hb'
      } elseif ($op.op -eq 'quit') {
        Save-History   # last chance: disk copy must match the screen when the session ends
        try { $child | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
        Reply $ns 'bye'; Done $ns 'quit'
        $endConn = $true
      } else {
        Reply $ns 'ERR unknown op'; Done $ns 'err'
      }
      # disk copy of the scrollback after every work op (cheap: 400 buffer lines + one file write);
      # this is what makes a bridge restart invisible — the next boot replays these records.
      if ($op.op -in @('keys','screen','history')) { Save-History }
    }
  }
  $c.Close()
  if ($endConn) { $listener.Stop(); exit 0 }
 } catch { Log ('loop: connection error: ' + $_.Exception.Message) }
}
