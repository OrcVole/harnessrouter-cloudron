# How far an agent can reach, and what this package does about it

Agents in HarnessRouter run bash, git and their own tools inside the app. This page says what the package does to confine them, what
was measured on a Cloudron 10 test install, and what it cannot prevent. `test/containment.sh` repeats the measurable part on any
install (run it as root in the web terminal: `/app/pkg/test/containment.sh`).

## The model

| Measure | What it does | How it was proven |
|---|---|---|
| **Broker mode** (`HR_SANDBOX_TRUST=broker`, forced) | Agents never hold a real provider key: the gateway strips every credential and hands the agent a token only it can redeem. Upstream's self-hosting default (`owner`) hands the agent the real key. | A turn on opencode and on codex against a stub model whose "real key" was a canary string: the canary never appeared in the agent's environment, its command output, any request body the model received, or the files an agent can read; the stub saw it only as the gateway's `Authorization` header. |
| **One uid per session** (70000 to 109999) | Each session's directory is 0700 under its own uid; sessions cannot read or write each other. The range is high so `RLIMIT_NPROC` does not collide with other containers' uids. Environment builds use their own range above it (`HR_ENV_GID_BASE=110000`): upstream's default overlapped ours, so a build could have run as a live session's uid. | `containment.sh` sections 3, 4f and 5, on the real `/app/workspaces` layout, and with a real session directory. |
| **Egress firewall** (`net_admin`, IPv4 and IPv6, owner match) over four principals | **Session uids** (70000 to 109999), **environment build uids** (110000 to 149999: a project's setup script and package hooks) and **install uids** (19001 to 19099: the package managers and unpackers of the first-start installs) cannot reach Cloudron's internal network (RFC 1918, link-local, CGNAT, ULA), the mail ports, or the runner's control port; they can reach the internet, DNS, the gateway, the console and the reverse proxy's HTTPS port. **Root** cannot reach Cloudron's internal network; it keeps loopback, DNS, the reverse proxy's HTTPS port and the internet (see "The relays" below). | Every rule asserted by name, per principal; each "blocked" result checked against a uid that no rule names reaching the same place; the edges of every range are exact; a start-up self-test for each of the four principals refuses at every start. Falsified on a test install: the session self-test with the rules removed (0.1.0), and root's rule removed at run time, when root then reached an internal address. |
| **Fail closed** | If any rule cannot be installed, or the self-test shows it did not hold, the app refuses to start. | Read in `start.sh`; a kernel without IPv6 is the one case that skips the IPv6 rules, since it has no IPv6 egress at all. |
| **Product data out of reach** | Session uids cannot read the data directory, the secrets, the login store, the operator's settings file, the product user's HOME or the workspace index, nor write where the product or other sessions read from (agent tools, environments). | `containment.sh` sections 4 and 4b, each with a root control. |
| **Nothing inherited** | No `CLOUDRON_*` variable reaches the entrypoint. The runner (the agents' parent) holds no secret in its environment at all: not the internal key (it reads it from `/run/harnessrouter/internal-key`, root-only), not the console password or the secret key, no secret-shaped name; it holds no supplementary group. Sessions start from a scrubbed environment through `setpriv`. | `containment.sh` sections 4, 4c and 6. The internal-key assertion was falsified against 0.1.0, where the runner held it (FAIL there, PASS here). Upstream's `scripts/secret-canary-gate.py`, run on the lab, found no planted canary in any session's environment, command line, files or client reads. |
| **Root's files are root's** (upstream 0.37.17, GHSA-mm72-wr37-26pv) | Everything under `/app` is root's and writable by root only; the data volume's top is `root:agent 1771`, so the product's user can make its own files there but cannot rename or replace root's (the tools, the environments, `.secrets`). The start script follows no link and re-owns no file with a second name. | `containment.sh` section 4a. |
| **Secrets sealed at rest** | Every stored record is encrypted under the secret key. | `containment.sh` section 4e: `healthz` reports it, and every record starts `hrenc1:`. |
| **No credentials on command lines** | Another session cannot pick a token out of `/proc/<pid>/cmdline`. | 2,591 command-line reads by an unrelated uid while six sessions ran turns: no token-shaped string. The sampler caught a planted one. |

## The relays, and why root is firewalled

The runner (root) opens two small HTTP relays on ephemeral loopback ports the first time a turn needs one. Agents are meant to reach
both, and each answers only the turn's random token (401 otherwise), so the firewall leaves them open and `containment.sh` asserts
that every loopback listener a session can reach refuses a request without a token.

- **The credential relay** holds the turn's credential. In broker mode it forwards to the gateway on loopback, and the gateway (the
  product's user) calls the provider.
- **The MCP relay** (upstream 0.38 onwards) holds each remote MCP server's address and credentials, so the session sees neither. It
  forwards only to the configured server (and to addresses that same server names, on the same host and port). Its connections are
  made by the runner, which is **root**, not by the session. Upstream's own reasoning ("a route reaches nothing the session could not
  already open") holds only without a per-uid firewall: under this package's rules an MCP address on Cloudron's internal network,
  set by the console, by an API caller (a harness, or a `$headers` value filled into a stored address) or by a plugin, would have
  become reachable from a turn although the session itself is refused it.

So the package firewalls root too, from Cloudron's internal network only (RFC 1918, link-local, CGNAT, ULA). Before adding the
rule, every outbound connection root made during a normal start and an agent turn was recorded on a test install: all of them went
to loopback or to public addresses, and no addon is used, so nothing root does needs the internal network. Consequences:

- an MCP server must be reachable at a public address (or through this Cloudron's HTTPS front door, which stays open to root);
- an agent still cannot reach another app's internal address, neither directly nor through the runner;
- the gateway (the product's user, which runs the console's "Test connection" and calls the providers) is not firewalled, as before:
  it acts only on addresses the operator or an API caller configured, never on an agent's choice.

## Why there is no Cloudron login wall (`proxyAuth`)

Measured on a separate test install with `proxyAuth` and Bearer passthrough:

- the wall takes over `/login`, so the console's own login page cannot be reached;
- public share links (`/share/`, `/api/share/`) end up behind the wall;
- any request carrying an `Authorization: Bearer` header goes through the wall, whatever the token. The console's own login then
  decided (a wrong password was refused), so the wall added nothing an attacker could not step around, and switching the console's
  own login off behind it would have left the instance open to anyone who sends that header.

So the package keeps the console's own login with a generated password, and offers no `proxyAuth` option.

## What this package cannot prevent

- **The instance's own power.** An agent can use what its session was given: run code there, call the brokered model, read its own
  inputs. A brokered token can still spend for the session's life, so give HarnessRouter a provider key with a spending cap.
- **The public internet.** Agents need it (model APIs, git hosts, registries), so what an agent can see, it can send out.
- **Prompt injection through task input.** Broker mode and the firewall bound the damage; they do not stop it.
- **Backends we do not build.** Each agent CLI is downloaded at first start under its own licence, from upstream's pins, each checked
  against a committed digest or lock; the default list stays short (`opencode`, `codex`, `claude`). `gemini` and `qoder` are refused,
  because broker mode cannot serve them.
- **What an MCP server you configure can be made to do.** An agent can send any MCP request to a server its harness names, for the life
  of its turn, with the credentials you gave that server. Give MCP servers tokens scoped to what agents should do.
- **Anyone who signs in.** There is one console user. Use a strong password and change the generated one.
