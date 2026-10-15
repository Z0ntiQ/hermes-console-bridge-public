#!/usr/bin/env bash
# console_down.sh — paired teardown: tray applet + bridge + tunnel all die together.
# Reads the same console.cfg as console_up.sh (HOST/KEY/PORT/TUNNEL/HC_HOST).
# TUNNEL=none: only the bridge `quit` is sent (a foreign tunnel is yours to manage).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/console.cfg"
cfg() {
  local v="${!1:-}"
  [ -z "$v" ] && v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CFG" 2>/dev/null | head -1 | tr -d '\r')"
  echo "${v:-$2}"
}
HOST="$(cfg HOST '')"
KEY="${KEY:-$(cfg KEY "$HOME/.ssh/id_ed25519")}"
PORT="$(cfg PORT 18799)"
TUNNEL="$(cfg TUNNEL ssh)"
HC_HOST="${HC_HOST:-$(cfg HC_HOST 127.0.0.1)}"
CLIENT="$DIR/hermes_console_client.py"

# 1) bridge self-quit (kills bridge + child cmd; history is saved first)
HC_HOST="$HC_HOST" python3 "$CLIENT" quit >/dev/null 2>&1
echo "bridge quit sent"

# 2) kill tray + bridge processes on the server (match their command lines).
#    -EncodedCommand avoids all cross-shell quoting hell.
if [ "$TUNNEL" = "ssh" ] && [ -n "$HOST" ]; then
  SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20 "$HOST")
  PS='Get-CimInstance Win32_Process -Filter "Name=`"powershell.exe`"" | Where-Object { $_.CommandLine -match "hermes_tray.ps1|hermes_bridge.ps1" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }'
  B64=$(printf '%s' "$PS" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  "${SSH[@]}" "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $B64" >/dev/null 2>&1
  echo "tray + bridge processes killed (icon removed from the clock area)"
fi

# 3) local tunnel (only ours; a foreign tunnel is not ours to kill)
if [ "$TUNNEL" = "ssh" ]; then
  pkill -f "$PORT:127.0.0.1:$PORT" 2>/dev/null
  echo "tunnel dropped"
fi
