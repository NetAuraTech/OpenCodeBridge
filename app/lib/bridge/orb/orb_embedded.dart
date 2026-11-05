/// The orb build context the app embeds (spec §5.2, issue #92).
///
/// The app is a built binary — there is no OpenCodeBridge checkout on the
/// host — so the Dockerfile and the boot scripts ride in the binary as these
/// string constants. [OrbBuildContext.materialize] writes them out,
/// create-if-missing, into the app-owned build-context dir
/// `~/.config/opencodebridge/orb/` at bridge startup. After materialization
/// the on-disk copy is the single source of truth for image content: an app
/// upgrade never overwrites an existing file, so the pinned versions are
/// under the user's control, never under the running app's.
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
ARG TYPESENSE_VERSION=28.1
ARG MAILHOG_VERSION=1.2.0
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
    git clone --depth 1 --branch "v${FLUTTER_VERSION}" \
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
RUN set -eux; \
    curl -fsSL -o /tmp/typesense.tar.gz \
        "https://download.typesense.org/typesense-typesense-v${TYPESENSE_VERSION}-linux-amd64.tar.gz"; \
    tar -xzf /tmp/typesense.tar.gz -C /usr/local/bin \
        typesense-server typesense-analyzers; \
    rm /tmp/typesense.tar.gz; \
    typesense-server --version;

# --- mailhog (official release binary, exact version) ---------------------
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/mailhog \
        "https://github.com/mailhog/MailHog/releases/download/v${MAILHOG_VERSION}/MailHog_linux_amd64"; \
    chmod +x /usr/local/bin/mailhog; \
    mailhog -version;

# --- Boot scripts (spec §6.6): the entrypoint is part of the build context
# and therefore of the image; the boot-prep ticket (#82) replaces the
# placeholder body in place (edit-the-files model, no app/bridge knob).
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
    redis-server --version | grep -q "version=${REDIS_VERSION}"; \
    pg_config --version | grep -q "PostgreSQL ${POSTGRES_VERSION}"; \
    typesense-server --version | grep -q "${TYPESENSE_VERSION}"; \
    mailhog -version | grep -qi "${MAILHOG_VERSION}"; \
    opencode --version | grep -qi "v${OPENCODE_VERSION}\|${OPENCODE_VERSION}"; \
    gh --version | grep -q "gh version ${GH_VERSION}";

ENTRYPOINT ["/usr/local/bin/orb-entrypoint"]
''';

  /// The container entrypoint (issue #93, spec §6.1–§6.3): the first-start
  /// boot prep (clone the project remote into the fresh workspace, install
  /// the `orb/<id>` post-commit hook, write the container-local gitconfig),
  /// then start opencode's server on the fixed in-container port
  /// (spec §2.9 — opencode's default, 4096). The installers, the local
  /// services, and the health gate are #94's and will extend this file in
  /// place (scripts-as-config, spec §6.6).
  ///
  /// The env the bridge passes at `docker create` (spec §2.3): `ORB_ID`
  /// (the orb id, which the hook bakes into its push refspec),
  /// `ORB_REPO_URL` (the project's GitHub remote url, spec §4),
  /// `ORB_GIT_NAME`/`ORB_GIT_EMAIL` (the host's git identity, copied verbatim
  /// — ADR-0001, the app never sees the values).
  ///
  /// The bridge injects the `.env*` files into the created (not yet started)
  /// container's workspace before `docker start`, so the first-start clone
  /// has to tolerate a non-empty `/workspace` (git does, once it owns the
  /// `.git` directory).
  static const String _entrypoint = r'''
#!/bin/sh
# Orb container entrypoint (issue #93).
#
# Boot prep, in order (spec §6.1–§6.3):
#   1. first start only: clone the project remote into the workspace and
#      install the `orb/<id>` post-commit hook;
#   2. every start: the container-local gitconfig (identity + the gh
#      credential helper — spec §4), and the SSH known-hosts fallback;
#   3. serve opencode on the fixed in-container port (spec §2.9).
# The installers, the local services, and the health gate are #94's: they
# will extend this file in place (scripts-as-config, spec §6.6).
set -eu

# --- 1. First start only: clone + hook -----------------------------------
if [ ! -d /workspace/.git ]; then
    git init /workspace
    git -C /workspace remote add origin "$ORB_REPO_URL"
    git -C /workspace fetch origin
    git -C /workspace remote set-head origin -a
    # -f: the bridge may already have injected `.env*` files into the
    # (non-empty) workspace before the start.
    git -C /workspace checkout -f "$(git -C /workspace symbolic-ref --short refs/remotes/origin/HEAD)"
    hook=/workspace/.git/hooks/post-commit
    printf '%s\n' \
        '#!/bin/sh' \
        "git push origin HEAD:refs/heads/orb/${ORB_ID}" \
        > "$hook"
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

# --- SSH fallback (spec §4) ------------------------------------------------
# The mounted `~/.ssh` is read-only, so a `github.com` entry missing there
# cannot be added in place: seed the container-local copy (in the orb state
# mount, so it persists) and point git's ssh at it — only when the mounted
# file lacks github, so entries for other hosts stay usable from the mount.
state_ssh=/root/.local/orb-ssh
if ! grep -q "github.com" /root/.ssh/known_hosts 2>/dev/null; then
    mkdir -p "$state_ssh"
    if ! grep -q "github.com" "$state_ssh/known_hosts" 2>/dev/null; then
        ssh-keyscan github.com >> "$state_ssh/known_hosts" 2>/dev/null || true
    fi
    export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$state_ssh/known_hosts -o StrictHostKeyChecking=yes"
fi

# --- 3. Serve opencode (spec §2.9) -----------------------------------------
# 0.0.0.0: the container is only reachable through the docker port mapping,
# which binds to the container's network address, never loopback.
exec opencode serve --hostname 0.0.0.0 --port 4096
''';
}
