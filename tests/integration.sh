#!/bin/sh
# Integration test against a running local Rex server. Creates and kills its
# own disposable session; never selects it in the app or reloads your config.
# Needs nvim on the login shell's PATH.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
json() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

# The pane prints its own output, then idles: no typing into a shell that may
# not be ready yet.
session=$(rex new rex-history-test --json -- sh -c 'seq -f "REXHIST-%04g" 1 3000; exec sleep 600' | json 'd["session_id"]')
trap 'rex kill "$session" >/dev/null 2>&1 || true' EXIT
block=$(rex session inspect "$session" --json | json 'd["windows"][0]["focused_block_id"]')
for _ in $(seq 1 40); do
  rex capture -s "$session" -b "$block" | grep -q 'REXHIST-3000' && break
  sleep 0.25
done

rex do -s "$session" -b "$block" "$here/fixture.lua" --action history_view >/dev/null
layer=""
for _ in $(seq 1 60); do
  layer=$(rex session inspect "$session" --json | json '([l["layout"].get("block_id") for w in d["windows"] for l in w.get("layers",[])[1:]] or [""])[-1]')
  if [ -n "$layer" ] && rex block call -s "$session" -b "$layer" title | grep -q 'history · scrollback'; then break; fi
  sleep 0.25
done
[ -n "$layer" ] || { echo "FAIL: no history layer"; exit 1; }

rex send -s "$session" -b "$layer" 'gg'
top=no
for _ in $(seq 1 8); do
  sleep 0.25
  if rex capture -s "$session" -b "$layer" | grep -q 'REXHIST-0001'; then top=yes; break; fi
done
[ "$top" = yes ] || { echo "FAIL: first scrollback line missing"; rex capture -s "$session" -b "$layer" | grep -v '^[[:space:]]*$' | tail -5; exit 1; }
rex send -s "$session" -b "$layer" 'q'
sleep 1
layers=$(rex session inspect "$session" --json | json 'sum(len(w.get("layers",[])) for w in d["windows"])')
[ "$layers" = 1 ] || { echo "FAIL: layer still open"; exit 1; }
focused=$(rex session inspect "$session" --json | json 'd["windows"][0]["focused_block_id"]')
[ "$focused" = "$block" ] || { echo "FAIL: focus not restored"; exit 1; }
echo "PASS: integration: scrollback layer opens, shows full history, q closes and restores focus"
