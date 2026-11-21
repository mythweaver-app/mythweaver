ARG ELIXIR_IMAGE=hexpm/elixir:1.20.5-erlang-29.1.2-ubuntu-noble-20261110
ARG RUNNER_IMAGE=ubuntu:noble-20261110
ARG BUN_IMAGE=oven/bun:1.4.4

FROM ${BUN_IMAGE} AS bun

FROM ${ELIXIR_IMAGE} AS builder
RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
COPY assets/package.json assets/bun.lock assets/
RUN cd assets && bun install --frozen-lockfile
# Branding is read at compile time (config/config.exs); pass --build-arg to set it. Declared after
# the dependency layers so changing it does not rebuild them.
ARG MYTHWEAVER_NAME=""
ARG MYTHWEAVER_LOGO_PATH=""
ENV MYTHWEAVER_NAME=${MYTHWEAVER_NAME} MYTHWEAVER_LOGO_PATH=${MYTHWEAVER_LOGO_PATH}
COPY priv priv
COPY lib lib
# The user docs are compiled in for the assistant (`Mythweaver.Docs`).
COPY docs docs
# Compiled before assets are copied, so an asset-only change reuses this layer; the compile inside
# `assets.deploy` is then a no-op.
RUN mix compile
RUN mix localize.download_locales
COPY assets assets
RUN mix assets.deploy
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# The bare release, for `docker build --target release --output type=local,dest=…` (the release
# workflow's Linux tarballs). Needs the runner image's libraries: glibc ≥ 2.39, OpenSSL 3, ncurses 6.
FROM scratch AS release
COPY --from=builder /app/_build/prod/rel/mythweaver /mythweaver

FROM ${RUNNER_IMAGE}
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod \
    MYTHWEAVER_UPLOADS_DIR=/data/uploads MYTHWEAVER_GEOIP_DIR=/data/geoip MYTHWEAVER_TOKENIZER_CACHE=/data/tokenizers \
    MYTHWEAVER_SECRETS_DIR=/data/secrets
WORKDIR /app
RUN mkdir -p /data && chown nobody /app /data
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/mythweaver ./
USER nobody
VOLUME /data
EXPOSE 4000
ENTRYPOINT ["/app/bin/entrypoint"]
CMD ["/app/bin/boot"]
