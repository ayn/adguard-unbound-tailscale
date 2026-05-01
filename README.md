# AdGuard + Unbound + Tailscale

A practical Docker Compose stack for running:

- AdGuard Home on its own LAN IP with Docker macvlan
- Unbound as a private recursive resolver on an internal Docker bridge
- Caddy as a tailnet-only TLS terminator with a real Let's Encrypt certificate
- Tailscale as a sidecar that shares AdGuard Home's network namespace

This layout avoids host port conflicts, so it can coexist with a DNS service
already running on the host, including Pi-hole.

This stack is intended to run on rootful Docker.  It depends on macvlan
networking, low-numbered DNS ports, `/dev/net/tun`, `NET_ADMIN`, and Docker
network namespace sharing, which are a poor fit for rootless Docker.  If your
host requires privileged Docker access, run the Compose and Docker commands
below with `sudo`.

## What This Stack Does

- Gives AdGuard Home its own LAN address for DNS on port 53
- Keeps Unbound private to Docker and unavailable on the host or LAN
- Exposes the same AdGuard Home DNS service to tailnet clients over Tailscale
- Exposes the AdGuard Home UI to tailnet clients through Caddy over HTTPS
- Uses Cloudflare DNS-01 validation, so no public A/AAAA record is required
- Persists AdGuard Home, Unbound, Caddy, and Tailscale state locally

## Architecture

```text
LAN Client -> AdGuard Home -> Unbound -> Root / Authoritative DNS
Tailnet Client -> https://${DOMAIN}/ -> Tailscale sidecar -> Caddy -> AdGuard Home UI
```

```text
LAN Client -> AdGuard Home macvlan LAN IP -> private Docker bridge -> Unbound

Tailnet Client -> Tailscale sidecar
                  shares AdGuard Home network namespace
                  :53 -> AdGuard Home DNS
                  :443 -> Caddy -> 127.0.0.1:80 -> AdGuard Home UI
```

## Features

- LAN DNS via macvlan
- Recursive DNS via Unbound
- Tailnet DNS via Tailscale sidecar
- Tailnet-only HTTPS UI via Caddy and Tailscale
- Let's Encrypt certificates via Cloudflare DNS-01
- No port conflicts with Pi-hole on the host

## Repository Layout

```text
AGENTS.md
docker-compose.yml
Dockerfile.caddy
Caddyfile
.env.example
README.md
conf-template/
scripts/
unbound/custom.conf.d/
```

Live runtime directories such as `conf/`, `work/`, `tailscale-state/`, and
`unbound/var/` are intentionally excluded from Git.

## Setup

1. Copy the environment template:

   ```sh
   cp .env.example .env
   ```

2. Edit `.env`:

   - choose an unused LAN IP for `AGH_IPV4`
   - set `LAN_PARENT_IFACE`, `LAN_SUBNET`, and `LAN_GATEWAY`
   - set `TS_HOSTNAME`
   - set `TS_AUTHKEY` for the first login
   - set `DOMAIN` to this Pi's hostname, for example
     `adguardhome-primary.example.com` or
     `adguardhome-secondary.example.com`
   - set `CF_API_TOKEN` to a Cloudflare token scoped to DNS edits for
     the parent DNS zone

3. Seed Unbound runtime state before first start:

   ```sh
   ./scripts/init-unbound.sh
   ```

   This fetches the current root hints file and generates the DNSSEC trust
   anchor in `./unbound/var/`, which the bundled Unbound container needs for a
   clean first boot.

4. Optionally seed AGH with the provided template so Unbound is preconfigured:

   ```sh
   mkdir -p conf work tailscale-state unbound/var
   cp conf-template/AdGuardHome.yaml conf/AdGuardHome.yaml
   ```

   If you skip this step, AdGuard Home will create its own initial config and
   you can set the upstream later through the UI.

5. Start the stack:

   ```sh
   sudo docker compose up -d
   ```

6. Open the AdGuard Home UI on the LAN IP you assigned:

   ```text
   http://<AGH_IPV4>/
   ```

7. Complete the AdGuard Home first-run setup, or if you used the template,
   immediately set admin credentials in the AGH UI before broader use.

8. If this stack previously used Tailscale Serve, reset the persisted Serve
   config once:

   ```sh
   sudo docker exec adguardhome-tailscale tailscale serve reset
   ```

9. Open the UI through the custom tailnet-only hostname:

   ```text
   https://${DOMAIN}/
   ```

10. If you change only `.env`, run `sudo docker compose up -d` to recreate
   affected containers with the new environment.  `sudo docker compose restart`
   reuses the existing container environment.

## Custom Domain via Caddy + Cloudflare DNS-01

This stack serves the AdGuard Home web UI at `https://${DOMAIN}/` for tailnet
clients only.  Caddy obtains a real Let's Encrypt certificate with Cloudflare
DNS-01 validation, so the hostname does not need a public A or AAAA record.

Create a Cloudflare API token with DNS edit permission scoped to the
parent DNS zone, then set it in `.env` as `CF_API_TOKEN`.  The token belongs
only in `.env`; do not commit it or paste it into logs.

Set `DOMAIN` per deployment:

- Primary node: `adguardhome-primary.example.com`
- Secondary node: `adguardhome-secondary.example.com`

The AdGuard split-horizon rewrites for those hostnames are expected to already
exist: one A record and one AAAA record for the hostname pointing to that Pi's
tailnet IPv4 and IPv6.  Do not create public Cloudflare A/AAAA records for
these names.

Start or update the stack with a build so the custom Caddy binary includes the
Cloudflare DNS plugin:

```sh
sudo env DOMAIN=adguardhome-primary.example.com docker compose up -d --build
```

You can also set `DOMAIN` in `.env` and run:

```sh
sudo docker compose up -d --build
```

If Docker build containers cannot resolve external module hosts because this
DNS stack is being rebuilt, build Caddy with host networking and then recreate
the stack without rebuilding:

```sh
sudo docker build --network host -t adguard-stack-caddy -f Dockerfile.caddy .
sudo docker compose up -d --no-build
```

If this node previously used Tailscale Serve, clear the persisted Serve config
once after the sidecar is running:

```sh
sudo docker exec adguardhome-tailscale tailscale serve reset
```

Tailscale Serve must stay disabled for this stack.  It terminates TLS with a
`*.ts.net` certificate and intercepts SNI before Caddy can present the custom
domain certificate.

Verify from a tailnet client:

```sh
curl -I https://${DOMAIN}/
```

On first issuance, Caddy logs should include certificate issuance messages:

```sh
sudo docker compose logs caddy | grep -i certificate
```

On hosts where Docker is root-owned, prefix the Docker commands in this section
with `sudo`, for example:

```sh
sudo docker compose up -d --build
sudo docker exec adguardhome-tailscale tailscale serve reset
```

## Install With AI

If you want Codex or Claude Code to perform the full install for you, give the
agent a prompt that is explicit about the constraints and verification steps.

Example prompt:

```text
Set up this repository as a private DNS stack on a Raspberry Pi running modern
Raspberry Pi OS 64-bit.

Install and run it in /opt/adguard-stack.

Requirements:
- Do not reinstall Docker if it is already installed.
- Use rootful Docker.  Do not migrate this stack to rootless Docker.
- If Docker is root-owned on the host, use `sudo docker ...` for Docker and
  Compose commands.
- Do not modify or reinstall host Tailscale.
- Do not modify host Unbound, Pi-hole, router, DHCP, or other host services.
- Do not use host networking.
- Do not publish or change host ports, especially port 53.
- Keep all new services inside Docker using this repository's compose design.
- Clone https://github.com/ayn/adguard-unbound-tailscale directly into
  /opt/adguard-stack.
- Copy .env.example to .env.
- Detect the primary LAN interface and subnet settings automatically.
- Ask me for AGH_IPV4, TS_HOSTNAME, TS_AUTHKEY, DOMAIN, and CF_API_TOKEN
  before editing .env.
- Run ./scripts/init-unbound.sh before sudo docker compose up -d.
- Seed conf/AdGuardHome.yaml from conf-template/AdGuardHome.yaml before first
  start so AdGuard uses the bundled Unbound container.
- Start the stack with sudo docker compose up -d --build.
- If Tailscale Serve was configured previously, run:
  sudo docker exec adguardhome-tailscale tailscale serve reset

Verification:
- sudo docker compose ps
- dig @<AGH_IPV4> google.com
- sudo docker exec adguardhome-tailscale tailscale status
- curl -I https://${DOMAIN}/ from a tailnet client
- sudo docker compose logs caddy | grep -i certificate

If any step fails:
- stop
- explain the exact error
- propose a fix before continuing
```

## Compose Design

This Compose file expects rootful Docker.  The AdGuard macvlan LAN attachment,
Tailscale TUN device, `NET_ADMIN`, and namespace-sharing sidecar pattern are
intentional parts of the design.

- `adguardhome`
  - joins the macvlan LAN network
  - joins the private Docker bridge used for Unbound
  - publishes no host ports
  - serves DNS on port 53 and its plain web UI on port 80 in the shared
    network namespace

- `unbound`
  - joins only the private Docker bridge
  - publishes no host ports
  - is reachable only from Docker-attached peers

- `caddy`
  - uses `network_mode: service:adguardhome`
  - shares AdGuard Home's network namespace
  - reverse-proxies the AdGuard Home web UI at `127.0.0.1:80`
  - obtains Let's Encrypt certificates through Cloudflare DNS-01
  - listens on HTTPS port 443 only; automatic HTTP redirects are disabled so
    AdGuard Home can keep port 80
  - publishes no host ports

- `tailscale`
  - uses `network_mode: service:adguardhome`
  - shares AdGuard Home's network namespace
  - gives the shared namespace a tailnet identity
  - exposes AdGuard Home DNS on port 53 to tailnet clients
  - exposes Caddy's HTTPS listener on port 443 to tailnet clients
  - does not use Tailscale Serve

## Stable IP Assignment

For a DNS server, clients need a stable address.

With a macvlan container, there are two common approaches:

- set a fixed IP in Compose with `ipv4_address`
- let the LAN assign an address dynamically and then reserve that address in
  the router once the container appears

This repository is set up for the fixed-IP approach because it is predictable
and simple.  If you prefer to manage the address from the router, reserve the
container's MAC there once it appears.  Routers such as UniFi can pin that
address for long-term use.

Whichever approach you use, do not let the address drift for a DNS service.

Example router workflow:

- start the stack and let the container appear on the LAN
- identify the container MAC and current lease in the router
- create a DHCP reservation for that MAC
- update `AGH_IPV4` in `.env` if you want Compose and the router to agree on a
  single fixed address

In UniFi, this is typically done from the client device view by setting a fixed
IP for the observed MAC address.

## Security Notes

- Set AdGuard Home admin credentials during first-run setup
- If you use `conf-template/AdGuardHome.yaml`, the initial web UI starts with no
  users configured.  Set authentication immediately after first login.
- Keep the UI behind Tailscale when possible
- Keep `.env`, service state, and local config out of Git
- Remove `TS_AUTHKEY` from `.env` after the first successful Tailscale login if
  state is persisted
- Keep `CF_API_TOKEN` in `.env` only

## Troubleshooting

### macvlan

- The Docker host usually cannot reach its own macvlan containers directly
- Test the LAN address from another device on the same network
- Make sure `LAN_PARENT_IFACE` matches the physical interface attached to the
  LAN

### IP Assignment

- Confirm `AGH_IPV4` is unused before starting the stack
- Make sure the chosen address does not collide with DHCP clients
- If the router tracks container MAC addresses, reserve the chosen address there

### Tailscale

- Confirm the sidecar has `/dev/net/tun`
- Confirm `TS_AUTHKEY` is valid for the first login
- Run `./scripts/init-unbound.sh` before first boot so Unbound has `root.hints`
  and `root.key`
- If you explicitly restart `adguardhome`, restart Caddy and the sidecar too so
  they rejoin the current shared network namespace:

  ```sh
  sudo docker compose restart adguardhome caddy tailscale
  ```

  If `adguardhome` was already restarted by itself, recover with:

  ```sh
  sudo docker restart adguardhome-caddy
  sudo docker restart adguardhome-tailscale
  ```
- Check:

  ```sh
  sudo docker exec adguardhome-tailscale tailscale status
  sudo docker exec adguardhome-tailscale tailscale serve status
  ```

  `tailscale serve status` should not show an active Serve config for this
  stack.  Reset it with:

  ```sh
  sudo docker exec adguardhome-tailscale tailscale serve reset
  ```

## Operational Commands

Use `sudo docker ...` on hosts where Docker is root-owned.

Start:

```sh
sudo docker compose up -d
```

Status:

```sh
./scripts/status.sh
```

Stop:

```sh
sudo docker compose down
```

Update After Pull:

```sh
git pull
sudo docker build --network host -t adguard-stack-caddy -f Dockerfile.caddy .
sudo docker compose up -d --no-build
sudo docker exec adguardhome-tailscale tailscale serve reset
```

## Syncing Policy Between AdGuard Home Instances

The repository includes two helper scripts for copying configuration from one
AdGuard Home instance to one or more others using the AdGuard Home HTTP API:

- `./scripts/sync-client.sh`
  - syncs a single client policy by exact client name or exact entry in
    `ids[]`
- `./scripts/sync-policy.sh`
  - syncs global blocklist filters, DNS rewrites, global custom filtering
    rules, and global SafeSearch settings

Both scripts use `curl -n`, which means credentials are read from `~/.netrc`.
They do not accept inline passwords and they do not require `PASS=...`
environment variables.

Example `~/.netrc` shape:

```text
machine agh-source.example
  login admin
  password <redacted>
machine agh-dest.example
  login admin
  password <redacted>
```

Adjust the machine names to match the AdGuard Home hostnames you call with
`--src` and `--dst`.

### Sync One Client

Sync one client from a source node to one destination:

```sh
./scripts/sync-client.sh \
  --src https://agh-source.example \
  --dst https://agh-dest.example \
  --client "Example Phone"
```

You can also match by an exact client ID from `ids[]`:

```sh
./scripts/sync-client.sh \
  --src https://agh-source.example \
  --dst https://agh-dest.example \
  --client example-phone
```

Sync the same client to multiple destinations:

```sh
./scripts/sync-client.sh \
  --src https://agh-source.example \
  --dst https://agh-b.example \
  --dst https://agh-c.example \
  --client example-phone
```

The client sync copies policy-related fields such as `ids`, `tags`,
`use_global_settings`, filtering state, safe browsing state, parental control,
SafeSearch, and blocked services.  On update, it preserves unrelated
destination-specific client settings instead of overwriting the whole client
object.

### Sync Global Policy

Sync global blocklist filters, DNS rewrites, custom filtering rules, and
SafeSearch settings:

```sh
./scripts/sync-policy.sh \
  --src https://agh-source.example \
  --dst https://agh-dest.example
```

Sync the same global policy to multiple destinations:

```sh
./scripts/sync-policy.sh \
  --src https://agh-source.example \
  --dst https://agh-b.example \
  --dst https://agh-c.example
```

### Defaults and Overrides

The scripts ship with sanitized placeholder defaults:

- source: `https://agh-source.example`
- destination: `https://agh-dest.example`

Override them with flags or environment variables:

```sh
SRC=https://agh-source.example \
DSTS="https://agh-b.example https://agh-c.example" \
./scripts/sync-policy.sh
```

```sh
SRC=https://agh-source.example \
DST=https://agh-dest.example \
./scripts/sync-client.sh --client example-phone
```

Both scripts continue across multiple destinations and exit nonzero if any
destination sync fails.

`sync-policy.sh` treats the source instance as authoritative for blocklist
filters: it adds missing source filters, updates matching destination filters by
URL, and removes destination-only blocklist filters.  It does not sync allowlist
filters.  It also treats source DNS rewrites as authoritative: it adds missing
source rewrites, updates matching rewrites when the enabled state differs, and
removes destination-only rewrites.

## Never Commit

- `.env`
- `conf/`
- `work/`
- `tailscale-state/`
- `unbound/var/`
- generated logs and local database files
