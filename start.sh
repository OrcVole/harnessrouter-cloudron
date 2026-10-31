#!/bin/bash
# HarnessRouter on Cloudron: prepare the data volume, set the broker-mode environment, install the agent
# egress firewall, then hand over to upstream's entrypoint. Design: CONTAINMENT.md in the workspace.
#
# Runs as root (the per-session uid switch needs it). Idempotent: every step can run on every boot, and a
# restore, which returns files with unmapped owners, is repaired at the top.
set -eu

log()  { echo "==> [start] $*"; }
warn() { echo "==> [start] WARNING: $*" >&2; }
die()  { echo "==> [start] REFUSING TO START: $*" >&2; exit 1; }

DATA=/app/data
SECRETS="${DATA}/.secrets"

# ---------------------------------------------------------------------------------------------
# 1. The data volume. Upstream's entrypoint writes /env on every boot (the image links it here)
#    and treats the data directory as its own, so the targets must exist before it runs.
# ---------------------------------------------------------------------------------------------
# Session workspaces and their checkpoint markers live OUTSIDE /app/data, in the manifest's persistentDirs: they survive updates but are
# not part of Cloudron's backups. Upstream treats a workspace as a cache of its checkpoint (it rehydrates from it and reaps idle ones
# after 72 hours), and a busy install writes about 50 MB per session (measured: 14 GB after 920 sessions), which a backup should not carry.
WS=/app/workspaces; WSM=/app/ws-markers
mkdir -p "${DATA}/home" "${DATA}/.hr-env" "${SECRETS}" "${WS}" "${WSM}"

# Ownership, reasserted on EVERY boot. A Cloudron restore returns files owned by an unmapped uid (808 on the lab), and upstream's
# entrypoint only re-owns a short list of named files: after a restore the product could not read its encrypted connection store
# (secrets/global/harness-integrations, mode 0600) and the console showed NO connections (measured, runbook note 97).
# The map below is what a fresh first boot produces: the product's user owns its databases, blobs, secret store, workspaces and
# HOME; root owns everything the entrypoint and the runner create for themselves.
for f in blobs secrets home control.db control.db-shm control.db-wal graph.db graph.db-shm graph.db-wal selfhost-auth.json; do
  [ -e "${DATA}/${f}" ] && chown -R agent:agent "${DATA}/${f}"
done
for f in .hr-env agent-tools environments; do
  [ -e "${DATA}/${f}" ] && chown -R root:root "${DATA}/${f}"
done
chown agent:agent "${DATA}"
# The product user's HOME holds its npm cache and logs and whatever its tools write later: not for session uids to read (it was
# created 0755; turns on opencode and codex work with 0700, measured).
chmod 0700 "${DATA}/home"
# Top level only: every session directory inside is owned by its own session uid (0700) and must stay that way. A recursive chown here
# would hand them all to the product's user and a resumed session would lose write access to its own workspace.
chown agent:agent "${WS}"; chmod 0751 "${WS}"
chown root:root "${WSM}"; chmod 0700 "${WSM}"
chmod 0700 "${SECRETS}"; chown -R root:root "${SECRETS}"

# ---------------------------------------------------------------------------------------------
# 2. Secrets, generated ONCE and kept in the volume (so a backup carries them). Never printed: the
#    operator reads the password from the file in the web terminal (POSTINSTALL says how).
# ---------------------------------------------------------------------------------------------
gen() { head -c 48 /dev/urandom | base64 | tr -d '=+/\n' | head -c 40; }
for f in admin-password secret-key; do
  if [ ! -s "${SECRETS}/${f}" ]; then
    ( umask 077; gen > "${SECRETS}/${f}" )
    log "generated ${f} (kept in ${SECRETS}, mode 0600)"
  fi
  chmod 0600 "${SECRETS}/${f}"; chown root:root "${SECRETS}/${f}"
done
HR_AUTH_PASSWORD="$(cat "${SECRETS}/admin-password")"; HR_SECRET_KEY="$(cat "${SECRETS}/secret-key")"
export HR_AUTH_PASSWORD HR_SECRET_KEY

# ---------------------------------------------------------------------------------------------
# 3. The environment. Trust model A with the broker hardening: agents never hold a real provider key.
# ---------------------------------------------------------------------------------------------
export HR_DATA_DIR="${DATA}" HARNESS_WORKSPACE="${WS}" HR_WS_MARKER_DIR="${WSM}"
export HR_AUTH_STORE="${DATA}/selfhost-auth.json"     # upstream defaults this to a literal /data path
export HR_SANDBOX_TRUST=broker                         # any value but "owner" is fail-closed broker mode
export WITH_STARTER_KITS=0
# No `proxyAuth`: measured on a test install, its wall takes /login from the console, blocks public share links, and lets any
# request that carries an `Authorization: Bearer` header through, so the console's own login stays the real gate.
# Session uids: moved to a high range, away from other containers' uids (RLIMIT_NPROC counts per real uid).
# Upstream's span is a fixed 40000 (runner/server.py); the firewall below uses the same numbers.
UID_BASE=70000; UID_SPAN=40000
export HR_SESSION_UID_BASE="${UID_BASE}"

# Backends: a short default. gemini and qoder are native-only and refused in broker mode, so they are
# stripped even if an operator asks. Claude Code installs on first start into the volume, under its own
# licence, by the operator's act; it is never in the image.
export HR_BACKENDS="opencode,codex,claude"
export HR_OPENCODE_VERSION=1.19.5                       # the v1 line: upstream's runner passes --pure, which v2.x (2.2.5) rejects (measured)
export HR_CODEX_VERSION=0.154.0                        # upstream's tested pin at this tag
export CLAUDE_CODE_VERSION=2.1.280                     # upstream's tested pin at this tag

# Operator overrides: /app/data/env, parsed, never sourced. The product's user owns the data directory, so a
# compromised console could write this file; sourcing it as root would turn that into root at the next boot.
# Only simple HR_* settings pass, and the settings that carry the security model cannot be changed here.
ENVFILE="${DATA}/env"
# Session uids can traverse /app/data (they run the agent tools under it), so a file whose name they know is readable unless its
# mode says otherwise, and a file made in the web terminal is 0644 (measured: a session read it). It may carry tokens.
[ -f "${ENVFILE}" ] && { chown root:root "${ENVFILE}"; chmod 0600 "${ENVFILE}"; }
if [ -f "${ENVFILE}" ]; then
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    if ! [[ "${k}" =~ ^(HR_[A-Z0-9_]+|CLAUDE_CODE_VERSION)$ ]]; then warn "env: ignoring '${k}' (not an HR_ setting)"; continue; fi
    case "${k}" in
      HR_SANDBOX_TRUST|HR_AUTH_*|HR_SECRET_*|HR_SESSION_UID_BASE|HR_DATA_DIR|HR_ENV_ROOT|HR_WS_MARKER_DIR|HR_BUILTIN_SKILLS_DIR|HR_KITS_DIR)
        warn "env: ${k} is part of the security model and cannot be set here"; continue ;;
    esac
    if ! [[ "${v}" =~ ^[A-Za-z0-9_.,:/@+=-]*$ ]]; then warn "env: ignoring ${k} (unsupported characters in the value)"; continue; fi
    export "${k}=${v}"
  done < "${ENVFILE}"
fi
kept=""; for b in ${HR_BACKENDS//,/ }; do
  case "${b}" in gemini|qoder) warn "backend '${b}' is refused in broker mode; removed" ;; *) kept="${kept:+${kept},}${b}" ;; esac
done
export HR_BACKENDS="${kept}"
[ -n "${HR_BACKENDS}" ] || die "HR_BACKENDS is empty after removing backends that broker mode refuses"

# ---------------------------------------------------------------------------------------------
# 4. The agent firewall (measure 10, Paperclip ADR 0002 section 3). Agents run as session uids; their
#    outbound traffic is cut off from Cloudron's internal network, the mail ports and the runner.
#    If any rule cannot be installed, or the self-test shows it did not hold, the app REFUSES TO START:
#    agents must never run unconfined.
# ---------------------------------------------------------------------------------------------
fw_ok=1
UIDS="${UID_BASE}-$((UID_BASE + UID_SPAN - 1))"
# A kernel booted without IPv6 has no /proc/net/if_inet6 and no IPv6 sockets at all, so there is no IPv6 egress to filter, and
# ip6tables would fail and refuse the whole app. Only that case skips the IPv6 rules; IPv6 switched off by sysctl still gets them.
have_v6=1; [ -e /proc/net/if_inet6 ] || have_v6=0
v4() { iptables  -A OUTPUT -m owner --uid-owner "${UIDS}" "$@" || fw_ok=0; }
v6() { (( have_v6 )) || return 0; ip6tables -A OUTPUT -m owner --uid-owner "${UIDS}" "$@" || fw_ok=0; }
command -v iptables >/dev/null && command -v ip6tables >/dev/null || die "iptables is missing from the image"
iptables -S OUTPUT >/dev/null 2>&1 || die "cannot read the firewall (is the net_admin capability granted?)"
# Re-running on a restart of the same container must not stack rules.
iptables  -S OUTPUT 2>/dev/null | grep -q -- "--uid-owner ${UIDS}" && { iptables -F OUTPUT; (( have_v6 )) && ip6tables -F OUTPUT 2>/dev/null || true; }

ns4="$(awk '/^nameserver/ && $2 !~ /:/ {print $2; exit}' /etc/resolv.conf)"
ns6="$(awk '/^nameserver/ && $2 ~ /:/ {print $2; exit}' /etc/resolv.conf)"
# The runner's control port (root, spawns sessions) is never an agent's business. The runner also opens a credential relay on an
# ephemeral loopback port that agents DO use: it answers only a per-turn random token (401 otherwise, measured), so it stays open.
# Then what an agent legitimately needs.
v4 -d 127.0.0.1 -p tcp --dport 8081 -j REJECT
v6 -d ::1       -p tcp --dport 8081 -j REJECT
if [ -n "${ns4}" ]; then for p in udp tcp; do v4 -d "${ns4}" -p "${p}" --dport 53 -j ACCEPT; done; fi
if [ -n "${ns6}" ]; then for p in udp tcp; do v6 -d "${ns6}" -p "${p}" --dport 53 -j ACCEPT; done; fi
v4 -d 127.0.0.1 -p tcp --dport 8080 -j ACCEPT           # the gateway: the broker's door
v4 -d 127.0.0.1 -p tcp --dport 3000 -j ACCEPT           # the console
v4 -d 172.18.0.1 -p tcp --dport 443 -j ACCEPT           # the reverse proxy, front door only
# Everything private, link-local and CGNAT is closed, then the mail ports. Other apps answer plain HTTP on
# their internal addresses, bypassing their own walls (measured on Paperclip); this is what closes that.
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do v4 -d "${net}" -j REJECT; done
for port in 25 465 587; do v4 -p tcp --dport "${port}" -j REJECT; done
for net in fc00::/7 fe80::/10; do v6 -d "${net}" -j REJECT; done
for port in 25 465 587; do v6 -p tcp --dport "${port}" -j REJECT; done
(( fw_ok )) || die "an agent firewall rule could not be installed (is the net_admin capability granted?)"

# Self-test from a session uid: the reverse proxy's plain-HTTP port is closed by the rules above, and open to
# anyone without them, so a connection that SUCCEEDS means the rules did not hold. (Falsified on purpose while packaging:
# with the rules removed, the self-test reported the breach.)
if timeout 4 setpriv --reuid="$((UID_BASE + 1))" --regid="$((UID_BASE + 1))" --clear-groups \
     bash -c 'echo > /dev/tcp/172.18.0.1/80' 2>/dev/null; then
  die "self-test: a session uid reached the reverse proxy on port 80 despite the rules"
fi
if (( have_v6 )); then log "firewall : active for uids ${UIDS} (IPv4 and IPv6); self-test refused as expected"
else log "firewall : active for uids ${UIDS} (IPv4; this kernel has no IPv6); self-test refused as expected"; fi

# ---------------------------------------------------------------------------------------------
# 5. Nothing of Cloudron's reaches an agent: drop every CLOUDRON_* variable, then hand over.
# ---------------------------------------------------------------------------------------------
for v in $(env | sed -n 's/^\(CLOUDRON_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "${v}"; done

log "starting HarnessRouter (broker mode; backends: ${HR_BACKENDS}); the first start installs agent CLIs and can take minutes"
exec /usr/bin/tini -- /app/entrypoint.sh
