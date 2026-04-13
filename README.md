# AdGuard + Unbound + Tailscale

A practical Docker Compose stack for running:

- AdGuard Home on its own LAN IP with Docker macvlan
- Unbound as a private recursive resolver on an internal Docker bridge
- Tailscale as a sidecar that shares AdGuard Home's network namespace
- Tailscale Serve for HTTPS access to the AdGuard Home UI
- DNS service over the tailnet from the same AdGuard Home instance

This layout avoids host port conflicts, so it can coexist with a DNS service
already running on the host, including Pi-hole.

## What This Stack Does

- Gives AdGuard Home its own LAN address for DNS on port 53
- Keeps Unbound private to Docker and unavailable on the host or LAN
- Exposes the same AdGuard Home DNS service to tailnet clients over Tailscale
- Exposes the AdGuard Home UI through Tailscale Serve over HTTPS
- Persists AdGuard Home, Unbound, and Tailscale state locally

## Architecture

```text
LAN Client -> AdGuard Home -> Unbound -> Root / Authoritative DNS
Tailnet Client -> AdGuard Home -> Unbound -> Root / Authoritative DNS
```

```text
             +----------------------+
LAN Client ->| AdGuard Home         |-> private Docker bridge -> Unbound
             | macvlan LAN address  |
             +----------+-----------+
                        |
                        +-> Tailscale sidecar -> DNS and HTTPS UI over Tailscale
```

## Features

- LAN DNS via macvlan
- Recursive DNS via Unbound
- Tailnet DNS via Tailscale sidecar
- HTTPS UI via Tailscale Serve
- No port conflicts with Pi-hole on the host

## Repository Layout

```text
docker-compose.yml
.env.example
README.md
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

3. Start the stack:

   ```sh
   docker compose up -d
   ```

4. Open the AdGuard Home UI on the LAN IP you assigned:

   ```text
   http://<AGH_IPV4>/
   ```

5. Complete the AdGuard Home first-run setup and set admin credentials.

6. Configure Tailscale Serve from inside the sidecar:

   ```sh
   docker exec adguardhome-tailscale tailscale serve --bg --https=443 http://127.0.0.1:80
   ```

7. Open the UI through the Tailscale MagicDNS name shown by `tailscale status`.

8. If you want tailnet clients to use this instance for DNS, add the node's
   Tailscale IP addresses under Tailscale DNS settings as global nameservers.

## Compose Design

- `adguardhome`
  - joins the macvlan LAN network
  - joins the private Docker bridge used for Unbound
  - publishes no host ports

- `unbound`
  - joins only the private Docker bridge
  - publishes no host ports
  - is reachable only from Docker-attached peers

- `tailscale`
  - uses `network_mode: service:adguardhome`
  - shares the AdGuard Home network namespace
  - gives the AGH namespace its own tailnet identity
  - exposes DNS on port 53 to tailnet clients
  - exposes the UI through Tailscale Serve without binding host ports

## Using as a Tailscale DNS Server

The Tailscale sidecar is not only for remote UI access.  It also allows the
same AdGuard Home instance to answer DNS queries from tailnet clients.

To use this stack as a Tailscale DNS server:

- add the node's Tailscale IP addresses under Tailscale DNS global nameservers
- keep MagicDNS enabled if you want stable device names on the tailnet

MagicDNS and DNS nameserver settings are separate:

- MagicDNS provides names for Tailscale nodes
- global nameservers tell Tailscale clients which DNS servers to use

If you configure multiple DNS servers in Tailscale, clients may use different
resolvers for different queries.  If you want consistent filtering behavior,
align blocklists, rewrites, and policy across those resolvers.

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

## Security Notes

- Set AdGuard Home admin credentials during first-run setup
- Keep the UI behind Tailscale when possible
- Keep `.env`, service state, and local config out of Git
- Remove `TS_AUTHKEY` from `.env` after the first successful Tailscale login if
  state is persisted

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
- Check:

  ```sh
  docker exec adguardhome-tailscale tailscale status
  docker exec adguardhome-tailscale tailscale serve status
  ```

## Operational Commands

Start:

```sh
docker compose up -d
```

Status:

```sh
./scripts/status.sh
```

Stop:

```sh
docker compose down
```

## Never Commit

- `.env`
- `conf/`
- `work/`
- `tailscale-state/`
- `unbound/var/`
- generated logs and local database files
