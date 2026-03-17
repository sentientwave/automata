FROM golang:1.24-bookworm AS temporal-cli-build

RUN go install github.com/temporalio/cli/cmd/temporal@v1.4.1

FROM vectorim/element-web:latest AS element-web-build

FROM docker.io/library/elixir:1.18.4

ENV DEBIAN_FRONTEND=noninteractive
ENV MIX_ENV=prod

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  build-essential \
  ca-certificates \
  curl \
  git \
  jq \
  netcat-openbsd \
  openssl \
  postgresql \
  postgresql-client \
  postgresql-server-dev-all \
  python3 \
  python3-pip \
  nginx \
  supervisor \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch v0.7.4 https://github.com/pgvector/pgvector.git /tmp/pgvector && \
  make -C /tmp/pgvector && \
  make -C /tmp/pgvector install && \
  rm -rf /tmp/pgvector

RUN pip3 install --break-system-packages --ignore-installed --no-cache-dir matrix-synapse

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

COPY mix.exs mix.lock ./
COPY config ./config
COPY apps ./apps

RUN mix deps.get
RUN mix assets.deploy
RUN mix compile

COPY --from=temporal-cli-build /go/bin/temporal /usr/local/bin/temporal
COPY --from=element-web-build /app /opt/element-web

COPY deploy/all-in-one/supervisord.conf /etc/supervisor/conf.d/all-in-one.conf
COPY deploy/all-in-one/scripts /opt/all-in-one/scripts

RUN chmod +x /opt/all-in-one/scripts/*.sh && \
  mkdir -p /data/postgres /data/matrix /data/temporal /data/logs /data/skills && \
  chown -R postgres:postgres /data/postgres

ENV POSTGRES_DATA_DIR=/data/postgres
ENV POSTGRES_PORT=5432
ENV APP_DB_NAME=sentientwave_dev
ENV APP_DB_USER=automata
ENV APP_DB_PASSWORD=automata
ENV MATRIX_CONFIG_DIR=/data/matrix
ENV MATRIX_CONFIG_PATH=/data/matrix/homeserver.yaml
ENV MATRIX_DATA_DIR=/data/matrix/data
ENV MATRIX_SERVER_NAME=localhost
ENV MATRIX_PORT=8008
ENV ELEMENT_WEB_PORT=8081
ENV ELEMENT_DEFAULT_HOMESERVER_URL=http://localhost:8008
ENV TEMPORAL_DB_FILE=/data/temporal/temporal.db
ENV TEMPORAL_PORT=7233
ENV TEMPORAL_UI_PORT=8233
ENV AUTOMATA_TEMPORAL_TASK_QUEUE=automata-agents
ENV AUTOMATA_SKILLS_PATH=/data/skills
ENV AUTOMATA_EMBEDDING_PROVIDER=local
ENV AUTOMATA_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ENV AUTOMATA_EMBEDDING_API_BASE=
ENV AUTOMATA_EMBEDDING_API_KEY=
ENV AUTOMATA_LLM_PROVIDER=local
ENV AUTOMATA_LLM_MODEL=local-default
ENV AUTOMATA_LLM_API_BASE=
ENV AUTOMATA_LLM_API_KEY=
ENV AUTOMATA_LLM_TIMEOUT_MS=30000
ENV AUTOMATA_LLM_CONNECT_TIMEOUT_MS=3000
ENV PGVECTOR_REQUIRED=false
ENV PORT=4000

EXPOSE 4000 5432 7233 8008 8081 8233

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null || exit 1

ENTRYPOINT ["/opt/all-in-one/scripts/entrypoint.sh"]
