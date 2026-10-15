#!/usr/bin/env python3
"""Client for the HERMES-CONSOLE bridge (default: via SSH tunnel 127.0.0.1:18799).

Endpoint is configurable — for a different tunnel realization (cloudflared, Tailscale
serve, socat, an existing remote port, etc.) point the client at it:
  env:       HC_HOST=100.x.y.z HC_PORT=18799 python3 hermes_console_client.py ...
  flags:     python3 hermes_console_client.py --host 100.x.y.z --port 18799 screen
  config:    scripts/console.cfg (KEY=VALUE, same file console_up.sh reads)

Protocol v2 — unique line prefixes, never confused with stray traffic:
  request : HERMES-REQ-8F27:<json>
  payload : HERMES-RES-8F27:<line>   (repeated)
  end     : HERMES-DONE-8F27:<op>
"""
import json, os, socket, sys

def load_cfg():
    """KEY=VALUE from scripts/console.cfg (next to this file), if present."""
    cfg = {}
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "console.cfg")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8", errors="replace"):
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                cfg[k.strip().upper()] = v.strip()
    return cfg

def pick(name, default):
    # priority: env > console.cfg > default
    return os.environ.get("HC_" + name) or load_cfg().get("HC_" + name) or default

HOST = pick("HOST", "127.0.0.1")      # where the bridge is REACHABLE from this machine.
                                      # NOTE: in console.cfg this is HC_HOST (plain HOST there
                                      # is the SSH target "user@host" — never a connect address).
BASE_PORT = int(pick("PORT", "18799"))
PORT = BASE_PORT                      # tab N speaks on BASE_PORT + N - 1
MAX_TABS = int(pick("TABS", "8"))     # how many tab ports to probe for `tabs`
TAB = 1
REQ, RES, DONE = "HERMES-REQ-8F27:", "HERMES-RES-8F27:", "HERMES-DONE-8F27:"

def request(obj, timeout=30):
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    s.settimeout(timeout)
    f = s.makefile("rwb")
    f.write((REQ + json.dumps(obj, ensure_ascii=True) + "\n").encode())
    f.flush()
    out = []
    while True:
        line = f.readline()
        if not line:
            break
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if line.startswith(DONE):
            break
        if line.startswith(RES):
            out.append(line[len(RES):])
    s.close()
    return "\n".join(out)

if __name__ == "__main__":
    argv = sys.argv[1:]
    # global flags before the command: --host H --port P
    while argv and argv[0].startswith("--"):
        if argv[0] == "--host" and len(argv) > 2:
            HOST, argv = argv[1], argv[2:]
        elif argv[0] == "--port" and len(argv) > 2:
            try:
                PORT = int(argv[1])
            except ValueError:
                print("bad --port:", argv[1]); sys.exit(2)
            if not 1 <= PORT <= 65535:
                print("bad --port:", argv[1]); sys.exit(2)
            BASE_PORT = PORT
            argv = argv[2:]
        elif argv[0] == "--tab" and len(argv) > 2:
            # tab addressing: `--tab 2 keys "..."` -> port BASE_PORT + 1
            try:
                TAB = int(argv[1])
            except ValueError:
                print("bad --tab:", argv[1]); sys.exit(2)
            if not 1 <= TAB <= 32:
                print("bad --tab (1..32):", argv[1]); sys.exit(2)
            PORT = BASE_PORT + TAB - 1
            argv = argv[2:]
        else:
            print("unknown flag:", argv[0]); sys.exit(2)
    cmd = argv[0] if argv else "screen"

    def need(n, what):
        if len(argv) <= n:
            print("usage: hermes_console_client.py %s %s" % (cmd, what))
            sys.exit(2)

    def run(obj, timeout=30):
        # one clean error line instead of a socket traceback — the agent parses stdout
        try:
            print(request(obj, timeout=timeout))
        except OSError as e:
            print("ERROR: cannot reach bridge at %s:%s — %s" % (HOST, PORT, e))
            print("(tunnel down? raise it: bash console_up.sh)")
            sys.exit(1)

    if cmd == "ping":
        run({"op": "ping"})
    elif cmd == "state":
        run({"op": "state"})
    elif cmd == "hb":
        run({"op": "hb"}, timeout=10)
    elif cmd == "wd":
        run({"op": "wd"})   # console default folder (what WORKDIR resolves to on the server)
    elif cmd == "geom":
        run({"op": "geom"})   # window placement: showCmd (1=normal 3=maximized), normal rect, live rect
    elif cmd == "screen":
        run({"op": "screen"})
    elif cmd == "history":
        lines = 400
        if len(argv) > 1:
            try:
                lines = max(1, min(9999, int(argv[1])))
            except ValueError:
                print("history: LINES must be a number"); sys.exit(2)
        run({"op": "history", "lines": lines})
    elif cmd == "show":
        run({"op": "show"})
    elif cmd == "hide":
        run({"op": "hide"})
    elif cmd == "sysmenu":
        run({"op": "sysmenu"}, timeout=10)
    elif cmd == "keys":
        # No sleep: the bridge injects and answers instantly. For long-running commands, poll
        # `screen`/`history` afterwards — never make the bridge wait (rock-solid status matters).
        # Enter is appended here: 'keys' means "type AND run". Without the trailing \r the text
        # only sits on the input line (this regression made every marker check a false positive —
        # grep matched the typed command, not its output).
        need(1, "keys \"text to type\"")
        text = argv[1]
        if not text.endswith("\r"):
            text += "\r"
        run({"op": "keys", "text": text}, timeout=15)
    elif cmd == "quit":
        run({"op": "quit"})
    elif cmd == "tabs":
        # probe the whole tab port range through the SAME endpoint: a tab that answers hb is open.
        # (The tray keeps its own table; the client stays stateless — no shared registry to corrupt.)
        rows = []
        for t in range(1, MAX_TABS + 1):
            PORT = BASE_PORT + t - 1   # request() reads the module-level PORT: rebind BEFORE probing
            try:
                hb = request({"op": "hb"}, timeout=2)
            except OSError:
                hb = ""
            if hb.startswith("pong"):
                parts = hb.split()
                ops = parts[2] if len(parts) > 2 else "?"
                vis = parts[3] if len(parts) > 3 else "?"
                try:
                    ident = request({"op": "tab"}, timeout=2)
                except OSError:
                    ident = ""
                # split BEFORE strip: an empty label makes the reply "label= pid=1234" and the
                # leading space is what separates the label from the pid field
                label = ident.split("label=", 1)[1].split(" pid=", 1)[0].strip() if "label=" in ident else ""
                rows.append("T%d\tport=%d\t%s\tops=%s\t%s" % (t, PORT, vis, ops, ("label=" + label) if label else ""))
        if not rows:
            print("no tabs answering on ports %d..%d" % (BASE_PORT, BASE_PORT + MAX_TABS - 1))
        else:
            print("\n".join(rows))
    elif cmd == "newtab":
        # ask the TRAY (through the bridge's seam) to open a new console in the desktop session.
        # usage: newtab ["label"] ["folder"]
        obj = {"op": "newtab"}
        if len(argv) > 1:
            obj["label"] = argv[1]
        if len(argv) > 2:
            obj["workdir"] = argv[2]
        run(obj, timeout=15)
    elif cmd == "closetab":
        need(1, "closetab N")
        try:
            n = int(argv[1])
        except ValueError:
            print("closetab: N must be a number"); sys.exit(2)
        run({"op": "closetab", "tab": n}, timeout=15)
    else:
        print("unknown command:", cmd)
        print("commands: ping hb state screen history [lines] keys \"text\" show hide sysmenu quit")
        print("          tabs  newtab [label] [folder]  closetab N   (global: --host H --port P --tab N)")
        sys.exit(2)
