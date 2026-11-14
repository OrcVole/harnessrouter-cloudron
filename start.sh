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
mkdir -p "${WS}" "${WSM}"
# The volume's top level is root's and the product's group's, mode 1771 (upstream's model since 0.37.17): the product can create its
# own files there but cannot rename or replace root's. A volume from 0.1.0 had it owned by the product's user, so a name root keeps
# at the top level may have been replaced by a link or a file: removed rather than followed (upstream's root_dir). Literal paths only.
chown root:agent /app/data; chmod 1771 /app/data
top_dir() {  # top_dir <name> <owner>: /app/data/<name> is a real directory (a link or a file in its place is removed), owned so
  case "$1" in ''|*/*|.|..) die "top_dir: bad name '$1'" ;; esac
  local d="/app/data/$1"
  if [ -L "${d}" ] || { [ -e "${d}" ] && [ ! -d "${d}" ]; }; then rm -f -- "/app/data/$1"; fi
  mkdir -p "${d}"; chown "$2" "${d}"
}
top_dir .hr-env root:root; top_dir .secrets root:root; top_dir home agent:agent

# Ownership, repaired on EVERY boot. A Cloudron restore returns files owned by an unmapped uid (808 on the lab), and upstream's
# entrypoint re-owns only the top level of a short list: after a restore the product could not read its encrypted connection store
# (secrets/global/harness-integrations, mode 0600) and the console showed NO connections (measured, runbook note 97).
# Only what is NOT already right is touched, links are never followed (-h), and a file with a second name is skipped: in a
# directory the product writes, a hard link to one of root's files would otherwise be handed to the product.
for d in blobs secrets home; do
  [ -d "${DATA}/${d}" ] && [ ! -L "${DATA}/${d}" ] && \
    find "${DATA}/${d}" -xdev \( -type d -o -type l -o -links 1 \) \( ! -user agent -o ! -group agent \) -exec chown -h agent:agent {} +
done
# The databases and the login store: only a regular file with one name (upstream's own rule, entrypoint.sh).
find "${DATA}" -maxdepth 1 -type f -links 1 \( -name '*.db' -o -name '*.db-*' -o -name selfhost-auth.json \) \
  \( ! -user agent -o ! -group agent \) -exec chown agent:agent {} +
# Root's trees. agent-tools is resealed by the entrypoint (seal_tools). environments: each one is root:<its own group> 0750, which
# the runner claims at start, so only an owner that is not root (the restore case) is changed, and the group is kept.
[ -d "${DATA}/environments" ] && [ ! -L "${DATA}/environments" ] && find "${DATA}/environments" -xdev ! -user root -exec chown -h root {} +
find "${DATA}/.hr-env" -xdev \( ! -user root -o ! -group root \) -exec chown -h root:root {} +
# The product user's HOME holds its npm cache and logs and whatever its tools write later: not for session uids to read (it was
# created 0755; turns on opencode and codex work with 0700, measured).
chmod 0700 "${DATA}/home"
# Top level only: every session directory inside is owned by its own session uid (0700) and must stay that way. Root's since
# 0.41 (the runner allocates them); traversable by sessions, neither listable nor writable.
chown root:root "${WS}"; chmod 0751 "${WS}"
chown root:root "${WSM}"; chmod 0700 "${WSM}"
chmod 0700 "${SECRETS}"; find "${SECRETS}" -xdev \( ! -user root -o ! -group root \) -exec chown -h root:root {} +
# Next's cache (the image links /app/ui/.next/cache here): the console's own, on the writable /run.
install -d -m 0700 -o agent -g agent /run/hr-next-cache

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
# Environment build identities (uid = gid = 60000 + hash % 40000 upstream, runner/environments.py) run a project's setup and its
# package hooks. Upstream's default range overlaps ours (70000-99999), so a build could run as a live session's own uid: moved
# above the session range, and firewalled like it (section 4). The runner migrates existing environments at start.
ENV_BASE=110000; ENV_SPAN=40000
export HR_ENV_GID_BASE="${ENV_BASE}"
# Install uids: upstream's entrypoint runs every package manager and unpacker of a first-start install as its base's own uid,
# 19000 + its place in a fixed list (31 bases today); 19001-19099 leaves room for new ones. Firewalled like sessions.
INSTALL_LO=19001; INSTALL_HI=19099
# Upstream's gateway probes its Docker-compose memory stack (mem0, graphiti, ...) by bare host name at every start: never here.
export HR_MEMORY_DISCOVER=0

# Backends: a short default. gemini and qoder are native-only and refused in broker mode, so they are
# stripped even if an operator asks. Claude Code installs on first start into the volume, under its own
# licence, by the operator's act; it is never in the image.
export HR_BACKENDS="opencode,codex,claude"
# Versions: upstream's own pins, each checked against a committed digest or installed from a committed lock (opencode 1.18.23,
# codex and Claude Code from docker/locks). Overriding one here would install it unverified, so the package sets none.

# Operator overrides: /app/data/env, parsed, never sourced. The product's user owns the data directory, so a
# compromised console could write this file; sourcing it as root would turn that into root at the next boot.
# Only simple HR_* settings pass, and the settings that carry the security model cannot be changed here.
ENVFILE="${DATA}/env"
# Session uids can traverse /app/data (they run the agent tools under it), so a file whose name they know is readable unless its
# mode says otherwise, and a file made in the web terminal is 0644 (measured: a session read it). It may carry tokens.
# Only a regular file with one name is read or re-owned: the product can create names in /app/data, and chown would follow a link.
if [ -L "${ENVFILE}" ] || { [ -e "${ENVFILE}" ] && { [ ! -f "${ENVFILE}" ] || [ "$(stat -c %h "${ENVFILE}")" != 1 ]; }; }; then
  warn "env: ${ENVFILE} is a link, not a regular file, or has a second name: ignored"; ENVFILE=/nonexistent
fi
[ -f "${ENVFILE}" ] && { chown root:root "${ENVFILE}"; chmod 0600 "${ENVFILE}"; }
if [ -f "${ENVFILE}" ]; then
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    if ! [[ "${k}" =~ ^(HR_[A-Z0-9_]+|CLAUDE_CODE_VERSION)$ ]]; then warn "env: ignoring '${k}' (not an HR_ setting)"; continue; fi
    case "${k}" in
      HR_SANDBOX_TRUST|HR_AUTH_*|HR_SECRET_*|HR_SESSION_UID_BASE|HR_DATA_DIR|HR_ENV_ROOT|HR_WS_MARKER_DIR|HR_BUILTIN_SKILLS_DIR|HR_KITS_DIR|\
      HR_ENV_GID_BASE|HR_INTERNAL_KEY_FILE|HR_SESSION_UIDS|HR_SANDBOX_PER_SESSION|HR_LOCKS_DIR)
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
# 4. The egress firewall (measure 10, Paperclip ADR 0002 section 3). Four principals, owner-matched:
#    - session uids (agents), environment build uids (a project's setup and package hooks) and install uids (first-start
#      package managers and unpackers): cut off from Cloudron's internal network, the mail ports and the runner's control
#      port; they keep DNS, the gateway, the console, the reverse proxy's HTTPS port and the internet;
#    - root (uid 0): cut off from Cloudron's internal network only. Since 0.41 the root runner dials remote MCP servers on an
#      agent's behalf (its MCP relay), so without this an MCP address on another app's internal address was reachable from a
#      turn. Root keeps loopback (the gateway, the relays, the container's resolver), the reverse proxy's HTTPS port and the
#      internet.
#    If any rule cannot be installed, or a self-test shows it did not hold, the app REFUSES TO START.
# ---------------------------------------------------------------------------------------------
fw_ok=1
UIDS="${UID_BASE}-$((UID_BASE + UID_SPAN - 1))"
EUIDS="${ENV_BASE}-$((ENV_BASE + ENV_SPAN - 1))"
IUIDS="${INSTALL_LO}-${INSTALL_HI}"
# A kernel booted without IPv6 has no /proc/net/if_inet6 and no IPv6 sockets at all, so there is no IPv6 egress to filter, and
# ip6tables would fail and refuse the whole app. Only that case skips the IPv6 rules; IPv6 switched off by sysctl still gets them.
have_v6=1; [ -e /proc/net/if_inet6 ] || have_v6=0
command -v iptables >/dev/null && command -v ip6tables >/dev/null || die "iptables is missing from the image"
iptables -S OUTPUT >/dev/null 2>&1 || die "cannot read the firewall (is the net_admin capability granted?)"
# Re-running on a restart of the same container must not stack rules.
iptables  -S OUTPUT 2>/dev/null | grep -q -- "--uid-owner ${UIDS}" && { iptables -F OUTPUT; (( have_v6 )) && ip6tables -F OUTPUT 2>/dev/null || true; }

ns4="$(awk '/^nameserver/ && $2 !~ /:/ {print $2; exit}' /etc/resolv.conf)"
ns6="$(awk '/^nameserver/ && $2 ~ /:/ {print $2; exit}' /etc/resolv.conf)"
PRIV4="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"
PRIV6="fc00::/7 fe80::/10"
# confine <uid range>: the agent set. The runner's control port (root, spawns sessions) is never their business; the runner also
# opens a credential relay and an MCP relay on ephemeral loopback ports that agents DO use: each answers only a per-turn random
# token (401 otherwise), so they stay open. Then what they legitimately need, then everything private, link-local and CGNAT, then
# the mail ports. Other apps answer plain HTTP on their internal addresses, bypassing their own walls (measured on Paperclip).
v4() { iptables  -A OUTPUT -m owner --uid-owner "${OWNER}" "$@" || fw_ok=0; }
v6() { (( have_v6 )) || return 0; ip6tables -A OUTPUT -m owner --uid-owner "${OWNER}" "$@" || fw_ok=0; }
confine() {
  OWNER="$1"
  local net port p
  v4 -d 127.0.0.1 -p tcp --dport 8081 -j REJECT
  v6 -d ::1       -p tcp --dport 8081 -j REJECT
  if [ -n "${ns4}" ]; then for p in udp tcp; do v4 -d "${ns4}" -p "${p}" --dport 53 -j ACCEPT; done; fi
  if [ -n "${ns6}" ]; then for p in udp tcp; do v6 -d "${ns6}" -p "${p}" --dport 53 -j ACCEPT; done; fi
  v4 -d 127.0.0.1 -p tcp --dport 8080 -j ACCEPT           # the gateway: the broker's door
  v4 -d 127.0.0.1 -p tcp --dport 3000 -j ACCEPT           # the console
  v4 -d 172.18.0.1 -p tcp --dport 443 -j ACCEPT           # the reverse proxy, front door only
  for net in ${PRIV4}; do v4 -d "${net}" -j REJECT; done
  for port in 25 465 587; do v4 -p tcp --dport "${port}" -j REJECT; done
  for net in ${PRIV6}; do v6 -d "${net}" -j REJECT; done
  for port in 25 465 587; do v6 -p tcp --dport "${port}" -j REJECT; done
}
confine "${UIDS}"; confine "${EUIDS}"; confine "${IUIDS}"
# Root: internal addresses only, after the reverse proxy's HTTPS port. Loopback is never touched.
OWNER=0
if [ -n "${ns4}" ]; then for p in udp tcp; do v4 -d "${ns4}" -p "${p}" --dport 53 -j ACCEPT; done; fi
if [ -n "${ns6}" ]; then for p in udp tcp; do v6 -d "${ns6}" -p "${p}" --dport 53 -j ACCEPT; done; fi
v4 -d 172.18.0.1 -p tcp --dport 443 -j ACCEPT
for net in ${PRIV4}; do v4 -d "${net}" -j REJECT; done   # ROOT-REJECT
for net in ${PRIV6}; do v6 -d "${net}" -j REJECT; done   # ROOT-REJECT
(( fw_ok )) || die "a firewall rule could not be installed (is the net_admin capability granted?)"

# Self-tests: the reverse proxy's plain-HTTP port is closed by the rules above and open to anyone without them, so a connection that
# SUCCEEDS means the rules did not hold: for a session uid, an environment build uid, an install uid and root.
# (Falsified on purpose while packaging: with the rules removed, the self-test reported the breach.)
for u in "$((UID_BASE + 1))" "$((ENV_BASE + 1))" "${INSTALL_LO}"; do
  if timeout 4 setpriv --reuid="${u}" --regid="${u}" --clear-groups bash -c 'echo > /dev/tcp/172.18.0.1/80' 2>/dev/null; then
    die "self-test: uid ${u} reached the reverse proxy on port 80 despite the rules"
  fi
done
if timeout 4 bash -c 'echo > /dev/tcp/172.18.0.1/80' 2>/dev/null; then   # ROOT-SELFTEST
  die "self-test: root reached the reverse proxy on port 80 despite the rules"   # ROOT-SELFTEST
fi   # ROOT-SELFTEST
v6note="IPv4 and IPv6"; (( have_v6 )) || v6note="IPv4; this kernel has no IPv6"
log "firewall : active for sessions ${UIDS}, environment builds ${EUIDS}, installs ${IUIDS} and root (internal addresses only) (${v6note}); self-tests refused as expected"

# ---------------------------------------------------------------------------------------------
# 5. Nothing of Cloudron's reaches an agent: drop every CLOUDRON_* variable, then hand over.
# ---------------------------------------------------------------------------------------------
for v in $(env | sed -n 's/^\(CLOUDRON_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "${v}"; done

log "starting HarnessRouter (broker mode; backends: ${HR_BACKENDS}); the first start installs agent CLIs and can take minutes"
exec /usr/bin/tini -- /app/entrypoint.sh
