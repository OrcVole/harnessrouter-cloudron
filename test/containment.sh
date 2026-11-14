#!/bin/bash
#
# The containment gate (docs/CONTAINMENT.md). Run INSIDE the app container as root, on a real box:
#   cloudron exec --app <app> -- /app/pkg/test/containment.sh        (the real gate)
# It cannot be meaningful on rootless podman (the kernel refuses owner-match rules outside the initial user namespace).
# Exit 0 only if every assertion holds. A single FAIL is a failed build. INCONCLUSIVE is printed, never counted as a pass.
#
# EVERY "blocked" or "denied" assertion has a positive control, or the result is INCONCLUSIVE. For file access the control is
# root. For the network it is a uid that no rule names (CTRL, below): since 0.2.0 root itself is firewalled from internal
# addresses, so root can no longer be the network control. (A security probe without a control passes vacuously: this project
# learned that the hard way.)
#
# What this does NOT cover and cannot from inside, each proven separately while packaging (docs/CONTAINMENT.md):
#   - the broker canary on each backend: needs a model endpoint (test/memory-gate/stub.py, and upstream's
#     scripts/secret-canary-gate.py, which runs its own stand-in model and MCP server);
#   - the fail-closed refusal when net_admin is absent: needs a restart without the capability;
#   - credentials on process command lines during live turns: needs turns running while another uid reads /proc.

set -u
fails=0; incon=0
ok()   { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails+1)); }
inc()  { echo "INCONCLUSIVE: $*"; incon=$((incon+1)); }

UID_LO=70000; UID_HI=109999; S1=70001; S2=70002          # sessions
ENV_LO=110000; ENV_HI=149999                               # environment build identities (HR_ENV_GID_BASE)
INS_LO=19001; INS_HI=19099                                 # first-start install uids
CTRL=65000                                                 # in no range: the network control
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

# 1. The firewall is installed over exactly each range: every rule start.sh promises, by name.
have_v6=1; [ -e /proc/net/if_inet6 ] || have_v6=0
rule() {  # rule <iptables|ip6tables> <uid range> <fixed text> <fixed text> -> success if one rule for that range carries both and REJECTs
  "$1" -S OUTPUT 2>/dev/null | grep -E -- "--uid-owner $2( |$)" | grep -F -- "$3" | grep -F -- "$4" | grep -q -- "-j REJECT"
}
for R in "${UID_LO}-${UID_HI}:sessions" "${ENV_LO}-${ENV_HI}:environment builds" "${INS_LO}-${INS_HI}:installs"; do
  rg="${R%%:*}"; who="${R#*:}"
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
    rule iptables "${rg}" "-d ${net} " "-d ${net} " && ok "IPv4 rule (${who}): ${net} rejected" || bad "IPv4 rule missing (${who}): ${net}"
  done
  for p in 25 465 587; do rule iptables "${rg}" "--dport ${p} " "-p tcp" && ok "IPv4 rule (${who}): mail port ${p} rejected" || bad "IPv4 rule missing (${who}): mail port ${p}"; done
  rule iptables "${rg}" "-d 127.0.0.1/32" "--dport 8081 " && ok "IPv4 rule (${who}): the runner's port rejected" || bad "IPv4 rule missing (${who}): the runner's port 8081"
  if (( have_v6 )); then
    for net in fc00::/7 fe80::/10; do rule ip6tables "${rg}" "-d ${net} " "-d ${net} " && ok "IPv6 rule (${who}): ${net} rejected" || bad "IPv6 rule missing (${who}): ${net}"; done
    for p in 25 465 587; do rule ip6tables "${rg}" "--dport ${p} " "-p tcp" && ok "IPv6 rule (${who}): mail port ${p} rejected" || bad "IPv6 rule missing (${who}): mail port ${p}"; done
    rule ip6tables "${rg}" "-d ::1/128" "--dport 8081 " && ok "IPv6 rule (${who}): the runner's port rejected" || bad "IPv6 rule missing (${who}): the runner's port 8081"
  fi
done
# Root: the internal ranges only (its MCP relay and every other root socket).
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
  rule iptables 0 "-d ${net} " "-d ${net} " && ok "IPv4 rule (root): ${net} rejected" || bad "IPv4 rule missing (root): ${net}"
done
if (( have_v6 )); then
  for net in fc00::/7 fe80::/10; do rule ip6tables 0 "-d ${net} " "-d ${net} " && ok "IPv6 rule (root): ${net} rejected" || bad "IPv6 rule missing (root): ${net}"; done
else ok "this kernel has no IPv6, so there is no IPv6 egress to filter"; fi
iptables -S OUTPUT 2>/dev/null | grep -E -- "--uid-owner 0( |$)" | grep -E -- "-d 127\." | grep -q -- "-j REJECT" \
  && bad "a root rule rejects loopback (the gateway, the relays and the resolver live there)" || ok "no root rule touches loopback"
# control for the rule matcher itself: a rule that does not exist must not be found
rule iptables "${UID_LO}-${UID_HI}" "-d 203.0.113.0/24 " "-d 203.0.113.0/24 " && bad "control failed: the rule matcher finds a rule that does not exist" || ok "control: the rule matcher does not invent rules"

# 2. Reachability, each "blocked" against the control uid (CTRL, named by no rule) reaching the same place.
check() {  # check <who: uid|root> <label> <host> <port> <expect: blocked|open> [conn function]
  local f="${6:-conn}" s c; s="$(${f} "$1" "$3" "$4")"; c="$(${f} "${CTRL}" "$3" "$4")"
  if [ "$5" = blocked ]; then
    if [ "${c}" != open ]; then inc "$2: blocked for $1, but ALSO for the control uid, so the network itself blocks it (rule presence checked above)"
    elif [ "${s}" = blocked ]; then ok "$2: blocked for $1, open for the control uid"
    else bad "$2: $1 REACHED it"; fi
  else
    [ "${s}" = open ] && ok "$2: open for $1" || { [ "${c}" = open ] && bad "$2: closed to $1 but open to the control uid" || inc "$2: unreachable for everyone"; }
  fi
}
check "${S1}" "the runner (127.0.0.1:8081)"                   127.0.0.1  8081  blocked
check "${S1}" "the runner by 0.0.0.0:8081"                    0.0.0.0    8081  blocked
check "${S1}" "the runner by [::ffff:127.0.0.1]:8081"         ::ffff:127.0.0.1 8081 blocked conn6
check "${S1}" "the gateway (127.0.0.1:8080)"                  127.0.0.1  8080  open
check "${S1}" "the console (127.0.0.1:3000)"                  127.0.0.1  3000  open
check "${S1}" "the reverse proxy, plain HTTP (172.18.0.1:80)" 172.18.0.1 80    blocked
check "${S1}" "the reverse proxy, front door (172.18.0.1:443)" 172.18.0.1 443  open
check "${S1}" "public HTTPS (1.1.1.1:443)"                    1.1.1.1    443   open
check "${S1}" "public mail port (1.1.1.1:25)"                 1.1.1.1    25    blocked
check "${S1}" "public mail port (1.1.1.1:587)"                1.1.1.1    587   blocked
check root    "root to the reverse proxy, plain HTTP (172.18.0.1:80)" 172.18.0.1 80 blocked
check root    "root to the reverse proxy, front door (172.18.0.1:443)" 172.18.0.1 443 open
check root    "root to public HTTPS (1.1.1.1:443)"            1.1.1.1    443   open
check root    "root to the gateway (127.0.0.1:8080)"          127.0.0.1  8080  open
check "$((ENV_LO + 1))" "an environment build uid to the reverse proxy, plain HTTP" 172.18.0.1 80 blocked
check "${INS_LO}" "an install uid to the reverse proxy, plain HTTP" 172.18.0.1 80 blocked
if [ -n "${PROBE_OTHER_APP:-}" ]; then   # <ip>:<port> of another app's container on the Cloudron network
  check "${S1}" "another app's internal address (${PROBE_OTHER_APP})" "${PROBE_OTHER_APP%:*}" "${PROBE_OTHER_APP#*:}" blocked
  check root "root to another app's internal address (${PROBE_OTHER_APP})" "${PROBE_OTHER_APP%:*}" "${PROBE_OTHER_APP#*:}" blocked
else inc "no PROBE_OTHER_APP given: another app's internal address was not tested"; fi
[ -n "$(asu ${S1} getent hosts github.com 2>/dev/null)" ] && ok "DNS resolves for a session uid" || bad "DNS does not resolve for a session uid"
[ -n "$(getent hosts github.com 2>/dev/null)" ] && ok "DNS resolves for root" || bad "DNS does not resolve for root"
# public HTTPS by root, end to end (the first-start installs need it): a real TLS fetch, status only
code="$(timeout 15 curl -s -o /dev/null -w '%{http_code}' https://registry.npmjs.org/ 2>/dev/null)"
[ "${code}" = 200 ] && ok "root fetches public HTTPS (registry.npmjs.org: ${code})" || bad "root cannot fetch public HTTPS (registry.npmjs.org: '${code}')"

# 2b. Every OTHER loopback listener a session can reach must refuse a request without credentials. The runner's credential relay
# and MCP relay (ephemeral ports, opened on first use) are such: each answers 401 without the turn's random token. Anything else
# that answers is a FAIL until someone has read what it is.
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
[ "${others}" -gt 0 ] || inc "no loopback listener besides 3000/8080/8081 is running (the runner's relays open on first use): not tested"

# 3. The uid ranges have exact edges (needs a destination the rules close: the reverse proxy's port 80, open to the control uid).
if [ "$(conn ${CTRL} 172.18.0.1 80)" = open ]; then
  e="$(for u in $((UID_LO-1)) ${UID_LO} ${UID_HI} ${ENV_LO} ${ENV_HI} $((ENV_HI+1)); do conn "${u}" 172.18.0.1 80; done | tr '\n' '/')"
  [ "${e}" = "open/blocked/blocked/blocked/blocked/open/" ] && ok "session and environment-build ranges: edges exact (${UID_LO}-${ENV_HI}, contiguous)" || bad "session/environment range edges wrong: ${e}"
  e="$(for u in $((INS_LO-1)) ${INS_LO} ${INS_HI} $((INS_HI+1)); do conn "${u}" 172.18.0.1 80; done | tr '\n' '/')"
  [ "${e}" = "open/blocked/blocked/open/" ] && ok "install range: edges exact (${INS_LO}-${INS_HI})" || bad "install range edges wrong: ${e}"
  e="$(for u in 1 10001; do conn "${u}" 172.18.0.1 80; done | tr '\n' '/')"
  [ "${e}" = "open/open/" ] && ok "root's rule names uid 0 only (uid 1 and the product's user 10001 not matched)" || bad "uids 1 / 10001 to port 80: ${e}"
else inc "uid range edges not tested (the control uid cannot reach the reverse proxy's port 80)"; fi

# 4. Data isolation: a session uid cannot read the product's data, secrets, login store, operator settings, HOME or the workspace
# index; root can (control).
for p in /app/data /app/data/.secrets /app/data/.secrets/admin-password /app/data/.secrets/secret-key /app/data/secrets /app/data/blobs \
         /app/data/control.db /app/data/graph.db /app/data/selfhost-auth.json /app/data/env /app/data/home /app/data/.hr-env \
         /app/ws-markers /app/workspaces /run/harnessrouter/internal-key; do
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
  pid="$(pgrep -f "^/usr/local/bin/python3 (-I )?-m ${pat}" | head -1)"
  [ -n "${pid}" ] || { inc "no process matching '${pat}'"; continue; }
  [ "$(readable ${S1} /proc/${pid}/environ)" = no ] && ok "session uid cannot read /proc/${pid}/environ ('${pat}')" || bad "session uid CAN read the environ of '${pat}'"
done
[ "$(readable ${S1} /proc/1/environ)" = no ] && ok "session uid cannot read /proc/1/environ" || bad "session uid CAN read /proc/1/environ"

# 4a. Upstream's ownership model (0.37.17, scripts/check-root-boundary.sh): the volume's top is root:<product> 1771, the workspace
# root root 751; nothing root runs under /app or agent-tools is anyone else's or writable by group or other.
st="$(stat -c '%u:%G %a' /app/data)"; [ "${st}" = "0:agent 1771" ] && ok "/app/data is root:agent 1771" || bad "/app/data is ${st}, not 0:agent 1771"
st="$(stat -c '%u:%g %a' /app/workspaces)"; [ "${st}" = "0:0 751" ] && ok "/app/workspaces is root:root 751" || bad "/app/workspaces is ${st}, not 0:0 751"
n="$(find /app -xdev \( -path /app/data -o -path /app/workspaces -o -path /app/ws-markers \) -prune -o ! -type l \( ! -user root -o -perm /022 \) -print 2>/dev/null | wc -l)"
[ "${n}" -eq 0 ] && ok "nothing in the image's /app is owned by anyone but root or writable by group or other" || bad "${n} entries in the image's /app not root's or group/other-writable"
if [ -d /app/data/agent-tools ]; then
  n="$(find /app/data/agent-tools -xdev ! -type l \( ! -user root -o ! -group root -o -perm /022 \) 2>/dev/null | wc -l)"
  [ "${n}" -eq 0 ] && ok "agent-tools: everything root's and writable by root only" || bad "agent-tools: ${n} entries not root's or group/other-writable"
else inc "/app/data/agent-tools does not exist yet"; fi
# The product's user may create its own files at the top (control) but may not move what root keeps there.
[ "$(writable 10001 /app/data)" = yes ] && ok "control: the product's user can create a file in /app/data" || inc "the product's user cannot create in /app/data (the move test below is vacuous)"
for d in agent-tools environments .hr-env .secrets; do
  [ -e "/app/data/${d}" ] || { inc "/app/data/${d} does not exist yet (move not tested)"; continue; }
  if asu 10001 mv "/app/data/${d}" "/app/data/.moved-${d}" 2>/dev/null; then mv "/app/data/.moved-${d}" "/app/data/${d}"; bad "the product's user CAN rename /app/data/${d}"
  else ok "the product's user cannot rename /app/data/${d}"; fi
done
for d in /app/ws-markers /app/workspaces; do
  [ "$(writable 10001 "${d}")" = no ] && ok "the product's user cannot write into ${d}" || bad "the product's user CAN write into ${d}"
done

# 4b. Tampering: a session uid cannot write where the product, the runner or other sessions read from. Root can (control).
for d in /app/data /app/data/agent-tools /app/data/agent-tools/bin /app/data/environments /app/data/home /app/data/.hr-env \
         /app/data/.secrets /app/workspaces /app/ws-markers; do
  [ -d "${d}" ] || { inc "${d} does not exist yet (not tested)"; continue; }
  [ "$(writable 0 "${d}")" = yes ] || { inc "${d}: root cannot write it either"; continue; }
  [ "$(writable ${S1} "${d}")" = no ] && ok "session uid cannot write into ${d}" || bad "session uid CAN write into ${d}"
done
ww="$(find /app/data/agent-tools /app/data/environments \( -perm -g+w -o -perm -o+w \) ! -type l 2>/dev/null | wc -l)"
[ "${ww}" -eq 0 ] && ok "nothing under agent-tools or environments is group- or world-writable" || bad "${ww} group- or world-writable entries under agent-tools or environments"

# 4c. What agents inherit. The runner (their parent) holds NO secret in its environment since upstream 0.41.13: not the internal key
# (it reads it from a root-only file), not the console credentials, not the secret key, no CLOUDRON_* and no secret-shaped name
# (upstream's own pattern, entrypoint.sh RUNNER_SECRET_ENV). Control: HR_SESSION_UIDS present shows we read the right process.
# Root here has no CAP_SYS_PTRACE (Cloudron's capability set), and the runner becomes non-dumpable at its first setfsuid (its file
# work in a session's folder), after which nobody in the container can read its environment: run this gate right after a restart.
rpid="$(pgrep -f '^/usr/local/bin/python3 (-I )?-m uvicorn server:app' | head -1)"
if [ -n "${rpid}" ]; then
  if ! head -c 1 /proc/${rpid}/environ >/dev/null 2>&1; then
    inc "the runner's environment is unreadable (non-dumpable after its first session file operation; no CAP_SYS_PTRACE here): run this gate right after a restart"
  else
  renv="$(tr '\0' '\n' < /proc/${rpid}/environ 2>/dev/null | cut -d= -f1)"
  if echo "${renv}" | grep -qx HR_SESSION_UIDS; then
    ok "control: the runner's environment is the one read (HR_SESSION_UIDS present)"
    echo "${renv}" | grep -qx HARNESS_INTERNAL_KEY && bad "the runner holds HARNESS_INTERNAL_KEY in its environment" || ok "the runner holds no HARNESS_INTERNAL_KEY"
    leak="$(echo "${renv}" | grep -iE '^(HARNESS_INTERNAL_KEY|HR_AUTH_.*|HR_SECRET_KEY|HR_SESSION_KEY|HR_POOL_.*|CLOUDRON_.*)$|_API_KEY$|_SECRET(_|$)|_TOKEN$|PASSWORD|^AWS_BEARER_TOKEN_|^GOOGLE_APPLICATION_CREDENTIALS$|_KEY$|_PASS(WORD)?$|_PWD$|_CREDENTIALS?$|_DSN$' | tr '\n' ' ')"
    [ -z "${leak}" ] && ok "the runner's environment carries no secret-shaped name, console credential or CLOUDRON_* variable" || bad "the runner's environment carries: ${leak}"
    echo "${renv}" | grep -qx HR_INTERNAL_KEY_FILE && ok "the runner takes its internal key from a file (HR_INTERNAL_KEY_FILE present)" || bad "the runner has no HR_INTERNAL_KEY_FILE"
    rh="$(tr '\0' '\n' < /proc/${rpid}/environ | sed -n 's/^HOME=//p')"
    [ "${rh}" = /root ] && ok "the runner's HOME is /root" || bad "the runner's HOME is '${rh}'"
    grep -qx 'HR_ENV_GID_BASE=110000' <(tr '\0' '\n' < /proc/${rpid}/environ) && ok "the runner builds environments from HR_ENV_GID_BASE=110000" || bad "the runner's HR_ENV_GID_BASE is not 110000"
  else inc "the runner's environment does not carry HR_SESSION_UIDS: wrong process, not tested"; fi
  fi
  g="$(awk '/^Groups:/ {$1=""; print}' /proc/${rpid}/status | tr -d ' ')"
  [ -z "${g}" ] && ok "the runner has no supplementary groups" || bad "the runner holds supplementary groups: ${g}"
else inc "no runner process found"; fi
# The gateway runs as the product's user; root cannot read another uid's environment here (no CAP_SYS_PTRACE), so read it as that user.
gpid="$(pgrep -f '^/usr/local/bin/python3 (-I )?-m uvicorn app:app' | head -1)"
if [ -n "${gpid}" ]; then
  gh="$(asu 10001 cat /proc/${gpid}/environ 2>/dev/null | tr '\0' '\n' | sed -n 's/^HOME=//p')"
  [ "${gh}" = /home/agent ] && ok "the gateway's HOME is /home/agent" || bad "the gateway's HOME is '${gh}'"
else inc "no gateway process found"; fi
# The internal key file: root-only, readable by root (control), not by a session.
if [ -f /run/harnessrouter/internal-key ]; then
  [ "$(stat -c '%u %a' /run/harnessrouter)" = "0 700" ] && ok "/run/harnessrouter is root 0700" || bad "/run/harnessrouter is $(stat -c '%u %a' /run/harnessrouter)"
else bad "/run/harnessrouter/internal-key does not exist"; fi

# 4d. No install uid is left running, and no install HOME is left behind (upstream's iu_sweep).
n="$(awk -v lo=${INS_LO} -v hi=${INS_HI} '/^Uid:/ { for (i = 2; i <= 5; i++) if ($i >= lo && $i <= hi) { print FILENAME; break } }' /proc/[0-9]*/status 2>/dev/null | wc -l)"
[ "${n}" -eq 0 ] && ok "no process of an install uid (${INS_LO}-${INS_HI}) is alive" || bad "${n} processes of install uids are alive"
n="$(find /tmp -maxdepth 1 -name 'hr-install.*' 2>/dev/null | wc -l)"
[ "${n}" -eq 0 ] && ok "no /tmp/hr-install.* left" || bad "${n} /tmp/hr-install.* directories left"

# 4e. Secrets at rest: the gateway says the store encrypts, and every stored record is sealed (counted, never printed).
h="$(timeout 5 curl -s http://127.0.0.1:8080/healthz 2>/dev/null)"
echo "${h}" | grep -q '"secrets_encrypted": *true' && ok "the gateway reports secrets_encrypted: true" || bad "healthz does not report secrets_encrypted: true ('${h:0:80}')"
tot=0; sealed=0
while IFS= read -r -d '' f; do tot=$((tot+1)); [ "$(head -c 7 "${f}")" = "hrenc1:" ] && sealed=$((sealed+1)); done < <(find /app/data/secrets -mindepth 2 -type f -print0 2>/dev/null)
if [ "${tot}" -eq 0 ]; then inc "no record in /app/data/secrets/*/ (nothing to check)"
elif [ "${sealed}" -eq "${tot}" ]; then ok "every stored secret record is sealed (hrenc1:): ${sealed} of ${tot}"
else bad "only ${sealed} of ${tot} stored secret records are sealed"; fi

# 4f. Environment build identities never fall in the session range (they are uid = gid of the environment's directory).
if [ -d /app/data/environments ]; then
  n=0; m=0
  for e in /app/data/environments/*/; do [ -d "${e}" ] || continue; m=$((m+1)); g="$(stat -c %g "${e}")"; [ "${g}" -ge "${UID_LO}" ] && [ "${g}" -le "${UID_HI}" ] && n=$((n+1)); done
  [ "${m}" -eq 0 ] && inc "no environment built yet (gid range not tested)" || { [ "${n}" -eq 0 ] && ok "no environment's gid lies in the session range (${m} environments)" || bad "${n} of ${m} environments have a gid in the session range"; }
fi

# 5. Sessions cannot reach each other, on the real layout (/app/workspaces, each session's directory 0700 under its own uid).
d="/app/workspaces/containment-test-${S1}"; mkdir -p "${d}" && chown "${S1}:${S1}" "${d}" && chmod 0700 "${d}" && echo x > "${d}/f" && chown "${S1}:${S1}" "${d}/f"
[ "$(readable ${S1} "${d}/f")" = yes ] && ok "control: a session reads its own directory" || bad "control failed: a session cannot read its own directory"
[ "$(readable ${S2} "${d}/f")" = no ] && ok "another session uid cannot read a session's files" || bad "another session uid CAN read a session's files"
asu "${S2}" sh -c "touch '${d}/y'" 2>/dev/null && bad "another session uid CAN write into a session's directory" || ok "another session uid cannot write into a session's directory"
rm -rf "/app/workspaces/containment-test-${S1}"
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
