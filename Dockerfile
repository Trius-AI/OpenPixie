FROM erlang:28 AS build

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

COPY rebar.config rebar.lock* ./
RUN rebar3 get-deps

COPY . .
RUN rm -rf _build/prod && rebar3 as prod release

FROM erlang:28-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates libstdc++6 git curl openssh-client && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /build/_build/prod/rel/openpixie /opt/openpixie
COPY --from=build /build/src /opt/openpixie/src
COPY --from=build /build/priv /opt/openpixie/priv
COPY --from=build /build/docs /opt/openpixie/docs
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /data/pixie /data/workspace /opt/openpixie/log

WORKDIR /opt/openpixie

ENV OPENPIXIE_DIR=/data/pixie
ENV OPENPIXIE_WORKSPACE=/data/workspace
ENV OPENPIXIE_PORT=8080
ENV OLLAMA_HOST=http://host.docker.internal:11434

EXPOSE 8080

VOLUME ["/data"]

# The auto-generated API key is saved to /data/pixie/API_KEY
# View it with: docker exec <container> cat /data/pixie/API_KEY

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["foreground"]