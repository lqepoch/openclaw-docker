# OpenClaw Docker

This repository builds and publishes an OpenClaw container image for `linux/amd64`.

The image now follows a stricter runtime contract:

- No runtime self-update.
- No background update loop.
- No automatic config mutation unless explicitly enabled.
- No automatic skill installation unless explicitly enabled.
- `OPENCLAW_PORT` is respected by both the entrypoint and the healthcheck.

## Image tags

CI resolves the current `openclaw@latest` npm version first, then passes that exact version into the Docker build. The pushed image tag and the installed OpenClaw version are expected to match.

## Persistent data

OpenClaw state lives in `/home/node/.openclaw`.

Recommended volume:

```bash
docker volume create openclaw-data
```

## Minimal runtime

This is the lowest-side-effect way to run the gateway:

```bash
docker run -d --name openclaw \
  --restart unless-stopped \
  -v openclaw-data:/home/node/.openclaw \
  -e OPENCLAW_AUTO_CONFIG=false \
  -e OPENCLAW_CLAWHUB_AUTO_INSTALL=false \
  -e OPENCLAW_GATEWAY_BIND=lan \
  -p 18789:18789 \
  lqepoch/openclaw:latest
```

## Explicit bootstrap config

If you want the container to write the minimal gateway bootstrap config for you, enable it explicitly:

```bash
docker run --rm -it \
  -v openclaw-data:/home/node/.openclaw \
  -e OPENCLAW_AUTO_CONFIG=true \
  lqepoch/openclaw:latest sh
```

When `OPENCLAW_AUTO_CONFIG=true`, the entrypoint only writes:

- `gateway.mode=local`
- Discord plugin enablement when Discord-related environment variables are present
- Discord allowlist config when both `DISCORD_GUILD_IDS` and `DISCORD_USER_IDS` are provided

It no longer writes unrelated personal preference defaults on every startup.

## Discord bootstrap

Discord allowlist bootstrap is optional and only runs when all of these are true:

- `OPENCLAW_AUTO_CONFIG=true`
- `DISCORD_GUILD_IDS` is set
- `DISCORD_USER_IDS` is set

Multiple guild IDs and user IDs are supported. Separate them with commas or spaces:

```bash
-e DISCORD_GUILD_IDS="1234567890,2345678901" \
-e DISCORD_USER_IDS="1111111111 2222222222"
```

## Optional skill installation

Automatic skill installation is now disabled by default. If you explicitly enable it, installation runs once and writes a sentinel only after at least one install succeeds.

```bash
docker run --rm -it \
  -v openclaw-data:/home/node/.openclaw \
  -e OPENCLAW_CLAWHUB_AUTO_INSTALL=true \
  -e OPENCLAW_CLAWHUB_EXTRA_SKILLS="owner2/skill2,https://clawhub.ai/owner3/skill3" \
  lqepoch/openclaw:latest sh
```

## Port binding

The image respects `OPENCLAW_PORT`.

Example:

```bash
docker run -d --name openclaw-alt-port \
  --restart unless-stopped \
  -v openclaw-data:/home/node/.openclaw \
  -e OPENCLAW_AUTO_CONFIG=true \
  -e OPENCLAW_PORT=18790 \
  -e OPENCLAW_GATEWAY_BIND=lan \
  -p 18790:18790 \
  lqepoch/openclaw:latest
```

## Healthcheck

The image healthcheck performs an HTTP probe against the configured local gateway port. It does not treat a bare TCP accept as healthy.

## Recommended hardened run options

The image already runs as a non-root `node` user. For stricter runtime isolation, prefer:

```bash
docker run -d --name openclaw \
  --restart unless-stopped \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --tmpfs /home/node/.cache:rw,noexec,nosuid,size=64m \
  -v openclaw-data:/home/node/.openclaw \
  -e OPENCLAW_AUTO_CONFIG=false \
  -e OPENCLAW_CLAWHUB_AUTO_INSTALL=false \
  -e OPENCLAW_GATEWAY_BIND=lan \
  -p 18789:18789 \
  lqepoch/openclaw:latest
```

## Environment variables

Supported runtime variables:

- `OPENCLAW_HOME` default: `/home/node/.openclaw`
- `OPENCLAW_PORT` default: `18789`
- `OPENCLAW_GATEWAY_BIND` optional bind mode passed to `openclaw gateway --bind`
- `OPENCLAW_AUTO_CONFIG` default: `false`
- `OPENCLAW_CLAWHUB_AUTO_INSTALL` default: `false`
- `OPENCLAW_CLAWHUB_EXTRA_SKILLS` optional extra skill list
- `GH_TOKEN` or `GITHUB_TOKEN` optional GitHub token for git/gh auth setup
- `DISCORD_BOT_TOKEN` optional Discord bot token
- `DISCORD_GUILD_IDS` optional Discord guild IDs, comma- or space-separated
- `DISCORD_USER_IDS` optional Discord user IDs, comma- or space-separated

## Local checks

Logs:

```bash
docker logs -f openclaw
```

Inspect Discord config:

```bash
docker exec -it openclaw sh -lc "openclaw config get --json 'channels.discord.guilds'"
```

Check the installed OpenClaw version:

```bash
docker exec -it openclaw sh -lc "openclaw --version"
```
