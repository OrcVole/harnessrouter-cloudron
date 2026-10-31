#!/bin/bash
#
# The containment gate (docs/CONTAINMENT.md). Run INSIDE the app container as root, on a real box:
#   cloudron exec --app <app> -- /app/pkg/test/containment.sh        (the real gate)
# It cannot be meaningful on rootless podman (the kernel refuses owner-match rules outside the initial user namespace).
# Exit 0 only if every assertion holds. A single FAIL is a failed build. INCONCLUSIVE is printed, never counted as a pass.
#
# EVERY "blocked" or "denied" assertion has a positive control: root must reach the same place, or the result is INCONCLUSIVE.
# (A security probe without a control passes vacuously: this project learned that the hard way.)
#
# What this does NOT cover and cannot from inside, each proven separately while packaging (docs/CONTAINMENT.md):
#   - the broker canary on each backend: needs a model endpoint (test/memory-gate/stub.py records the Authorization header
#     the gateway presents, and its tool call runs `id`, `env` and reads in the agent's own shell);
#   - the fail-closed refusal when net_admin is absent: needs a restart without the capability;
#   - credentials on process command lines during live turns: needs turns running while another uid reads /proc.

set -u
fails=0; incon=0
ok()   { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails+1)); }
inc()  { echo "INCONCLUSIVE: $*"; incon=$((incon+1)); }

UID_LO=70000; UID_HI=109999; S1=70001; S2=70002
asu() { setpriv --reuid="$1" --regid="$1" --clear-groups "${@:2}"; }

conn() {  # conn <uid|root> <host> <port> -> open|blocked   (IPv4 or a host name)
  if [ "$1" = root ]; then timeout 3 bash -c "echo > /dev/tcp/$2/$3" 2>/dev/null && echo open || echo blocked
  else asu "$1" timeout 3 bash -c "echo > /dev/tcp/$2/$3" 2>/dev/null && echo open || echo blocked; fi
}
conn6() {  # conn6 <uid|root> <IPv6 literal> <port> -> open|blocked
  local py="import socket; s=socket.socket(socket.AF_INET6); s.settimeout(2); s.connect(('$2',$3))"
  if [ "$1" = root ]; then timeout 4 python3 -c "${py}" 2>/dev/null && echo open || echo blocked
  else asu "$1" timeout 4 python3 -c "${py}" 2>/dev/null && echo open || echo blocked; fi
}
readable() {  # readable <uid> <path> -> yes|no   (file: read content; directory: list it)
  if [ -d "$2" ]; then asu "$1" sh -c "ls '$2' >/dev/null 2>&1" && echo yes || echo no
  else asu "$1" sh -c "head -c 1 '$2' >/dev/null 2>&1" && echo yes || echo no; fi
}
writable() {  # writable <uid> <dir> -> yes|no   (creates and removes a probe file)
  local t="$2/.containment-$$"
  if [ "$1" = 0 ]; then touch "${t}" 2>/dev/null && { rm -f "${t}"; echo yes; } || echo no
  else asu "$1" sh -c "touch '${t}'" 2>/dev/null && { rm -f "${t}"; echo yes; } || echo no; fi
}

# 1. The firewall is installed over exactly the session range: every rule start.sh promises, by name.
have_v6=1; [ -e /proc/net/if_inet6 ] || have_v6=0
rule() {  # rule <iptables|ip6tables> <fixed text> <fixed text> -> success if one session-range rule carries both and REJECTs
  "$1" -S OUTPUT 2>/dev/null | grep -F -- "--uid-owner ${UID_LO}-${UID_HI}" | grep -F -- "$2" | grep -F -- "$3" | grep -q -- "-j REJECT"
}
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
  rule iptables "-d ${net} " "-d ${net} " && ok "IPv4 rule: ${net} rejected for sessions" || bad "IPv4 rule missing: ${net}"
done
for p in 25 465 587; do rule iptables "--dport ${p} " "-p tcp" && ok "IPv4 rule: mail port ${p} rejected" || bad "IPv4 rule missing: mail port ${p}"; done
rule iptables "-d 127.0.0.1/32" "--dport 8081 " && ok "IPv4 rule: the runner's port rejected" || bad "IPv4 rule missing: the runner's port 8081"
if (( have_v6 )); then
  for net in fc00::/7 fe80::/10; do rule ip6tables "-d ${net} " "-d ${net} " && ok "IPv6 rule: ${net} rejected" || bad "IPv6 rule missing: ${net}"; done
  for p in 25 465 587; do rule ip6tables "--dport ${p} " "-p tcp" && ok "IPv6 rule: mail port ${p} rejected" || bad "IPv6 rule missing: mail port ${p}"; done
  rule ip6tables "-d ::1/128" "--dport 8081 " && ok "IPv6 rule: the runner's port rejected" || bad "IPv6 rule missing: the runner's port 8081"
else ok "this kernel has no IPv6, so there is no IPv6 egress to filter"; fi
# control for the rule matcher itself: a rule that does not exist must not be found
rule iptables "-d 203.0.113.0/24 " "-d 203.0.113.0/24 " && bad "control failed: the rule matcher finds a rule that does not exist" || ok "control: the rule matcher does not invent rules"

# 2. Reachability from a session uid, each with a positive control (root).
check() {  # check <label> <host> <port> <expect: blocked|open> [conn function]
  local f="${5:-conn}" s c; s="$(${f} "${S1}" "$2" "$3")"; c="$(${f} root "$2" "$3")"
  if [ "$4" = blocked ]; then
    if [ "${c}" != open ]; then inc "$1: blocked for the session, but ALSO for root, so the network itself blocks it (rule presence checked above)"
    elif [ "${s}" = blocked ]; then ok "$1: blocked for a session uid, open for root"
    else bad "$1: a session uid REACHED it"; fi
  else
    [ "${s}" = open ] && ok "$1: open for a session uid" || { [ "${c}" = open ] && bad "$1: closed to a session uid but open to root" || inc "$1: unreachable for everyone"; }
  fi
}
check "the runner (127.0.0.1:8081)"                   127.0.0.1  8081  blocked
check "the runner by 0.0.0.0:8081"                    0.0.0.0    8081  blocked
check "the runner by [::ffff:127.0.0.1]:8081"         ::ffff:127.0.0.1 8081 blocked conn6
check "the gateway (127.0.0.1:8080)"                  127.0.0.1  8080  open
check "the console (127.0.0.1:3000)"                  127.0.0.1  3000  open
check "the reverse proxy, plain HTTP (172.18.0.1:80)" 172.18.0.1 80    blocked
check "the reverse proxy, front door (172.18.0.1:443)" 172.18.0.1 443  open
check "public HTTPS (1.1.1.1:443)"                    1.1.1.1    443   open
check "public mail port (1.1.1.1:25)"                 1.1.1.1    25    blocked
check "public mail port (1.1.1.1:587)"                1.1.1.1    587   blocked
if [ -n "${PROBE_OTHER_APP:-}" ]; then   # <ip>:<port> of another app's container on the Cloudron network
  check "another app's internal address (${PROBE_OTHER_APP})" "${PROBE_OTHER_APP%:*}" "${PROBE_OTHER_APP#*:}" blocked
else inc "no PROBE_OTHER_APP given: another app's internal address was not tested"; fi
[ -n "$(asu ${S1} getent hosts github.com 2>/dev/null)" ] && ok "DNS resolves for a session uid" || bad "DNS does not resolve for a session uid"

# 2b. Every OTHER loopback listener a session can reach must refuse a request without credentials. The runner's credential relay
# (an ephemeral port, opened on first use) is one: it answers 401 without the turn's random token. Anything else that answers is a FAIL
# until someone has read what it is.
listeners() {  # port of every TCP listener on 127.0.0.1, 0.0.0.0, ::1 or ::
  for f in /proc/net/tcp /proc/net/tcp6; do awk 'NR>1 && $4=="0A" {print $2}' "${f}"; done | while read -r a; do
    case "${a%%:*}" in 0100007F|00000000|00000000000000000000000001000000|00000000000000000000000000000000) echo $((16#${a##*:})) ;; esac
  done | sort -un
}
others=0
for port in $(listeners); do
  case "${port}" in 3000|8080|8081) continue ;; esac
  others=$((others+1))
  if [ "$(conn ${S1} 127.0.0.1 "${port}")" = blocked ]; then ok "loopback listener ${port}: closed to a session uid"; continue; fi
  st="$(asu ${S1} timeout 4 python3 -c "
import socket; s=socket.create_connection(('127.0.0.1',${port}),timeout=3); s.sendall(b'GET / HTTP/1.0\r\nHost: x\r\n\r\n')
print((s.recv(64).split(b' ')+[b'',b''])[1].decode(errors='replace'))" 2>/dev/null)"
  [ "${st}" = 401 ] && ok "loopback listener ${port}: a session uid without a token gets 401" || bad "loopback listener ${port} answers a session uid with '${st:-nothing}': find out what it is"
done
[ "${others}" -gt 0 ] || inc "no loopback listener besides 3000/8080/8081 is running (the runner's relay opens on first use): not tested"

# 3. The uid range has exact edges (needs a destination the rules close: the reverse proxy's port 80).
[ "$(conn root 172.18.0.1 80)" = open ] && {
  e1="$(conn $((UID_LO-1)) 172.18.0.1 80)"; e2="$(conn ${UID_LO} 172.18.0.1 80)"; e3="$(conn ${UID_HI} 172.18.0.1 80)"; e4="$(conn $((UID_HI+1)) 172.18.0.1 80)"
  [ "${e1}/${e2}/${e3}/${e4}" = "open/blocked/blocked/open" ] && ok "uid range edges exact (${UID_LO}-${UID_HI})" || bad "uid range edges wrong: ${e1}/${e2}/${e3}/${e4}"
} || inc "uid range edges not tested (no reachable control destination)"

# 4. Data isolation: a session uid cannot read the product's data, secrets, login store, operator settings, HOME or the workspace
# index; root can (control).
for p in /app/data /app/data/.secrets /app/data/.secrets/admin-password /app/data/.secrets/secret-key /app/data/secrets /app/data/blobs \
         /app/data/control.db /app/data/graph.db /app/data/selfhost-auth.json /app/data/env /app/data/home /app/data/.hr-env \
         /app/ws-markers /app/workspaces; do
  [ -e "${p}" ] || { inc "${p} does not exist yet (not tested)"; continue; }
  s="$(readable ${S1} "${p}")"; c="$(readable 0 "${p}")"
  [ "${c}" = yes ] || { inc "${p}: root cannot read it either"; continue; }
  [ "${s}" = no ] && ok "session uid cannot read ${p}" || bad "session uid CAN read ${p}"
done
[ "$(readable ${S1} /app/entrypoint.sh)" = yes ] && ok "control: a world-readable file reads as readable to a session uid" || bad "control failed: /app/entrypoint.sh unreadable to a session uid (the probe above is vacuous)"
# Not just the named paths: session uids can traverse /app/data (they run the agent tools under it), so ANY file there with a
# world-read bit is readable by name. Outside the tool trees agents are meant to run, there must be none.
leaky="$(find /app/data -xdev -type f -perm -o+r ! -path '/app/data/agent-tools/*' ! -path '/app/data/environments/*' 2>/dev/null |
  while read -r f; do [ "$(readable ${S1} "${f}")" = yes ] && echo "${f}"; done)"
[ -z "${leaky}" ] && ok "no file under /app/data (outside agent-tools and environments) is readable by a session uid" \
  || bad "$(echo "${leaky}" | wc -l) file(s) under /app/data readable by a session uid, e.g. $(echo "${leaky}" | head -3 | tr '\n' ' ')"
for pat in 'uvicorn server:app' 'uvicorn app:app'; do
  pid="$(pgrep -f "^/usr/local/bin/python3 -m ${pat}" | head -1)"
  [ -n "${pid}" ] || { inc "no process matching '${pat}'"; continue; }
  [ "$(readable ${S1} /proc/${pid}/environ)" = no ] && ok "session uid cannot read /proc/${pid}/environ ('${pat}')" || bad "session uid CAN read the environ of '${pat}'"
done
[ "$(readable ${S1} /proc/1/environ)" = no ] && ok "session uid cannot read /proc/1/environ" || bad "session uid CAN read /proc/1/environ"

# 4b. Tampering: a session uid cannot write where the product, the runner or other sessions read from. Root can (control).
for d in /app/data /app/data/agent-tools /app/data/agent-tools/bin /app/data/environments /app/data/home /app/data/.hr-env \
         /app/data/.secrets /app/workspaces /app/ws-markers; do
  [ -d "${d}" ] || { inc "${d} does not exist yet (not tested)"; continue; }
  [ "$(writable 0 "${d}")" = yes ] || { inc "${d}: root cannot write it either"; continue; }
  [ "$(writable ${S1} "${d}")" = no ] && ok "session uid cannot write into ${d}" || bad "session uid CAN write into ${d}"
done
ww="$(find /app/data/agent-tools /app/data/environments \( -perm -g+w -o -perm -o+w \) ! -type l 2>/dev/null | wc -l)"
[ "${ww}" -eq 0 ] && ok "nothing under agent-tools or environments is group- or world-writable" || bad "${ww} group- or world-writable entries under agent-tools or environments"

# 4c. What agents inherit: the runner (their parent) holds no console credential, secret key or Cloudron variable. Root reads it;
# finding the runner's own marker variable is the control that we read the right process.
rpid="$(pgrep -f '^/usr/local/bin/python3 -m uvicorn server:app' | head -1)"
if [ -n "${rpid}" ]; then
  renv="$(tr '\0' '\n' < /proc/${rpid}/environ 2>/dev/null | cut -d= -f1)"
  if echo "${renv}" | grep -qx HR_SESSION_UIDS; then
    ok "control: the runner's environment is the one read (HR_SESSION_UIDS present)"
    leak="$(echo "${renv}" | grep -E '^(HR_AUTH_PASSWORD|HR_AUTH_USER|HR_AUTH_STORE|HR_SECRET_KEY|CLOUDRON_.*)$' | tr '\n' ' ')"
    [ -z "${leak}" ] && ok "the runner (agents' parent) holds no console credential, secret key or CLOUDRON_* variable" || bad "the runner's environment carries: ${leak}"
  else inc "the runner's environment does not carry HR_SESSION_UIDS: wrong process, not tested"; fi
else inc "no runner process found"; fi

# 5. Sessions cannot reach each other, on the real layout (/app/workspaces, each session's directory 0700 under its own uid).
d="/app/workspaces/containment-test-${S1}"; mkdir -p "${d}" && chown "${S1}:${S1}" "${d}" && chmod 0700 "${d}" && echo x > "${d}/f" && chown "${S1}:${S1}" "${d}/f"
[ "$(readable ${S1} "${d}/f")" = yes ] && ok "control: a session reads its own directory" || bad "control failed: a session cannot read its own directory"
[ "$(readable ${S2} "${d}/f")" = no ] && ok "another session uid cannot read a session's files" || bad "another session uid CAN read a session's files"
asu "${S2}" sh -c "touch '${d}/y'" 2>/dev/null && bad "another session uid CAN write into a session's directory" || ok "another session uid cannot write into a session's directory"
rm -rf "${d}"
real="$(find /app/workspaces -mindepth 1 -maxdepth 1 -type d ! -name 'containment-test-*' 2>/dev/null | head -1)"
if [ -n "${real}" ]; then o="$(stat -c %u "${real}")"; other=$(( o == S1 ? S2 : S1 ))
  if [ "${o}" -ge "${UID_LO}" ] && [ "${o}" -le "${UID_HI}" ]; then
    [ "$(readable "${o}" "${real}")" = yes ] && [ "$(readable "${other}" "${real}")" = no ] \
      && ok "a real session directory (uid ${o}, mode $(stat -c %a "${real}")) is listable by its owner only" || bad "a real session directory is readable by another session uid, or not by its owner"
  else bad "a real session directory is owned by uid ${o}, outside the session range"; fi
else inc "no real session directory yet (run a turn first): not tested"; fi

# 6. Nothing of Cloudron's is inherited: the entrypoint's environment holds no CLOUDRON_* variable (a bare CLOUDRON=1 marker is set by the platform).
leak="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -E '^CLOUDRON_' | cut -d= -f1 | tr '\n' ' ')"
[ -z "${leak}" ] && ok "no CLOUDRON_* variable in the entrypoint's environment" || bad "CLOUDRON_* variables survive into the entrypoint: ${leak}"

echo "---"; echo "failures: ${fails}; inconclusive: ${incon}"
[ "${fails}" -eq 0 ]
