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
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
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

ENTRYPOINT ["/brain/soul-daemon.sh"]
