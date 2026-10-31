# Changelog

[0.1.0]
* First package of HarnessRouter Community Edition 0.37.13, rebuilt from upstream source on `cloudron/base` 6.0.1.
* Broker mode is forced: agents never hold a real provider key.
* Each agent session runs as its own user behind an IPv4 and IPv6 egress firewall; the app refuses to start if the firewall cannot be installed.
* The console password is generated on first start; the published default is refused.
* Agent session workspaces are kept outside the backup and rebuilt from each session's checkpoint.
* Default memory limit 4 GiB, measured against ten concurrent agent sessions.
