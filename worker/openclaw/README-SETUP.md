# OpenClaw Discord Bot - Setup Guide

## Prerequisites

- Docker and Docker Compose installed
- A Discord account

## Step 1: Create a Discord Bot

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Click **New Application** and give it a name
3. Go to **Bot** in the left sidebar
4. Click **Reset Token** and copy the token

## Step 2: Configure Bot Permissions

In the Discord Developer Portal:

1. Go to **Bot** > **Privileged Gateway Intents**
2. Enable **Message Content Intent** (required)
3. Enable **Server Members Intent** (recommended)

## Step 3: Invite the Bot to Your Server

1. Go to **OAuth2** > **URL Generator**
2. Select scopes: `bot`, `applications.commands`
3. Select permissions:
   - View Channels
   - Send Messages
   - Read Message History
   - Embed Links
   - Attach Files
4. Copy the generated URL and open it in your browser
5. Select your server and authorize

## Step 4: Configure Environment Variables

Edit `/soul/openclaw/.env`:

```env
DISCORD_BOT_TOKEN=your_bot_token_here
ANTHROPIC_API_KEY=your_anthropic_key_here
```

## Step 4b: Enable Web Search (Optional)

To enable the `web_search` tool (real-time information retrieval):

1. Get a free Brave Search API key at https://brave.com/search/api/
   - Free plan: 2,000 queries/month
2. Add to `/soul/worker/openclaw/.env`:
   ```env
   BRAVE_API_KEY=your_brave_api_key_here
   ```
3. Rebuild the container (Step 5)

## Step 5: Build and Start

```bash
cd /soul
docker compose up -d --build openclaw
```

## Step 6: Verify

Check the logs:
```bash
docker logs soul-openclaw --tail 50
```

You should see:
```
OpenClaw container starting...
Discord configuration written.
Starting OpenClaw gateway...
```

## Step 7: Test

Send a DM to your bot on Discord. On first contact, you'll receive a **pairing code** that you need to approve.

## Troubleshooting

### Bot not responding
```bash
docker logs soul-openclaw --tail 100
```

### Restart the container
```bash
cd /soul && docker compose restart openclaw
```

### Rebuild from scratch
```bash
cd /soul && docker compose up -d --build openclaw
```

### Stop the bot
```bash
cd /soul && docker compose stop openclaw
```
