#!/usr/bin/env bash
set -e

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

echo "[entrypoint] state dir: $STATE_DIR"
echo "[entrypoint] workspace dir: $WORKSPACE_DIR"

# ── Setup Persistent Storage for Tools ────────────────────────────────────────

echo "[entrypoint] setting up persistent tool storage in /data..."
mkdir -p "$NPM_CONFIG_PREFIX/bin" "$UV_TOOL_DIR/bin" "$UV_CACHE_DIR" "$GOPATH/bin"

# Linuxbrew persistence and symlinking
BREW_PERSIST_DIR="/data/linuxbrew"
if [ ! -d "$BREW_PERSIST_DIR" ]; then
    echo "[entrypoint] Initializing persistent linuxbrew storage..."
    mkdir -p "$BREW_PERSIST_DIR"
    if [ -d "/home/linuxbrew/.linuxbrew" ] && [ ! -L "/home/linuxbrew/.linuxbrew" ]; then
        cp -a /home/linuxbrew/.linuxbrew/* "$BREW_PERSIST_DIR/" || true
        cp -a /home/linuxbrew/.linuxbrew/.[!.]* "$BREW_PERSIST_DIR/" 2>/dev/null || true
    fi
    chown -R linuxbrew:linuxbrew "$BREW_PERSIST_DIR"
fi

if [ ! -L "/home/linuxbrew/.linuxbrew" ]; then
    rm -rf /home/linuxbrew/.linuxbrew
    ln -s "$BREW_PERSIST_DIR" /home/linuxbrew/.linuxbrew
    chown -h linuxbrew:linuxbrew /home/linuxbrew/.linuxbrew
fi

# Ensure tool paths survive login-shell PATH reset (/etc/profile overwrites PATH)
cat << 'EOF' > /etc/profile.d/custom-tools.sh
export NPM_CONFIG_PREFIX="/data/npm-global"
export UV_TOOL_DIR="/data/uv/tools"
export UV_CACHE_DIR="/data/uv/cache"
export GOPATH="/data/go"
export PATH="/data/npm-global/bin:/data/uv/tools/bin:/data/go/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/go/bin:$PATH"
EOF
chmod +x /etc/profile.d/custom-tools.sh

# Create a wrapper for brew to drop root privileges
cat << 'EOF' > "$NPM_CONFIG_PREFIX/bin/brew"
#!/bin/bash
if [ "$(id -u)" = "0" ]; then
    export HOME=/home/linuxbrew
    export USER=linuxbrew
    exec runuser -u linuxbrew -- /home/linuxbrew/.linuxbrew/bin/brew "$@"
else
    exec /home/linuxbrew/.linuxbrew/bin/brew "$@"
fi
EOF
chmod +x "$NPM_CONFIG_PREFIX/bin/brew"

# ── Install extra apt packages (if requested) ────────────────────────────────
if [ -n "${OPENCLAW_DOCKER_APT_PACKAGES:-}" ]; then
  echo "[entrypoint] installing extra packages: $OPENCLAW_DOCKER_APT_PACKAGES"
  apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      $OPENCLAW_DOCKER_APT_PACKAGES \
    && rm -rf /var/lib/apt/lists/*
fi

# ── Require OPENCLAW_GATEWAY_TOKEN ───────────────────────────────────────────
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  echo "[entrypoint] ERROR: OPENCLAW_GATEWAY_TOKEN is required."
  echo "[entrypoint] Generate one with: openssl rand -hex 32"
  exit 1
fi
GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"

mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"
mkdir -p "$STATE_DIR/agents/main/sessions" "$STATE_DIR/credentials"
chmod 700 "$STATE_DIR"

# Export state/workspace dirs so openclaw CLI + configure.js see them
export OPENCLAW_STATE_DIR="$STATE_DIR"
export OPENCLAW_WORKSPACE_DIR="$WORKSPACE_DIR"

# Set HOME so that ~/.openclaw resolves to $STATE_DIR directly.
# This avoids "multiple state directories" warnings from openclaw doctor
# (symlinks are detected as separate paths).
export HOME="${STATE_DIR%/.openclaw}"

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

has_git_changes() {
  local dir="$1"
  ! git -C "$dir" diff --quiet || \
  ! git -C "$dir" diff --cached --quiet || \
  [ -n "$(git -C "$dir" ls-files --others --exclude-standard)" ]
}

GIT_SYNC_ENABLED_RAW="${GIT_SYNC_ENABLED:-}"
GIT_SYNC_REPO_URL="${GIT_SYNC_REPO_URL:-}"
GIT_SYNC_BRANCH="${GIT_SYNC_BRANCH:-}"
GIT_SYNC_INTERVAL_SEC="${GIT_SYNC_INTERVAL_SEC:-300}"
GIT_SYNC_PUSH_ENABLED_RAW="${GIT_SYNC_PUSH_ENABLED:-true}"
GIT_SYNC_STATE_ENABLED_RAW="${GIT_SYNC_STATE_ENABLED:-false}"
GIT_SYNC_WORKSPACE_ENABLED_RAW="${GIT_SYNC_WORKSPACE_ENABLED:-true}"
GIT_SYNC_COMMIT_MESSAGE="${GIT_SYNC_COMMIT_MESSAGE:-chore(sync): periodic container sync}"
GIT_SYNC_AUTHOR_NAME="${GIT_SYNC_AUTHOR_NAME:-Openclaw Sync Bot}"
GIT_SYNC_AUTHOR_EMAIL="${GIT_SYNC_AUTHOR_EMAIL:-openclaw-sync@local}"
GIT_SYNC_GITHUB_TOKEN="${GIT_SYNC_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"

GIT_SYNC_ENABLED=false
GIT_SYNC_PUSH_ENABLED=false
GIT_SYNC_STATE_ENABLED=false
GIT_SYNC_WORKSPACE_ENABLED=false

if is_true "$GIT_SYNC_ENABLED_RAW"; then
  GIT_SYNC_ENABLED=true
fi
if is_true "$GIT_SYNC_PUSH_ENABLED_RAW"; then
  GIT_SYNC_PUSH_ENABLED=true
fi
if is_true "$GIT_SYNC_STATE_ENABLED_RAW"; then
  GIT_SYNC_STATE_ENABLED=true
fi
if is_true "$GIT_SYNC_WORKSPACE_ENABLED_RAW"; then
  GIT_SYNC_WORKSPACE_ENABLED=true
fi

if [ "$GIT_SYNC_ENABLED" = true ]; then
  if [ -z "$GIT_SYNC_REPO_URL" ]; then
    echo "[entrypoint] ERROR: GIT_SYNC_ENABLED=true requires GIT_SYNC_REPO_URL"
    exit 1
  fi

  if ! [[ "$GIT_SYNC_INTERVAL_SEC" =~ ^[0-9]+$ ]] || [ "$GIT_SYNC_INTERVAL_SEC" -lt 60 ]; then
    echo "[entrypoint] invalid GIT_SYNC_INTERVAL_SEC ($GIT_SYNC_INTERVAL_SEC), using 300"
    GIT_SYNC_INTERVAL_SEC=300
  fi

  echo "[entrypoint] git sync enabled"
  echo "[entrypoint] git sync repo: $GIT_SYNC_REPO_URL"
  echo "[entrypoint] git sync interval: ${GIT_SYNC_INTERVAL_SEC}s"
  if [ "$GIT_SYNC_PUSH_ENABLED" = true ]; then
    echo "[entrypoint] git sync push: enabled"
  else
    echo "[entrypoint] git sync push: disabled"
  fi
fi

git_sync_cmd() {
  local dir="$1"
  shift

  if [ -n "$GIT_SYNC_GITHUB_TOKEN" ] && [[ "$GIT_SYNC_REPO_URL" == *"github.com"* ]]; then
    git -C "$dir" -c credential.helper= -c "http.https://github.com/.extraheader=AUTHORIZATION: bearer ${GIT_SYNC_GITHUB_TOKEN}" "$@"
  else
    git -C "$dir" -c credential.helper= "$@"
  fi
}

git_sync_cmd_logged() {
  local dir="$1"
  local context="$2"
  shift 2

  local output
  if ! output="$(git_sync_cmd "$dir" "$@" 2>&1)"; then
    echo "[entrypoint] git sync: ${context} failed: git $*"
    if [ -n "$output" ]; then
      while IFS= read -r line; do
        echo "[entrypoint] git sync:   $line"
      done <<< "$output"
    fi
    return 1
  fi

  return 0
}

git_sync_commit_if_needed() {
  local dir="$1"
  local label="$2"

  if has_git_changes "$dir"; then
    git -C "$dir" add -A
    if ! git -C "$dir" diff --cached --quiet; then
      git -C "$dir" \
        -c user.name="$GIT_SYNC_AUTHOR_NAME" \
        -c user.email="$GIT_SYNC_AUTHOR_EMAIL" \
        commit -m "$GIT_SYNC_COMMIT_MESSAGE ($label)" >/dev/null 2>&1 || true
    fi
  fi
}

git_sync_target() {
  local label="$1"
  local dir="$2"
  local branch="$GIT_SYNC_BRANCH"

  mkdir -p "$dir"

  if [ ! -d "$dir/.git" ]; then
    git -C "$dir" init >/dev/null 2>&1
  fi

  if ! git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$dir" checkout -B "${branch:-main}" >/dev/null 2>&1 || true
    git_sync_commit_if_needed "$dir" "$label bootstrap"
  fi

  local origin_url
  origin_url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  if [ -z "$origin_url" ]; then
    git -C "$dir" remote add origin "$GIT_SYNC_REPO_URL"
  elif [ "$origin_url" != "$GIT_SYNC_REPO_URL" ]; then
    git -C "$dir" remote set-url origin "$GIT_SYNC_REPO_URL"
  fi

  if [ -n "$branch" ]; then
    git_sync_cmd_logged "$dir" "$label fetch origin/$branch" fetch --prune origin "$branch" || \
      git_sync_cmd_logged "$dir" "$label fetch origin" fetch --prune origin || return 1
  else
    git_sync_cmd_logged "$dir" "$label fetch origin" fetch --prune origin || return 1
    branch="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    if [ -z "$branch" ]; then
      branch="main"
    fi
  fi

  if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$dir" checkout "$branch" >/dev/null 2>&1
  elif git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$dir" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1 || true
  else
    git -C "$dir" checkout -B "$branch" >/dev/null 2>&1 || true
  fi

  git_sync_commit_if_needed "$dir" "$label pre-pull"

  if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    if ! git_sync_cmd_logged "$dir" "$label pull origin/$branch" pull --rebase --autostash origin "$branch"; then
      git -C "$dir" rebase --abort >/dev/null 2>&1 || true
      git_sync_cmd_logged "$dir" "$label merge origin/$branch" merge --no-edit --allow-unrelated-histories "origin/$branch" || return 1
    fi
  fi

  git_sync_commit_if_needed "$dir" "$label post-pull"

  if [ "$GIT_SYNC_PUSH_ENABLED" = true ]; then
    if git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
      git_sync_cmd_logged "$dir" "$label push origin/$branch" push origin "$branch" || return 1
    else
      echo "[entrypoint] git sync: $label repository has no commits yet, skipping push"
    fi
  fi

  return 0
}

git_sync_once() {
  local failures=0

  if [ "$GIT_SYNC_STATE_ENABLED" = true ]; then
    if git_sync_target "state" "$STATE_DIR"; then
      echo "[entrypoint] git sync: state directory synced"
    else
      echo "[entrypoint] git sync: state directory sync failed"
      failures=$((failures + 1))
    fi
  fi

  if [ "$GIT_SYNC_WORKSPACE_ENABLED" = true ]; then
    if git_sync_target "workspace" "$WORKSPACE_DIR"; then
      echo "[entrypoint] git sync: workspace directory synced"
    else
      echo "[entrypoint] git sync: workspace directory sync failed"
      failures=$((failures + 1))
    fi
  fi

  return "$failures"
}

git_sync_loop() {
  while true; do
    git_sync_once || true
    sleep "$GIT_SYNC_INTERVAL_SEC"
  done
}

# ── Run custom init script (if provided) ─────────────────────────────────────
INIT_SCRIPT="${OPENCLAW_DOCKER_INIT_SCRIPT:-}"
if [ -n "$INIT_SCRIPT" ]; then
  if [ ! -f "$INIT_SCRIPT" ]; then
    echo "[entrypoint] WARNING: init script not found: $INIT_SCRIPT"
  else
    # Auto-make executable — volume mounts often lose +x
    chmod +x "$INIT_SCRIPT" 2>/dev/null || true
    echo "[entrypoint] running init script: $INIT_SCRIPT"
    "$INIT_SCRIPT" || echo "[entrypoint] WARNING: init script exited with code $?"
  fi
fi

# ── Configure openclaw from env vars ─────────────────────────────────────────
echo "[entrypoint] running configure..."
node /app/scripts/configure.js
chmod 600 "$STATE_DIR/openclaw.json"

# ── Auto-fix doctor suggestions (e.g. enable configured channels) ─────────
echo "[entrypoint] running openclaw doctor --fix..."
cd /opt/openclaw/app
openclaw doctor --fix 2>&1 || true

# ── Read hooks path from generated config (if hooks enabled) ─────────────────
HOOKS_PATH=""
HOOKS_PATH=$(node -e "
  try {
    const c = JSON.parse(require('fs').readFileSync('$STATE_DIR/openclaw.json','utf8'));
    if (c.hooks && c.hooks.enabled) process.stdout.write(c.hooks.path || '/hooks');
  } catch {}
" 2>/dev/null || true)
if [ -n "$HOOKS_PATH" ]; then
  echo "[entrypoint] hooks enabled, path: $HOOKS_PATH (will bypass HTTP auth)"
fi

# ── Generate nginx config ────────────────────────────────────────────────────
AUTH_PASSWORD="${AUTH_PASSWORD:-}"
AUTH_USERNAME="${AUTH_USERNAME:-admin}"
NGINX_CONF="/etc/nginx/conf.d/openclaw.conf"

AUTH_BLOCK=""
if [ -n "$AUTH_PASSWORD" ]; then
  echo "[entrypoint] setting up nginx basic auth (user: $AUTH_USERNAME)"
  htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USERNAME" "$AUTH_PASSWORD" 2>/dev/null
  AUTH_BLOCK='auth_basic "Openclaw";
        auth_basic_user_file /etc/nginx/.htpasswd;'
else
  echo "[entrypoint] no AUTH_PASSWORD set, nginx will not require authentication"
fi

# Build hooks location block (skips HTTP basic auth, openclaw validates hook token)
HOOKS_LOCATION_BLOCK=""
if [ -n "$HOOKS_PATH" ]; then
  HOOKS_LOCATION_BLOCK="location ${HOOKS_PATH} {
        proxy_pass http://127.0.0.1:${GATEWAY_PORT};
        proxy_set_header Authorization \\\$http_authorization;

        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;

        proxy_http_version 1.1;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        error_page 502 503 504 /starting.html;
    }"
fi

# ── Write startup page for 502/503/504 while gateway boots ───────────────────
mkdir -p /usr/share/nginx/html
cat > /usr/share/nginx/html/starting.html <<'STARTPAGE'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Openclaw - Starting</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; background: #0a0a0a; color: #e5e5e5; display: flex; align-items: center; justify-content: center; min-height: 100vh; }
    .card { text-align: center; max-width: 480px; padding: 2.5rem; }
    h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 1rem; }
    p { color: #a3a3a3; line-height: 1.6; margin-bottom: 1.5rem; }
    .spinner { width: 32px; height: 32px; border: 3px solid #333; border-top-color: #e5e5e5; border-radius: 50%; animation: spin 0.8s linear infinite; margin: 0 auto 1.5rem; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .retry { color: #737373; font-size: 0.85rem; }
  </style>
</head>
<body>
  <div class="card">
    <div class="spinner"></div>
    <h1>Openclaw is starting up</h1>
    <p>The gateway is initializing.</p>
    <p>This usually takes a few minutes.</p>
    <p class="retry">This page will auto-refresh.</p>
  </div>
  <script>setTimeout(function(){ location.reload(); }, 3000);</script>
</body>
</html>
STARTPAGE

cat > "$NGINX_CONF" <<NGINXEOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

map \$arg_token \$ocw_has_token {
    ''      0;
    default 1;
}

map "\$ocw_has_token:\$args" \$ocw_proxy_args {
    ~^1:    \$args;
    ~^0:.+  "\$args&token=${GATEWAY_TOKEN}";
    default "token=${GATEWAY_TOKEN}";
}

server {
    listen ${PORT:-8080} default_server;
    server_name _;
    absolute_redirect off;

    location = /healthz {
        access_log off;
        proxy_pass http://127.0.0.1:${GATEWAY_PORT}/;
        proxy_set_header Host \$host;
        proxy_connect_timeout 2s;
        error_page 502 503 504 = @healthz_fallback;
    }

    location @healthz_fallback {
        return 200 '{"ok":true,"gateway":"starting"}';
        default_type application/json;
    }

    ${HOOKS_LOCATION_BLOCK}

    location / {
        ${AUTH_BLOCK}

        proxy_pass http://127.0.0.1:${GATEWAY_PORT}\$uri?\$ocw_proxy_args;
        proxy_set_header Authorization "Bearer ${GATEWAY_TOKEN}";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        error_page 502 503 504 /starting.html;
    }

    location = /starting.html {
        root /usr/share/nginx/html;
        internal;
    }

    # Browser sidecar proxy (VNC web UI)
    location /browser/ {
        ${AUTH_BLOCK}

        proxy_pass http://browser:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINXEOF

# ── Start nginx ──────────────────────────────────────────────────────────────
echo "[entrypoint] starting nginx on port ${PORT:-8080}..."
nginx

# ── Clean up stale lock files ────────────────────────────────────────────────
rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$STATE_DIR/gateway.lock" 2>/dev/null || true

# ── Start openclaw gateway ───────────────────────────────────────────────────
echo "[entrypoint] starting openclaw gateway on port $GATEWAY_PORT..."

# cwd must be the app root so the gateway finds dist/control-ui/ assets
# "gateway run" = foreground mode; all config comes from openclaw.json
cd /opt/openclaw/app

SYNC_PID=""
GATEWAY_PID=""

cleanup_children() {
  if [ -n "$SYNC_PID" ] && kill -0 "$SYNC_PID" 2>/dev/null; then
    kill "$SYNC_PID" 2>/dev/null || true
    wait "$SYNC_PID" 2>/dev/null || true
  fi

  if [ -n "$GATEWAY_PID" ] && kill -0 "$GATEWAY_PID" 2>/dev/null; then
    kill "$GATEWAY_PID" 2>/dev/null || true
    wait "$GATEWAY_PID" 2>/dev/null || true
  fi
}

trap cleanup_children TERM INT

if [ "$GIT_SYNC_ENABLED" = true ]; then
  echo "[entrypoint] running initial git sync..."
  git_sync_once || true
  echo "[entrypoint] starting git sync loop..."
  git_sync_loop &
  SYNC_PID=$!
fi

openclaw gateway run &
GATEWAY_PID=$!
wait "$GATEWAY_PID"
GATEWAY_EXIT_CODE=$?

cleanup_children
exit "$GATEWAY_EXIT_CODE"
