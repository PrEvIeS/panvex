#!/usr/bin/env bash
# Panvex senko deploy. Run from a Mac dev box; ships to vpn_senko.
#
# Usage:
#   PANVEX_ADMIN_PASS='<pw>' deploy/senko/deploy.sh             # full install
#   PANVEX_SKIP_BUILD=1 deploy/senko/deploy.sh                  # only ship + restart
#   PANVEX_SKIP_BOOTSTRAP=1 deploy/senko/deploy.sh              # skip admin bootstrap
#
# What it does (idempotent):
#   1. Generates .env with PANVEX_ENCRYPTION_KEY if missing
#   2. Builds linux/amd64 images on this Mac (buildx)
#   3. docker save → ssh → docker load on vpn_senko
#   4. Rsyncs compose + config + .env to /root/panvex/
#   5. docker compose up -d on the server
#   6. ufw allow 9443/tcp (no-op if already open)
#   7. bootstrap-admin inside the backend container (skipped if PANVEX_ADMIN_PASS unset)
#   8. Probes https://panvex.azzazelvpn.ru/healthz until 200 OK

set -euo pipefail

SSH_HOST="${SSH_HOST:-vpn_senko}"
REMOTE_DIR="${REMOTE_DIR:-/root/panvex}"
HEALTH_URL="${HEALTH_URL:-https://panvex.azzazelvpn.ru/healthz}"
GRPC_HOST_PORT="${GRPC_HOST_PORT:-9443}"
ADMIN_USER="${PANVEX_ADMIN_USER:-admin}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
info()  { printf "  • %s\n" "$*"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$*"; }
die()   { printf "  \033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }
step()  { printf "\n\033[1m── %s ──\033[0m\n" "$*"; }

# ── 1. .env ─────────────────────────────────────────────────────────────────
step "Local .env"

ENV_FILE="$HERE/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    die "openssl is required to generate PANVEX_ENCRYPTION_KEY"
  fi
  KEY=$(openssl rand -hex 32)
  cat >"$ENV_FILE" <<EOF
PANVEX_ENCRYPTION_KEY=$KEY
EOF
  chmod 0600 "$ENV_FILE"
  ok "Generated $ENV_FILE (chmod 0600)"
else
  ok "Reusing existing $ENV_FILE"
fi

# ── 2. Build (buildx, linux/amd64) ──────────────────────────────────────────
if [[ "${PANVEX_SKIP_BUILD:-0}" != "1" ]]; then
  step "Build (linux/amd64)"
  cd "$REPO_ROOT"

  # buildx output goes straight to the local docker daemon (--load) so we can
  # `docker save` the image afterwards. The default `docker buildx build`
  # builds in a builder image and discards the result; --load is required.
  info "Building panvex-control-plane:senko"
  docker buildx build \
    --platform linux/amd64 \
    --target control-plane \
    --tag panvex-control-plane:senko \
    --load \
    .

  info "Building panvex-web:senko"
  docker buildx build \
    --platform linux/amd64 \
    --target web \
    --tag panvex-web:senko \
    --load \
    .
  ok "Images built"
else
  warn "PANVEX_SKIP_BUILD=1 — using existing local images"
fi

# ── 3. Ship images ──────────────────────────────────────────────────────────
step "Ship images to $SSH_HOST"
info "docker save | ssh | docker load (this is the slow part)"
docker save panvex-control-plane:senko panvex-web:senko \
  | ssh "$SSH_HOST" 'docker load'
ok "Images loaded on $SSH_HOST"

# ── 4. Rsync compose + config + .env ────────────────────────────────────────
step "Sync deploy files to $SSH_HOST:$REMOTE_DIR"
ssh "$SSH_HOST" "mkdir -p $REMOTE_DIR && chmod 0700 $REMOTE_DIR"
rsync -avz --no-perms --omit-dir-times \
  --include='docker-compose.senko.yml' \
  --include='config.toml' \
  --include='.env' \
  --exclude='*' \
  "$HERE/" "$SSH_HOST:$REMOTE_DIR/"
ssh "$SSH_HOST" "chmod 0600 $REMOTE_DIR/.env"
ok "Files synced"

# ── 5. Bring stack up ───────────────────────────────────────────────────────
step "docker compose up -d"
ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml up -d"
ok "Stack started"

# ── 6. UFW ──────────────────────────────────────────────────────────────────
step "Firewall"
if ssh "$SSH_HOST" "ufw status | grep -qE '^${GRPC_HOST_PORT}/tcp.*ALLOW'"; then
  ok "ufw already allows ${GRPC_HOST_PORT}/tcp"
else
  ssh "$SSH_HOST" "ufw allow ${GRPC_HOST_PORT}/tcp"
  ok "ufw allow ${GRPC_HOST_PORT}/tcp"
fi

# ── 7. Bootstrap admin ──────────────────────────────────────────────────────
GENERATED_PASS=""
if [[ "${PANVEX_SKIP_BOOTSTRAP:-0}" != "1" ]]; then
  step "Bootstrap admin '$ADMIN_USER'"

  if [[ -z "${PANVEX_ADMIN_PASS:-}" ]]; then
    # Generate a hex-only password — no shell metacharacters, no quoting traps.
    GENERATED_PASS=$(openssl rand -hex 16)
    PANVEX_ADMIN_PASS="$GENERATED_PASS"
    info "Auto-generated admin password (will be displayed once at the end)"
  fi

  # SQLite locks the file while the backend runs, so stop it for the one-shot
  # bootstrap. `--rm` mounts the same panvex_sqlite_data volume the service
  # uses, so the admin row lands in the right database.
  # `-T` disables TTY allocation (required over non-interactive SSH).
  # Compose auto-loads PANVEX_ENCRYPTION_KEY from /root/panvex/.env.
  ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml stop backend" >/dev/null

  # `docker compose run` replaces CMD but keeps ENTRYPOINT (= ./panvex-
  # control-plane), so we pass only the subcommand + its flags here.
  # Listing the binary again would shift it into argv[1], where flag.Parse
  # would treat it as a non-flag and stop, silently dropping every flag.
  BOOTSTRAP_OUT=$(ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml run --rm -T \
      backend bootstrap-admin \
        -storage-driver sqlite \
        -storage-dsn /var/lib/panvex/panvex.db \
        -username $ADMIN_USER \
        -password $PANVEX_ADMIN_PASS" 2>&1) && BOOTSTRAP_RC=0 || BOOTSTRAP_RC=$?

  if [[ $BOOTSTRAP_RC -eq 0 ]]; then
    ok "Admin '$ADMIN_USER' created"
  else
    warn "Bootstrap exited $BOOTSTRAP_RC — output:"
    echo "$BOOTSTRAP_OUT" | sed 's/^/    /'
    warn "(common cause: account already exists from a previous run — that's fine)"
  fi

  ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml up -d backend" >/dev/null
else
  warn "PANVEX_SKIP_BOOTSTRAP=1 — skipping bootstrap-admin"
fi

# ── 8. Smoke test ───────────────────────────────────────────────────────────
step "Smoke test ($HEALTH_URL)"
# Traefik may take ~30s on first run to issue the cert via letsencrypt.
WAITED=0
TIMEOUT=120
until curl -fsSL --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; do
  if [[ $WAITED -ge $TIMEOUT ]]; then
    warn "Health check did not pass after ${TIMEOUT}s"
    warn "Try: curl -fsSL $HEALTH_URL"
    warn "Logs: ssh $SSH_HOST 'cd $REMOTE_DIR && docker compose logs --tail=50'"
    exit 1
  fi
  sleep 3
  WAITED=$((WAITED + 3))
  printf "\r  • waiting for traefik+cert+backend... %ds/%ds" "$WAITED" "$TIMEOUT"
done
echo
ok "Health check passed"

step "Done"
echo "  Panel: https://panvex.azzazelvpn.ru/"
echo "  gRPC:  144.31.122.180:${GRPC_HOST_PORT} (embedded-CA TLS)"
echo "  Login: $ADMIN_USER"
if [[ -n "$GENERATED_PASS" ]]; then
  echo "  Password: $GENERATED_PASS"
  echo "  ⚠  Save this password — it is only printed once. Change it on first login."
fi
echo "  Logs:  ssh $SSH_HOST 'cd $REMOTE_DIR && docker compose logs -f'"
