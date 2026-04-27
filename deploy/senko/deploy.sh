#!/usr/bin/env bash
# Panvex senko deploy. Run from a Mac dev box; ships to vpn_senko.
#
# Usage:
#   PANVEX_ADMIN_PASS='<pw>' deploy/senko/deploy.sh             # full install
#   PANVEX_SKIP_BUILD=1 deploy/senko/deploy.sh                  # only ship + restart
#   PANVEX_SKIP_BOOTSTRAP=1 deploy/senko/deploy.sh              # skip admin bootstrap
#   PANVEX_SKIP_TELEMT=1 deploy/senko/deploy.sh                 # skip telemt + agent provisioning
#   PANVEX_SKIP_SMOKE_CLIENT=1 deploy/senko/deploy.sh           # skip end-to-end client smoke test
#
# What it does (idempotent):
#   1. Generates .env with PANVEX_ENCRYPTION_KEY if missing
#   2. Builds linux/amd64 images on this Mac (buildx) — control-plane, web, agent
#   3. docker save → ssh → docker load on vpn_senko
#   4. Rsyncs compose + config + .env to /root/panvex/
#   5. docker compose up -d on the server (backend + web + telemt)
#   6. ufw allow 9443/tcp + 2443/tcp (no-op if already open)
#   7. bootstrap-admin inside the backend container (skipped if PANVEX_ADMIN_PASS unset)
#   8. Probes https://panvex.azzazelvpn.ru/healthz until 200 OK
#   9. Configures panel settings (grpc_public_endpoint=144.31.122.180:9443) so
#      enrollment tokens hand agents the right gRPC port instead of the default :8443
#  10. Issues an enrollment token, bootstraps panvex-agent, brings it up
#  11. Waits for the agent to register as online via GET /api/agents
#  12. Smoke-creates a Telemt client and prints its tg:// link

set -euo pipefail

SSH_HOST="${SSH_HOST:-vpn_senko}"
REMOTE_DIR="${REMOTE_DIR:-/root/panvex}"
PANEL_BASE_URL="${PANEL_BASE_URL:-https://panvex.azzazelvpn.ru}"
HEALTH_URL="${HEALTH_URL:-${PANEL_BASE_URL}/healthz}"
PANEL_API_URL="${PANEL_API_URL:-${PANEL_BASE_URL}/api}"
PANEL_PUBLIC_HOST="${PANEL_PUBLIC_HOST:-144.31.122.180}"
GRPC_HOST_PORT="${GRPC_HOST_PORT:-9443}"
TELEMT_HOST_PORT="${TELEMT_HOST_PORT:-2443}"
GRPC_PUBLIC_ENDPOINT="${GRPC_PUBLIC_ENDPOINT:-${PANEL_PUBLIC_HOST}:${GRPC_HOST_PORT}}"
ADMIN_USER="${PANVEX_ADMIN_USER:-admin}"
AGENT_NODE_NAME="${AGENT_NODE_NAME:-vpn-senko}"
SMOKE_CLIENT_NAME="${SMOKE_CLIENT_NAME:-senko-smoke}"

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

  info "Building panvex-agent:senko"
  docker buildx build \
    --platform linux/amd64 \
    --target agent \
    --tag panvex-agent:senko \
    --load \
    .
  ok "Images built"
else
  warn "PANVEX_SKIP_BUILD=1 — using existing local images"
fi

# ── 3. Ship images ──────────────────────────────────────────────────────────
step "Ship images to $SSH_HOST"
info "docker save | ssh | docker load (this is the slow part)"
docker save panvex-control-plane:senko panvex-web:senko panvex-agent:senko \
  | ssh "$SSH_HOST" 'docker load'
ok "Images loaded on $SSH_HOST"

# ── 4. Rsync compose + config + .env ────────────────────────────────────────
step "Sync deploy files to $SSH_HOST:$REMOTE_DIR"
ssh "$SSH_HOST" "mkdir -p $REMOTE_DIR && chmod 0700 $REMOTE_DIR"
rsync -avz --no-perms --omit-dir-times \
  --include='docker-compose.senko.yml' \
  --include='config.toml' \
  --include='telemt-config.toml' \
  --include='.env' \
  --exclude='*' \
  "$HERE/" "$SSH_HOST:$REMOTE_DIR/"
ssh "$SSH_HOST" "chmod 0600 $REMOTE_DIR/.env"
# Seed the telemt config volume. Telemt mutates config.toml as users come
# and go (api/config_store::write_atomic), so we keep its workdir as a
# host bind mount and reset it from the repo copy on every deploy. The
# panvex agent re-syncs user state from the control-plane DB on boot, so
# overwriting is safe.
ssh "$SSH_HOST" "mkdir -p $REMOTE_DIR/telemt-data && cp $REMOTE_DIR/telemt-config.toml $REMOTE_DIR/telemt-data/config.toml && chmod 0644 $REMOTE_DIR/telemt-data/config.toml && chown -R 65532:65532 $REMOTE_DIR/telemt-data"
ok "Files synced"

# ── 5. Bring stack up ───────────────────────────────────────────────────────
step "docker compose up -d"
ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml up -d"
ok "Stack started"

# ── 6. UFW ──────────────────────────────────────────────────────────────────
step "Firewall"
allow_ufw_port() {
  local port="$1"
  if ssh "$SSH_HOST" "ufw status | grep -qE '^${port}/tcp.*ALLOW'"; then
    ok "ufw already allows ${port}/tcp"
  else
    ssh "$SSH_HOST" "ufw allow ${port}/tcp"
    ok "ufw allow ${port}/tcp"
  fi
}
allow_ufw_port "$GRPC_HOST_PORT"
allow_ufw_port "$TELEMT_HOST_PORT"

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

# ── 9. Provision Telemt + agent + smoke client ──────────────────────────────
SMOKE_CLIENT_LINK=""
SMOKE_CLIENT_ID=""
AGENT_ID=""
if [[ "${PANVEX_SKIP_TELEMT:-0}" != "1" ]]; then
  if [[ -z "${PANVEX_ADMIN_PASS:-}" ]]; then
    warn "PANVEX_ADMIN_PASS unset — cannot drive panel API. Skipping Telemt + agent provisioning."
    warn "Re-run with PANVEX_ADMIN_PASS set, or pass PANVEX_SKIP_TELEMT=1 to silence this warning."
  else
    step "Configure panel grpc_public_endpoint"

    # The bootstrap response derives GRPCEndpoint from the request Host
    # header when grpc_public_endpoint is empty (see internal/controlplane/
    # server/http_enrollment.go bootstrapGatewayAddress). Behind traefik
    # the Host is `panvex.azzazelvpn.ru` and the default port is 8443 —
    # neither matches our :9443 host port, so the agent would dial the
    # wrong endpoint. Set the public endpoint explicitly before issuing
    # any enrollment token.
    COOKIE_JAR=$(mktemp -t panvex-cookies.XXXXXX)
    trap 'rm -f "$COOKIE_JAR"' EXIT

    info "Logging in as $ADMIN_USER"
    LOGIN_BODY=$(printf '{"username":"%s","password":"%s"}' "$ADMIN_USER" "$PANVEX_ADMIN_PASS")
    LOGIN_RC=$(curl -fsS -o /dev/null -w '%{http_code}' \
      -c "$COOKIE_JAR" \
      -H "Content-Type: application/json" \
      -H "Origin: $PANEL_BASE_URL" \
      -X POST \
      --data "$LOGIN_BODY" \
      --max-time 10 \
      "${PANEL_API_URL}/auth/login" || echo "000")
    if [[ "$LOGIN_RC" != "200" ]] && [[ "$LOGIN_RC" != "204" ]]; then
      die "Login failed (HTTP $LOGIN_RC) — check PANVEX_ADMIN_PASS"
    fi
    ok "Logged in"

    info "Fetching CSRF token"
    CSRF_RESPONSE=$(curl -fsS -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "Origin: $PANEL_BASE_URL" \
      --max-time 10 \
      "${PANEL_API_URL}/auth/csrf-token") || die "CSRF token fetch failed"
    CSRF_TOKEN=$(printf '%s' "$CSRF_RESPONSE" | sed -n 's/.*"csrf_token":"\([^"]*\)".*/\1/p')
    if [[ -z "$CSRF_TOKEN" ]]; then
      CSRF_TOKEN=$(printf '%s' "$CSRF_RESPONSE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    fi
    if [[ -z "$CSRF_TOKEN" ]]; then
      die "Could not extract CSRF token from: $CSRF_RESPONSE"
    fi
    ok "CSRF token acquired"

    info "Setting grpc_public_endpoint=${GRPC_PUBLIC_ENDPOINT}"
    SETTINGS_BODY=$(printf '{"http_public_url":"%s","grpc_public_endpoint":"%s"}' "$PANEL_BASE_URL" "$GRPC_PUBLIC_ENDPOINT")
    SETTINGS_RC=$(curl -fsS -o /dev/null -w '%{http_code}' \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "Content-Type: application/json" \
      -H "Origin: $PANEL_BASE_URL" \
      -H "X-CSRF-Token: $CSRF_TOKEN" \
      -X PUT \
      --data "$SETTINGS_BODY" \
      --max-time 10 \
      "${PANEL_API_URL}/settings/panel" || echo "000")
    if [[ "$SETTINGS_RC" != "200" ]]; then
      die "Failed to update panel settings (HTTP $SETTINGS_RC)"
    fi
    ok "Panel settings updated"

    step "Start telemt"
    ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml up -d telemt" >/dev/null
    info "Waiting for telemt healthcheck"
    TWAITED=0
    TTIMEOUT=60
    until ssh "$SSH_HOST" "docker inspect -f '{{.State.Health.Status}}' telemt 2>/dev/null | grep -q healthy"; do
      if [[ $TWAITED -ge $TTIMEOUT ]]; then
        warn "telemt did not become healthy after ${TTIMEOUT}s"
        ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml logs --tail=40 telemt" || true
        die "telemt unhealthy"
      fi
      sleep 3
      TWAITED=$((TWAITED + 3))
    done
    ok "telemt healthy"

    step "Bootstrap panvex-agent"

    info "Issuing enrollment token"
    TOKEN_BODY='{"ttl_seconds":3600}'
    TOKEN_RESPONSE=$(curl -fsS \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "Content-Type: application/json" \
      -H "Origin: $PANEL_BASE_URL" \
      -H "X-CSRF-Token: $CSRF_TOKEN" \
      -X POST \
      --data "$TOKEN_BODY" \
      --max-time 10 \
      "${PANEL_API_URL}/agents/enrollment-tokens") || die "Enrollment token issuance failed"
    ENROLLMENT_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
    if [[ -z "$ENROLLMENT_TOKEN" ]]; then
      die "Could not extract enrollment token from response: $TOKEN_RESPONSE"
    fi
    ok "Enrollment token issued"

    info "Removing any stale agent state"
    ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml --profile agent rm -fsv panvex-agent" >/dev/null 2>&1 || true
    ssh "$SSH_HOST" "docker volume rm -f panvex_panvex_agent_state panvex-agent-state 2>/dev/null" >/dev/null 2>&1 || true

    info "Running agent bootstrap subcommand"
    BOOTSTRAP_OUT=$(ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml run --rm -T \
        panvex-agent bootstrap \
          -panel-url '$PANEL_BASE_URL' \
          -enrollment-token '$ENROLLMENT_TOKEN' \
          -state-file /var/lib/panvex-agent/state.json \
          -node-name '$AGENT_NODE_NAME' \
          -version senko \
          -force" 2>&1) || die "Agent bootstrap failed: $BOOTSTRAP_OUT"
    ok "Agent enrolled"

    step "Start panvex-agent"
    ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml --profile agent up -d panvex-agent" >/dev/null
    ok "Agent started"

    info "Waiting for agent to register as online"
    AWAITED=0
    ATIMEOUT=90
    until AGENTS_JSON=$(curl -fsS -b "$COOKIE_JAR" -H "Origin: $PANEL_BASE_URL" --max-time 10 "${PANEL_API_URL}/agents" 2>/dev/null) && \
          printf '%s' "$AGENTS_JSON" | grep -q '"presence_state":"online"'; do
      if [[ $AWAITED -ge $ATIMEOUT ]]; then
        warn "Agent did not report online after ${ATIMEOUT}s"
        ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml logs --tail=80 panvex-agent" || true
        die "Agent offline"
      fi
      sleep 3
      AWAITED=$((AWAITED + 3))
      printf "\r  • waiting for agent... %ds/%ds" "$AWAITED" "$ATIMEOUT"
    done
    echo
    AGENT_ID=$(printf '%s' "$AGENTS_JSON" | sed -n 's/.*"id":"\([^"]*\)"[^}]*"presence_state":"online".*/\1/p' | head -1)
    if [[ -z "$AGENT_ID" ]]; then
      AGENT_ID=$(printf '%s' "$AGENTS_JSON" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
    fi
    ok "Agent online (id=${AGENT_ID:-unknown})"

    if [[ "${PANVEX_SKIP_SMOKE_CLIENT:-0}" != "1" ]] && [[ -n "$AGENT_ID" ]]; then
      step "Smoke-create Telemt client '$SMOKE_CLIENT_NAME'"
      CLIENT_BODY=$(printf '{"name":"%s","enabled":true,"agent_ids":["%s"]}' "$SMOKE_CLIENT_NAME" "$AGENT_ID")
      CLIENT_RESPONSE=$(curl -fsS \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -H "Content-Type: application/json" \
        -H "Origin: $PANEL_BASE_URL" \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        -X POST \
        --data "$CLIENT_BODY" \
        --max-time 15 \
        "${PANEL_API_URL}/clients") || die "Client create failed"
      SMOKE_CLIENT_ID=$(printf '%s' "$CLIENT_RESPONSE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
      ok "Client created (id=${SMOKE_CLIENT_ID})"

      info "Polling for connection_link from agent"
      LWAITED=0
      LTIMEOUT=60
      while [[ $LWAITED -lt $LTIMEOUT ]]; do
        DETAIL=$(curl -fsS -b "$COOKIE_JAR" -H "Origin: $PANEL_BASE_URL" --max-time 10 "${PANEL_API_URL}/clients/${SMOKE_CLIENT_ID}" 2>/dev/null) || true
        SMOKE_CLIENT_LINK=$(printf '%s' "$DETAIL" | sed -n 's/.*"connection_link":"\([^"]*\)".*/\1/p' | head -1)
        if [[ -n "$SMOKE_CLIENT_LINK" ]]; then
          break
        fi
        sleep 3
        LWAITED=$((LWAITED + 3))
        printf "\r  • waiting for tg:// link... %ds/%ds" "$LWAITED" "$LTIMEOUT"
      done
      echo
      if [[ -n "$SMOKE_CLIENT_LINK" ]]; then
        ok "Telegram link issued"
      else
        warn "No connection_link surfaced after ${LTIMEOUT}s — check agent logs"
      fi
    else
      warn "Skipping smoke client (PANVEX_SKIP_SMOKE_CLIENT=1 or no agent id)"
    fi
  fi
else
  warn "PANVEX_SKIP_TELEMT=1 — skipping Telemt + agent provisioning"
fi

step "Done"
echo "  Panel:  ${PANEL_BASE_URL}/"
echo "  gRPC:   ${GRPC_PUBLIC_ENDPOINT} (embedded-CA TLS)"
echo "  Telemt: ${PANEL_PUBLIC_HOST}:${TELEMT_HOST_PORT} (Fake-TLS, SNI=panvex.azzazelvpn.ru)"
echo "  Login:  $ADMIN_USER"
if [[ -n "$GENERATED_PASS" ]]; then
  echo "  Password: $GENERATED_PASS"
  echo "  ⚠  Save this password — it is only printed once. Change it on first login."
fi
if [[ -n "$AGENT_ID" ]]; then
  echo "  Agent:  $AGENT_ID (vpn-senko, online)"
fi
if [[ -n "$SMOKE_CLIENT_ID" ]]; then
  echo "  Client: $SMOKE_CLIENT_ID ($SMOKE_CLIENT_NAME)"
fi
if [[ -n "$SMOKE_CLIENT_LINK" ]]; then
  echo "  Link:   $SMOKE_CLIENT_LINK"
fi
echo "  Logs:   ssh $SSH_HOST 'cd $REMOTE_DIR && docker compose -f docker-compose.senko.yml logs -f'"
