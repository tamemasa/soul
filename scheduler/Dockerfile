FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /scheduler

COPY cron-tasks.sh /scheduler/cron-tasks.sh
COPY scheduler-loop.sh /scheduler/scheduler-loop.sh
RUN chmod +x /scheduler/cron-tasks.sh /scheduler/scheduler-loop.sh

CMD ["/scheduler/scheduler-loop.sh"]
