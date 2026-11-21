---
title: HTTPS and client IPs
order: 4
description: Serving Mythweaver over HTTPS and recording real client IP addresses behind a proxy.
---

Mythweaver records each account's IP addresses for moderation, so the address it sees must be the real client's and impossible to forge. The compose stack's nginx is the front door for this: it hands the app only the address it saw itself and drops any `X-Forwarded-For` header a client sends.

HTTPS also matters for features: Web Push, the service worker and, in most browsers, notification popups only work on a secure origin. See [Web Push](push.md).

## To run locally without TLS

Run `docker compose up -d`. nginx serves the app at http://localhost:4080 without TLS.

> [!NOTE]
> On Docker Desktop the app records no real client IPs, because Docker hides them behind its network gateway.

## To serve HTTPS with the bundled nginx

1. In `.env`, set `MYTHWEAVER_DOMAIN` (the public host name), `MYTHWEAVER_ACME_EMAIL` (your Let's Encrypt contact address) and `COMPOSE_FILE=compose.yml:compose.tls.yml`.
2. Point the domain's DNS at the host.
3. Open ports 80 and 443 to the internet. Let's Encrypt checks the domain over port 80.
4. Run `docker compose up -d`.

nginx gets and renews its Let's Encrypt certificate itself and keeps it in the `nginx-acme` volume, and the app records real client IPs.

> [!NOTE]
> Once `COMPOSE_FILE` or `-f` is used, Docker Compose no longer reads `compose.override.yml` automatically. List it in `COMPOSE_FILE` too if you need it.

## To put another proxy in front of nginx

If TLS ends at another proxy that forwards to nginx (Tailscale Serve, Caddy on the host):

1. Set `MYTHWEAVER_NGINX_TRUSTED_UPSTREAM` to the address that proxy reaches nginx from. On Docker Desktop that is the network gateway, `172.30.250.1/32`; on Linux Docker Engine it is the host's address on the bridge.
2. Keep nginx published on loopback only (the default).

> [!WARNING]
> On Docker Desktop every direct client of a published port also arrives from the gateway address. Trusting it trusts them too, so nginx must stay on loopback or clients could forge their IP.

## To run the app behind a different proxy

If you don't use the compose stack's nginx, set `MYTHWEAVER_TRUSTED_PROXIES` to your proxy's addresses as comma-separated CIDRs, for example `10.0.0.5/32,fd00::/8`. The app believes `X-Forwarded-For` only from those addresses. An empty value trusts no proxy. `mise.toml` defaults it to loopback plus the compose network: `127.0.0.0/8,::1/128,172.30.250.0/24`.

Your proxy must replace, not append to, any `X-Forwarded-For` a client sends, or clients can forge their address.

## The development container

The development container publishes port 4000 on every interface, and its trusted list includes its Docker network (`172.30.251.0/24`), where a LAN client hitting port 4000 directly arrives from. Such a client can set its own `X-Forwarded-For`, so IPs recorded in the development container are not trustworthy. Production traffic goes through nginx.
