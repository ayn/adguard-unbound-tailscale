# Setup Notes

These notes cover the first-run steps that happen after `docker compose up -d`.

## 1. Open the AdGuard Home UI

Use the LAN IP assigned in `.env`:

```text
http://<AGH_IPV4>/
```

If Tailscale Serve is already configured, you can also use the node's MagicDNS
name over HTTPS.

## 2. Complete the AdGuard Home first-run flow

During the initial setup:

- create an admin username
- create an admin password
- confirm the DNS listener is bound to port 53 inside the container
- confirm the web UI listener is bound inside the container

This repository intentionally does not commit the live `conf/` directory or any
AdGuard Home configuration that contains credentials or runtime state.

## 3. Set the upstream resolver

This stack is designed so AdGuard Home forwards to the private Unbound
container on the internal Docker bridge.

Use:

```text
172.30.53.2:53
```

Do not point AdGuard Home at the host's resolver or a host macvlan shim.

## 4. Configure Tailscale Serve

Once the Tailscale sidecar is logged in, expose the AdGuard Home UI over HTTPS:

```sh
docker exec adguardhome-tailscale tailscale serve --bg --https=443 http://127.0.0.1:80
```

Check the status:

```sh
docker exec adguardhome-tailscale tailscale serve status
docker exec adguardhome-tailscale tailscale status
```

## 5. Optionally use this node as a Tailscale DNS server

If you want tailnet clients to use this AdGuard Home instance for DNS:

- find the node's Tailscale IPv4 and IPv6 addresses
- add them under Tailscale DNS global nameservers

MagicDNS is separate from nameserver configuration:

- MagicDNS gives you stable node names
- global nameservers tell clients which DNS servers to use

If you use multiple DNS servers in Tailscale, clients may use different
resolvers for different queries.  Align filtering and policy if you need
consistent results.

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
