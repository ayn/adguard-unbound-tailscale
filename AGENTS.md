# AGENTS.md

This repository runs a private DNS stack entirely inside Docker:

- AdGuard Home on a macvlan LAN IP
- Unbound on a private Docker bridge
- Tailscale as a sidecar that shares the AdGuard Home network namespace

## Rules

- Do not modify or reinstall host Tailscale.
- Do not modify host Unbound, Pi-hole, router, or DHCP settings.
- Do not publish host ports or use host networking.
- Keep all new services inside Docker Compose as defined by this repository.
- Preserve the `adguardhome` + `tailscale` namespace-sharing design.
- Preserve the private `unbound` bridge-only design.

## Setup Expectations

- Install into `/opt/adguard-stack`.
- Copy `.env.example` to `.env` and set `AGH_IPV4`, `LAN_PARENT_IFACE`,
  `LAN_SUBNET`, `LAN_GATEWAY`, `TS_HOSTNAME`, and `TS_AUTHKEY`.
- Seed AdGuard Home with `conf-template/AdGuardHome.yaml` before first start if
  you want Unbound preconfigured as the upstream resolver.
- Run `./scripts/init-unbound.sh` before `docker compose up -d` so Unbound has
  both `root.hints` and `root.key` in `./unbound/var`.
- Configure Tailscale Serve after the sidecar is logged in:
  `docker exec adguardhome-tailscale tailscale serve --bg --https=443 http://127.0.0.1:80`

## Verification

- `docker compose ps`
- `dig @<AGH_IPV4> google.com`
- `docker exec adguardhome-tailscale tailscale status`
- `docker exec adguardhome-tailscale tailscale serve status`

## Notes

- The Docker host usually cannot reach its own macvlan container IP directly.
- Remove `TS_AUTHKEY` from `.env` after the first successful Tailscale login if
  `tailscale-state/` is persisted.
