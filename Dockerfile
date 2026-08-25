# Build Docker.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/fruit-market
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c $NimFlags \
    --nimcache:/tmp/fm-nimcache-game \
    --out:fruit-market \
    src/fruit_market.nim && \
  nim c $NimFlags \
    --nimcache:/tmp/fm-nimcache-player \
    --out:fruit-market-player \
    src/fruit_market_player.nim

# Run Docker. One image carries BOTH binaries: the LLM policy and the scripted
# baselines are the same build, selected by env var.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/fruit-market
COPY --from=build /workspace/fruit-market/fruit-market /bin/fruit-market
COPY --from=build /workspace/fruit-market/fruit-market-player \
  /bin/fruit-market-player
COPY --from=build /workspace/fruit-market/data ./data

CMD ["/bin/fruit-market"]
