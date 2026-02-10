FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    cron \
    jq \
    ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /scheduler

COPY cron-tasks.sh /scheduler/cron-tasks.sh
RUN chmod +x /scheduler/cron-tasks.sh

RUN echo "0 */6 * * * /scheduler/cron-tasks.sh evaluation >> /var/log/scheduler.log 2>&1" > /etc/cron.d/soul-scheduler \
    && chmod 0644 /etc/cron.d/soul-scheduler \
    && crontab /etc/cron.d/soul-scheduler

CMD ["cron", "-f"]
