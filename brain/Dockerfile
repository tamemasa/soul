FROM debian:bookworm-slim

ARG DOCKER_GID=984

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    jq \
    inotify-tools \
    ripgrep \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && npm install -g @modelcontextprotocol/server-memory @modelcontextprotocol/server-sequential-thinking \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv \
    && pip3 install --break-system-packages mcp-server-fetch \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create writable home for non-root execution and add docker group
RUN groupadd -g ${DOCKER_GID} docker || true \
    && mkdir -p /home/soul/.claude/todos /home/soul/.claude/debug /home/soul/.claude/cache \
    && echo '{}' > /home/soul/.claude/settings.json \
    && chmod -R 777 /home/soul

WORKDIR /brain

COPY soul-daemon.sh /brain/soul-daemon.sh
COPY lib/ /brain/lib/
COPY protocols/ /brain/protocols/

RUN chmod +x /brain/soul-daemon.sh /brain/lib/*.sh

# Docker command guard: prevents self-destructive docker operations
COPY lib/docker-guard.sh /usr/local/bin/docker
RUN chmod +x /usr/local/bin/docker

HEALTHCHECK --interval=60s --timeout=10s --retries=3 --start-period=60s \
  CMD grep -q soul-daemon /proc/1/cmdline 2>/dev/null || exit 1

ENTRYPOINT ["/brain/soul-daemon.sh"]
