#!/bin/bash
#
# The containment gate (CONTAINMENT.md, probes 2, 4, 5, 7). Run INSIDE the app container as root, on a real box:
#   cloudron exec --app <app> -- /app/pkg/test/containment.sh        (the real gate)
# It cannot be meaningful on rootless podman (the kernel refuses owner-match rules outside the initial user namespace).
# Exit 0 only if every assertion holds. A single FAIL is a failed build. INCONCLUSIVE is printed, never counted as a pass.
#
# EVERY "blocked" assertion has a positive control: root must reach the same place, or the result is INCONCLUSIVE.
# (A security probe without a control passes vacuously: this project learned that the hard way, runbook notes 69-70.)
#
# What this does NOT cover and cannot from inside: the broker canary on each backend (needs a model endpoint; see
# test/broker-canary/), and the fail-closed refusal when net_admin is absent (needs a restart without the capability).

set -u
fails=0; incon=0
ok()   { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails+1)); }
inc()  { echo "INCONCLUSIVE: $*"; incon=$((incon+1)); }

UID_LO=70000; UID_HI=109999; S1=70001; S2=70002

conn() {  # conn <uid|root> <host> <port> -> open|blocked
  if [ "$1" = root ]; then timeout 3 bash -c "echo > /dev/tcp/$2/$3" 2>/dev/null && echo open || echo blocked
  else setpriv --reuid="$1" --regid="$1" --clear-groups timeout 3 bash -c "echo > /dev/tcp/$2/$3" 2>/dev/null && echo open || echo blocked; fi
}
readable() {  # readable <uid> <path> -> yes|no   (file: read content; directory: list it)
  if [ -d "$2" ]; then setpriv --reuid="$1" --regid="$1" --clear-groups sh -c "ls '$2' >/dev/null 2>&1" && echo yes || echo no
  else setpriv --reuid="$1" --regid="$1" --clear-groups sh -c "head -c 1 '$2' >/dev/null 2>&1" && echo yes || echo no; fi
}

# 1. The firewall is installed, for IPv4 and IPv6, over exactly the session range.
n4="$(iptables -S OUTPUT 2>/dev/null | grep -c -- "--uid-owner ${UID_LO}-${UID_HI}")"
n6="$(ip6tables -S OUTPUT 2>/dev/null | grep -c -- "--uid-owner ${UID_LO}-${UID_HI}")"
[ "${n4}" -ge 10 ] && ok "IPv4 egress rules installed (${n4})" || bad "IPv4 egress rules missing (${n4}); nothing below is meaningful"
[ "${n6}" -ge 4 ]  && ok "IPv6 egress rules installed (${n6})" || bad "IPv6 egress rules missing (${n6})"
for p in 25 465 587; do
  iptables -S OUTPUT | grep -q -- "--dport ${p} -j REJECT" && ok "rule present: mail port ${p} rejected for sessions" || bad "no mail-port ${p} rule"
done

# 2. Reachability from a session uid, each with a positive control (root).
check() {  # check <label> <host> <port> <expect: blocked|open>
  local s c; s="$(conn "${S1}" "$2" "$3")"; c="$(conn root "$2" "$3")"
  if [ "$4" = blocked ]; then
    if [ "${c}" != open ]; then inc "$1: blocked for the session, but ALSO for root, so the network itself blocks it (rule presence checked above)"
    elif [ "${s}" = blocked ]; then ok "$1: blocked for a session uid, open for root"
    else bad "$1: a session uid REACHED it"; fi
  else
    [ "${s}" = open ] && ok "$1: open for a session uid" || { [ "${c}" = open ] && bad "$1: closed to a session uid but open to root" || inc "$1: unreachable for everyone"; }
  fi
}
check "the runner (127.0.0.1:8081)"                 127.0.0.1  8081  blocked
check "the gateway (127.0.0.1:8080)"                127.0.0.1  8080  open
check "the console (127.0.0.1:3000)"                127.0.0.1  3000  open
check "the reverse proxy, plain HTTP (172.18.0.1:80)" 172.18.0.1 80   blocked
check "the reverse proxy, front door (172.18.0.1:443)" 172.18.0.1 443 open
check "public HTTPS (1.1.1.1:443)"                  1.1.1.1    443   open
check "public mail port (1.1.1.1:25)"               1.1.1.1    25    blocked
check "public mail port (1.1.1.1:587)"              1.1.1.1    587   blocked
if [ -n "${PROBE_OTHER_APP:-}" ]; then   # <ip>:<port> of another app's container on the Cloudron network
  check "another app's internal address (${PROBE_OTHER_APP})" "${PROBE_OTHER_APP%:*}" "${PROBE_OTHER_APP#*:}" blocked
else inc "no PROBE_OTHER_APP given: another app's internal address was not tested"; fi
[ -n "$(setpriv --reuid=${S1} --regid=${S1} --clear-groups getent hosts github.com 2>/dev/null)" ] && ok "DNS resolves for a session uid" || bad "DNS does not resolve for a session uid"

# 3. The uid range has exact edges (needs a destination the rules close: the reverse proxy's port 80).
[ "$(conn root 172.18.0.1 80)" = open ] && {
  e1="$(conn $((UID_LO-1)) 172.18.0.1 80)"; e2="$(conn ${UID_LO} 172.18.0.1 80)"; e3="$(conn ${UID_HI} 172.18.0.1 80)"; e4="$(conn $((UID_HI+1)) 172.18.0.1 80)"
  [ "${e1}/${e2}/${e3}/${e4}" = "open/blocked/blocked/open" ] && ok "uid range edges exact (${UID_LO}-${UID_HI})" || bad "uid range edges wrong: ${e1}/${e2}/${e3}/${e4}"
} || inc "uid range edges not tested (no reachable control destination)"

# 4. Data isolation: a session uid cannot read the product's data or secrets; root can (control).
for p in /app/data /app/data/.secrets /app/data/.secrets/admin-password /app/data/.secrets/secret-key /app/data/secrets /app/data/blobs \
         /app/data/control.db /app/data/graph.db; do
  [ -e "${p}" ] || { inc "${p} does not exist yet (not tested)"; continue; }
  s="$(readable ${S1} "${p}")"; c="$(readable 0 "${p}")"
  [ "${c}" = yes ] || { inc "${p}: root cannot read it either"; continue; }
  [ "${s}" = no ] && ok "session uid cannot read ${p}" || bad "session uid CAN read ${p}"
done
[ "$(readable ${S1} /app/entrypoint.sh)" = yes ] && ok "control: a world-readable file reads as readable to a session uid" || bad "control failed: /app/entrypoint.sh unreadable to a session uid (the probe above is vacuous)"
for pat in 'uvicorn server:app' 'uvicorn app:app'; do
  pid="$(pgrep -f "^/usr/local/bin/python3 -m ${pat}" | head -1)"
  [ -n "${pid}" ] || { inc "no process matching '${pat}'"; continue; }
  [ "$(readable ${S1} /proc/${pid}/environ)" = no ] && ok "session uid cannot read /proc/${pid}/environ ('${pat}')" || bad "session uid CAN read the environ of '${pat}'"
done
[ "$(readable ${S1} /proc/1/environ)" = no ] && ok "session uid cannot read /proc/1/environ" || bad "session uid CAN read /proc/1/environ"

# 5. Sessions cannot reach each other.
d="/app/data/workspaces/containment-test-${S1}"; mkdir -p "${d}" && chown "${S1}:${S1}" "${d}" && chmod 0700 "${d}" && echo x > "${d}/f" && chown "${S1}:${S1}" "${d}/f"
[ "$(readable ${S1} "${d}/f")" = yes ] && ok "control: a session reads its own directory" || bad "control failed: a session cannot read its own directory"
[ "$(readable ${S2} "${d}/f")" = no ] && ok "another session uid cannot read a session's files" || bad "another session uid CAN read a session's files"
setpriv --reuid="${S2}" --regid="${S2}" --clear-groups sh -c "touch '${d}/y'" 2>/dev/null && bad "another session uid CAN write into a session's directory" || ok "another session uid cannot write into a session's directory"
rm -rf "${d}"

# 6. Nothing of Cloudron's is inherited: the entrypoint's environment holds no CLOUDRON_* variable (a bare CLOUDRON=1 marker is set by the platform).
leak="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -E '^CLOUDRON_' | cut -d= -f1 | tr '\n' ' ')"
[ -z "${leak}" ] && ok "no CLOUDRON_* variable in the entrypoint's environment" || bad "CLOUDRON_* variables survive into the entrypoint: ${leak}"

echo "---"; echo "failures: ${fails}; inconclusive: ${incon}"
[ "${fails}" -eq 0 ]
