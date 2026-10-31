**First sign-in**

The console password is generated on first start. Open the web terminal for this app and run:

    cat /app/data/.secrets/admin-password

Sign in as `harnessrouter` with that password, then change it on the Profile page. A password changed there replaces the generated one from then on.

**The first start is slow**

Agent command-line tools are downloaded into `/app/data` the first time the app starts. The console does not answer until that finishes, so a first start of several minutes is normal. Later starts are quick.

**What this package cannot prevent**

Agents execute code on this server. Each session runs as its own user behind an egress firewall, and provider keys are held by the HarnessRouter service, not by the agents. Anyone who can sign in can still use the connections you add. If the firewall cannot be installed, agents are refused rather than run unconfined.

**Backups**

Transcripts, secrets and the installed agent tools are all in the app's backup.
