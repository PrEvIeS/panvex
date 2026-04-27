# Panvex on vpn_senko

Single-host deployment of the Panvex control-plane behind the existing
traefik stack on `144.31.122.180`. Reachable at
`https://panvex.azzazelvpn.ru/`.

## Topology

```
internet ─► traefik :443  (vpn-setup compose, certresolver=myresolver)
              └─ Host(`panvex.azzazelvpn.ru`) ─► web:80 (nginx)
                                                 ├─ /        SPA static
                                                 └─ /api/    → backend:8080

internet ─► panvex-backend :9443 (gRPC, auto-TLS from embedded CA)
              └─ enrolled agents pin the CA from their bootstrap state
```

Storage is SQLite (the box has ~1.9 GB RAM — Postgres is overkill).

## Files

| Path | Role |
|------|------|
| `docker-compose.senko.yml` | Two services (`backend`, `web`) joining the existing `proxy` network |
| `config.toml` | Control-plane TOML config (`tls.mode = proxy`) |
| `.env.example` | Template for `PANVEX_ENCRYPTION_KEY` — copy to `.env`, do NOT commit |
| `deploy.sh` | One-shot installer: builds images on Mac (linux/amd64), ships to senko, brings the stack up, opens UFW :9443, bootstraps the admin |

## First install (from a Mac dev machine)

```bash
cd deploy/senko
PANVEX_ADMIN_PASS='<pw>' ./deploy.sh
```

The script:
1. Generates `.env` with a fresh `PANVEX_ENCRYPTION_KEY` if none exists locally.
2. Builds `panvex-control-plane:senko` and `panvex-web:senko` for `linux/amd64`.
3. `docker save` → ssh → `docker load` on `vpn_senko`.
4. Rsyncs the compose, config, and `.env` to `/root/panvex/`.
5. `docker compose up -d` on the server.
6. `ufw allow 9443/tcp` (idempotent).
7. Runs `bootstrap-admin` inside the backend container.
8. Probes `https://panvex.azzazelvpn.ru/healthz` until it returns 200.

## Updating

Same script, same flags — `docker save | docker load` is idempotent and
docker compose `up -d` only restarts changed services.

## Manual smoke test

```bash
curl -fsSL https://panvex.azzazelvpn.ru/healthz                 # 200 OK
openssl s_client -connect 144.31.122.180:9443 -alpn h2 </dev/null \
  | head -2                                                     # gRPC TLS handshake
```

## Why these choices

- **traefik `proxy` network** — joining it lets the existing letsencrypt
  resolver auto-issue a cert for `panvex.azzazelvpn.ru` without
  duplicating an acme client.
- **gRPC bypasses traefik** — agents pin the embedded CA, so an upstream
  TLS terminator would break the cert chain.
- **SQLite** — the host has ~250 MB free RAM after the existing
  workloads; Postgres + connection pool would be a memory hog for the
  single-tenant fleet this box runs.
- **stop_grace_period: 45s** — matches `controlPlaneShutdownGraceMin` so
  the audit-event drain finishes before SIGKILL.
