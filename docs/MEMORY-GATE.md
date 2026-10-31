# Memory gate: idle against production-like load

Measured 2026-10-31 on a lab install (Cloudron 10.1.6, packaged HarnessRouter 0.37.13, backends opencode 1.19.5 and codex 0.154.0, broker mode, firewall active).
Method: cgroup v2 counters on the app's container (`memory.current`, `memory.peak`, `memory.events`, `memory.stat`), per-process RSS, `oom_kill`.
The guest kernel (6.8) cannot reset `memory.peak`, so each reading starts from a freshly recreated container.

## Result

| Invariant | Idle | Loaded, 10 concurrent agent sessions, 4 minutes |
|---|---|---|
| `memory.current` | 199 MiB | up to the limit (page cache fills it; the kernel reclaims it) |
| anonymous memory | about 180 MiB | **peak 2,637 MiB = 64% of the 4 GiB limit** |
| `oom_kill` | 0 | 0 (all three runs) |
| per-process RSS at idle | console 104 MB, gateway 101 MB, runner 75 MB | one agent CLI is about 0.17 to 0.25 GiB |
| turns completed | | 508 of 508 at 4 GiB (426 at 2 GiB, 494 at 6 GiB) |
| verdict | | **PASS at 4 GiB, judged on anonymous memory** |

Why anonymous memory: `memory.peak` reached 100% of every limit tried (2, 4 and 6 GiB) because the page cache expands to fill whatever cgroup it is given.
That is reclaimable and is not demand. Cache pressure (`memory.events` `max`) fell as the limit rose: 30,599 at 2 GiB, 7,840 at 4 GiB, 2,143 at 6 GiB, with no kills at any of them.
A 2 GiB limit completed fewer turns (426) than 4 GiB (508). Sizing: anonymous peak divided by 0.65 gives about 4 GiB for 10 concurrent sessions.

## What this does not measure (say so, do not hide it)

* The model was a stub that answers instantly, so each session is short. A real model holds an agent process alive for the whole turn, which raises
  concurrency per request rate. The 10-concurrent figure is concurrent live agent processes, which is the quantity that costs memory.
* The `claude` backend (Node-based, heavier) was not in the load: only opencode and codex. Budget more per session if it is the main backend.
* Rule of thumb from these runs: about 0.2 GiB base plus about 0.25 GiB per concurrently active agent session. Raise `memoryLimit` for more than about 12 concurrent sessions.

## Disk finding from the same runs

Each session workspace is about 49 MB (120 files); 920 sessions left 14 GB under the workspace root. Workspaces are caches of their checkpoints
(upstream: rehydrated from the checkpoint, idle ones removed after 72 hours), so the package keeps them in `persistentDirs` (not in the backup).

## Repeating it

`test/memory-gate/load.sh <workers> <seconds>` with `A=<test install hostname>` and `PG=<a wrapper that runs `cloudron exec --app` on the test install>` drives alternating opencode and codex turns through the gateway against a stub model
(`stub.py`, run it as a container on the Cloudron network; a model on the host is not reachable from an app container). Take `memory.current`, `memory.stat`
and `memory.events` from the container's cgroup before and after, sampling every 2 seconds during the run.
