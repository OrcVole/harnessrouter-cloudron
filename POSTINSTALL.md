**First sign-in**

The console password is generated on first start. Open the web terminal for this app and run:

    cat /app/data/.secrets/admin-password

Sign in as `harnessrouter` with that password, then change it on the Profile page. A password changed there replaces the generated one from then on, across restarts, and the file above no longer holds your password.

**If you forget a password you set**, open the web terminal, run `mv /app/data/selfhost-auth.json /app/data/selfhost-auth.json.old`, then restart the app: the password in `/app/data/.secrets/admin-password` works again. Until the restart the console does not answer.

**The first start is slow**

Agent command-line tools are downloaded into `/app/data` the first time the app starts. The console does not answer until that finishes, so a first start of several minutes is normal. Later starts are quick.

**What this package cannot prevent**

Agents execute code on this server. Each session runs as its own user behind an egress firewall, and provider keys are held by the HarnessRouter service, not by the agents. Anyone who can sign in can still use the connections you add. If the firewall cannot be installed, the app refuses to start rather than run agents unconfined.

**Settings**

Optional settings go in `/app/data/env`, one `HR_NAME=value` per line; the file is read, never executed, and the settings that carry the security model are ignored. Create it with `umask 077` first (agents can read a file there that is readable by everyone), then restart the app; every start also makes it readable by root only.

**Backups**

Transcripts, secrets, your password and the installed agent tools are in the app's backup. Agent session workspaces are not: each is rebuilt from its session's checkpoint, which is backed up.
