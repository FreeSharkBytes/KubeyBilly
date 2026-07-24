# syntax=docker/dockerfile:1
#
# Multi-stage build: compile the release on the pinned hexpm toolchain image,
# run it on plain debian-slim. OCI-clean; builds identically under podman and
# in CI. Toolchain versions match .tool-versions.

FROM docker.io/hexpm/elixir:1.20.2-erlang-29.0.3-debian-bookworm-20260713-slim AS builder

# git for github-sourced deps (heroicons, daisyui); ca-certificates so the
# esbuild/tailwind hex-managed binary downloads can speak TLS. No npm: the
# asset pipeline uses the standalone binaries fetched by the hex packages.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# Dependency layer: cache deps against mix.exs/mix.lock only.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Compile-time config before deps so a config change rebuilds deps that read it.
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# Application code and assets.
COPY assets assets
COPY priv priv
COPY lib lib

# Compile before assets.deploy: the LiveView colocated CSS/JS that the asset
# pipeline imports (phoenix-colocated/*) is emitted by the compiler.
RUN mix assets.setup && mix compile && mix assets.deploy

# Runtime config is read at boot, not compile; copy it last for layer reuse.
COPY config/runtime.exs config/

RUN mix release kubeybilly

# ---------------------------------------------------------------------------

FROM docker.io/debian:bookworm-slim

# Runtime needs of an OTP release: TLS roots for the Kubernetes API,
# ncurses + libstdc++ for the BEAM, openssl for the crypto NIFs.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates libncurses6 libstdc++6 openssl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-root, distroless-style fixed uid (65532, "nonroot" convention).
RUN groupadd --gid 65532 kubeybilly && \
    useradd --uid 65532 --gid 65532 --home-dir /app --shell /usr/sbin/nologin kubeybilly

WORKDIR /app

# ERL_MAX_PORTS: containerd sets LimitNOFILE to 2^31; the BEAM sizes its port
# table from the fd limit and would try to allocate gigabytes at boot (proven
# on kind). Pin the table to a sane size instead.
ENV ERL_MAX_PORTS=65536 \
    LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

COPY --from=builder --chown=kubeybilly:kubeybilly /app/_build/prod/rel/kubeybilly ./

USER 65532:65532

EXPOSE 4000

CMD ["/app/bin/kubeybilly", "start"]
