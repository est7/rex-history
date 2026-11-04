#!/bin/sh
# Integration test against a running local Rex server. Creates and kills its
# own disposable session; never selects it in the app or reloads your config.
# Needs nvim on the login shell's PATH.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
json() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

session=$(rex new rex-history-test --json | json 'd["session_id"]')
trap 'rex kill "$session" >/dev/null 2>&1 || true' EXIT
block=$(rex session inspect "$session" --json | json 'd["windows"][0]["focused_block_id"]')
sleep 1.5
rex send -s "$session" -b "$block" 'seq -f "REXHIST-%04g" 1 3000'
rex send-key -s "$session" -b "$block" enter
sleep 1.5

rex do -s "$session" -b "$block" "$here/fixture.lua" --action history_view >/dev/null
layer=""
for _ in $(seq 1 60); do
  layer=$(rex session inspect "$session" --json | json '([l["layout"].get("block_id") for w in d["windows"] for l in w.get("layers",[])[1:]] or [""])[-1]')
  if [ -n "$layer" ] && rex block call -s "$session" -b "$layer" title | grep -q 'history · scrollback'; then break; fi
  sleep 0.25
done
[ -n "$layer" ] || { echo "FAIL: no history layer"; exit 1; }

rex send -s "$session" -b "$layer" 'gg'
sleep 0.5
rex capture -s "$session" -b "$layer" | grep -q 'REXHIST-0001' || { echo "FAIL: first scrollback line missing"; exit 1; }
rex send -s "$session" -b "$layer" 'q'
sleep 1
layers=$(rex session inspect "$session" --json | json 'sum(len(w.get("layers",[])) for w in d["windows"])')
[ "$layers" = 1 ] || { echo "FAIL: layer still open"; exit 1; }
focused=$(rex session inspect "$session" --json | json 'd["windows"][0]["focused_block_id"]')
[ "$focused" = "$block" ] || { echo "FAIL: focus not restored"; exit 1; }
echo "PASS: integration: scrollback layer opens, shows full history, q closes and restores focus"
