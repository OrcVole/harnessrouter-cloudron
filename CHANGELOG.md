# Changelog

[0.2.0]
* Update HarnessRouter Community Edition to 0.41.16 (from 0.37.13). Upstream's release notes: https://github.com/HarnessRouter/harnessrouter/releases
* **Security: 0.1.0 was affected by upstream advisories fixed in this span.** Among them: GHSA-2464-fhr4-w9xw and GHSA-2xp9-vwfh-vxw4 (remote code execution in the console's image optimiser, without signing in; the optimiser is now off), and the critical fix in upstream 0.37.17 (anyone holding an API key could read any file as root, including the internal key, the secret key, provider keys and the databases). Upstream asks affected operators to **rotate the secret key (HR_SECRET_KEY), the console password, every provider key and every API key**. The secret key here is `/app/data/.secrets/secret-key`; stored connections and MCP secrets are sealed under it. Rotate MCP server tokens too if untrusted agents ran.
* **Rolling back to 0.1.0 is not clean.** The first start on 0.41.16 moves some stored tokens and MCP secrets into new forms that 0.37.13 cannot read. Keep the backup Cloudron takes before the update.
* The first start after the update reinstalls the agent command-line tools once, now each from a pinned version checked against a committed digest or lock (opencode 1.18.23, Codex and Claude Code from upstream's locks). The console does not answer until that finishes: allow several minutes.
* Downloads at first start now run as unprivileged install users, which are behind the same egress firewall as agent sessions.
* Environment build users moved above the session user range (they could overlap with a session's user before) and are firewalled like sessions.
* Since 0.41 the HarnessRouter runner (root) reaches remote MCP servers for agents. Root is now firewalled from Cloudron's internal network too, so an agent still cannot reach another app's internal address, through the runner or directly. An MCP server must be reachable at a public address or through this Cloudron's HTTPS front door.
* Files under `/app` belong to root and are read-only (upstream's GHSA-mm72-wr37-26pv). The data volume follows upstream's new ownership model.
* The image carries the console's third-party licence texts at `/app/THIRD-PARTY-console.txt`; the LGPL image library is no longer included.
* The package's listing now says it is unofficial and not supported by the HarnessRouter project.

[0.1.0]
* First package of HarnessRouter Community Edition 0.37.13, rebuilt from upstream source on `cloudron/base` 6.0.1.
* Broker mode is forced: agents never hold a real provider key.
* Each agent session runs as its own user behind an IPv4 and IPv6 egress firewall; the app refuses to start if the firewall cannot be installed.
* The console password is generated on first start; the published default is refused.
* Agent session workspaces are kept outside the backup and rebuilt from each session's checkpoint.
* Default memory limit 4 GiB, measured against ten concurrent agent sessions.
