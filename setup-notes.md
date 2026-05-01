# Setup Notes

These notes cover the first-run steps that happen after `docker compose up -d`.

This stack is intended to run on rootful Docker.  If Docker is root-owned on
the host, use `sudo docker ...` for the Docker and Compose commands below.
Rootless Docker is not recommended for this stack because it relies on macvlan,
`/dev/net/tun`, `NET_ADMIN`, low-numbered DNS ports, and Docker network
namespace sharing.

## 1. Open the AdGuard Home UI

Use the LAN IP assigned in `.env`:

```text
http://<AGH_IPV4>/
```

After Caddy is running and the split-horizon rewrite resolves on the tailnet,
use the custom hostname over HTTPS:

```text
https://${DOMAIN}/
```

## 2. Decide whether to use the optional seed template

If you want AdGuard Home to start with Unbound already configured as the
upstream, copy the template before starting the stack:

```sh
mkdir -p conf work tailscale-state unbound/var
cp conf-template/AdGuardHome.yaml conf/AdGuardHome.yaml
```

If you skip this step, AdGuard Home will generate its own initial config and
you can set the upstream manually later.

## 3. Complete the AdGuard Home first-run flow

During the initial setup:

- create an admin username
- create an admin password
- confirm the DNS listener is bound to port 53 inside the container
- confirm the web UI listener is bound inside the container

This repository intentionally does not commit the live `conf/` directory or any
AdGuard Home configuration that contains credentials or runtime state.

If you use the template, the upstream is already preconfigured but web UI
authentication starts disabled.  Set admin credentials immediately after first
login.

## 4. Set the upstream resolver

This stack is designed so AdGuard Home forwards to the private Unbound
container on the internal Docker bridge.

Use:

```text
172.30.53.2:53
```

Do not point AdGuard Home at the host's resolver or a host macvlan shim.

## 5. Configure Caddy for Tailnet HTTPS

Set `DOMAIN` and `CF_API_TOKEN` in `.env`, then build and start the stack:

```sh
docker compose up -d --build
```

If this node previously used Tailscale Serve, reset the persisted Serve config
once after the sidecar is logged in:

```sh
docker exec adguardhome-tailscale tailscale serve reset
```

Do not configure `TS_SERVE_CONFIG` or run `tailscale serve` for this stack.
Tailscale Serve terminates TLS with a `*.ts.net` certificate before Caddy can
present the custom domain certificate.

Check the status and Caddy issuance logs:

```sh
docker exec adguardhome-tailscale tailscale status
docker compose logs caddy | grep -i certificate
```

## 6. Reserve the LAN IP if the deployment becomes permanent

This stack is easiest to operate when the AdGuard Home LAN address is stable.
If your router supports reservations based on the container MAC address, pin it
there once the deployment is established.

## 7. Keep local state out of Git

Do not commit:

- `.env`
- `conf/`
- `work/`
- `tailscale-state/`
- `unbound/var/`
