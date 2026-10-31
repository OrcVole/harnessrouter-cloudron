#!/usr/bin/env bash
# hr-load.sh <workers> <seconds>: concurrent agent turns (opencode and codex alternating) through the gateway against the stub. Prints counts only.
set -uo pipefail
# Needs: PG (a command that runs `exec --app <app> -- <cmd>` on the TEST install, e.g. a wrapper around `cloudron exec`) and A (its hostname).
: "${PG:?set PG to the test-install exec wrapper}" "${A:?set A to the test install hostname}"; H=https://$A; S=$(dirname "$0"); W=$1; D=$2
PW=$($PG exec --app $A -- cat /app/data/.secrets/admin-password 2>/dev/null | tr -d '\r\n')
export C=$(curl -sk -m 15 -D - -o /dev/null -H 'content-type: application/json' -d "{\"username\":\"harnessrouter\",\"password\":\"$PW\"}" $H/api/selfhost/login | grep -i '^set-cookie' | sed 's/^[Ss]et-[Cc]ookie: //; s/;.*//' | paste -sd';' -); unset PW
[ -n "$C" ] || { echo "login failed"; exit 1; }
export H DEADLINE=$(( $(date +%s) + D )) RES="$S/hr-load.results"; : > "$RES"
worker() {
  local n=$1 h m
  if [ $((n % 2)) -eq 0 ]; then h=opencode; m=stub-model; else h=codex; m=stub-resp; fi
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    out=$(curl -sk -m 120 -H "Cookie: $C" -H 'content-type: application/json' -d "{\"input\":\"Run the probe.\",\"metadata\":{\"harness_id\":\"$h\"},\"model\":\"$m\",\"stream\":false}" "$H/api/harness/v1/responses" 2>/dev/null)
    if echo "$out" | grep -q '"status":"completed"'; then echo "$h ok" >> "$RES"; else echo "$h FAIL" >> "$RES"; fi
  done
}
export -f worker
seq 1 "$W" | xargs -P "$W" -I{} bash -c 'worker {}'
echo "turns: $(wc -l < "$RES") | ok: $(grep -c ' ok' "$RES") | failed: $(grep -c FAIL "$RES") | opencode: $(grep -c '^opencode ok' "$RES") codex: $(grep -c '^codex ok' "$RES")"
