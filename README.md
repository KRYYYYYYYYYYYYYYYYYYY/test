# Skill setup notes

Installed custom skill:
- `3x-ui-vps` from `olegtsvetkov/3x-ui-vpn-skill` (path: `skills/3x-ui-vps`, ref: `master`).

The skill provides scripted workflows for:
- Fresh 3X-UI deployment on Ubuntu/Debian VPS via Docker Compose.
- Nginx + ACME TLS setup and UFW hardening.
- Keeping panel and subscription listeners on loopback.
- SSH tunnel access to panel.
- Bootstrapping or updating VLESS/XHTTP inbound and adding clients.
- Conservative update routine for OS + containers.
