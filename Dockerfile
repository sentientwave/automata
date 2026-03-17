FROM hexpm/elixir:1.19.0-erlang-28.0-debian-bookworm-20250610-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential git curl ca-certificates && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
COPY apps ./apps

RUN mix deps.get
RUN mix compile

EXPOSE 4000
CMD ["mix", "phx.server"]
