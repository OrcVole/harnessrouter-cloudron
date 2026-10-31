HarnessRouter is a self-hosted API and console in front of agent command-line tools such as OpenCode, Codex and Claude Code. Your own product or scripts talk to one OpenAI Responses-compatible API; HarnessRouter runs the chosen agent, streams its progress and keeps the transcripts.

<upstream>0.37.13</upstream>

**What this package does**

* Runs the console, the gateway and the runner in one container, with all state under `/app/data`.
* Generates the console password on first start. It never ships the published default.
* Runs every agent session as its own user, behind an egress firewall, and keeps your provider keys out of the agents' reach (broker mode).

**What to know before you install**

* Agents run bash and git on your server. Give them only the connections you are willing to have used by anyone who can sign in.
* Agent command-line tools are downloaded on first start, under their own licences. The first start can take several minutes.
