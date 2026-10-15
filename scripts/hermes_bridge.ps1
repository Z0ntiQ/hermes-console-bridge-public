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
#     TABS=8              max console tabs (tab N listens on PORT+N-1)
#   Env overrides: HERMES_BIND / HERMES_PORT / HERMES_WORKDIR.
# ---- TABS (user request 2026-10-15): several consoles, one bridge process PER TAB. ----
# A real tab strip inside one window is impossible here: conhost has no tabs and one console has
# exactly ONE input queue — while a tab runs a long-lived server (START.bat -> ComfyUI), its stdin
# belongs to that server and no other command can be typed into it. So a tab = its own console
# window + its own cmd child + its own port (base + tab - 1). The tray supervises the whole set and
# the client addresses tabs by number. Tab 1 keeps the legacy port and the legacy file names.
param([int] $Tab = 1, [string] $TabLabel = '', [string] $WorkDir = '')
$ErrorActionPreference = 'Stop'
if ($Tab -lt 1 -or $Tab -gt 32) { Write-Error ('bad -Tab ' + $Tab); exit 2 }
$TabTag = if ($Tab -eq 1) { '' } else { ('_T' + $Tab) }
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
$basePort = [int] (CfgVal 'PORT' 18799)
$MAX_TABS = [int] (CfgVal 'TABS' 8)          # tab N listens on basePort + N - 1
$port = $basePort + ($Tab - 1)
$bindStr = [string] (CfgVal 'BIND' '127.0.0.1')
# Protocol v2 constants (defined early: the startup sibling-tab probe needs them)
$REQ = 'HERMES-REQ-8F27:'; $RES = 'HERMES-RES-8F27:'; $DONE = 'HERMES-DONE-8F27:'
# per-tab folder: -WorkDir wins (the tray passes it per tab), else global cfg WORKDIR
$workDir = if ($WorkDir) { $WorkDir } else { [string] (CfgVal 'WORKDIR' 'E:\AI') }
$log = Join-Path $here ('hermes_bridge' + $TabTag + '.log')   # per-tab log; tab 1 keeps the legacy name
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
  // ---- Job object: the whole console tree must die WITH the bridge ----
  // Root cause of desktop litter: when the bridge was killed/crashed, its cmd.exe and
  // everything started inside the console survived as orphans, each keeping a zombie
  // console window (45+ of them after the 14 Oct restart storm). A kill-on-close job
  // assigned to the bridge itself makes Windows destroy the entire tree — cmd, nested
  // powershell, their windows — the instant the bridge handle closes.
  [StructLayout(LayoutKind.Sequential)]
  public struct IO_COUNTERS { public ulong ReadBytes, WriteBytes, OtherBytes, ReadOps, WriteOps, OtherOps; }
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass, SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
  }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr sa, string name);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  static IntPtr s_job = IntPtr.Zero;
  public static bool SetupSelfJob() {
    // Must run BEFORE any child is started: membership is inherited, so every process the
    // console tree spawns joins the job automatically. KILL_ON_JOB_CLOSE (0x2000) does the rest.
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) return false;
    int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    IntPtr info = Marshal.AllocHGlobal(size);
    try {
      JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
      li.BasicLimitInformation.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      Marshal.StructureToPtr(li, info, false);
      if (!SetInformationJobObject(job, 9, info, (uint)size)) { CloseHandle(job); return false; }   // 9 = JobObjectExtendedLimitInformation
    } finally { Marshal.FreeHGlobal(info); }
    if (!AssignProcessToJobObject(job, GetCurrentProcess())) { CloseHandle(job); return false; }
    s_job = job;   // keep open for our lifetime; the OS closes it when we die, and that kills the tree
    return true;
  }
  public static string PosStr() {
    var h = GetConsoleWindow();
    if (h == IntPtr.Zero) return "NO-HWND";
    RECT r; GetWindowRect(h, out r);
    return "POS " + r.Left + "x" + r.Top + " (" + (r.Right - r.Left) + "x" + (r.Bottom - r.Top) + "px)";
  }
  // ---- one-console invariant: close console windows left behind by DEAD bridge generations ----
  // A console window survives as long as ANY process is attached to it. When a bridge was
  // killed, its child cmd.exe stayed attached as an orphan, so the window (title contains
  // HERMES-CONSOLE) lingered — the user saw two+ blue consoles at once. The self-job prevents
  // NEW ones; this sweep cleans EXISTING ones at every startup. WM_CLOSE is the graceful X-click
  // path: conhost exits and takes the attached orphan with it. Our own HWND is skipped by
  // identity — WM_CLOSE would bypass the SC_CLOSE lock, so exact-handle comparison is mandatory.
  public delegate bool EnumWinCB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWinCB cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  // liveTabs = tab ids whose bridges answer the protocol right now. A window tagged [Tn] with a
  // live n is a SIBLING TAB, not a zombie: with the tabs feature several HERMES-CONSOLE windows
  // legitimately coexist, so the sweep must be tag-aware or it would close the user's other tabs.
  public static int CloseForeignHermesConsoles(int[] liveTabs) {
    IntPtr mine = GetConsoleWindow();
    int closed = 0;
    EnumWinCB cb = delegate(IntPtr h, IntPtr l) {
      if (h == mine) return true;
      var cls = new System.Text.StringBuilder(64); GetClassNameW(h, cls, cls.Capacity);
      if (cls.ToString() != "ConsoleWindowClass") return true;
      var t = new System.Text.StringBuilder(512); GetWindowTextW(h, t, t.Capacity);
      string title = t.ToString();
      if (title.IndexOf("HERMES-CONSOLE", System.StringComparison.OrdinalIgnoreCase) < 0) return true;
      var m = System.Text.RegularExpressions.Regex.Match(title, @"\[T(\d+)\]");
      int tabId = m.Success ? int.Parse(m.Groups[1].Value) : 1;   // untagged legacy title == tab 1
      bool live = false;
      if (liveTabs != null) foreach (int x in liveTabs) if (x == tabId) { live = true; break; }
      if (live) return true;
      PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE
      closed++;
      return true;
    };
    EnumWindows(cb, IntPtr.Zero);
    return closed;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint MapVirtualKeyW(uint code, uint mapType);
  // ---- window PLACEMENT: what the user did by hand (maximized / moved / resized) ----
  // GetWindowPlacement/SetWindowPlacement is the canonical Win32 pair for this: unlike
  // GetWindowRect it separates the NORMAL rect from the maximized state (showCmd), so a
  // maximized window survives hide->show instead of collapsing to its default size.
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct WINDOWPLACEMENT {
    public int length; public int flags; public int showCmd;
    public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
  }
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT wp);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT wp);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  public static string PlacementStr() {
    var h = GetConsoleWindow();
    if (h == IntPtr.Zero) return "NO-HWND";
    WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
    wp.length = System.Runtime.InteropServices.Marshal.SizeOf(typeof(WINDOWPLACEMENT));
    if (!GetWindowPlacement(h, ref wp)) return "PLACEMENT-FAIL";
    RECT r; GetWindowRect(h, out r);
    return "PLACEMENT showCmd=" + wp.showCmd + " zoom=" + (IsZoomed(h) ? 1 : 0) +
           " normal=" + wp.rcNormalPosition.Left + "," + wp.rcNormalPosition.Top + "," +
                        wp.rcNormalPosition.Right + "," + wp.rcNormalPosition.Bottom +
           " now=" + (r.Right - r.Left) + "x" + (r.Bottom - r.Top) + "px @" + r.Left + "x" + r.Top;
  }
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
$histFile = Join-Path $here ('hermes_history' + $TabTag + '.txt')
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

# ---- window geometry persistence (user rule 2026-10-15: if he maximized / resized / moved the
# window by hand, Hide -> Show must bring it back EXACTLY as he left it, not the defaults).
# One line: "<showCmd> <L> <T> <R> <B>" (showCmd 1=normal, 3=maximized; rect = normal position).
$geomFile = Join-Path $here ('hermes_geom' + $TabTag + '.txt')
function Get-Placement {
  $h = [WinCon]::GetConsoleWindow()
  if ($h -eq [IntPtr]::Zero) { return $null }
  try {
    $wp = New-Object WinCon+WINDOWPLACEMENT
    $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp)
    if (-not [WinCon]::GetWindowPlacement($h, [ref] $wp)) { return $null }
    return $wp
  } catch { Log ('geom: placement read failed: ' + $_.Exception.Message); return $null }
}
function Save-Geom {
  $wp = Get-Placement
  if (-not $wp) { return }
  # Only normal(1)/maximized(3) are worth remembering: hidden(0)/minimized(2) are transient
  # system states, and overwriting with them would erase the user's real choice.
  if (([int] $wp.showCmd) -ne 1 -and ([int] $wp.showCmd) -ne 3) { return }
  try {
    $r = $wp.rcNormalPosition
    $txt = ([int] $wp.showCmd).ToString() + ' ' + $r.Left + ' ' + $r.Top + ' ' + $r.Right + ' ' + $r.Bottom
    [System.IO.File]::WriteAllText($geomFile, $txt, [System.Text.UTF8Encoding]::new($false))
  } catch { Log ('geom-save failed: ' + $_.Exception.Message) }
}
function Restore-Geom([string] $why) {
  # Apply the placement the user left behind. Returns the showCmd to pass to ShowWindow
  # (1=SW_SHOWNORMAL, 3=SW_SHOWMAXIMIZED) or 0 when there is no usable saved geometry
  # (caller keeps its own defaults). Never throws: a bad file falls back to defaults.
  # NOTE: SetWindowPlacement on a HIDDEN window sets the rect but neither shows the window
  # nor keeps maximized state — the caller must ShowWindow() with the returned code.
  $wp = Get-Placement
  if (-not $wp) { return 0 }
  try {
    if (-not (Test-Path $geomFile)) { return 0 }
    $p = @(([System.IO.File]::ReadAllText($geomFile)) -replace "^\uFEFF" -split '\s+' | Where-Object { $_ -ne '' })
    if ($p.Count -lt 5) { Log 'geom: file malformed - using defaults'; return 0 }
    $showCmd = [int] $p[0]
    if ($showCmd -ne 3) { $showCmd = 1 }   # only maximized or normal; minimized is never a goal
    $L = [int] $p[1]; $T = [int] $p[2]; $R = [int] $p[3]; $B = [int] $p[4]
    if (($R - $L) -lt 60 -or ($B - $T) -lt 40) { Log 'geom: saved rect too small - using defaults'; return 0 }
    # monitor layout can change between sessions: keep the window reachable on the current screen
    $vsL = [WinCon]::GetSystemMetrics(76); $vsT = [WinCon]::GetSystemMetrics(77)
    $vsR = $vsL + [WinCon]::GetSystemMetrics(78) - 1; $vsB = $vsT + [WinCon]::GetSystemMetrics(79) - 1
    if ($R -lt $vsL -or $L -gt $vsR -or $B -lt $vsT -or $T -gt $vsB) {
      $w = $R - $L; $ht = $B - $T
      $L = [Math]::Max($vsL, [Math]::Min($L, $vsR - 40)); $T = [Math]::Max($vsT, [Math]::Min($T, $vsB - 40))
      $R = $L + $w; $B = $T + $ht
      Log 'geom: saved rect was off-screen (monitor change) - position pulled back inside'
    }
    $rc = New-Object WinCon+RECT
    $rc.Left = $L; $rc.Top = $T; $rc.Right = $R; $rc.Bottom = $B
    $wp.showCmd = $showCmd
    $wp.rcNormalPosition = $rc
    if (-not [WinCon]::SetWindowPlacement([WinCon]::GetConsoleWindow(), [ref] $wp)) {
      Log ('geom: SetWindowPlacement failed (' + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() + ') - using defaults')
      return 0
    }
    Log ('geom(' + $why + '): restored showCmd=' + $showCmd + ' normal=' + $L + ',' + $T + ' ' + ($R - $L) + 'x' + ($B - $T) + 'px')
    return $showCmd
  } catch { Log ('geom-restore failed: ' + $_.Exception.Message); return 0 }
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
  # Window geometry: if the user left a placement (maximized / his size / his position) from a
  # previous session, replay it — his hand-made layout wins over the defaults. Only with no
  # saved file we apply the default top-left corner 1366 x 844 px (user-specified once).
  if (-not (Restore-Geom 'startup')) {
    # default corner, cascaded per tab so several tab windows never sit exactly on top of each other
    $px = 1366 + (($Tab - 1) * 48); $py = 844 + (($Tab - 1) * 32)
    $vsL = [WinCon]::GetSystemMetrics(76); $vsT = [WinCon]::GetSystemMetrics(77)   # virtual-screen origin
    $vsR = $vsL + [WinCon]::GetSystemMetrics(78) - 1; $vsB = $vsT + [WinCon]::GetSystemMetrics(79) - 1
    $r = New-Object WinCon+RECT
    [WinCon]::GetWindowRect($hSetup, [ref]$r) | Out-Null
    $px = [Math]::Max($vsL, [Math]::Min($px, $vsR - 40))
    $py = [Math]::Max($vsT, [Math]::Min($py, $vsB - 40))
    [WinCon]::SetWindowPos($hSetup, [IntPtr]::Zero, $px, $py, 0, 0, 0x0001) | Out-Null   # SWP_NOSIZE
  }
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
Write-Host "HERMES-CONSOLE bridge up on 127.0.0.1:$port (tab $Tab) - Hermes drives this window. CWD: $workDir"
Write-Host "Console hidden - open it from the HERMES tray icon (near the clock)."
$Host.UI.RawUI.WindowTitle = 'HERMES-CONSOLE [T' + $Tab + ']'
# Kill-on-close job, assigned to OURSELVES before any child exists: membership is inherited by
# everything the console tree spawns (cmd, nested powershell, tools). When the bridge dies for
# ANY reason (kill, crash, reboot of the session) the OS closes our handle and the whole tree —
# including their console windows — is destroyed. Without this, orphans kept zombie windows.
if ([WinCon]::SetupSelfJob()) { Log 'bridge: self-job armed (KILL_ON_JOB_CLOSE) - console tree dies with us' } else { Log 'bridge: self-job FAILED - orphan windows possible' }
# One-console invariant: sweep zombie HERMES-CONSOLE windows left by dead bridge generations.
# Runs in OUR interactive session (an SSH-side EnumWindows would see session 0's empty station).
# Which tabs are alive right now? A sibling bridge that answers hb owns a LEGITIMATE window.
function Get-LiveTabs([int] $selfTab, [int] $baseP) {
  $live = New-Object 'System.Collections.Generic.List[int]'
  $live.Add($selfTab)
  for ($t = 1; $t -le $MAX_TABS; $t++) {
    if ($t -eq $selfTab) { continue }
    try {
      $tc = New-Object System.Net.Sockets.TcpClient
      $ar = $tc.BeginConnect([System.Net.IPAddress]::Loopback, ($baseP + $t - 1), $null, $null)
      if (-not $ar.AsyncWaitHandle.WaitOne(250)) { $tc.Close(); continue }
      try { $tc.EndConnect($ar) } catch { $tc.Close(); continue }
      $s2 = $tc.GetStream(); $s2.ReadTimeout = 700
      $b2 = [System.Text.Encoding]::UTF8.GetBytes($REQ + '{"op":"hb"}' + "`n")
      $s2.Write($b2, 0, $b2.Length); $s2.Flush()
      $buft = New-Object byte[] 512; $n2 = 0
      try { $n2 = $s2.Read($buft, 0, $buft.Length) } catch { $n2 = 0 }
      $tc.Close()
      if ($n2 -gt 0 -and [System.Text.Encoding]::UTF8.GetString($buft, 0, $n2).Contains('pong ')) { $live.Add($t) }
    } catch {}
  }
  return , $live.ToArray()
}
$liveTabs = Get-LiveTabs $Tab $basePort
$zombies = [WinCon]::CloseForeignHermesConsoles($liveTabs)
if ($zombies -gt 0) { Log ('bridge: closed ' + $zombies + ' zombie HERMES-CONSOLE window(s) (live tabs: ' + ($liveTabs -join ',') + ')') }
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
          # Restore what the USER left (maximized / his size / his position) — user rule:
          # hand-made geometry must survive Hide->Show. SetWindowPlacement alone does not
          # show a hidden window nor keep maximize: ShowWindow with the saved showCmd does.
          $sc = Restore-Geom 'show'
          if ($sc -ne 0) {
            [WinCon]::ShowWindow($hwnd, $sc) | Out-Null       # 1=SW_SHOWNORMAL 3=SW_SHOWMAXIMIZED
          } else {
            [WinCon]::ShowWindow($hwnd, 9) | Out-Null          # SW_RESTORE (no saved geometry)
            # conhost moves the window back on restore — re-assert the user position 1366x844.
            $vsL = [WinCon]::GetSystemMetrics(76); $vsT = [WinCon]::GetSystemMetrics(77)
            $vsR = $vsL + [WinCon]::GetSystemMetrics(78) - 1; $vsB = $vsT + [WinCon]::GetSystemMetrics(79) - 1
            $r = New-Object WinCon+RECT
            [WinCon]::GetWindowRect($hwnd, [ref]$r) | Out-Null
            $nx = [Math]::Max($vsL, [Math]::Min((1366 + (($Tab - 1) * 48)), $vsR - 40))
            $ny = [Math]::Max($vsT, [Math]::Min((844  + (($Tab - 1) * 32)), $vsB - 40))
            [WinCon]::SetWindowPos($hwnd, [IntPtr]::Zero, $nx, $ny, 0, 0, 0x0001) | Out-Null   # SWP_NOSIZE
          }
          [WinCon]::SetForegroundWindow($hwnd) | Out-Null
        }
        $script:hidden = $false
        Log ('loop: show (user opened from tray) ' + [WinCon]::PlacementStr())
        Reply $ns ('shown ' + [WinCon]::PlacementStr()); Done $ns 'show'
      } elseif ($op.op -eq 'hide') {
        $hwnd = [WinCon]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
          Save-Geom   # remember maximized/moved/resized state BEFORE hiding: Show must replay it
          [WinCon]::ShowWindow($hwnd, 0) | Out-Null }   # SW_HIDE
        $script:hidden = $true
        Log ('loop: hide (user hid from tray) ' + [WinCon]::PlacementStr())
        Reply $ns 'hidden'; Done $ns 'hide'
      } elseif ($op.op -eq 'newtab' -or $op.op -eq 'closetab') {
        # tab lifecycle belongs to the tray (it lives in the interactive session and owns the
        # icon): write the request into the tray's command seam instead of doing it here.
        $seam = Join-Path $here 'tray_cmd.txt'
        $verb = if ($op.op -eq 'newtab') {
          $lbl = if ($op.label) { [string] $op.label } else { '' }
          $wdp = if ($op.workdir) { [string] $op.workdir } else { '' }
          ('!addtab ' + $lbl + '|' + $wdp)
        } else { ('!closetab ' + [int] $op.tab) }
        try {
          Add-Content -Path $seam -Value ('!file ' + $verb) -Encoding UTF8
          Reply $ns ('queued: ' + $verb + ' (the tray applies it in the desktop session)'); Done $ns $op.op
        } catch { Reply $ns ('ERR cannot write ' + $seam + ': ' + $_.Exception.Message); Done $ns $op.op }
      } elseif ($op.op -eq 'tab') {
        # pid= is for the tray's tabs panel: the tray's worker runspace has CIM DENIED by its
        # scheduled-task token (probe-verified), so it cannot find the bridge by port owner —
        # the bridge reports its own PID instead.
        Reply $ns ('T' + $Tab + ' port=' + $port + ' label=' + $TabLabel + ' pid=' + $PID); Done $ns 'tab'
      } elseif ($op.op -eq 'geom') {
        # fact-check for the agent/tray: current placement (showCmd, normal rect, live rect)
        Reply $ns ([WinCon]::PlacementStr()); Done $ns 'geom'
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
      } elseif ($op.op -eq 'wd') {
        # current working directory of the console (fact-check for tray tooltip / client `wd`)
        Reply $ns $workDir; Done $ns 'wd'
      } elseif ($op.op -eq 'hb') {
        # heartbeat for the tray: liveness + activity + visibility in ONE round trip
        # ("pong <secs> <opCount> <VISIBLE|HIDDEN>") — the tray worker polls this and never blocks UI
        $s = -1
        if ($script:lastActivity) { $s = [int]((Get-Date) - $script:lastActivity).TotalSeconds }
        $vis = if ($script:hidden) { 'HIDDEN' } else { 'VISIBLE' }
        Reply $ns ('pong ' + $s + ' ' + $script:opCount + ' ' + $vis); Done $ns 'hb'
      } elseif ($op.op -eq 'quit') {
        Save-History   # last chance: disk copy must match the screen when the session ends
        Save-Geom      # last chance: the user's window layout must outlive this process
        try { $child | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
        Reply $ns 'bye'; Done $ns 'quit'
        $endConn = $true
      } else {
        Reply $ns 'ERR unknown op'; Done $ns 'err'
      }
      # disk copy of the scrollback after every work op (cheap: 400 buffer lines + one file write);
      # this is what makes a bridge restart invisible — the next boot replays these records.
      if ($op.op -in @('keys','screen','history')) { Save-History; Save-Geom }
    }
  }
  $c.Close()
  if ($endConn) { $listener.Stop(); exit 0 }
 } catch { Log ('loop: connection error: ' + $_.Exception.Message) }
}
