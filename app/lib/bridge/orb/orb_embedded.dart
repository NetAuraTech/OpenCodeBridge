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

# --- System packages: build tools + php + git -----------------------------
# build-essential/libc6-dev/make back the redis source build (below); the
# rest are runtime deps of the pinned toolchains.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        libc6-dev \
        make \
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
    opencode --version | grep -qi "v${OPENCODE_VERSION}\|${OPENCODE_VERSION}";

ENTRYPOINT ["/usr/local/bin/orb-entrypoint"]
''';

  /// The container entrypoint. A placeholder for this ticket: #92 owns the
  /// image pipeline, and the real boot prep (first-start clone/hook/
  /// installers, the local services, the health gate — spec §6) is owned by
  /// #82, which replaces this body in place. Until then it just starts
  /// opencode's server so an orb can come up.
  static const String _entrypoint = r'''
#!/bin/sh
# Orb container entrypoint (placeholder — issue #92).
#
# #92 delivers the base-image pipeline: the Dockerfile, the materialized
# build context, the `orb:<hash>` tag, and the build. The real entrypoint —
# the first-start clone/hook/installers, the local services, and the health
# gate (spec §6) — is owned by #82 and will replace this file in place
# (scripts-as-config, spec §6.6). Until then it just starts opencode's
# server on the fixed in-container port (spec §2.9; opencode's default).
set -eu
exec opencode serve
''';
}
