#!/bin/bash
# Preview environment setup for umami (Aviator Verify).
#
# Aviator runs this inside a freshly-booted preview sandbox, AFTER it has fetched
# the repo into /code and checked out the runbook's branch. Our job is to rebuild
# whatever the branch changed and get the Next.js server listening.
#
# Contract:
#   * PREVIEW_URL is injected with the sandbox's public https URL.
#   * Account secrets listed under `secrets:` in the Verify config arrive as
#     environment variables named exactly like the secret key.
#   * The script MUST start the app and then EXIT. If it blocks, the launch times
#     out (PREVIEW_SCRIPT_TIMEOUT_SEC, default 1800s).
#   * A non-zero exit fails the preview and shows the tail of our output, so
#     anything worth debugging has to be printed here.
set -euo pipefail

LOG="/tmp/preview-timing.log"
START=$(date +%s)

t() {
  local now
  now=$(date +%s)
  echo "[$((now - START))s] $1" | tee -a "$LOG"
}

t "Starting umami preview setup"

# The sandbox may run git as a different user than built the image, so git
# refuses to touch /code until it is marked safe. Set in the Dockerfile too;
# repeated here so the script still works if the image is rebuilt without it.
git config --global --add safe.directory /code
cd /code

PORT=3000
APP_LOG=/var/log/app/umami.log
# `next start` renames its own process to "next-server (vX.Y.Z)" once it is up,
# so a pattern that only matched the launch argv would stop matching a healthy
# server. Match both shapes.
NEXT_MATCH='next-server|next/dist/bin/next|node_modules/.bin/next'

mkdir -p /var/log/app

# --- Credentials -------------------------------------------------------------
#
# umami gates everything behind a login. prisma/migrations/01_init seeds one
# admin user; we rewrite its username and password from account secrets so the
# real values live in Aviator, not in this repo, and so the verify skill can
# reference them as {{ secrets.* }}.
#
# Aviator names the injected env var exactly like the secret key. The keys are
# lowercase by convention (the collector lowercases placeholder names), but the
# uppercase spelling is accepted too so a secret created as UMAMI_ADMIN_PASSWORD
# still works.
ADMIN_USER="${umami_admin_username:-${UMAMI_ADMIN_USERNAME:-}}"
ADMIN_PASS="${umami_admin_password:-${UMAMI_ADMIN_PASSWORD:-}}"

if [ -z "$ADMIN_PASS" ] || [ -z "$ADMIN_USER" ]; then
  # Fail rather than fall back to umami's default admin/umami. The verify agent
  # signs in with the secret values; if they are not here it would type
  # credentials that do not exist and report a working app as broken login.
  t "ERROR: admin credentials were not injected."
  t "       Add account secrets 'umami_admin_username' and 'umami_admin_password'"
  t "       (Verify -> Settings -> Secrets), then list both under 'secrets:' in"
  t "       the preview config. Neither is optional."
  exit 1
fi

# --- Runtime environment -----------------------------------------------------
#
# e2b does NOT carry a base image's environment into the sandbox at run time —
# only the template BUILD sees the Dockerfile's ENV lines. Everything the app
# needs has to be exported here.
#
# There is deliberately no PREVIEW_URL wiring below. umami builds no absolute
# URLs from configuration: LINKS_URL and PIXELS_URL default to
# `globalThis.location.origin` (src/lib/constants.ts) and the tracker snippet is
# rendered client-side, so the app is already correct at whatever origin it is
# served from. Inventing a base-URL env var here would be a no-op.
export DATABASE_URL="postgresql://umami:umami@127.0.0.1:5432/umami"
# Tokens are signed with hash(APP_SECRET) (src/lib/crypto.ts). A fixed value is
# fine: every preview is a throwaway sandbox and the token only has to stay
# valid for the life of that sandbox. It matches the Dockerfile's value so a
# reconnect does not invalidate a session.
export APP_SECRET="aviator-preview"
export NODE_ENV=production
export NEXT_TELEMETRY_DISABLED=1
# Both of these call out to umami's own hosted services. DISABLE_UPDATES matters
# most: the update check drives a banner in the main layout, and a sandbox with
# restricted egress would leave it hanging.
export DISABLE_TELEMETRY=1
export DISABLE_UPDATES=1
export PORT="$PORT"
export HOSTNAME=0.0.0.0
# The sandbox has 4 GB, where Node defaults its old-space to roughly 2 GB — not
# always enough for the Next.js rebuild below. Same value the image builds with.
export NODE_OPTIONS="--max-old-space-size=3584"

# --- PostgreSQL --------------------------------------------------------------
#
# The database lives at /var/lib/postgresql, outside /code, so the launch's
# `git clean -fd` never touches it — the schema and the seeded demo analytics
# baked into the image are still here.
PGVER="$(ls /etc/postgresql | sort -V | tail -1)"
mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql

if pg_isready -q -h 127.0.0.1 -p 5432; then
  t "PostgreSQL already running"
else
  # A cluster snapshotted while running leaves a postmaster.pid behind, and
  # pg_ctlcluster refuses to start if it thinks that PID is alive. The image
  # stops the cluster cleanly, so this is belt-and-braces for a manual re-run.
  PIDFILE="/var/lib/postgresql/${PGVER}/main/postmaster.pid"
  if [ -f "$PIDFILE" ] && ! kill -0 "$(head -1 "$PIDFILE")" 2>/dev/null; then
    t "  clearing stale postmaster.pid"
    rm -f "$PIDFILE"
  fi

  t "Starting PostgreSQL ${PGVER}..."
  pg_ctlcluster "$PGVER" main start

  for i in $(seq 1 30); do
    pg_isready -q -h 127.0.0.1 -p 5432 && break
    if [ "$i" -eq 30 ]; then
      t "ERROR: PostgreSQL did not accept connections — last log lines:"
      tail -40 "/var/log/postgresql/postgresql-${PGVER}-main.log" | tee -a "$LOG" || true
      exit 1
    fi
    sleep 1
  done
fi
t "PostgreSQL ready"

psql_umami() { PGPASSWORD=umami psql -h 127.0.0.1 -U umami -d umami "$@"; }

# --- Decide what actually needs rebuilding -----------------------------------
#
# The image baked node_modules, the prisma client, the tracker and recorder
# bundles, the geo database and the whole .next build. The launch cleans with
# `git reset --hard` + `git clean -fd` — no -x — so all of those gitignored
# paths are still here.
#
# /preview-image-sha records the commit that cache was built from. It lives
# outside /code precisely so the clean cannot delete it.
BASE_SHA=""
[ -f /preview-image-sha ] && BASE_SHA=$(cat /preview-image-sha)

CHANGED="__ALL__"
if [ -n "$BASE_SHA" ] && git cat-file -e "$BASE_SHA" 2>/dev/null; then
  CHANGED=$(git diff --name-only "$BASE_SHA" HEAD 2>/dev/null || echo "__ALL__")
  t "  build cache baked at $(echo "$BASE_SHA" | cut -c1-12), branch head is $(git rev-parse --short HEAD)"
else
  t "  no usable baked SHA — rebuilding everything"
fi

# changed <regex> -> true if the baked->HEAD diff touched a matching path, or if
# we have no reference and must assume everything changed.
changed() { [ "$CHANGED" = "__ALL__" ] || echo "$CHANGED" | grep -qE "$1"; }

# Nothing may be holding .next open while we rebuild into it. Normally nothing is
# running — Aviator either reconnects (skipping this script entirely) or cold
# boots a fresh sandbox — but a manual re-run would otherwise serve half-written
# chunks out of a directory being rewritten underneath it.
if pgrep -f "$NEXT_MATCH" >/dev/null 2>&1; then
  t "Stopping previous umami instance..."
  pkill -f "$NEXT_MATCH" || true
  for _ in $(seq 1 10); do
    pgrep -f "$NEXT_MATCH" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f "$NEXT_MATCH" 2>/dev/null || true
fi

# pnpm dependencies: only when the lockfile or the workspace definition moved.
if [ ! -d node_modules ] || changed '^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$'; then
  t "Dependencies changed — running pnpm install"
  pnpm install --frozen-lockfile 2>&1 | tail -20 || { t "ERROR: pnpm install failed"; exit 1; }
else
  t "  dependencies unchanged — reusing baked node_modules"
fi

# Prisma client. Cheap (seconds) and the single most annoying thing to get wrong
# — a branch that adds a column but keeps the baked client fails at request time
# with an opaque error — so it is regenerated unconditionally rather than gated.
t "Generating prisma client..."
pnpm build-db 2>&1 | tail -10 || { t "ERROR: pnpm build-db failed"; exit 1; }

# Migrations. Must run every launch: the branch may add one, and a schema behind
# the code is a broken app, not a slow one.
t "Applying database migrations..."
pnpm exec prisma migrate deploy 2>&1 | tail -20 || { t "ERROR: prisma migrate deploy failed"; exit 1; }

# Tracker and recorder bundles are rollup builds into gitignored paths under
# public/, so the baked ones survive and only their own sources force a rebuild.
if [ ! -f public/script.js ] || changed '^src/tracker/|^rollup\.tracker\.config\.js$'; then
  t "Rebuilding tracker script..."
  pnpm build-tracker 2>&1 | tail -10 || { t "ERROR: pnpm build-tracker failed"; exit 1; }
else
  t "  tracker unchanged — reusing baked public/script.js"
fi

if [ ! -f public/recorder.js ] || changed '^src/recorder/|^rollup\.recorder\.config\.js$'; then
  t "Rebuilding recorder script..."
  pnpm build-recorder 2>&1 | tail -10 || { t "ERROR: pnpm build-recorder failed"; exit 1; }
else
  t "  recorder unchanged — reusing baked public/recorder.js"
fi

# The geo database is a ~60 MB download from an external host and never changes
# with a branch. Only fetch it if the baked copy somehow did not survive.
if [ ! -d geo ] || [ -z "$(ls -A geo 2>/dev/null)" ]; then
  t "Geo database missing — downloading..."
  pnpm build-geo 2>&1 | tail -10 || t "  WARN: build-geo failed — location data will be empty"
else
  t "  geo database present — skipping download"
fi

# The Next.js build. This is the slow half, which is why it is gated — but the
# gate is deliberately wide: anything that can end up in the bundle forces a
# rebuild, and only diffs confined to tests/docs/CI skip it. .next/cache is
# gitignored and survived the clean, so a rebuild here is incremental.
if [ ! -d .next ] || changed '^(src/|public/|prisma/|scripts/|next\.config\.ts|package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|postcss\.config\.js|tsconfig|rollup\.)'; then
  t "App sources changed — running next build (this is the slow one)..."
  if ! pnpm build-app 2>&1 | tail -40; then
    # Fail rather than serve the bundle baked into the image. That bundle was
    # built from the base commit, so starting it would hand the verifier a
    # healthy preview of the WRONG code and could report PASS on a branch that
    # does not even build. A false green is worse than no preview.
    t "ERROR: next build failed. Refusing to serve the bundle baked into the"
    t "       image — that would preview the base commit, not this branch."
    exit 1
  fi
  t "  build ok"
else
  t "  app sources unchanged — reusing baked .next"
fi

# --- Admin credentials -------------------------------------------------------
#
# Rewrite the seeded admin user (prisma/migrations/01_init) to the secret values.
# Passwords are bcrypt with 10 rounds — see src/lib/password.ts, which is what
# the login route verifies against — so the hash is produced with the same
# bcryptjs the app itself depends on.
#
# Both values go through psql's :'var' interpolation, which quotes them safely;
# neither ever appears in a shell-expanded SQL string.
#
# The statement is fed on STDIN, not with -c. psql only applies its own parsing —
# including :'var' substitution — to input it reads as a script; a -c string is
# handed straight to the server, where `:'u'` is a syntax error.
t "Setting admin credentials from account secrets..."
ADMIN_HASH=$(UMAMI_PW="$ADMIN_PASS" node -e \
  'process.stdout.write(require("bcryptjs").hashSync(process.env.UMAMI_PW, 10))')

psql_umami -v ON_ERROR_STOP=1 -q -v u="$ADMIN_USER" -v h="$ADMIN_HASH" <<'SQL' \
  || { t "ERROR: failed to set admin credentials"; exit 1; }
UPDATE "user" SET username = :'u', password = :'h'
 WHERE role = 'admin' AND deleted_at IS NULL;
SQL

ADMIN_COUNT=$(psql_umami -tAc "SELECT count(*) FROM \"user\" WHERE role = 'admin' AND deleted_at IS NULL;")
if [ "$ADMIN_COUNT" -lt 1 ]; then
  t "ERROR: no admin user in the database — sign-in would be impossible."
  exit 1
fi
t "  admin user '$ADMIN_USER' ready"

# --- Demo data ---------------------------------------------------------------
#
# The image seeds two websites ("Demo Blog", "Demo SaaS") with 30 days of
# sessions, events and revenue, because an empty umami renders "no data" on every
# dashboard, chart, funnel and report — close to unverifiable.
#
# This is only a fallback for when the image's seed step failed. It is slow, and
# every preview boots from that image, so it should almost never run.
WEBSITE_COUNT=$(psql_umami -tAc "SELECT count(*) FROM website WHERE deleted_at IS NULL;" 2>/dev/null || echo 0)
if [ "$WEBSITE_COUNT" -lt 1 ]; then
  t "No websites found — seeding demo analytics (slow, one-off)..."
  # Invoked through tsx directly rather than `pnpm seed-data --days 30`, so the
  # flags reach the script instead of being read as pnpm's own.
  pnpm exec tsx scripts/seed-data.ts --days 30 2>&1 | tail -10 \
    || t "  WARN: seed-data failed — dashboards will be empty"
else
  t "  demo data present ($WEBSITE_COUNT website(s))"
fi

# --- Start the server --------------------------------------------------------
#
# `next start` serves the .next build directly. The repo also emits a standalone
# bundle (next.config.ts sets output: 'standalone') and the production Dockerfile
# runs that via `node server.js`, but standalone expects its files copied into a
# separate tree — `next start` reads the build in place, which is what we have.
#
# -H 0.0.0.0 is not optional: the browser reaches this box over the public
# internet, so binding loopback makes the preview unreachable.
t "Starting umami on 0.0.0.0:${PORT}..."
setsid node_modules/.bin/next start -H 0.0.0.0 -p "$PORT" \
  < /dev/null > "$APP_LOG" 2>&1 &
disown

# Do not report success until the port actually answers. Reporting early hands
# the verifier a URL that fails on its first navigation, which reads as a broken
# app rather than a not-yet-started one. /api/heartbeat is umami's own liveness
# endpoint — it is what their docker-compose healthcheck uses.
t "Waiting for umami on port ${PORT}..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/api/heartbeat"; then
    t "umami is up on port ${PORT} (public URL: ${PREVIEW_URL:-unset})"
    break
  fi
  # Fail fast on a crash-on-boot rather than burning the full 60s — but not
  # before the process has had a chance to exist. `setsid ... &` forks a subshell
  # that execs setsid that execs node; until that chain completes, pgrep matches
  # nothing, and checking immediately would report a healthy server as dead on a
  # cold sandbox.
  if [ "$i" -ge 5 ] && ! pgrep -f "$NEXT_MATCH" >/dev/null 2>&1; then
    t "ERROR: umami exited during startup — last log lines:"
    tail -40 "$APP_LOG" | tee -a "$LOG" || true
    exit 1
  fi
  if [ "$i" -eq 60 ]; then
    t "ERROR: umami did not come up on port ${PORT} — last log lines:"
    tail -40 "$APP_LOG" | tee -a "$LOG" || true
    exit 1
  fi
  sleep 1
done

t "Preview environment ready."
