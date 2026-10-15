# hermes_tray.ps1 v4.0: TABS (several consoles, one bridge per tab) + non-blocking UI + endpoint
# menu + balloon feedback + per-tab and default folder.
# A tab = a separate HERMES-CONSOLE window/process/port (base + tab - 1). One console has exactly
# ONE input queue, so a tab busy with a long-lived server (START.bat -> ComfyUI) cannot accept other
# input; separate consoles are the only way to have several live, independently driven terminals.
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
$workDir0 = [string] (CfgVal 'WORKDIR' 'E:\AI')             # console default folder (shown in tooltip, editable in menu)
$maxTabs = [int] (CfgVal 'TABS' 8)                          # tab N listens on PORT + N - 1
if ($maxTabs -lt 1 -or $maxTabs -gt 32) { $maxTabs = 8 }
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
$status['workdir'] = $workDir0 # console default folder (tooltip + 'Set default folder...' menu)
$status['tablist'] = @()      # snapshot of tabs for the menu: {tab,port,label,workdir,state,visible,ops}
$cmds = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$stop = New-Object System.Threading.ManualResetEventSlim($false)

# ============================ worker runspace: all networking lives here ============================
$workerBody = {
  param($tlog, $bridgeScript, $bridgeBind, $bridgePort, $cfgFile, $status, $cmds, $stop, $maxTabs)
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
  function Upsert-CfgKey([string]$key, [string]$value) {
    # generic key upsert (BIND/PORT/WORKDIR): read cfg, replace the key or prepend it, write back.
    try {
      $lines = @()
      if (Test-Path $cfgFile) { $lines = @(Get-Content $cfgFile -ErrorAction SilentlyContinue) }
      $out = @(); $saw = $false
      foreach ($l in $lines) {
        if ($l -match '^\s*([A-Za-z_]+)\s*=' -and $matches[1].ToUpper() -eq $key.ToUpper()) {
          $out += ($key + '=' + $value); $saw = $true; continue
        }
        $out += $l
      }
      if (-not $saw) { $out = @($key + '=' + $value) + $out }
      Set-Content -Path $cfgFile -Value $out -Encoding UTF8
      WLog ('cfg: ' + $key + '=' + $value + ' saved to ' + $cfgFile)
      return $true
    } catch { WLog ('cfg save failed: ' + $_.Exception.Message); return $false }
  }
  function Upsert-Cfg([string]$addr, [int]$port) {
    [void] (Upsert-CfgKey 'BIND' $addr)
    [void] (Upsert-CfgKey 'PORT' ([string] $port))
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

  $workDirDefault = [string] $status['workdir']   # worker-local copy; '!setwd' updates it
  # ---- TABS: one bridge process per tab, tab N on port base+N-1 ----
  $tabs = @{}   # tab id -> hashtable(tab, port, label, workdir, proc, lastLaunch, fails, state, visible, ops)
  function New-TabState([int] $t, [string] $label, [string] $wd) {
    $h = @{ tab = $t; port = ($bridgePort + $t - 1); label = $label; workdir = $wd
            proc = $null; lastLaunch = $null; fails = 0; state = 'down'; visible = $false; ops = -1 }
    $tabs[$t] = $h
    return $h
  }
  function Launch-Tab($h) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bridgeScript, '-Tab', ([string] $h['tab']))
    if ($h['label'])   { $a += @('-TabLabel', $h['label']) }
    if ($h['workdir']) { $a += @('-WorkDir',  $h['workdir']) }
    $h['lastLaunch'] = Get-Date
    $h['proc'] = Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden -PassThru
    WLog ('tab ' + $h['tab'] + ': launched pid=' + $h['proc'].Id + ' port=' + $h['port'] + ' wd=' + $h['workdir'])
  }
  function Publish-Tabs {
    $arr = @()
    foreach ($k in ($tabs.Keys | Sort-Object)) {
      $h = $tabs[$k]
      $arr += [pscustomobject]@{ tab = $h['tab']; port = $h['port']; label = $h['label']; workdir = $h['workdir']
                                 state = $h['state']; visible = $h['visible']; ops = $h['ops'] }
    }
    $status['tablist'] = $arr
  }
  function Free-TabId {
    for ($t = 1; $t -le $maxTabs; $t++) { if (-not $tabs.ContainsKey($t)) { return $t } }
    return 0
  }
  function Close-Tab([int] $t, [string] $why) {
    if (-not $tabs.ContainsKey($t)) { return ('tab ' + $t + ' is not open') }
    $h = $tabs[$t]
    [void] (Invoke-BridgeAt (Get-Endpoint)[0] $h['port'] '{"op":"quit"}' 1500)
    if ($h['proc'] -and -not $h['proc'].HasExited) { Stop-Process -Id $h['proc'].Id -Force -ErrorAction SilentlyContinue }
    $tabs.Remove($t) | Out-Null
    Publish-Tabs
    WLog ('tab ' + $t + ': closed (' + $why + ')')
    return ('tab ' + $t + ' closed')
  }
  $wdPoll = 0   # counter for periodic 'wd' fetches (tooltip/menu folder stays honest)
  # optional manual seam: write a line "!file <cmd>" into tray_cmd.txt (same folder) to enqueue
  # a menu command from outside the UI — same handlers, same queue. ("!detect", "!setep h p", ...)
  $cmdFile = (Split-Path -Parent $tlog) + '\tray_cmd.txt'
  WLog 'worker: start'
  # Adopt tabs that are ALREADY answering (a tray restart must not orphan running consoles,
  # and a bridge started by hand must appear in the menu without a restart).
  $ep0 = Get-Endpoint
  for ($t = 1; $t -le $maxTabs; $t++) {
    $probe = Invoke-BridgeAt $ep0[0] ($bridgePort + $t - 1) '{"op":"hb"}' 700
    if ($null -ne $probe -and $probe.Count -ge 1 -and $probe[0] -match '^pong ') {
      $h = New-TabState $t '' $workDirDefault
      $h['state'] = 'alive'
      $tr = Invoke-BridgeAt $ep0[0] $h['port'] '{"op":"tab"}' 900
      if ($null -ne $tr -and $tr.Count -ge 1 -and $tr[0] -match '^T\d+ port=\d+ label=(.*)$') { $h['label'] = $matches[1].Trim() }
      $wr = Invoke-BridgeAt $ep0[0] $h['port'] '{"op":"wd"}' 900
      if ($null -ne $wr -and $wr.Count -ge 1 -and $wr[0]) { $h['workdir'] = $wr[0].Trim() }
      $p = $probe[0] -split ' '
      if ($p.Count -ge 4) { $h['visible'] = ($p[3] -eq 'VISIBLE') }
      WLog ('tab ' + $t + ': adopted live bridge on port ' + $h['port'])
    }
  }
  if ($tabs.Count -eq 0) { [void] (New-TabState 1 '' $workDirDefault); Launch-Tab $tabs[1]; WLog 'worker: no tabs found, started tab 1' }
  Publish-Tabs
  # NOTE: loop is while($true) ON PURPOSE: the queue must be drained even after $stop is set,
  # otherwise a queued '!quit' is skipped and the bridge is left orphaned when the tray exits.
  while ($true) {
    $immediate = $false   # set when a queued command changed things -> skip the poll sleep, react NOW
    try {
      if (Test-Path $cmdFile) {
        # rename-then-read: the bridge APPENDS lines here (newtab/closetab), so a plain
        # read-then-delete could swallow a line written between the two calls.
        $qf = $cmdFile + '.q'
        try { Move-Item -Force $cmdFile $qf -ErrorAction Stop } catch { WLog ('cmd-file rename failed: ' + $_.Exception.Message) }
        try {
          $raw = [System.IO.File]::ReadAllText($qf)
          Remove-Item $qf -Force -ErrorAction SilentlyContinue
        } catch { WLog ('cmd-file read failed: ' + $_.Exception.Message) }
        if ($raw) {
          foreach ($ln in ($raw -split "`r?`n")) {
            $cf = $ln.Trim() -replace '^!file\s+', ''
            if ($cf) { WLog ('cmd-file: [' + $cf + ']'); $cmds.Enqueue($cf) }
          }
        } else { WLog 'cmd-file: present but read returned nothing' }
      }
    } catch { WLog ('cmd-file error: ' + $_.Exception.Message) }
    # 1) user actions queued by the UI (menu clicks / double-click) go first — they must feel instant
    $j = $null
    while ($cmds.TryDequeue([ref] $j)) {
      if ($j -eq '!quit') {
        # quit EVERY tab: each bridge saves its own history/geometry on quit, then we make sure
        # the process is gone (a bridge that does not answer must not leave a zombie window).
        foreach ($t in @($tabs.Keys)) { [void] (Close-Tab $t 'quit all') }
        $status['quitui'] = $true   # the paint timer will close the UI too (seam '!quit' must not leave a zombie icon)
        $stop.Set(); break
      }
      if ($j -eq '!toggle') {
        # icon double-click: one gesture for the whole set - show every hidden tab, or hide all
        $anyVisible = $false
        foreach ($t in $tabs.Keys) { if ($tabs[$t]['visible']) { $anyVisible = $true } }
        $j = if ($anyVisible) { '!hideall' } else { '!showall' }
      }
      if ($j -in @('!showall','!hideall')) {
        $opName = if ($j -eq '!showall') { 'show' } else { 'hide' }
        foreach ($t in @($tabs.Keys)) { [void] (Invoke-BridgeAt (Get-Endpoint)[0] $tabs[$t]['port'] ('{"op":"' + $opName + '"}') 2000) }
        WLog ('worker: ' + $opName + ' applied to ' + $tabs.Count + ' tab(s)')
      } elseif ($j -eq '!restart') {
        foreach ($t in @($tabs.Keys)) {
          $h = $tabs[$t]
          [void] (Invoke-BridgeAt (Get-Endpoint)[0] $h['port'] '{"op":"quit"}' 1500)
          if ($h['proc'] -and -not $h['proc'].HasExited) { Stop-Process -Id $h['proc'].Id -Force -ErrorAction SilentlyContinue }
          $h['proc'] = $null; $h['lastLaunch'] = $null; $h['fails'] = 0; $h['state'] = 'down'
        }
        Start-Sleep -Milliseconds 600
        # launch right here — waiting for supervision would cost 4 failed polls first (~3 s)
        foreach ($t in @($tabs.Keys)) {
          try { Launch-Tab $tabs[$t] } catch { WLog ('worker: restart launch failed tab ' + $t + ': ' + $_.Exception.Message) }
        }
        Publish-Tabs
      } elseif ($j -match '^!addtab (.*)$') {
        # new tab: "label|workdir" (either part may be empty)
        $spec = $matches[1]
        $parts = $spec -split '\|', 2
        $lbl = [string] $parts[0]
        $wd = if ($parts.Count -gt 1) { [string] $parts[1] } else { '' }
        $id = Free-TabId
        if ($id -eq 0) {
          $status['balloon'] = @('warning', 'HERMES: no free tab', ('All ' + $maxTabs + ' tabs are open - close one first (TABS=' + $maxTabs + ' in hermes_console.cfg).'))
          WLog 'addtab: no free tab id'
        } elseif ($wd -and (Test-Path -LiteralPath $wd -PathType Leaf)) {
          $status['balloon'] = @('warning', 'HERMES: bad folder', ('This is a file, not a folder: ' + $wd + ' - tab not created.'))
        } else {
          $h = New-TabState $id $lbl $wd
          try { Launch-Tab $h; Publish-Tabs
            $status['balloon'] = @('info', 'HERMES: tab opened', ('Tab T' + $id + ' started on port ' + $h['port'] + ' in ' + ($wd -or $workDirDefault) + '. Open it from the tray menu (Tabs).'))
          } catch { $tabs.Remove($id) | Out-Null; Publish-Tabs
            $status['balloon'] = @('warning', 'HERMES: tab failed', ('Could not start tab T' + $id + ': ' + $_.Exception.Message)) }
        }
        $immediate = $true
      } elseif ($j -match '^!closetab (\d+)$') {
        $msg = Close-Tab ([int] $matches[1]) 'user request'
        $status['balloon'] = @('info', 'HERMES: tab closed', $msg)
        $immediate = $true
      } elseif ($j -match '^!tabop (\S+) (\d+)$') {
        # per-tab show/hide from the menu
        $th = $tabs[[int] $matches[2]]
        if ($th) { [void] (Invoke-BridgeAt (Get-Endpoint)[0] $th['port'] ('{"op":"' + $matches[1] + '"}') 2000) }
      } elseif ($j -match '^!tabrestart (\d+)$') {
        $th = $tabs[[int] $matches[1]]
        if ($th) {
          [void] (Invoke-BridgeAt (Get-Endpoint)[0] $th['port'] '{"op":"quit"}' 1500)
          if ($th['proc'] -and -not $th['proc'].HasExited) { Stop-Process -Id $th['proc'].Id -Force -ErrorAction SilentlyContinue }
          $th['proc'] = $null; $th['fails'] = 0; $th['state'] = 'down'
          Start-Sleep -Milliseconds 400
          try { Launch-Tab $th } catch { WLog ('tabrestart: launch failed: ' + $_.Exception.Message) }
          Publish-Tabs
        }
        $immediate = $true
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
      } elseif ($j -match '^!setwd (.+)$') {
        # default console folder: save WORKDIR into the cfg, then relaunch the bridge so it
        # re-reads the cfg and starts cmd.exe in the NEW folder (history file is path-independent).
        # The bridge CREATES a missing folder at startup, but a file in place of the path must fail
        # with an honest balloon instead of a silent restart into confusion.
        $wd = $matches[1].Trim().Trim('"')
        if (-not $wd) {
          $status['balloon'] = @('warning', 'HERMES: bad folder', 'Folder path is empty - nothing changed.')
        } elseif ((Test-Path -LiteralPath $wd -PathType Leaf)) {
          $status['balloon'] = @('warning', 'HERMES: bad folder', ('This is a file, not a folder: ' + $wd + ' - nothing changed.'))
          WLog ('setwd: refused, path is a file: ' + $wd)
        } else {
          if (Upsert-CfgKey 'WORKDIR' $wd) {
            $status['workdir'] = $wd
            # tabs that follow the DEFAULT folder move with it; a tab opened with its own explicit
            # folder keeps that folder (that is the point of per-tab folders)
            $moved = 0
            foreach ($t in @($tabs.Keys)) {
              if (-not $tabs[$t]['workdir'] -or $tabs[$t]['workdir'] -eq $workDirDefault) {
                $tabs[$t]['workdir'] = ''; $moved++
                [void] (Invoke-BridgeAt (Get-Endpoint)[0] $tabs[$t]['port'] '{"op":"quit"}' 1500)
                if ($tabs[$t]['proc'] -and -not $tabs[$t]['proc'].HasExited) { Stop-Process -Id $tabs[$t]['proc'].Id -Force -ErrorAction SilentlyContinue }
                $tabs[$t]['proc'] = $null; $tabs[$t]['fails'] = 0; $tabs[$t]['state'] = 'down'
              }
            }
            $workDirDefault = $wd
            Start-Sleep -Milliseconds 500
            foreach ($t in @($tabs.Keys)) { if (-not $tabs[$t]['proc'] -or $tabs[$t]['proc'].HasExited) { try { Launch-Tab $tabs[$t] } catch { WLog ('setwd relaunch failed tab ' + $t) } } }
            Publish-Tabs
            $status['balloon'] = @('info', 'HERMES: folder applied',
              ('Default folder applied and saved: ' + $wd + ' - restarted ' + $moved + ' default-folder tab(s); tabs with their own folder untouched.'))
            WLog ('setwd: WORKDIR=' + $wd + ' - restarted ' + $moved + ' tab(s) into it')
            $immediate = $true
          } else {
            $status['balloon'] = @('warning', 'HERMES: save failed', ('Could not write WORKDIR into ' + $cfgFile + ' - nothing changed.'))
          }
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

    # 2) heartbeat EVERY tab: liveness + activity + visibility in ONE round trip each
    #    ("pong <secs> <ops> <VISIBLE|HIDDEN>"). The icon shows the AGGREGATE: any tab working =
    #    green blink, any tab alive = not red, all tabs silent-but-alive = yellow, all dead = red.
    $epH = (Get-Endpoint)[0]
    $anyAlive = $false; $anyBusy = $false; $opsSum = 0; $anyVisible = $false
    $published = $false
    foreach ($t in @($tabs.Keys)) {
      $h = $tabs[$t]
      $r = Invoke-BridgeAt $epH $h['port'] '{"op":"hb"}' 2500
      if ($null -ne $r -and $r.Count -ge 1 -and $r[0] -match '^pong ') {
        if ($h['fails'] -ge 2) { WLog ('tab ' + $t + ': back after ' + $h['fails'] + ' failed polls') }
        $h['fails'] = 0; $h['state'] = 'alive'
        $p = $r[0] -split ' '
        if ($p.Count -ge 3) { $h['ops'] = [int] $p[2] }
        if ($p.Count -ge 4) { $h['visible'] = ($p[3] -eq 'VISIBLE') }
      } else {
        $h['fails']++
        if ($h['fails'] -ge 4) {
          # only now do we call it dead: 4 consecutive failures ~= several seconds of silence
          if ($h['proc'] -and -not $h['proc'].HasExited) {
            # honest status: process ALIVE but not answering = BUSY (long command / booting).
            # NOT down: the icon must never lie. The bridge answers hb between ops.
            $h['state'] = 'busy'
            if ($h['fails'] % 10 -eq 4) { WLog ('tab ' + $t + ': busy (alive, silent ' + ($h['fails'] * 3) + 's) - not touching it') }
          } else {
            $h['state'] = 'down'
            if (-not $h['lastLaunch'] -or ((Get-Date) - $h['lastLaunch']).TotalSeconds -ge 30) {
              # a dead bridge's orphan cmd.exe child may still own the port (inherited listen socket)
              try {
                Get-NetTCPConnection -LocalPort $h['port'] -State Listen -ErrorAction SilentlyContinue |
                  ForEach-Object {
                    $pp = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)" -ErrorAction SilentlyContinue
                    if ($pp -and ($pp.Name -in @('powershell.exe', 'cmd.exe', 'conhost.exe'))) {
                      Stop-Process -Id $pp.ProcessId -Force -ErrorAction SilentlyContinue
                      WLog ('worker: killed stale port owner pid=' + $pp.ProcessId + ' name=' + $pp.Name)
                    }
                  }
                Start-Sleep -Milliseconds 400
              } catch {}
              try { Launch-Tab $h; $published = $true } catch { WLog ('tab ' + $t + ': relaunch failed: ' + $_.Exception.Message) }
              $h['fails'] = 0
            }
          }
        }
      }
      if ($h['state'] -eq 'alive') { $anyAlive = $true; $opsSum += [int] $h['ops']; if ($h['visible']) { $anyVisible = $true } }
      elseif ($h['state'] -eq 'busy') { $anyBusy = $true }
    }
    $status['state'] = if ($anyAlive) { 'alive' } elseif ($anyBusy) { 'busy' } else { 'down' }
    $status['ops'] = $opsSum
    $status['visible'] = $anyVisible
    # keep the folder shown in tooltip/menu honest: the BRIDGE knows where cmd.exe really
    # started (a manual cfg edit or a bridge restart with another cfg must stay visible).
    $wdPoll = $wdPoll + 1
    if ($wdPoll -ge 15 -and $tabs.Count -ge 1) {
      $wdPoll = 0
      $first = ($tabs.Keys | Sort-Object | Select-Object -First 1)
      $wr = Invoke-BridgeAt $epH $tabs[$first]['port'] '{"op":"wd"}' 1500
      if ($null -ne $wr -and $wr.Count -ge 1 -and $wr[0] -and $wr[0] -notlike 'ERR*') {
        $tabs[$first]['workdir'] = $wr[0].Trim()
        $status['workdir'] = $wr[0].Trim()
      }
    }
    Publish-Tabs

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
foreach ($a in @($tlog, $bridgeScript, $bridgeBind, $bridgePort, $cfgFile, $status, $cmds, $stop, $maxTabs)) { [void] $worker.AddArgument($a) }
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
$miShow = $menu.Items.Add('Show all consoles')
$miHide = $menu.Items.Add('Hide all consoles')
# ---- Tabs submenu: rebuilt on every open from the worker's tab table (status['tablist']) ----
$miTabs = New-Object System.Windows.Forms.ToolStripMenuItem
$miTabs.Text = 'Tabs'
[void] $menu.Items.Add($miTabs)
$miAddTab = $menu.Items.Add('New tab...')
[void] $menu.Items.Add('-')
$miRestart = $menu.Items.Add('Restart all bridges')
# ---- Endpoint section: where this tray talks to the bridge (host:port) ----
[void] $menu.Items.Add('-')
$miEpLabel = $menu.Items.Add('Endpoint: -')
$miEpLabel.Enabled = $false
$miEpAuto = $menu.Items.Add('Auto-detect on this PC')
$miEpManual = $menu.Items.Add('Set host:port manually...')
# ---- Folder section: default working folder of the console (WORKDIR), editable without files ----
[void] $menu.Items.Add('-')
$miWdLabel = $menu.Items.Add('Folder: -')
$miWdLabel.Enabled = $false
$miWdSet = $menu.Items.Add('Set default folder...')
[void] $menu.Items.Add('-')
$miQuit = $menu.Items.Add('Quit')
$ni.ContextMenuStrip = $menu

# Refresh the endpoint label each time the menu opens — reads the shared cache only, no I/O.
$menu.Add_Opening({
  # ---- rebuild the Tabs submenu from the worker's snapshot (cache read only, no sockets) ----
  $script:miTabs.DropDownItems.Clear()
  $tl = @($script:status['tablist'])
  foreach ($t in $tl) {
    $mark = if ($t.visible) { '[open]  ' } elseif ($t.state -eq 'alive') { '[hidden]' } else { '[' + $t.state.ToUpper() + ']' }
    $name = 'T' + $t.tab
    if ($t.label) { $name += ' - ' + $t.label }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = ($mark + ' ' + $name + '  :' + $t.port)
    $ti = $t.tab
    if ($t.visible) { $item.Add_Click({ $script:cmds.Enqueue(('!tabop hide ' + $ti)) }.GetNewClosure()) }
    else { $item.Add_Click({ $script:cmds.Enqueue(('!tabop show ' + $ti)) }.GetNewClosure()) }
    [void] $script:miTabs.DropDownItems.Add($item)
    $subShow = New-Object System.Windows.Forms.ToolStripMenuItem; $subShow.Text = 'Show'
    $subShow.Add_Click({ $script:cmds.Enqueue(('!tabop show ' + $ti)) }.GetNewClosure())
    $subHide = New-Object System.Windows.Forms.ToolStripMenuItem; $subHide.Text = 'Hide'
    $subHide.Add_Click({ $script:cmds.Enqueue(('!tabop hide ' + $ti)) }.GetNewClosure())
    $subRestart = New-Object System.Windows.Forms.ToolStripMenuItem; $subRestart.Text = 'Restart'
    $subRestart.Add_Click({ $script:cmds.Enqueue(('!tabrestart ' + $ti)) }.GetNewClosure())
    $subClose = New-Object System.Windows.Forms.ToolStripMenuItem; $subClose.Text = 'Close tab'
    $subClose.Add_Click({ $script:cmds.Enqueue(('!closetab ' + $ti)) }.GetNewClosure())
    [void] $item.DropDownItems.AddRange(@($subShow, $subHide, $subRestart, $subClose))
  }
  if ($tl.Count -eq 0) {
    $none = New-Object System.Windows.Forms.ToolStripMenuItem; $none.Text = '(no tabs)'; $none.Enabled = $false
    [void] $script:miTabs.DropDownItems.Add($none)
  }
  $script:miEpLabel.Text = 'Endpoint: ' + [string] $script:status['endpoint']
  $wdTxt = [string] $script:status['workdir']
  # tooltip/menu text has a hard cap in Windows; trim long paths from the middle, keep the tail
  if ($wdTxt.Length -gt 50) { $wdTxt = '...' + $wdTxt.Substring($wdTxt.Length - 47) }
  $script:miWdLabel.Text = 'Folder: ' + $wdTxt
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

# New-tab dialog: an optional label and an optional folder. Cancel = nothing happens.
# The folder box is prefilled with the DEFAULT folder; clearing it means 'use whatever the
# bridge cfg says'. The worker validates and launches; failures come back as a balloon.
function Show-NewTabDialog {
  $frm = New-Object System.Windows.Forms.Form
  $frm.Text = 'HERMES - new console tab'
  $frm.FormBorderStyle = 'FixedDialog'; $frm.MaximizeBox = $false; $frm.MinimizeBox = $false
  $frm.ShowInTaskbar = $false; $frm.TopMost = $true
  $frm.ClientSize = New-Object System.Drawing.Size(420, 150)
  $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Label (optional):'; $l1.Location = New-Object System.Drawing.Point(12, 14); $l1.AutoSize = $true
  $tbL = New-Object System.Windows.Forms.TextBox; $tbL.Location = New-Object System.Drawing.Point(120, 11); $tbL.Width = 285
  $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'Folder:'; $l2.Location = New-Object System.Drawing.Point(12, 44); $l2.AutoSize = $true
  $tbW = New-Object System.Windows.Forms.TextBox; $tbW.Text = [string] $script:status['workdir']; $tbW.Location = New-Object System.Drawing.Point(120, 41); $tbW.Width = 245
  $btnW = New-Object System.Windows.Forms.Button; $btnW.Text = '...'; $btnW.Location = New-Object System.Drawing.Point(370, 40); $btnW.Width = 35
  $btnW.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path -LiteralPath $tbW.Text -PathType Container) { $fb.SelectedPath = $tbW.Text }
    if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $fb.SelectedPath) { $tbW.Text = $fb.SelectedPath }
    $fb.Dispose()
  })
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Open tab'; $ok.Location = New-Object System.Drawing.Point(120, 92); $ok.Width = 110; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(240, 92); $cancel.Width = 110; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $frm.Controls.AddRange(@($l1, $tbL, $l2, $tbW, $btnW, $ok, $cancel))
  $frm.AcceptButton = $ok; $frm.CancelButton = $cancel
  $res = $frm.ShowDialog()
  $lbl = $tbL.Text.Trim(); $wd = $tbW.Text.Trim()
  $frm.Dispose()
  if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
  if ($lbl -match '[|\r\n]') { [void] [System.Windows.Forms.MessageBox]::Show('Label must not contain | or newlines.', 'HERMES', 'OK', 'Warning'); return $null }
  return ($lbl + '|' + $wd)
}

# Every handler only ENQUEUES — no sockets, no Sleep, so the menu closes instantly and the
# worker performs the action right after its current poll.
$miShow.Add_Click({ $script:cmds.Enqueue('!showall') })
$miHide.Add_Click({ $script:cmds.Enqueue('!hideall') })
$miRestart.Add_Click({ $script:cmds.Enqueue('!restart') })
$miAddTab.Add_Click({
  $spec = Show-NewTabDialog
  if ($null -ne $spec) { $script:cmds.Enqueue(('!addtab ' + $spec)) }
})
$miEpAuto.Add_Click({ $script:cmds.Enqueue('!detect') })
$miEpManual.Add_Click({
  $spec = Show-EndpointDialog
  if ($spec) { $script:cmds.Enqueue(('!setep ' + $spec)) }
})
$miWdSet.Add_Click({
  # native folder picker (Start-Path prefilled with the current folder); pure UI, the worker
  # does the apply (cfg write + bridge restart). Cancel leaves everything untouched.
  $fb = New-Object System.Windows.Forms.FolderBrowserDialog
  $fb.Description = 'Default folder for the HERMES console (WORKDIR)'
  $cur = [string] $script:status['workdir']
  if ($cur -and (Test-Path -LiteralPath $cur -PathType Container)) { $fb.SelectedPath = $cur }
  $res = $fb.ShowDialog()
  $sel = $fb.SelectedPath
  $fb.Dispose()
  if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $sel) {
    $script:cmds.Enqueue(('!setwd ' + $sel))
  }
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
  $wdNow = [string] $script:status['workdir']
  if ($wdNow.Length -gt 40) { $wdNow = '...' + $wdNow.Substring($wdNow.Length - 37) }   # tooltip cap
  if ($state -ne $script:lastState -or $epNow -ne $script:lastEp -or $wdNow -ne $script:lastWd) {
    $script:ni.Icon = Make-Icon $state
    $tip = $(switch ($state) {
      'red'    { 'HERMES-CONSOLE - bridge DOWN' }
      'yellow' { 'HERMES-CONSOLE - bridge BUSY (working)' }
      'green'  { 'HERMES-CONSOLE - agent WORKING' }
      default  { 'HERMES-CONSOLE - ready (idle)' }
    }) + ' @ ' + $epNow + ' | ' + $wdNow
    $tl2 = @($script:status['tablist'])
    if ($tl2.Count -gt 0) {
      $vis = 0; foreach ($t in $tl2) { if ($t.visible) { $vis++ } }
      $tip += ' | tabs: ' + $tl2.Count + ' (' + $vis + ' shown)'
    }
    # HARD CAP: NotifyIcon.Text throws ArgumentException over 63 chars on .NET Framework
    # (PS 5.1) — an unclamped tooltip killed the tray with a .NET crash dialog on the monitor.
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $script:ni.Text = $tip
    $script:lastState = $state
    $script:lastEp = $epNow
    $script:lastWd = $wdNow
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
