FROM debian:bookworm-slim

ARG DOCKER_GID=984

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    ca-certificates \
    curl \
    gnupg \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && groupadd -g ${DOCKER_GID} docker || true \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /scheduler

COPY cron-tasks.sh /scheduler/cron-tasks.sh
COPY scheduler-loop.sh /scheduler/scheduler-loop.sh
COPY archive-tasks.sh /scheduler/archive-tasks.sh
RUN chmod +x /scheduler/cron-tasks.sh /scheduler/scheduler-loop.sh /scheduler/archive-tasks.sh

CMD ["/scheduler/scheduler-loop.sh"]
