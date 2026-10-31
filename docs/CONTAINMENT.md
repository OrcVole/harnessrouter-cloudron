# How far an agent can reach, and what this package does about it

Agents in HarnessRouter run bash, git and their own tools inside the app. This page says what the package does to confine them, what
was measured on a Cloudron 10 test install, and what it cannot prevent. `test/containment.sh` repeats the measurable part on any
install (run it as root in the web terminal: `/app/pkg/test/containment.sh`).

## The model

| Measure | What it does | How it was proven |
|---|---|---|
| **Broker mode** (`HR_SANDBOX_TRUST=broker`, forced) | Agents never hold a real provider key: the gateway strips every credential and hands the agent a token only it can redeem. Upstream's self-hosting default (`owner`) hands the agent the real key. | A turn on opencode and on codex against a stub model whose "real key" was a canary string: the canary never appeared in the agent's environment, its command output, any request body the model received, or the files an agent can read; the stub saw it only as the gateway's `Authorization` header. |
| **One uid per session** (70000 to 109999) | Each session's directory is 0700 under its own uid; sessions cannot read or write each other. The range is high so `RLIMIT_NPROC` does not collide with other containers' uids. | `containment.sh` section 5, on the real `/app/workspaces` layout, and with a real session directory. |
| **Egress firewall** (`net_admin`, IPv4 and IPv6, owner match on the session range) | Session uids cannot reach Cloudron's internal network (RFC 1918, link-local, CGNAT, ULA), the mail ports, or the runner's control port. They can reach the internet, DNS, the gateway, the console and the reverse proxy's HTTPS port. | Every rule asserted by name; each "blocked" result checked against root reaching the same place; the uid-range edges are exact; the start-up self-test was falsified on purpose (rules removed: it reported the breach). |
| **Fail closed** | If any rule cannot be installed, or the self-test shows it did not hold, the app refuses to start. | Read in `start.sh`; a kernel without IPv6 is the one case that skips the IPv6 rules, since it has no IPv6 egress at all. |
| **Product data out of reach** | Session uids cannot read the data directory, the secrets, the login store, the operator's settings file, the product user's HOME or the workspace index, nor write where the product or other sessions read from (agent tools, environments). | `containment.sh` sections 4 and 4b, each with a root control. |
| **Nothing inherited** | No `CLOUDRON_*` variable reaches the entrypoint; the runner (the agents' parent) holds no console password, secret key or login store path. | `containment.sh` sections 4c and 6. |
| **No credentials on command lines** | Another session cannot pick a token out of `/proc/<pid>/cmdline`. | 2,591 command-line reads by an unrelated uid while six sessions ran turns: no token-shaped string. The sampler caught a planted one. |

## The credential relay

The runner opens a small HTTP relay on an ephemeral loopback port the first time a turn needs one. Agents are meant to reach it: it
holds the turn's credential and forwards to the provider, and it answers only the turn's random `hr-relay-` token (401 otherwise). It
is upstream's credential boundary, so the firewall leaves it open and `containment.sh` asserts that every loopback listener a session
can reach refuses a request without a token.

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
- **Backends we do not build.** Each agent CLI is downloaded at first start under its own licence; the package pins versions and keeps
  the default list short (`opencode`, `codex`, `claude`). `gemini` and `qoder` are refused, because broker mode cannot serve them.
- **Anyone who signs in.** There is one console user. Use a strong password and change the generated one.
