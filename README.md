# OpenClaw Telegram Deploy

Run OpenClaw as a rootless, read-only Podman pod with Telegram bot + browser automation.

## What you get

- Two-container pod: **gateway** (Telegram bot + AI agent) and **browser** (Chromium + noVNC)
- Read-only containers with `--cap-drop=ALL` and `--no-new-privileges`
- Browser accessible via noVNC for CAPTCHAs and manual input
- Persistent config, workspace, and browser data on the host

## Prerequisites

- [Podman](https://podman.io/) installed (rootless)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- An [Anthropic API key](https://console.anthropic.com/)
- OpenClaw container images built locally (see [openclaw](https://github.com/nicepkg/openclaw))

## Setup

1. **Build the images** from the openclaw source repo:

```bash
podman build -t openclaw-gateway:local -f Dockerfile .
podman build -t openclaw-browser:local -f Dockerfile.sandbox-browser .
```

2. **Copy config templates:**

```bash
mkdir -p ~/.openclaw
cp config/openclaw.json.example ~/.openclaw/openclaw.json
cp config/env.example ~/.openclaw/.env
```

3. **Edit `~/.openclaw/.env`** with your real tokens:

```bash
# Generate a gateway token
openssl rand -hex 32
# Paste it as OPENCLAW_GATEWAY_TOKEN, then add your bot token and API key
```

4. **Edit `~/.openclaw/openclaw.json`** -- replace `your_telegram_user_id` with your numeric Telegram ID.

5. **Start the pod** (skills are auto-pulled from [GitLab](https://gitlab.com/sbose78/openclaw-skills) on start):

```bash
./run-openclaw-telegram.sh start
```

6. **DM your bot** on Telegram. It will show a pairing code. Approve it:

```bash
./run-openclaw-telegram.sh approve <CODE>
```

## Commands

```
./run-openclaw-telegram.sh start          # Start the pod
./run-openclaw-telegram.sh stop           # Stop and remove
./run-openclaw-telegram.sh restart        # Stop then start
./run-openclaw-telegram.sh status         # Container status
./run-openclaw-telegram.sh logs           # Gateway logs (live)
./run-openclaw-telegram.sh logs-browser   # Browser logs (live)
./run-openclaw-telegram.sh sync-skills    # Pull latest skills from GitLab
./run-openclaw-telegram.sh approve <CODE> # Approve Telegram pairing
./run-openclaw-telegram.sh shell          # Shell into gateway
```

## Access points

| Service | URL |
|---|---|
| Admin dashboard | http://127.0.0.1:18789/ |
| noVNC (browser view) | http://127.0.0.1:6080/vnc.html |
| noVNC (LAN) | http://YOUR_IP:6080/vnc.html |

## File layout

```
~/.openclaw/
├── .env                  # Secrets (tokens, API keys)
├── openclaw.json         # Main config
├── workspace/            # Agent workspace (skills, memory)
│   └── skills/           # Reusable automation skills
├── browser-data/         # Chromium profile (cookies, sessions)
└── agents/               # Session history
```

## Notes

- noVNC is bound to `0.0.0.0:6080` -- accessible from any device on your LAN. No auth. Use on trusted networks only.
- Gateway dashboard requires the gateway token from `.env` on first connect.
- Skills are auto-pulled from Git on `start`. Update them independently: `./run-openclaw-telegram.sh sync-skills`
- Override the skills repo: `OPENCLAW_SKILLS_REPO=git@gitlab.com:you/your-skills.git ./run-openclaw-telegram.sh start`
