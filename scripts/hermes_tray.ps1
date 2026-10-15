# hermes_tray.ps1 v3.2: non-blocking UI + endpoint menu + balloon feedback (no hint lines in menu)
# A noticeable icon in the notification area (near the clock) supervising the HERMES-CONSOLE bridge.
#   left double-click = show/hide console
#   right-click menu  = Show / Hide / Restart bridge / Endpoint (auto-detect on this PC,
#                       manual host:port) / Quit
#   icon colour: ORANGE = ready/idle, GREEN flashing = agent working, RED = bridge down
#
# WHY v3: the v2 tray did ALL bridge networking on the UI thread (blocking TcpClient.Read, 5 s
# timeout, every 500 ms). While the single-threaded bridge was busy serving one agent request, the
# tray's UI thread sat in Read(); timer ticks kept arriving inside the menu's modal loop, so the
# right-click menu froze and the shell stuttered. The menu itself (ContextMenuStrip) is fine and
# stays — the fix is that the UI thread NEVER touches a socket.
#   UI thread      : NotifyIcon + ContextMenuStrip + paint timer. Reads only a thread-safe cache.
#   worker runspace: owns ALL bridge I/O (heartbeat, supervision, restart, queued user commands).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = New-Object System.Threading.Mutex($false, 'HERMES-CONSOLE-TRAY')
if (-not $mutex.WaitOne(0)) { exit 0 }   # another tray instance already runs

# ---- CONFIG (same hermes_console.cfg as the bridge, next to this script; env wins) ----
#   BIND/PORT: where the tray must REACH the bridge (must match the bridge's listen address).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgFile = Join-Path $here 'hermes_console.cfg'
function CfgVal($name, $default) {
  $v = [Environment]::GetEnvironmentVariable('HERMES_' + $name)
  if ($v) { return $v }
  if (Test-Path $cfgFile) {
    foreach ($l in (Get-Content $cfgFile -ErrorAction SilentlyContinue)) {
      if ($l -match '^\s*([A-Za-z_]+)\s*=\s*(.+)$' -and $matches[1].ToUpper() -eq $name) { return $matches[2].Trim() }
    }
  }
  return $default
}
$bridgeBind = [string] (CfgVal 'BRIDGE_BIND' '127.0.0.1')   # address the bridge listens on (server-side)
$bridgePort = [int] (CfgVal 'PORT' 18799)
$bridgeScript = Join-Path $here 'hermes_bridge.ps1'
$tlog = Join-Path $here 'hermes_tray.log'
# hygiene: cap log growth — rotate once at startup (tray restarts are rare), keep .old for triage
if ((Test-Path $tlog) -and ((Get-Item $tlog).Length -gt 1MB)) {
  Move-Item $tlog ($tlog + '.old') -Force -ErrorAction SilentlyContinue
}
function TLog($m) { Add-Content -Path $tlog -Value ((Get-Date -Format 'HH:mm:ss') + ' [ui] ' + $m) -ErrorAction SilentlyContinue }
TLog 'tray: start v3 (non-blocking UI)'

# ---- thread-safe shared state (plain .NET concurrent objects: safe across runspaces) ----
$status = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,object]'
$status['state'] = 'init'      # init | alive | down
$status['ops'] = -1            # bridge work-op counter (drives the blink)
$status['visible'] = $false
$status['uiBeat'] = $null      # last UI timer tick — used to MEASURE UI-thread stalls
$status['endpoint'] = ($bridgeBind + ':' + $bridgePort)   # live "addr:port" the tray talks to (menu shows it)
$status['detect'] = 'idle'     # idle | scanning | found | none | manual  (endpoint auto-detect feedback)
$cmds = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$stop = New-Object System.Threading.ManualResetEventSlim($false)

# ============================ worker runspace: all networking lives here ============================
$workerBody = {
  param($tlog, $bridgeScript, $bridgeBind, $bridgePort, $cfgFile, $status, $cmds, $stop)
  # Protocol v2 (must match hermes_bridge.ps1 exactly)
  $REQ = 'HERMES-REQ-8F27:'; $RES = 'HERMES-RES-8F27:'; $DONE = 'HERMES-DONE-8F27:'
  function WLog($m) { Add-Content -Path $tlog -Value ((Get-Date -Format 'HH:mm:ss') + ' [w] ' + $m) -ErrorAction SilentlyContinue }

  # One protocol request to an EXPLICIT endpoint -> payload lines, or $null on any failure.
  # Short timeout: a busy bridge queues our connection, so a slow hb means "busy", NOT "dead".
  function Invoke-BridgeAt($addr, [int]$port, [string]$json, [int]$timeoutMs) {
    try {
      try { $ip = [System.Net.IPAddress]::Parse($addr) }
      catch { $ip = ([System.Net.Dns]::GetHostAddresses($addr) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1) }
      if (-not $ip) { return $null }
      $c = New-Object System.Net.Sockets.TcpClient
      $ar = $c.BeginConnect($ip, $port, $null, $null)
      if (-not $ar.AsyncWaitHandle.WaitOne(400)) { $c.Close(); return $null }   # connect budget: 400ms
      $c.EndConnect($ar)
      $ns = $c.GetStream()
      $ns.ReadTimeout = $timeoutMs
      $b = [System.Text.Encoding]::UTF8.GetBytes($REQ + $json + "`n")
      $ns.Write($b, 0, $b.Length); $ns.Flush()
      $lines = @(); $pending = ''; $gotDone = $false
      $endT = (Get-Date).AddMilliseconds($timeoutMs)
      while ((Get-Date) -lt $endT) {
        $buf = New-Object byte[] 8192
        try { $n = $ns.Read($buf, 0, $buf.Length) } catch { break }
        if ($n -le 0) { break }
        $pending += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        while ($pending.Contains("`n")) {
          $idx = $pending.IndexOf("`n")
          $line = $pending.Substring(0, $idx).Trim()
          $pending = $pending.Substring($idx + 1)
          if ($line.StartsWith($DONE)) { $gotDone = $true; continue }
          if ($line.StartsWith($RES)) { $lines += $line.Substring($RES.Length) }
        }
        if ($gotDone) { break }
      }
      $c.Close()
      if ($gotDone) { return , $lines }
      return $null
    } catch { return $null }
  }
  # Endpoint lives in the shared $status cache (NOT in a local variable): a function cannot
  # reliably reassign the runspace's param variables, and the UI must see changes too.
  function Get-Endpoint {
    $ep = [string] $status['endpoint']
    if ($ep -match '^(.+):(\d+)$') { return @($matches[1], [int] $matches[2]) }
    return @('127.0.0.1', 18799)
  }
  function Invoke-Bridge([string]$json, [int]$timeoutMs) {
    $ep = Get-Endpoint
    Invoke-BridgeAt $ep[0] $ep[1] $json $timeoutMs
  }

  # ---- persist endpoint into hermes_console.cfg so the bridge WE launch listens on the same place ----
  function Upsert-Cfg([string]$addr, [int]$port) {
    try {
      $lines = @()
      if (Test-Path $cfgFile) { $lines = @(Get-Content $cfgFile -ErrorAction SilentlyContinue) }
      $out = @(); $sawB = $false; $sawP = $false
      foreach ($l in $lines) {
        if ($l -match '^\s*([A-Za-z_]+)\s*=') {
          $k = $matches[1].ToUpper()
          if ($k -eq 'BIND') { $out += ('BIND=' + $addr); $sawB = $true; continue }
          if ($k -eq 'PORT') { $out += ('PORT=' + $port); $sawP = $true; continue }
        }
        $out += $l
      }
      if (-not $sawB) { $out = @('BIND=' + $addr) + $out }
      if (-not $sawP) { $out = @('PORT=' + $port) + $out }
      Set-Content -Path $cfgFile -Value $out -Encoding UTF8
      WLog ('cfg: endpoint saved to ' + $cfgFile)
    } catch { WLog ('cfg save failed: ' + $_.Exception.Message) }
  }

  # Apply a new endpoint everywhere at once: shared cache (worker loop + menu + tooltip) + config file.
  function Set-Endpoint([string]$addr, [int]$port, [string]$how) {
    $status['endpoint'] = ($addr + ':' + $port)
    WLog ('endpoint: ' + $addr + ':' + $port + ' (' + $how + ')')
    if ($how -ne 'startup') { Upsert-Cfg $addr $port }
  }

  # ---- auto-detect: which host:port on THIS PC actually speaks the HERMES protocol ----
  # Two sources, then a PROTOCOL probe as the arbiter (a listening port is not enough — it must
  # answer hb with pong). Deterministic first: sockets owned by a hermes_bridge.ps1 process.
  function Find-BridgeEndpoints {
    $cands = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    function AddCand($a, $p, $why) {
      if (-not $a -or -not $p) { return }
      if ($a -eq '::' -or $a -eq '0.0.0.0') { $a = '127.0.0.1' }   # wildcard -> probe via loopback
      $key = $a + ':' + $p
      if ($seen.ContainsKey($key)) { return }
      $seen[$key] = $true
      $cands.Add([pscustomobject]@{ addr = $a; port = [int] $p; why = $why })
    }
    try {
      $bp = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -match 'hermes_bridge\.ps1' })
      foreach ($p in $bp) {
        Get-NetTCPConnection -State Listen -OwningProcess $p.ProcessId -ErrorAction SilentlyContinue |
          ForEach-Object { AddCand $_.LocalAddress $_.LocalPort 'hermes_bridge process' }
      }
    } catch {}
    # then every other local listener (covers a foreign tunnel/proxy forwarding to the bridge);
    # capped: the scan is interactive and must stay bounded even on a busy dev machine
    try {
      $extra = 0
      Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LocalPort -ge 1024 -and $extra -lt 40) { AddCand $_.LocalAddress $_.LocalPort 'local listener'; $extra++ }
      }
    } catch {}
    return , $cands
  }

  $bridgeProc = $null
  $lastLaunch = $null
  $fails = 0
  # optional manual seam: write a line "!file <cmd>" into tray_cmd.txt (same folder) to enqueue
  # a menu command from outside the UI — same handlers, same queue. ("!detect", "!setep h p", ...)
  $cmdFile = (Split-Path -Parent $tlog) + '\tray_cmd.txt'
  WLog 'worker: start'
  # NOTE: loop is while($true) ON PURPOSE: the queue must be drained even after $stop is set,
  # otherwise a queued '!quit' is skipped and the bridge is left orphaned when the tray exits.
  while ($true) {
    $immediate = $false   # set when a queued command changed things -> skip the poll sleep, react NOW
    try {
      if (Test-Path $cmdFile) {
        $raw = $null
        try { $raw = [System.IO.File]::ReadAllText($cmdFile) } catch { WLog ('cmd-file read failed: ' + $_.Exception.Message) }
        try { Remove-Item $cmdFile -Force -ErrorAction SilentlyContinue } catch {}
        if ($raw) {
          $cf = $raw.Trim() -replace '^!file\s+', ''
          WLog ('cmd-file: [' + $cf + ']')
          if ($cf) { $cmds.Enqueue($cf) }
        } else { WLog 'cmd-file: present but read returned nothing' }
      }
    } catch { WLog ('cmd-file error: ' + $_.Exception.Message) }
    # 1) user actions queued by the UI (menu clicks / double-click) go first — they must feel instant
    $j = $null
    while ($cmds.TryDequeue([ref] $j)) {
      if ($j -eq '!quit') {
        [void] (Invoke-Bridge '{"op":"quit"}' 1500)
        if ($bridgeProc -and -not $bridgeProc.HasExited) { Stop-Process -Id $bridgeProc.Id -Force -ErrorAction SilentlyContinue }
        $status['quitui'] = $true   # the paint timer will close the UI too (seam '!quit' must not leave a zombie icon)
        $stop.Set(); break
      }
      if ($j -eq '!toggle') { if ($status['visible']) { $j = '{"op":"hide"}' } else { $j = '{"op":"show"}' } }
      if ($j -eq '!restart') {
        [void] (Invoke-Bridge '{"op":"quit"}' 1500)
        if ($bridgeProc -and -not $bridgeProc.HasExited) { Stop-Process -Id $bridgeProc.Id -Force -ErrorAction SilentlyContinue }
        $bridgeProc = $null; $lastLaunch = $null; $fails = 0
        Start-Sleep -Milliseconds 600
        # launch right here — waiting for supervision would cost 4 failed polls first (~3 s)
        try {
          $lastLaunch = Get-Date
          $bridgeProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bridgeScript `
            -WindowStyle Hidden -PassThru
          WLog ('worker: restart requested from menu, bridge relaunched pid=' + $bridgeProc.Id)
        } catch { WLog ('worker: restart launch failed: ' + $_.Exception.Message) }
      } elseif ($j -eq '!detect') {
        # auto-detect: probe local endpoints that ANSWER the HERMES protocol.
        # Results reach the user as balloon tips (pick dialog when several answer) —
        # never as menu hint lines (user: «из строки меню - ее надо убрать»).
        $status['detect'] = 'scanning'
        WLog 'detect: start'
        $cur = Get-Endpoint
        $r = Invoke-Bridge '{"op":"hb"}' 1500
        if ($null -ne $r -and $r.Count -ge 1 -and $r[0] -match '^pong ') {
          $status['detect'] = 'found (current endpoint answers)'
          $status['balloon'] = @('info', 'HERMES: address applied',
            ('Found ' + $cur[0] + ':' + $cur[1] + ' - it answers the protocol and stays applied.'))
          WLog ('detect: current endpoint ' + $cur[0] + ':' + $cur[1] + ' answers, keeping it')
        } else {
          $cands = Find-BridgeEndpoints
          WLog ('detect: probing ' + $cands.Count + ' candidate endpoints')
          $answers = New-Object 'System.Collections.Generic.List[object]'
          $probes = 0
          foreach ($cd in $cands) {
            if ($probes -ge 16 -or $answers.Count -ge 6) { break }   # interactive scan stays bounded
            if ($cd.addr -eq $cur[0] -and $cd.port -eq $cur[1]) { continue }
            $probes++
            $r2 = Invoke-BridgeAt $cd.addr $cd.port '{"op":"hb"}' 900
            if ($null -ne $r2 -and $r2.Count -ge 1 -and $r2[0] -match '^pong ') { $answers.Add($cd) }
          }
          if ($answers.Count -eq 1) {
            $hit = $answers[0]
            Set-Endpoint $hit.addr $hit.port ('detect: ' + $hit.why)
            $status['detect'] = 'found (' + $hit.why + ')'
            $status['balloon'] = @('info', 'HERMES: address found and applied',
              ('Found ' + $hit.addr + ':' + $hit.port + ' (' + $hit.why + ') - applied automatically.'))
            $immediate = $true   # re-probe the NEW endpoint right away: icon tells the truth fast
          } elseif ($answers.Count -gt 1) {
            # several endpoints answer: picking one silently would be a guess - user picks by click
            $status['detect'] = ('multiple (' + $answers.Count + ' answer)')
            $status['pick'] = $answers
            WLog ('detect: ' + $answers.Count + ' endpoints answer - user picks in the dialog')
          } else {
            # nothing answered anywhere: re-probe current (it may have been busy, not dead)
            $r3 = Invoke-Bridge '{"op":"hb"}' 1500
            if ($null -ne $r3 -and $r3.Count -ge 1 -and $r3[0] -match '^pong ') {
              $status['detect'] = 'found: current endpoint was just busy'
              $status['balloon'] = @('info', 'HERMES: address applied',
                ('Current ' + $cur[0] + ':' + $cur[1] + ' was just busy - it answers, kept as current.'))
              WLog 'detect: no other endpoint answered; current one is alive (was busy)'
            } else {
              $status['detect'] = 'none (' + $probes + ' probes)'
              $status['balloon'] = @('warning', 'HERMES: nothing found',
                ('No local address answered the HERMES protocol (' + $probes + ' probes). Start the bridge or set the address manually.'))
              WLog 'detect: no HERMES-speaking endpoint found on this PC'
            }
          }
        }
      } elseif ($j -match '^!setep (\S+) (\d+)$') {
        $np = [int] $matches[2]
        if ($np -ge 1 -and $np -le 65535) {
          Set-Endpoint $matches[1] $np 'manual'
          $status['detect'] = 'manual (typed in the dialog)'
          $status['balloon'] = @('info', 'HERMES: address applied',
            ('Manual address ' + $matches[1] + ':' + $np + ' applied and saved.'))
          $immediate = $true   # re-probe the new endpoint instantly
        } else {
          WLog ('setep: port ' + $np + ' out of range 1-65535, ignored')
          $status['detect'] = 'error: port out of range'
          $status['balloon'] = @('warning', 'HERMES: bad port', ('Port ' + $np + ' is out of range 1-65535 - nothing changed.'))
        }
      } elseif ($j -match '^!pick (\S+) (\d+)$') {
        # user clicked one of the several answering addresses in the pick dialog
        $np2 = [int] $matches[2]
        if ($np2 -ge 1 -and $np2 -le 65535) {
          Set-Endpoint $matches[1] $np2 'detect: picked by user'
          $status['detect'] = 'picked by user'
          $status['balloon'] = @('info', 'HERMES: address applied', ('Selected ' + $matches[1] + ':' + $np2 + ' - applied and saved.'))
          $immediate = $true
        }
      } elseif ($j -eq '!pickfirst') {
        # seam-only: click the first row of a pending pick dialog (test helper for the pick chain)
        $pend = $null
        if ($status.TryRemove('pick', [ref] $pend) -and $null -ne $pend -and $pend.Count -ge 1) {
          $cmds.Enqueue(('!pick ' + $pend[0].addr + ' ' + $pend[0].port))
          WLog ('pickfirst: enqueued !pick ' + $pend[0].addr + ' ' + $pend[0].port)
        } else { WLog 'pickfirst: no pending pick dialog' }
      } elseif ($j -eq '!multitest') {
        # deterministic exercise of the multi-address pick path (seam-only, never in the menu):
        # the SAME status['pick'] path the real !detect uses, with a fixed answering list
        $fixed = New-Object 'System.Collections.Generic.List[object]'
        $fixed.Add([pscustomobject]@{ addr = '127.0.0.1'; port = 18901; why = 'fake listener A' })
        $fixed.Add([pscustomobject]@{ addr = '127.0.0.1'; port = 18902; why = 'fake listener B' })
        $fixed.Add([pscustomobject]@{ addr = '127.0.0.1'; port = 18799; why = 'hermes_bridge process' })
        $status['pick'] = $fixed
        WLog 'multitest: pick dialog queued with 3 fixed endpoints'
      } else {
        [void] (Invoke-Bridge $j 2500)
      }
    }
    if ($stop.IsSet) { break }

    # 2) heartbeat: liveness + activity + visibility in ONE round trip ("pong <secs> <ops> <VIS>")
    $r = Invoke-Bridge '{"op":"hb"}' 2500
    if ($null -ne $r -and $r.Count -ge 1 -and $r[0] -match '^pong ') {
      if ($fails -ge 2) { WLog ('worker: bridge back after ' + $fails + ' failed polls') }
      $fails = 0
      $status['state'] = 'alive'
      $p = $r[0] -split ' '
      if ($p.Count -ge 3) { $status['ops'] = [int] $p[2] }
      if ($p.Count -ge 4) { $status['visible'] = ($p[3] -eq 'VISIBLE') }
    } else {
      $fails++
      if ($fails -ge 4) {
        # only now do we call it dead: 4 consecutive failures ~= several seconds of silence
        if ($bridgeProc -and -not $bridgeProc.HasExited) {
          # honest status: process ALIVE but not answering = BUSY (long command / booting).
          # NOT down: the icon must never lie. The bridge answers hb between ops.
          $status['state'] = 'busy'
          if ($fails % 10 -eq 4) { WLog ('worker: bridge busy (alive, silent ' + ($fails * 3) + 's) - not touching it') }
        } else {
          $status['state'] = 'down'
          if (-not $lastLaunch -or ((Get-Date) - $lastLaunch).TotalSeconds -ge 30) {
          # a dead bridge's orphan cmd.exe child may still own the port (inherited listen socket)
          try {
            Get-NetTCPConnection -LocalPort (Get-Endpoint)[1] -State Listen -ErrorAction SilentlyContinue |
              ForEach-Object {
                $pp = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)" -ErrorAction SilentlyContinue
                if ($pp -and ($pp.Name -in @('powershell.exe', 'cmd.exe', 'conhost.exe'))) {
                  Stop-Process -Id $pp.ProcessId -Force -ErrorAction SilentlyContinue
                  WLog ('worker: killed stale port owner pid=' + $pp.ProcessId + ' name=' + $pp.Name)
                }
              }
            Start-Sleep -Milliseconds 400
          } catch {}
          $lastLaunch = Get-Date
          $bridgeProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bridgeScript `
            -WindowStyle Hidden -PassThru
          WLog ('worker: bridge launched pid=' + $bridgeProc.Id)
          $fails = 0
          }
        }
      }
    }

    # 3) instrument the UI thread: if its paint timer stopped beating, the menu WILL feel frozen.
    #    This is how the old design was caught, and how the fix is verified by fact.
    $beat = $status['uiBeat']
    if ($beat -and ((Get-Date) - $beat).TotalMilliseconds -gt 1600) {
      WLog ('UI STALL: ' + [int] ((Get-Date) - $beat).TotalMilliseconds + 'ms since last UI tick')
    }
    if ($immediate) { continue }   # a command changed endpoint/restarted bridge: poll NOW
    Start-Sleep -Milliseconds 800
  }
  WLog 'worker: stop'
}

$worker = [PowerShell]::Create().AddScript($workerBody)
foreach ($a in @($tlog, $bridgeScript, $bridgeBind, $bridgePort, $cfgFile, $status, $cmds, $stop)) { [void] $worker.AddArgument($a) }
[void] $worker.BeginInvoke()

# ================================ UI thread: icon + menu + paint ================================
$script:iconCache = @{}
function Make-Icon($state) {   # ORANGE ready | GREEN working(blink) | YELLOW busy | RED down
  if ($script:iconCache.ContainsKey($state)) { return $script:iconCache[$state] }  # cache: no GDI leak per tick
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $col = switch ($state) {
    'red'    { [System.Drawing.Color]::FromArgb(210, 40, 40) }
    'green'  { [System.Drawing.Color]::FromArgb(0, 190, 90) }
    'yellow' { [System.Drawing.Color]::FromArgb(255, 220, 0) }   # busy: alive but not answering
    default  { [System.Drawing.Color]::FromArgb(255, 150, 0) }   # orange = ready
  }
  $b = New-Object System.Drawing.SolidBrush $col
  $g.FillEllipse($b, 1, 1, 30, 30)
  $f = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = [System.Drawing.StringAlignment]::Center
  $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
  $rect = New-Object System.Drawing.RectangleF 0, 0, 32, 32
  $g.DrawString('H', $f, [System.Drawing.Brushes]::White, $rect, $sf)
  $g.Dispose()
  $ic = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
  $bmp.Dispose()
  $script:iconCache[$state] = $ic
  return $ic
}

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = Make-Icon 'orange'
$ni.Text = 'HERMES-CONSOLE - starting'
$ni.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
# NOTE: no status/hint lines in the menu (user: «убери из меню верхнюю строку подсказки -
# console: hidden» and the found-hint line too). The menu is ACTIONS only; state lives in the
# icon color + tooltip, detect results arrive as balloon tips, results of auto-detect never
# sit in the menu.
$miShow = $menu.Items.Add('Show console')
$miHide = $menu.Items.Add('Hide console')
[void] $menu.Items.Add('-')
$miRestart = $menu.Items.Add('Restart bridge')
# ---- Endpoint section: where this tray talks to the bridge (host:port) ----
[void] $menu.Items.Add('-')
$miEpLabel = $menu.Items.Add('Endpoint: -')
$miEpLabel.Enabled = $false
$miEpAuto = $menu.Items.Add('Auto-detect on this PC')
$miEpManual = $menu.Items.Add('Set host:port manually...')
[void] $menu.Items.Add('-')
$miQuit = $menu.Items.Add('Quit')
$ni.ContextMenuStrip = $menu

# Refresh the endpoint label each time the menu opens — reads the shared cache only, no I/O.
$menu.Add_Opening({
  $script:miEpLabel.Text = 'Endpoint: ' + [string] $script:status['endpoint']
})

# Manual endpoint dialog: pure UI (textboxes), no sockets — safe on the UI thread.
function Show-EndpointDialog {
  $ep = [string] $script:status['endpoint']
  $curH = '127.0.0.1'; $curP = '18799'
  if ($ep -match '^(.+):(\d+)$') { $curH = $matches[1]; $curP = $matches[2] }
  $frm = New-Object System.Windows.Forms.Form
  $frm.Text = 'HERMES endpoint (host:port)'
  $frm.FormBorderStyle = 'FixedDialog'; $frm.MaximizeBox = $false; $frm.MinimizeBox = $false
  $frm.ShowInTaskbar = $false; $frm.TopMost = $true
  $frm.ClientSize = New-Object System.Drawing.Size(320, 130)
  $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Host / IP:'; $l1.Location = New-Object System.Drawing.Point(12, 14); $l1.AutoSize = $true
  $tbH = New-Object System.Windows.Forms.TextBox; $tbH.Text = $curH; $tbH.Location = New-Object System.Drawing.Point(90, 11); $tbH.Width = 215
  $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'Port:'; $l2.Location = New-Object System.Drawing.Point(12, 44); $l2.AutoSize = $true
  $tbP = New-Object System.Windows.Forms.TextBox; $tbP.Text = $curP; $tbP.Location = New-Object System.Drawing.Point(90, 41); $tbP.Width = 90
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Apply'; $ok.Location = New-Object System.Drawing.Point(90, 80); $ok.Width = 90; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(190, 80); $cancel.Width = 90; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $frm.Controls.AddRange(@($l1, $tbH, $l2, $tbP, $ok, $cancel))
  $frm.AcceptButton = $ok; $frm.CancelButton = $cancel
  $res = $frm.ShowDialog()
  $frm.Dispose()
  if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
  $h = $tbH.Text.Trim(); $p = $tbP.Text.Trim()
  if ($h -notmatch '^[A-Za-z0-9_.:\-]+$' -or $p -notmatch '^\d{1,5}$') {
    [void] [System.Windows.Forms.MessageBox]::Show('Host and port must be plain host/IP and digits.', 'HERMES', 'OK', 'Warning')
    return $null
  }
  return ($h + ' ' + [int] $p)
}

# Several answering addresses: the user picks one by click. Pure UI (listbox) — safe on the
# UI thread; the click only enqueues '!pick <addr> <port>' for the worker to apply + persist.
function Show-PickDialog($items, $curEp) {
  $frm = New-Object System.Windows.Forms.Form
  $frm.Text = 'HERMES - several addresses answer - pick one'
  $frm.FormBorderStyle = 'FixedDialog'; $frm.MaximizeBox = $false; $frm.MinimizeBox = $false
  $frm.ShowInTaskbar = $false; $frm.TopMost = $true
  $frm.ClientSize = New-Object System.Drawing.Size(360, 260)
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = 'These addresses answered the HERMES protocol. Click one to apply it:'
  $lbl.Location = New-Object System.Drawing.Point(12, 10); $lbl.AutoSize = $true
  $lb = New-Object System.Windows.Forms.ListBox
  $lb.Location = New-Object System.Drawing.Point(12, 34); $lb.Size = New-Object System.Drawing.Size(336, 170)
  $lb.Font = New-Object System.Drawing.Font('Consolas', 10)
  $objs = New-Object 'System.Collections.Generic.List[object]'
  foreach ($it in $items) {
    $tag = $it.addr + ':' + $it.port
    $mark = if ($tag -eq $curEp) { '   (current)' } else { '' }
    [void] $lb.Items.Add($tag + '   - ' + $it.why + $mark)
    [void] $objs.Add($it)
  }
  if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Apply selected'; $ok.Location = New-Object System.Drawing.Point(12, 216); $ok.Width = 160; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(188, 216); $cancel.Width = 160; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $frm.Controls.AddRange(@($lbl, $lb, $ok, $cancel))
  $frm.AcceptButton = $ok; $frm.CancelButton = $cancel
  # double-click on a row = select + apply in one click, as the user asked
  $lb.Add_MouseDoubleClick({ $frm.DialogResult = [System.Windows.Forms.DialogResult]::OK })
  $res = $frm.ShowDialog()
  $sel = $null
  if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $lb.SelectedIndex -ge 0) { $sel = $objs[$lb.SelectedIndex] }
  $frm.Dispose()
  return $sel
}

# Every handler only ENQUEUES — no sockets, no Sleep, so the menu closes instantly and the
# worker performs the action right after its current poll.
$miShow.Add_Click({ $script:cmds.Enqueue('{"op":"show"}') })
$miHide.Add_Click({ $script:cmds.Enqueue('{"op":"hide"}') })
$miRestart.Add_Click({ $script:cmds.Enqueue('!restart') })
$miEpAuto.Add_Click({ $script:cmds.Enqueue('!detect') })
$miEpManual.Add_Click({
  $spec = Show-EndpointDialog
  if ($spec) { $script:cmds.Enqueue(('!setep ' + $spec)) }
})
$script:running = $true
$miQuit.Add_Click({
  $script:cmds.Enqueue('!quit')
  $script:stop.Set()
  $script:ni.Visible = $false
  $script:ni.Dispose()
  $script:running = $false
  $script:ctx.ExitThread()
})
$ni.Add_MouseDoubleClick({ $script:cmds.Enqueue('!toggle') })

# ---- paint timer: reads the cache only. Blink rule (user-specified): each console op = 2 green
# flashes over the orange ready light; ops arriving faster keep restarting the cycle. ----
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500            # half-period of one blink
$script:blinkLeft = 0
$script:blinkOn = $false
$script:lastOps = -1
$script:lastEp = ''
$timer.Add_Tick({
  $script:status['uiBeat'] = Get-Date
  if ($script:status['quitui']) {
    # quit came through the worker (menu Quit already exits directly; the tray_cmd.txt seam does not)
    $script:ni.Visible = $false
    $script:ni.Dispose()
    $script:ctx.ExitThread()
    return
  }
  # auto-detect results arrive through the cache: balloon tips, never menu hint lines.
  # TryRemove (not '= $null'): ConcurrentDictionary rejects null values.
  # try/catch: a WinForms failure here must never kill the message loop (icon would freeze).
  $dummy = $null
  try {
    if ($script:status.TryRemove('pick', [ref] $dummy)) {
      $sel = Show-PickDialog $dummy ([string] $script:status['endpoint'])
      if ($sel) { $script:cmds.Enqueue(('!pick ' + $sel.addr + ' ' + $sel.port)) }
    }
    if ($script:status.TryRemove('balloon', [ref] $dummy)) {
      $kind = if ($dummy[0] -eq 'warning') { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
      $script:ni.ShowBalloonTip(7000, $dummy[1], $dummy[2], $kind)
    }
  } catch { WLog ('ui notify error: ' + $_.Exception.Message) }
  $state = 'red'
  $st = $script:status['state']
  if ($st -eq 'busy') {
    $state = 'yellow'                                          # alive but busy: honest, never red
  } elseif ($st -eq 'alive') {
    $ops = [int] $script:status['ops']
    if ($ops -gt $script:lastOps) { $script:blinkLeft = 2 }   # user rule: 2 blinks per console op
    $script:lastOps = $ops
    if ($script:blinkLeft -gt 0) {
      $script:blinkOn = -not $script:blinkOn
      if ($script:blinkOn) { $script:blinkLeft-- }
      $state = if ($script:blinkOn) { 'green' } else { 'orange' }
    } else {
      $script:blinkOn = $false
      $state = 'orange'                                       # idle = ready
    }
  }
  $epNow = [string] $script:status['endpoint']
  if ($state -ne $script:lastState -or $epNow -ne $script:lastEp) {
    $script:ni.Icon = Make-Icon $state
    $script:ni.Text = $(switch ($state) {
      'red'    { 'HERMES-CONSOLE - bridge DOWN' }
      'yellow' { 'HERMES-CONSOLE - bridge BUSY (working)' }
      'green'  { 'HERMES-CONSOLE - agent WORKING' }
      default  { 'HERMES-CONSOLE - ready (idle)' }
    }) + ' @ ' + $epNow
    $script:lastState = $state
    $script:lastEp = $epNow
  }
})
$timer.Start()

# Real message pump (Application.Run) instead of a DoEvents polling loop: a DoEvents loop that
# sleeps 60 ms between pumps starves the menu's modal loop and makes right-click feel laggy.
$script:ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($script:ctx)
$stop.Set()
try { $worker.Stop(); $worker.Dispose() } catch {}
$timer.Stop(); $timer.Dispose()
$mutex.ReleaseMutex()
