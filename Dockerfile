# syntax=docker/dockerfile:1
#
# JawnOS in a container. The tree is the same one ./jawn runs on a bare machine:
# it keeps its database, config and state on volumes, and the app's own
# non-interactive setup seeds them on first boot (docker/entrypoint.sh).
#
# Build:  docker compose build
# Run:    docker compose up -d

# ---- modules ---------------------------------------------------------------
# President.pl does `use threads`; the non-threaded perl image dies at "This
# Perl not built to support threads", so every stage uses the threaded build.
# Both stages start from the same Perl image, so the site_perl path the builder
# writes is exactly the one the runtime searches. The builder adds the compiler
# and the development headers; the runtime only needs the shared libraries the
# compiled modules link against.
FROM perl:5.40-slim-threaded-bookworm AS modules

ENV DEBIAN_FRONTEND=noninteractive \
    PERL_MM_USE_DEFAULT=1 \
    MAKEFLAGS=-j4

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential pkg-config \
      libssl-dev zlib1g-dev libzstd-dev libsqlite3-dev libexpat1-dev \
 && rm -rf /var/lib/apt/lists/*

# Keep this list in step with scripts/jawnos_deps.pl @modules. Text::Unidecode
# and Email::Sender are loaded by the domain layer but are not in that list.
# The four pinned modules are the set this house runs; unpinned, cpanm pulled
# Mojolicious 9.53 + Mojo::SQLite 4 + Minion 12 and logged encode_json prototype
# warnings. Minion::Backend::SQLite 6 requires that newer trio, so it is pinned
# to 5.0.0 with them.
RUN cpanm --notest --force \
      Mojolicious@9.39 \
      Mojo::SQLite@3.009 \
      Minion@10.31 \
      Minion::Backend::SQLite@5.0.0 \
      Mojo::IOLoop::ReadWriteFork@2.02 \
      Sereal::Encoder@5.004 \
      Sereal::Decoder@5.004 \
      CryptX@0.085 \
      DBD::SQLite@1.76 \
      Crypt::Simple \
      WWW::Mechanize \
      Time::Duration \
      Date::Parse \
      Hash::Merge \
      File::Slurp \
      Number::Format \
      SQL::Abstract \
      Data::UUID \
      Mojolicious::Plugin::RenderFile \
      LWP::UserAgent \
      LWP::Protocol::https \
      File::Type \
      HTML::Strip \
      URI::Encode \
      Net::SSLeay \
      Net::IMAP::Client \
      MIME::Parser \
      Email::Stuffer \
      Email::Sender \
      Authen::SASL \
      Text::Unidecode \
      Clone \
      Compress::Zlib

# ---- runtime ---------------------------------------------------------------
# A current Node for verify_change.pl's `node --check` (the bookworm package is
# Node 18); only the binary is needed, not npm.
FROM node:22-bookworm-slim AS node

FROM perl:5.40-slim-threaded-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    HOME=/home/jawn

# The same command-line tools scripts/jawnos_deps.pl names for Debian, plus the
# shared libraries the compiled Perl modules were linked against. The desktop
# app's WebKitGTK/GStreamer set is deliberately absent: this is the server.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates tzdata procps util-linux \
      openssl sqlite3 argon2 curl \
      openssh-client sshpass autossh rsync \
      net-tools iproute2 \
      ffmpeg imagemagick tesseract-ocr qrencode zbar-tools \
      espeak sox zip unzip tmux \
      git \
      libssl3 zlib1g libzstd1 libsqlite3-0 libexpat1 \
 && rm -rf /var/lib/apt/lists/*

# The modules were installed by the same Perl release into the same site_perl
# path, so the directory can move between the two images unchanged. The
# executables a few distributions add (mojo, minion) are not used by the tree.
COPY --from=modules /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=node /usr/local/bin/node /usr/local/bin/node

RUN groupadd --gid 1000 jawn \
 && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/jawn --shell /bin/bash jawn

WORKDIR /app
COPY --chown=jawn:jawn . .

# The tree writes beside itself: the database and its sealed backups, TLS
# material, and the voice/APK blob stores. The entry point makes the parts a
# fresh volume starts empty.
RUN mkdir -p /home/jawn/.president /app/database/backups /app/voices /app/releases \
 && chmod +x /app/docker/entrypoint.sh \
 && chown -R jawn:jawn /home/jawn /app

USER jawn

# main (working_port), websocket (working_port + 1) and the locker that mints
# login tickets. The defaults match config.json.example and compose.yaml.
EXPOSE 3000 45545 45546

ENTRYPOINT ["/app/docker/entrypoint.sh"]
# The perl base image ships a CMD of its own; clear it so nothing is appended
# to the entry point's argv.
CMD []
