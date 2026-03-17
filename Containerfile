FROM docker.io/library/elixir:1.19.0-erlang-28

WORKDIR /app
COPY . /app

RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get && mix compile

EXPOSE 4000
CMD ["mix", "phx.server"]
