# AGENTS.md

This repository runs a private DNS stack entirely inside Docker:

- AdGuard Home on a macvlan LAN IP
- Unbound on a private Docker bridge
- Caddy as a TLS terminator sharing AdGuard Home's network namespace
- Tailscale as a sidecar that also shares AdGuard Home's network namespace

## Rules

- Do not modify or reinstall host Tailscale.
- Do not modify host Unbound, Pi-hole, router, or DHCP settings.
- Do not publish host ports or use host networking.
- Keep all new services inside Docker Compose as defined by this repository.
- Use rootful Docker.  Do not migrate this stack to rootless Docker.
- Preserve the `adguardhome` + `caddy` + `tailscale` namespace-sharing design.
- Preserve the private `unbound` bridge-only design.
- Do not configure `TS_SERVE_CONFIG` or `tailscale serve`; Caddy owns tailnet
  HTTPS for the custom domain, while AdGuard Home owns tailnet DNS on port 53.
- Do not enable AdGuard Home's own TLS listener on port 443; Caddy owns that
  port in the shared namespace.

## Setup Expectations

- Install into `/opt/adguard-stack`.
- Expect Docker to be root-owned on the target host; use `sudo docker ...` if
  required by the environment.
- Copy `.env.example` to `.env` and set `AGH_IPV4`, `LAN_PARENT_IFACE`,
  `LAN_SUBNET`, `LAN_GATEWAY`, `DOMAIN`, `CF_API_TOKEN`, `TS_HOSTNAME`, and
  `TS_AUTHKEY`.
- Seed AdGuard Home with `conf-template/AdGuardHome.yaml` before first start if
  you want Unbound preconfigured as the upstream resolver.
- Run `./scripts/init-unbound.sh` before `sudo docker compose up -d` so Unbound has
  both `root.hints` and `root.key` in `./unbound/var`.
- Run `sudo docker compose up -d --build` so the Caddy image includes the
  Cloudflare DNS plugin.
- If Tailscale Serve was configured previously, reset it once after the
  sidecar is logged in:
  `sudo docker exec adguardhome-tailscale tailscale serve reset`

## Verification

- `sudo docker compose ps`
- `dig @<AGH_IPV4> google.com`
- `sudo docker exec adguardhome-tailscale tailscale status`
- `curl -I https://${DOMAIN}/` from a tailnet client
- `sudo docker compose logs caddy | grep -i certificate`

## Notes

- The Docker host usually cannot reach its own macvlan container IP directly.
- Rootful Docker is intentional because this stack uses macvlan, `/dev/net/tun`,
  `NET_ADMIN`, low-numbered DNS ports, and Docker namespace sharing.
- Remove `TS_AUTHKEY` from `.env` after the first successful Tailscale login if
  `tailscale-state/` is persisted.
- Keep `CF_API_TOKEN` in `.env` only.
