#!/usr/bin/env bash
# console_up.sh — ONE-COMMAND bring-up of the HERMES-CONSOLE pair (bridge window + tunnel).
# The tunnel and the bridge are a single unit: this script is the mandatory entry point.
# Idempotent: checks each layer, raises only what is missing, verifies end-to-end.
#
# ---- CONFIG: scripts/console.cfg (KEY=VALUE) or env vars (env wins) ----
#   HOST=user@192.168.1.10   SSH target of the Windows server
#   KEY=~/.ssh/id_ed25519    SSH private key
#   PORT=18799               bridge TCP port (server-side listen AND local tunnel endpoint)
#   TUNNEL=ssh|none          'none' = the tunnel is realized some other way (cloudflared,
#                            Tailscale serve, socat, an already-open remote port...). Then this
#                            script does NOT raise any ssh -L; it just verifies PORT is reachable.
#   HC_HOST=127.0.0.1        where the bridge is reachable FROM THIS MACHINE (with TUNNEL=none
#                            set it to the address your other tunnel exposes)
#   EXPECT_HOST=DESKTOP-SERVER   optional SSH identity check; empty = skip (portable default)
#   PS1_DIR=E:\LOCAL_HERMES  server folder holding hermes_tray.ps1 / hermes_bridge.ps1
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/console.cfg"
cfg() { # cfg KEY DEFAULT  (env HC_KEY wins, then console.cfg, then default)
  local v="${!1:-}"
  [ -z "$v" ] && v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CFG" 2>/dev/null | head -1 | tr -d '\r')"
  echo "${v:-$2}"
}
HOST="$(cfg HOST '')"
KEY="${KEY:-$(cfg KEY "$HOME/.ssh/id_ed25519")}"
PORT="$(cfg PORT 18799)"
TUNNEL="$(cfg TUNNEL ssh)"
HC_HOST="${HC_HOST:-$(cfg HC_HOST 127.0.0.1)}"
EXPECT_HOST="$(cfg EXPECT_HOST '')"
PS1_DIR="$(cfg PS1_DIR 'E:\LOCAL_HERMES')"
CLIENT="$DIR/hermes_console_client.py"
[ -n "$HOST" ] || { echo "FAIL: HOST not set (console.cfg or HC_HOST env)" >&2; exit 1; }
SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20 "$HOST")
fail() { echo "FAIL: $1" >&2; exit 1; }

# server-side PowerShell runner (-EncodedCommand: no quoting hell)
ps_run() {
  local B64
  B64=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  "${SSH[@]}" "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $B64" 2>/dev/null
}

# 1) SSH reachability (skipped for TUNNEL=none — the bridge is reached some other way).
if [ "$TUNNEL" = "ssh" ]; then
  HN="$("${SSH[@]}" hostname 2>/dev/null | tr -d '\r')"
  if [ -n "$EXPECT_HOST" ] && [ "$HN" != "$EXPECT_HOST" ]; then
    echo "SSH reached a host that is NOT $EXPECT_HOST (got: ${HN:-none})." >&2
    echo "Route to target:" >&2; route -n get "${HOST#*@}" 2>/dev/null | grep interface >&2 || true
    fail "wrong server or tunnel misrouted — check Tailscale / Amnezia split-tunnel, or set EXPECT_HOST to this server"
  fi
  [ -n "$HN" ] || fail "SSH to $HOST not working — check Tailscale / key / EXPECT_HOST"
  echo "SSH ok: ${HN}${EXPECT_HOST:+ (expected $EXPECT_HOST)}"
else
  echo "TUNNEL=none: skipping SSH; bridge must be reachable at $HC_HOST:$PORT"
fi

# 2) Bridge on the server (session 1, window hidden until the user opens it from the tray icon).
#    Launch if the port is not listening; if it listens but does not answer (ZOMBIE: the bridge died
#    and an orphan cmd.exe child kept the inherited listen socket), clear everything and relaunch.
UP="0"
if [ "$TUNNEL" = "ssh" ]; then
  UP="$("${SSH[@]}" "powershell -ExecutionPolicy Bypass -Command \"(Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count\"" 2>/dev/null | tr -dc '0-9')"
  # Task action = the tray DIRECTLY (powershell), NOT the .bat: Task Scheduler kills the whole
  # job object when the action process exits, so a bat that returns instantly via `start`
  # would take the freshly-spawned tray down with it. The bat stays for manual double-click use.
  # Do NOT swallow stderr. Success wording is locale-dependent (RU output has no "success"),
  # so verify by FACT: query the task back. schtasks /query prints UTF-16 — grep can't see it,
  # so the check runs through cmd|findstr ON THE SERVER and we read only its exit code.
  "${SSH[@]}" "schtasks /create /tn HERMES-CONSOLE /tr \"powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $PS1_DIR\\hermes_tray.ps1\" /sc once /st 00:00 /it /f" >/dev/null 2>&1
  if ! "${SSH[@]}" 'cmd /c "schtasks /query /tn HERMES-CONSOLE /fo list | findstr /i /c:HERMES-CONSOLE >nul"' 2>/dev/null; then
    echo "WARN: scheduled task HERMES-CONSOLE does not exist after /create — check permissions" >&2
  fi
fi
if [ "${UP:-0}" = "0" ]; then
  if [ "$TUNNEL" = "ssh" ]; then
    echo "bridge not up -> launching HERMES tray+bridge on the server desktop"
    "${SSH[@]}" 'schtasks /run /tn HERMES-CONSOLE' >/dev/null 2>&1 || echo "WARN: schtasks /run failed" >&2
    sleep 8
  else
    echo "bridge not listening on $HC_HOST:$PORT — start it on the server (hermes_console.bat or the scheduled task)" >&2
  fi
elif ! HC_HOST="$HC_HOST" python3 "$CLIENT" ping 2>/dev/null | grep -q pong; then
  echo "stale listener on $PORT (zombie or dead tunnel) — clearing local tunnel, server procs..."
  if [ "$TUNNEL" = "ssh" ]; then
    # local tunnel may be half-dead (remote end gone): always drop and re-raise it in this branch
    pkill -f "$PORT:127.0.0.1:$PORT" 2>/dev/null
    sleep 1
    PS="Get-CimInstance Win32_Process -Filter \"Name=\`\"powershell.exe\`\"\" | Where-Object { \$_.CommandLine -match \"hermes_bridge.ps1|hermes_tray.ps1\" } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter \"Name=\`\"cmd.exe\`\"\" | Where-Object { -not (Get-Process -Id \$_.ParentProcessId -ErrorAction SilentlyContinue) } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 2
(Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count"
    LEFT="$(ps_run "$PS" | tr -dc '0-9')"
    echo "listeners after clear: ${LEFT:-?}"
    "${SSH[@]}" 'schtasks /run /tn HERMES-CONSOLE' >/dev/null 2>&1
    sleep 8
  else
    fail "stale listener and TUNNEL=none: restart the bridge on the server, then retry"
  fi
fi

# 3) Local SSH tunnel — only TUNNEL=ssh: always paired with the bridge, never raised separately.
if [ "$TUNNEL" = "ssh" ]; then
  if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    pkill -f "$PORT:127.0.0.1:$PORT" 2>/dev/null
    ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -f -N -L $PORT:127.0.0.1:$PORT "$HOST" || fail "tunnel raise failed"
    sleep 1
  fi
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || fail "tunnel not listening on $PORT"
fi

# 4) End-to-end verify (bridge may still be booting -> retry).
PONG=""
for i in 1 2 3 4 5 6; do
  PONG="$(HC_HOST="$HC_HOST" python3 "$CLIENT" ping 2>/dev/null | tr -d '\r' | tr -d '\xef\xbb\xbf')"
  echo "$PONG" | grep -q pong && break
  sleep 3
done
echo "$PONG" | grep -q pong || fail "bridge ping failed — tray/bridge may be down on the server"
echo "HERMES-CONSOLE ready: bridge at $HC_HOST:$PORT (tunnel=$TUNNEL) — client: python3 $CLIENT hb"
