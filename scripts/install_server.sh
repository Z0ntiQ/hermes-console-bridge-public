#!/usr/bin/env bash
# install_server.sh — one-command deployment of the HERMES-CONSOLE server side onto a NEW
# Windows server. This repo + this script = turnkey: it copies the scripts (CRLF), creates the
# server-side config from the example (NEVER overwrites an existing one), registers the
# scheduled task, and verifies the stack end-to-end. After it prints OK, use console_up.sh /
# console_down.sh as the daily entry points.
#
# Reads the SAME console.cfg as console_up.sh (HOST/KEY/PORT/TUNNEL/HC_HOST/PS1_DIR/EXPECT_HOST).
# Prerequisites it CHECKS (and tells you exactly what is missing if it fails):
#   - SSH to HOST works with KEY (BatchMode: key auth only, no password prompts)
#   - PS1_DIR is writable (created if absent)
# What it does NOT check (human prerequisites, printed as a reminder):
#   - someone is logged in at the server's monitor (session 1): the tray/console are GUI,
#     they only appear on the physical desktop
#   - the network path (Tailscale/VPN/SSH tunnel) is up
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
EXPECT_HOST="$(cfg EXPECT_HOST '')"
PS1_DIR="$(cfg PS1_DIR 'E:\LOCAL_HERMES')"
CLIENT="$DIR/hermes_console_client.py"
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -n "$HOST" ] || fail "HOST not set — copy console.cfg.example to console.cfg and fill it"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20 "$HOST")

# 1) SSH identity check (same rule as console_up.sh: verify by fact, not hope)
HN="$("${SSH[@]}" hostname 2>/dev/null | tr -d '\r')"
[ -n "$HN" ] || fail "SSH to $HOST does not work — check the network path (Tailscale/VPN), the key ($KEY), and that the Windows OpenSSH server runs"
if [ -n "$EXPECT_HOST" ] && [ "$HN" != "$EXPECT_HOST" ]; then
  fail "SSH reached '$HN', but EXPECT_HOST is '$EXPECT_HOST' — wrong server or misrouted tunnel"
fi
echo "SSH ok: $HN"

# 2) server folder: create if absent, prove it is writable by a real round-trip.
#    PowerShell with -EncodedCommand: nested cmd quotes through ssh are a trap (see up script).
ps_run() {
  local B64
  B64=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  "${SSH[@]}" "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $B64" 2>/dev/null
}
RES="$(ps_run "if (-not (Test-Path -LiteralPath '$PS1_DIR')) { New-Item -ItemType Directory -Force -Path '$PS1_DIR' | Out-Null }
\$t = Join-Path '$PS1_DIR' '.hermes_write_test'
try { Set-Content -LiteralPath \$t -Value ok -ErrorAction Stop; Remove-Item \$t -Force; Write-Output 'DIR-OK' } catch { Write-Output ('DIR-FAIL: ' + \$_.Exception.Message) }" | tr -d '\r')"
echo "$RES" | grep -q '^DIR-OK' || fail "cannot create/write $PS1_DIR on the server: ${RES:-no answer} — check the drive letter and permissions"
echo "server dir ok: $PS1_DIR"

# 3) copy scripts with CRLF endings (Windows convention; PS 5.1 is picky about mixed files).
#    The .ps1 files in the repo carry a UTF-8 BOM — keep it, sed on a copy does not strip it.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for f in hermes_bridge.ps1 hermes_tray.ps1 hermes_console.bat; do
  [ -f "$DIR/$f" ] || fail "repo is missing $f"
  sed 's/$/\r/' "$DIR/$f" > "$TMP/$f"
done
[ -f "$DIR/hermes_console_client.py" ] || fail "repo is missing hermes_console_client.py"
scp -i "$KEY" -q "$TMP"/*.ps1 "$TMP"/*.bat "$DIR/hermes_console_client.py" "$HOST:$PS1_DIR/" || fail "scp failed"
echo "scripts copied: bridge, tray, client, bat -> $PS1_DIR"

# 4) server-side config: create from the example ONLY if absent (an existing cfg is sacred:
#    it holds this server's BIND/PORT/WORKDIR choices made from the tray)
HAVE_CFG="$(ps_run "if (Test-Path -LiteralPath (Join-Path '$PS1_DIR' 'hermes_console.cfg')) { 'YES' } else { 'NO' }" | tr -d ' \r')"
if [ "$HAVE_CFG" = "NO" ]; then
  sed 's/$/\r/' "$DIR/hermes_console.cfg.example" > "$TMP/hermes_console.cfg"
  scp -i "$KEY" -q "$TMP/hermes_console.cfg" "$HOST:$PS1_DIR/" || fail "scp cfg failed"
  echo "server config created from example (BIND/PORT/WORKDIR editable later from the tray menu or by hand)"
else
  echo "server config exists — left untouched"
fi

# 5) scheduled task (same action wording as console_up.sh: the tray DIRECTLY, not the .bat —
#    Task Scheduler kills the job object when the action exits, a bat would take the tray down)
"${SSH[@]}" "schtasks /create /tn HERMES-CONSOLE /tr \"powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $PS1_DIR\\hermes_tray.ps1\" /sc once /st 00:00 /it /f" >/dev/null 2>&1
# verify by FACT through cmd|findstr on the server (schtasks /query prints UTF-16; local grep can't see it)
"${SSH[@]}" 'cmd /c "schtasks /query /tn HERMES-CONSOLE /fo list | findstr /i /c:HERMES-CONSOLE >nul"' 2>/dev/null \
  || fail "scheduled task HERMES-CONSOLE not visible after create — check admin rights / interactive task permissions"
echo "scheduled task ok: HERMES-CONSOLE"

# 6) end-to-end verify: bring the stack up through the normal entry point and ping the bridge.
#    If the stack is already running with the OLD files, say so honestly: new code activates
#    on the next console_down.sh + console_up.sh, we do NOT silently restart a working session.
if HC_HOST="$HC_HOST" python3 "$CLIENT" ping 2>/dev/null | grep -q pong; then
  echo "bridge already running — new files will activate on the next console_down.sh + console_up.sh"
else
  bash "$DIR/console_up.sh" || fail "console_up.sh failed on a fresh install — see its message above"
fi

echo ""
echo "INSTALL OK. Reminder (human prerequisites): a user must be logged in at the server's"
echo "monitor for the tray icon and console window to appear on the physical desktop."
echo "Daily use: bash console_up.sh / console_down.sh; client: python3 $CLIENT hb"
