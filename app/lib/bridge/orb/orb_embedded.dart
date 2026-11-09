/// The orb build context the app embeds (spec §5.2, issue #92).
///
/// The app is a built binary — there is no OpenCodeBridge checkout on the
/// host — so the Dockerfile and the boot scripts ride in the binary as these
/// string constants. [OrbBuildContext.materialize] writes them out into the
/// app-owned build-context dir `~/.config/opencodebridge/orb/` at bridge
/// startup: the app's code (the boot scripts, [OrbEmbedded.files] minus
/// [OrbEmbedded.pinnedFiles]) re-written on every startup so an app upgrade
/// always ships the current boot path, the user's pins ([pinnedFiles]) written
/// create-if-missing and never overwritten.
///
/// The repo copies of these files stay the reviewed source at app-build time.
abstract class OrbEmbedded {
  /// The build-context files, keyed by their path relative to the build-
  /// context root. The [OrbImageBuilder] builds from exactly this dir, so
  /// every one of these files is part of the image and of the tag hash.
  static const Map<String, String> files = {
    'Dockerfile': _dockerfile,
    'orb-entrypoint.sh': _entrypoint,
  };

  /// The build-context files that are the **user's**, not the app's: written
  /// create-if-missing and never overwritten (the user's pin edits). Every
  /// file of [files] not listed here is the app's code and is re-written
  /// from the embedded copy at every startup (issue #145).
  static const Set<String> pinnedFiles = {'Dockerfile'};

  /// The shared base image (spec §5.1). One image for all projects: node,
  /// npm, php, flutter, redis, postgres, typesense, mailhog, opencode, git —
  /// every one pinned to an explicit version (the ARGs below; no rolling
  /// `latest`). Updating the base = bump an ARG default + rebuild, which
  /// yields a new `orb:<hash>` tag without touching existing images.
  static const String _dockerfile = r'''
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    PIPED_FAILURES=1

# Pinned toolchain versions (spec §5.1). Every toolchain the orb mechanism
# depends on is an ARG with a default; no rolling latest. opencode is pinned
# to v2.1.4, the version every orb mechanism was verified against (#83).
ARG NODE_VERSION=22.14.0
ARG NPM_VERSION=10.9.2
ARG PHP_VERSION=8.3
ARG FLUTTER_VERSION=3.47.8
ARG REDIS_VERSION=7.4.0
ARG POSTGRES_VERSION=16
ARG TYPESENSE_VERSION=28.0
ARG MAILHOG_VERSION=1.0.1
ARG GIT_VERSION=2.43
ARG OPENCODE_VERSION=2.1.4
ARG GH_VERSION=2.103.3

# --- System packages: build tools + php + git + ssh ------------------------
# build-essential/libc6-dev/make back the redis source build (below); the
# rest are runtime deps of the pinned toolchains. openssh-client backs the
# entrypoint's git-over-ssh and its `ssh-keyscan` host-key fallback (spec §4,
# issue #93) — without it an orb cannot authenticate to an ssh remote.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        libc6-dev \
        make \
        openssh-client \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-common \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        unzip \
        xz-utils; \
    rm -rf /var/lib/apt/lists/*;

# --- node + npm (official tarball, exact version) -------------------------
RUN set -eux; \
    curl -fsSL -o /tmp/node.tar.xz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    rm /tmp/node.tar.xz; \
    npm install -g --no-audit --no-fund "npm@${NPM_VERSION}"; \
    node --version; npm --version;

# --- opencode (v2, npm; the node tarball ships npm <12 so no allow-scripts
# flag is needed — that gate only appears on npm 12) -----------------------
RUN set -eux; \
    npm install -g --no-audit --no-fund "@opencode/cli@${OPENCODE_VERSION}"; \
    opencode --version;

# --- gh (GitHub CLI, official release tarball, exact version; issue #93):
# the container-local credential helper (`gh auth git-credential`) backs the
# orb's git push — spec §4 — so the orb image needs it like it needs git.
RUN set -eux; \
    curl -fsSL -o /tmp/gh.tar.gz \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"; \
    tar -xzf /tmp/gh.tar.gz -C /tmp; \
    install /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh; \
    rm -rf /tmp/gh.tar.gz /tmp/gh_${GH_VERSION}_linux_amd64; \
    gh --version;

# --- flutter (SDK pinned to a git tag) ------------------------------------
ENV FLUTTER_ROOT=/opt/flutter \
    PATH="/opt/flutter/bin:${PATH}"
RUN set -eux; \
    git clone --depth 1 --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter "${FLUTTER_ROOT}"; \
    "${FLUTTER_ROOT}/bin/flutter" --version;

# --- redis (source, pinned to a tag) --------------------------------------
RUN set -eux; \
    git clone --depth 1 --branch "${REDIS_VERSION}" \
        https://github.com/redis/redis /usr/src/redis; \
    make -C /usr/src/redis; \
    make -C /usr/src/redis install; \
    rm -rf /usr/src/redis; \
    redis-server --version;

# --- postgres (official pgdg repo, pinned to a major) ---------------------
RUN set -eux; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
http://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "postgresql-${POSTGRES_VERSION}"; \
    rm -rf /var/lib/apt/lists/*;

# --- typesense (official static binary, exact version) --------------------
# Official release tarball on dl.typesense.org, with the pinned md5
# verified before install: a tampered or wrong-version binary fails the
# build.
RUN set -eux; \
    curl -fsSL -o /tmp/typesense.tar.gz \
        "https://dl.typesense.org/releases/${TYPESENSE_VERSION}/typesense-server-${TYPESENSE_VERSION}-linux-amd64.tar.gz"; \
    tar -xzf /tmp/typesense.tar.gz -C /tmp \
        typesense-server typesense-server.md5.txt; \
    [ "$(cat /tmp/typesense-server.md5.txt)" = "$(md5sum /tmp/typesense-server | cut -d' ' -f1)" ]; \
    install /tmp/typesense-server /usr/local/bin/typesense-server; \
    rm -rf /tmp/typesense.tar.gz /tmp/typesense-server /tmp/typesense-server.md5.txt; \
    typesense-server 2>&1 | grep -q "Typesense ${TYPESENSE_VERSION}";

# --- mailhog (official release binary, exact version) ---------------------
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/mailhog \
        "https://github.com/mailhog/MailHog/releases/download/v${MAILHOG_VERSION}/MailHog_linux_amd64"; \
    chmod +x /usr/local/bin/mailhog; \
    mailhog -version;

# --- Boot scripts (spec §6.6): the entrypoint (clone, installers, local
# services, health gate, serve — issues #93/#94) is part of the build
# context and therefore of the image (edit-the-files model, no app/bridge
# knob).
COPY orb-entrypoint.sh /usr/local/bin/orb-entrypoint
RUN chmod +x /usr/local/bin/orb-entrypoint

# Enforce the pins at build time: if an ARG default no longer matches what the
# installer actually produced, the build fails here rather than shipping a
# silently drifted base image (spec §5.1).
RUN set -eux; \
    git --version | grep -q "git version ${GIT_VERSION}"; \
    node --version | grep -q "v${NODE_VERSION}"; \
    npm --version | grep -q "^${NPM_VERSION}$"; \
    php --version | grep -q "^PHP ${PHP_VERSION}"; \
    "${FLUTTER_ROOT}/bin/flutter" --version | grep -q "${FLUTTER_VERSION}"; \
    redis-server --version | grep -q "v=${REDIS_VERSION}"; \
    pg_config --version | grep -q "PostgreSQL ${POSTGRES_VERSION}"; \
    typesense-server 2>&1 | grep -q "Typesense ${TYPESENSE_VERSION}"; \
    mailhog -version | grep -qi "${MAILHOG_VERSION}"; \
    opencode --version | grep -qi "v${OPENCODE_VERSION}\|${OPENCODE_VERSION}"; \
    gh --version | grep -q "gh version ${GH_VERSION}";

ENTRYPOINT ["/usr/local/bin/orb-entrypoint"]
''';

  /// The container entrypoint (issues #93 + #94, spec §6). Boot prep, in
  /// order:
  ///   1. first start only: clone the project remote into the fresh
  ///      workspace and install the `orb/<id>` post-commit hook (spec §6.1);
  ///   2. every start: the container-local gitconfig (identity + the gh
  ///      credential helper — spec §4), the staged gh credentials when the
  ///      bridge staged them (issue #120), and the SSH known-hosts fallback;
  ///   3. first start only: the installers (spec §6.3) — `npm ci` when the
  ///      lockfile is present else `npm install`, `composer install`,
  ///      `flutter pub get` — triggered by file presence, non-fatal;
  ///   4. every start: the local services (spec §6.4) — postgres, redis,
  ///      typesense, mailhog — started only when the project's `.env*`
  ///      files declare a local host (127.0.0.1/localhost/::1), bound to
  ///      127.0.0.1 in-container on the `.env` port else the conventional
  ///      default, data on the data volume (never the workspace),
  ///      health-checked before start (idempotent), provisioned from the
  ///      `.env`;
  ///   5. every start: the health gate (spec §6.5) — wait for every
  ///      declared service to become healthy (SERVICE_HEALTH_TIMEOUT_SECONDS,
  ///      ~30 s) before serving; a timeout exits non-zero and the bridge
  ///      surfaces the failure with the boot log tail (issue #93);
  ///   6. every start: the shell probe (issue #149, spec §6.8) — the
  ///      agent's code tasks (run the tests, typecheck, build, `git commit`,
  ///      `gh pr create`) need a shell to run a command in. The spawn prompt
  ///      asks for them, so the orb must prove command execution before it
  ///      serves opencode: `/bin/sh -c 'printf ok'` (no auth, no network). A
  ///      missing or broken shell fails the boot and the bridge surfaces it
  ///      as `broken:shell` — never `running`;
  ///   7. serve opencode on the fixed in-container port (spec §2.9).
  /// Each boot stage streams as a `[orb] stage: <word>` line (cloning,
  /// installing, services, health, shell, ready) so the preparing state can
  /// show the stage (spec §9.3/§9.4).
  ///
  /// The env the bridge passes at `docker create` (spec §2.3): `ORB_ID`
  /// (the orb id, which the hook bakes into its push refspec),
  /// `ORB_REPO_URL` (the project's GitHub remote url, spec §4),
  /// `ORB_GIT_NAME`/`ORB_GIT_EMAIL` (the host's git identity, copied verbatim
  /// — ADR-0001, the app never sees the values),
  /// `ORB_BASE_BRANCH` (optional, issue #100 spec §3.3: the seed's branch —
  /// the first-start clone checks that branch out instead of the remote's
  /// default).
  ///
  /// The bridge injects the `.env*` files into the created (not yet started)
  /// container's workspace before `docker start`; the entrypoint reads them
  /// — merged in filename order, later files win, `*.example` skipped — for
  /// the service declarations and the postgres/typesense provisioning. The
  /// first-start clone tolerates the non-empty workspace (git does, once it
  /// owns the `.git` directory).
  ///
  /// Scripts-as-config (spec §6.6): this file lives in the app-owned build
  /// context and is baked into the image — there is no app/bridge knob.
  /// `ORB_WORKSPACE`/`ORB_DATA_DIR`/`ORB_SSH_DIR`/`ORB_STATE_DIR` exist for
  /// tests; their defaults are the container layout.
  static const String _entrypoint = r'''
#!/bin/sh
# Orb container entrypoint (issues #93 + #94).
#
# Boot prep, in order (spec §6.1–§6.5):
#   1. first start only: clone the project remote into the fresh workspace
#      and install the `orb/<id>` post-commit hook (spec §6.1);
#   2. every start: the container-local gitconfig (identity + the gh
#      credential helper — spec §4), the staged gh credentials when the
#      bridge staged them (issue #120), and the SSH known-hosts fallback;
#   3. first start only: the installers (spec §6.3), triggered by file
#      presence, non-fatal (log + continue);
#   4. every start: the local services (spec §6.4) — postgres, redis,
#      typesense, mailhog — started only when the project's `.env*` files
#      declare a local host (127.0.0.1, localhost, ::1), bound to
#      127.0.0.1 inside the container, data on the data volume,
#      health-checked before start, provisioned from the `.env`;
#   5. every start: the health gate (spec §6.5) — wait for every declared
#      service to become healthy (SERVICE_HEALTH_TIMEOUT_SECONDS) before
#      serving; a timeout exits non-zero, the bridge surfaces the failure
#      with the boot log tail (issue #93);
#   6. every start: the shell probe (issue #149, spec §6.8) — the agent's
#      code tasks need a shell to run a command in; the orb proves it can
#      before it serves opencode, else the boot fails (broken:shell).
#
# Scripts-as-config (spec §6.6): this file lives in the app-owned build
# context and is baked into the image — there is no app/bridge knob. The
# ORB_WORKSPACE / ORB_DATA_DIR / ORB_SSH_DIR / ORB_STATE_DIR env exist for
# tests; their defaults are the container layout.
#
# Every boot stage streams as a `[orb] stage: <word>` line so the preparing
# state can show it (spec §9.3/§9.4).
set -eu

# --- Named constants (spec §2.9, §6.5, §6.8) ------------------------------
OPENCODE_PORT=4096
SERVICE_HEALTH_TIMEOUT_SECONDS=30
# The shell the agent's commands run in (spec §6.8): the image's own sh,
# resolved on PATH, so a code task's `printf ok` smoke test proves the same
# execution path the agent will use — no host binary, no dependency beyond
# the base image.
AGENT_SHELL=${ORB_PROBE_SHELL:-sh}

# --- Container paths (defaults = the container layout) --------------------
WORKSPACE=${ORB_WORKSPACE:-/workspace}
DATA=${ORB_DATA_DIR:-/var/lib/orb-data}
SSH_DIR=${ORB_SSH_DIR:-/root/.ssh}
STATE_DIR=${ORB_STATE_DIR:-/root/.local}

log() {
    printf '[orb] %s\n' "$*"
}

# --- 1. First start only: clone + hook (spec §6.1) -------------------------
first_start=0
if [ ! -d "$WORKSPACE/.git" ]; then
    first_start=1
    log "stage: cloning"
    git init "$WORKSPACE"
    git -C "$WORKSPACE" remote add origin "$ORB_REPO_URL"
    git -C "$WORKSPACE" fetch origin
    git -C "$WORKSPACE" remote set-head origin -a
    # -f: the bridge may already have injected `.env*` files into the
    # (non-empty) workspace before the start.
    # The clone's base: the seed's branch when the bridge set
    # ORB_BASE_BRANCH (a seeded orb, spec §3.3 — the branch tip read from
    # the remote), the remote's default branch otherwise.
    if [ -n "${ORB_BASE_BRANCH:-}" ]; then
        git -C "$WORKSPACE" checkout -f "origin/$ORB_BASE_BRANCH"
    else
        git -C "$WORKSPACE" checkout -f "$(git -C "$WORKSPACE" symbolic-ref --short refs/remotes/origin/HEAD)"
    fi
    hook="$WORKSPACE/.git/hooks/post-commit"
    # The push-failed marker (issue #120): a hook push that fails must not
    # leave the orb looking healthy — the branch is the return channel
    # (spec §3). git ignores a post-commit hook's exit code (the commit
    # stands, exit 0 — verified live), so the push failure reaches the
    # committing agent through the hook's OUTPUT (git streams it) and the
    # durable signal is the marker on the state mount: the bridge reads it
    # host-side and surfaces the orb. A successful push removes it. When
    # the bridge staged the gh credentials (the keyring host case, §4),
    # the hook carries their config dir itself.
    marker="$STATE_DIR/push-failed"
    hook_body="if git push origin HEAD:refs/heads/orb/${ORB_ID}; then
    rm -f '$marker'
else
    printf '%s\n' 'git push origin HEAD:refs/heads/orb/${ORB_ID} failed -- the branch is not on the remote' | tee '$marker' >&2
    exit 1
fi"
    printf '%s\n' '#!/bin/sh' > "$hook"
    if [ -f "$STATE_DIR/gh/hosts.yml" ]; then
        printf '%s\n' "export GH_CONFIG_DIR='$STATE_DIR/gh'" >> "$hook"
    fi
    printf '%s\n' "$hook_body" >> "$hook"
    chmod +x "$hook"
fi

# --- 2. Every start: the container-local gitconfig (spec §4) --------------
# Container-local only: the host's gitconfig is never copied in, and the
# values are re-asserted on every start so a restart never carries a stale
# identity. The credential helper is the host's form (gh is installed in
# the image), scoped to the GitHub hosts only.
git config --global user.name "$ORB_GIT_NAME"
git config --global user.email "$ORB_GIT_EMAIL"
git config --global --unset-all credential.https://github.com.helper || true
git config --global --add "credential.https://github.com.helper" '!gh auth git-credential'
git config --global --unset-all credential.https://gist.github.com.helper || true
git config --global --add "credential.https://gist.github.com.helper" '!gh auth git-credential'

# --- The staged gh credentials (issue #120, spec §4) ------------------------
# On a host whose gh keeps its token in the Secret-Service keyring, the
# read-only `~/.config/gh` mount carries no token and every https push/gh
# call in the orb fails. The bridge reads the host token (the bridge CAN
# reach the keyring) and stages a container-local gh config on the state
# mount before every start; pointing GH_CONFIG_DIR at it (exported for the
# whole boot, so opencode — and every shell it spawns: the push hook, the
# agent's `gh pr create` — inherits it) makes the container's gh and the
# credential helper self-sufficient. No staged config: the mount stays the
# surface, gh keeps its default dir.
if [ -f "$STATE_DIR/gh/hosts.yml" ]; then
    export GH_CONFIG_DIR="$STATE_DIR/gh"
fi

# --- SSH fallback (spec §4) ------------------------------------------------
# The mounted `~/.ssh` is read-only, so a `github.com` entry missing there
# cannot be added in place: seed the container-local copy (in the orb state
# mount, so it persists) and point git's ssh at it — only when the mounted
# file lacks github, so entries for other hosts stay usable from the mount.
state_ssh="$STATE_DIR/orb-ssh"
if ! grep -q "github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then
    mkdir -p "$state_ssh"
    if ! grep -q "github.com" "$state_ssh/known_hosts" 2>/dev/null; then
        ssh-keyscan github.com >> "$state_ssh/known_hosts" 2>/dev/null || true
    fi
    export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$state_ssh/known_hosts -o StrictHostKeyChecking=yes"
fi

# --- 3. First start only: the installers (spec §6.3) -----------------------
# Run once, at create — a wake never re-runs them. Triggered purely by file
# presence; a failure is non-fatal (log and continue): a missing dependency
# must not brick the orb, opencode starts anyway and reports what it needs.
if [ "$first_start" -eq 1 ]; then
    log "stage: installing"
    if [ -f "$WORKSPACE/package.json" ]; then
        if [ -f "$WORKSPACE/package-lock.json" ]; then
            (cd "$WORKSPACE" && npm ci) || log "npm ci failed (non-fatal)"
        else
            (cd "$WORKSPACE" && npm install) || log "npm install failed (non-fatal)"
        fi
    fi
    if [ -f "$WORKSPACE/composer.json" ]; then
        (cd "$WORKSPACE" && composer install) || log "composer install failed (non-fatal)"
    fi
    if [ -f "$WORKSPACE/pubspec.yaml" ]; then
        (cd "$WORKSPACE" && flutter pub get) || log "flutter pub get failed (non-fatal)"
    fi
fi

# --- 4. Every start: the local services (spec §6.4) ------------------------
# Declared by the project's `.env*` files (merged in filename order, later
# files win; `*.example` are documentation, never declarations). Only a
# local host is served in-container; a non-local host is logged and ignored.
# Data lives on the data volume, never the workspace. Every service is
# health-checked before start, so a wake of an orb whose data volume
# persists is idempotent.
log "stage: services"

# Print the value of $1 across the merged `.env*` files (later files win).
env_value() {
    ev_val=""
    for ev_f in "$WORKSPACE"/.env*; do
        [ -f "$ev_f" ] || continue
        case "$ev_f" in
            *.example) continue ;;
        esac
        ev_line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" "$ev_f" 2>/dev/null | tail -n 1) || continue
        [ -n "$ev_line" ] || continue
        ev_val=${ev_line#*=}
    done
    ev_val=$(printf '%s' "$ev_val" | sed -e 's/[[:space:]]*$//')
    case "$ev_val" in
        \"*\") ev_val=${ev_val#\"}; ev_val=${ev_val%\"} ;;
        \'*\') ev_val=${ev_val#\'}; ev_val=${ev_val%\'} ;;
    esac
    printf '%s' "$ev_val"
}

is_local_host() {
    case "$1" in
        127.0.0.1 | localhost | ::1) return 0 ;;
        *) return 1 ;;
    esac
}

PG_BIN=$(pg_config --bindir 2>/dev/null) || PG_BIN=/usr/lib/postgresql/16/bin

healthy_postgres() {
    "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$pg_port" -U postgres >/dev/null 2>&1
}

healthy_redis() {
    redis-cli -h 127.0.0.1 -p "$redis_port" ping >/dev/null 2>&1
}

healthy_typesense() {
    curl -fsS "http://127.0.0.1:$ts_port/health" >/dev/null 2>&1
}

healthy_mailhog() {
    curl -fsS "http://127.0.0.1:$mh_port/api/v2/messages" >/dev/null 2>&1
}

declared=""

# --- postgres ---------------------------------------------------------------
pg_host=$(env_value PG_HOST)
[ -n "$pg_host" ] || pg_host=$(env_value PGHOST)
if [ -n "$pg_host" ]; then
    if is_local_host "$pg_host"; then
        pg_port=$(env_value PG_PORT)
        [ -n "$pg_port" ] || pg_port=$(env_value PGPORT)
        [ -n "$pg_port" ] || pg_port=5432
        declared="$declared postgres"
        if healthy_postgres; then
            log "postgres: already healthy"
        else
            log "postgres: starting on 127.0.0.1:$pg_port"
            pg_data="$DATA/postgres"
            pg_sock="$DATA/pg-sock"
            mkdir -p "$pg_data" "$pg_sock"
            chown -R postgres:postgres "$pg_data" "$pg_sock"
            if [ ! -f "$pg_data/PG_VERSION" ]; then
                runuser -u postgres -- "$PG_BIN/initdb" -D "$pg_data" -U postgres
            fi
            # The data volume outlives the processes: a postmaster.pid left by
            # a previous container life names a pid from a dead PID namespace,
            # and the new namespace can reuse that number for an unrelated
            # process — which makes postmaster refuse to start. We only reach
            # this branch when nothing answers on the port, so no live
            # postmaster of ours can exist: the file is stale.
            rm -f "$pg_data/postmaster.pid"
            # The port goes in the -o string (the postmaster's own -p flag):
            # pg_ctl's -p option is the postmaster binary's path, not a port
            # (a numeric -p makes pg_ctl try to exec it). GUCs in that string
            # carry their -- prefix: a bare listen_addresses=... is not a
            # postmaster command-line argument.
            runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$pg_data" \
                -o "--listen_addresses='127.0.0.1' -k $pg_sock -p $pg_port" \
                -l "$pg_data/pg.log" -w start
            # Provision the role + database the `.env` names (idempotent:
            # created only when missing, the password re-asserted).
            pg_user=$(env_value PG_USER)
            pg_db=$(env_value PG_DB_NAME)
            pg_pass=$(env_value PG_PASSWORD)
            if [ -n "$pg_user" ] && [ -n "$pg_db" ]; then
                log "postgres: provisioning role $pg_user / database $pg_db"
                runuser -u postgres -- "$PG_BIN/psql" -h "$pg_sock" -p "$pg_port" \
                    -U postgres -v ON_ERROR_STOP=1 -d postgres <<ORB_PG_PROVISION
SELECT 'CREATE ROLE "$pg_user" LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$pg_user')\gexec
SELECT 'CREATE DATABASE "$pg_db" OWNER "$pg_user"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$pg_db')\gexec
ALTER ROLE "$pg_user" WITH PASSWORD '$pg_pass';
ORB_PG_PROVISION
            fi
        fi
    else
        log "postgres: host $pg_host is not local to the orb — ignored (only 127.0.0.1, localhost and ::1 are served in-container)"
    fi
fi

# --- redis -------------------------------------------------------------------
redis_host=$(env_value REDIS_HOST)
if [ -n "$redis_host" ]; then
    if is_local_host "$redis_host"; then
        redis_port=$(env_value REDIS_PORT)
        [ -n "$redis_port" ] || redis_port=6379
        declared="$declared redis"
        if healthy_redis; then
            log "redis: already healthy"
        else
            log "redis: starting on 127.0.0.1:$redis_port"
            mkdir -p "$DATA/redis"
            redis-server --daemonize yes --bind 127.0.0.1 --port "$redis_port" \
                --dir "$DATA/redis" --pidfile "$DATA/redis/redis.pid" \
                --logfile "$DATA/redis/redis.log"
        fi
    else
        log "redis: host $redis_host is not local to the orb — ignored"
    fi
fi

# --- typesense ---------------------------------------------------------------
ts_host=$(env_value TYPESENSE_HOST)
if [ -n "$ts_host" ]; then
    if is_local_host "$ts_host"; then
        ts_port=$(env_value TYPESENSE_PORT)
        [ -n "$ts_port" ] || ts_port=8108
        declared="$declared typesense"
        if healthy_typesense; then
            log "typesense: already healthy"
        else
            log "typesense: starting on 127.0.0.1:$ts_port"
            # The log directory must already exist: typesense refuses to
            # start without it.
            mkdir -p "$DATA/typesense/log"
            # 28.0 flags: the API service binds via --api-address/--api-port.
            # --bind/--port do not exist in 28.0 and unknown flags are
            # silently ignored — typesense would fall back to 0.0.0.0:8108,
            # ignoring the configured port, and the health gate would never
            # pass.
            ts_args="--data-dir=$DATA/typesense --api-address=127.0.0.1 --api-port=$ts_port --log-dir=$DATA/typesense/log"
            ts_key=$(env_value TYPESENSE_API_KEY)
            if [ -n "$ts_key" ]; then
                ts_args="$ts_args --api-key=$ts_key"
            fi
            nohup typesense-server $ts_args >/dev/null 2>&1 &
        fi
    else
        log "typesense: host $ts_host is not local to the orb — ignored"
    fi
fi

# --- mailhog -----------------------------------------------------------------
mh_host=$(env_value MAILHOG_HOST)
if [ -n "$mh_host" ]; then
    if is_local_host "$mh_host"; then
        mh_port=$(env_value MAILHOG_PORT)
        [ -n "$mh_port" ] || mh_port=8025
        declared="$declared mailhog"
        if healthy_mailhog; then
            log "mailhog: already healthy"
        else
            log "mailhog: starting on 127.0.0.1:$mh_port"
            # 1.0.1 flags: there is no --api/--smtp. UI and API on the same
            # address: MailHog serves both on one listener only when the two
            # bind addresses are equal — on different addresses they fight
            # over the port and the API never comes up.
            nohup mailhog \
                --api-bind-addr "127.0.0.1:$mh_port" \
                --ui-bind-addr "127.0.0.1:$mh_port" \
                --smtp-bind-addr "127.0.0.1:1025" >/dev/null 2>&1 &
        fi
    else
        log "mailhog: host $mh_host is not local to the orb — ignored"
    fi
fi

# --- 5. Every start: the health gate (spec §6.5) ----------------------------
# opencode starts only after every declared service is healthy. A service
# that is not healthy within SERVICE_HEALTH_TIMEOUT_SECONDS fails the boot
# with a non-zero exit: the bridge surfaces the failure with the boot log
# tail (issue #93), so the orb shows broken:boot with the reason.
if [ -n "$declared" ]; then
    log "stage: health"
    log "waiting for $declared (up to ${SERVICE_HEALTH_TIMEOUT_SECONDS}s)"
    deadline=$(( $(date +%s) + SERVICE_HEALTH_TIMEOUT_SECONDS ))
    while :; do
        all_healthy=1
        for svc in $declared; do
            case "$svc" in
                postgres) healthy_postgres ;;
                redis) healthy_redis ;;
                typesense) healthy_typesense ;;
                mailhog) healthy_mailhog ;;
            esac || all_healthy=0
        done
        if [ "$all_healthy" -eq 1 ]; then
            for svc in $declared; do
                log "$svc: healthy"
            done
            break
        fi
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            log "FATAL: $declared not healthy after ${SERVICE_HEALTH_TIMEOUT_SECONDS}s — the boot fails"
            exit 1
        fi
        sleep 1
    done
fi

# --- 6. Every start: the shell probe (issue #149, spec §6.8) ----------------
# The spawn prompt asks the agent to run the tests, typecheck, build them,
# commit (the post-commit hook pushes) and open the PR — all of it through a
# shell. An orb whose agent has no shell must not come up "ready": it would
# answer succeeded on a well-written "I can't" and every code task would die
# on arrival. The probe is the agent's own execution path, checked *before*
# opencode serves: $AGENT_SHELL -c 'printf ok' must exit 0 and print ok — no
# auth, no network. A failure fails the boot (the bridge surfaces it as
# broken:shell with this log tail), never a silently shell-less ready.
log "stage: shell"
# The probe must observe the shell's own failure: `set -e` exits on the
# command substitution's status before the check below runs, so the call is
# guarded by `if` (a non-zero status is the shell-less orb, not a crash).
if shell_out=$("$AGENT_SHELL" -c 'printf ok' 2>&1); then
    shell_status=0
else
    shell_status=$?
fi
if [ "$shell_status" -ne 0 ] || [ "$shell_out" != "ok" ]; then
    log "FATAL: no usable shell — the agent could not run a command"
    log "shell: tried $AGENT_SHELL -c 'printf ok'"
    log "shell: exit $shell_status"
    [ -n "$shell_out" ] && log "shell: output: $shell_out"
    log "shell: an orb whose agent cannot execute is not offered as a workspace (issue #149)"
    # The durable signal, like the push marker (issue #120): a host-side
    # read on the state mount, so the bridge classifies the orb without a
    # `docker logs` on every list. Cleared on a boot that passes the probe.
    printf '%s\n' "no usable shell: $AGENT_SHELL -c 'printf ok' exited $shell_status" \
        > "$STATE_DIR/no-shell"
    exit 1
fi
rm -f "$STATE_DIR/no-shell"
log "shell: usable ($AGENT_SHELL -c 'printf ok')"

# --- 7. Serve opencode (spec §2.9) -------------------------------------------
log "stage: ready"
# 0.0.0.0: the container is only reachable through the docker port mapping,
# which binds to the container's network address, never loopback.
exec opencode serve --hostname 0.0.0.0 --port "$OPENCODE_PORT"
''';
}
