# HarnessRouter for Cloudron

An unofficial Cloudron package for [HarnessRouter](https://github.com/HarnessRouter/harnessrouter) Community Edition: one API and console in
front of agent command-line tools (OpenCode, Codex, Claude Code). Your own product or scripts talk to one OpenAI Responses-compatible API;
HarnessRouter runs the chosen agent, streams its progress and keeps the transcripts.

**Status: not published.** This repository has no versions feed yet and the image is not on a public registry. It has been built and
gated on a Cloudron 10 test install only (upstream 0.37.13, package 0.1.0).

## What the package does

- Rebuilds upstream from its source at a pinned commit on `cloudron/base` (not a repack of upstream's image).
- One container: console (3000), gateway (8080) and runner (8081), SQLite, all state under `/app/data`.
- Generates the console password and the secret key on first start; the published default password is refused.
- **Broker mode** (`HR_SANDBOX_TRUST=broker`): every agent session runs as its own unprivileged user, behind an egress firewall, and provider
  keys stay with the HarnessRouter service, out of the agents' reach. If the firewall cannot be installed, the app refuses to start agents
  rather than running them unconfined. The package needs the `net_admin` capability for this and for nothing else.
- Agent CLIs are downloaded on first start into the data volume, under their own licences; they are not in the image.
- Agent session workspaces live in `persistentDirs` (outside the backup, rebuilt from checkpoints); transcripts and secrets are in the backup.
- The operator's `/app/data/env` file is parsed against an allowlist, never executed.

## Tests

| Script | What it proves |
|---|---|
| `test/containment.sh` | run as root inside the app: the firewall rules, reachability from a session uid (each "blocked" result has a root control), data isolation, session-to-session isolation, no `CLOUDRON_*` in the entrypoint's environment |
| `test/memory-gate/` | idle against production-like load, judged on anonymous memory (see `docs/MEMORY-GATE.md`) |
| `test/secret-scan.sh` | the pre-publish anonymity and credential scan over the repository and the exact image digest |

`docs/MEMORY-GATE.md` lists what the memory run does not measure.

## Licence

The packaging is Apache-2.0 (see `LICENSE`). HarnessRouter Community Edition keeps its own licence; the agent CLIs it installs keep theirs.
