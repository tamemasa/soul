FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    iptables \
    gosu \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install OpenClaw globally
RUN npm install -g openclaw@latest

# Create non-root user
RUN groupadd -r openclaw && useradd -r -g openclaw -m -d /home/openclaw -s /bin/bash openclaw

# Create data and config directories
RUN mkdir -p /home/openclaw/.openclaw/workspace /app/data \
    && chown -R openclaw:openclaw /home/openclaw /app

WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
COPY network-restrict.sh /app/network-restrict.sh
RUN chmod +x /app/entrypoint.sh /app/network-restrict.sh

# Copy Masaru personality files
COPY personality/SOUL.md /app/personality/SOUL.md
COPY personality/IDENTITY.md /app/personality/IDENTITY.md

# Start as root so we can apply iptables rules, then drop to openclaw via gosu
ENV HOME=/home/openclaw

ENTRYPOINT ["/app/entrypoint.sh"]
