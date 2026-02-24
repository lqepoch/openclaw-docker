#!/usr/bin/env sh
set -eu

: "${OPENCLAW_HOME:=/home/node/.openclaw}"
: "${OPENCLAW_AUTO_CONFIG:=true}"
: "${GITHUB_HOST:=github.com}"

# Persist gh/git config under OPENCLAW_HOME (volume-friendly)
: "${XDG_CONFIG_HOME:=${OPENCLAW_HOME}/.config}"
: "${GH_CONFIG_DIR:=${XDG_CONFIG_HOME}/gh}"

# Optional: pass through to `openclaw gateway --bind ...` (e.g. lan/loopback/auto)
: "${OPENCLAW_GATEWAY_BIND:=}"

OPENCLAW_PORT="18789"

mkdir -p "${OPENCLAW_HOME}" "${XDG_CONFIG_HOME}" "${GH_CONFIG_DIR}"
chmod 700 "${OPENCLAW_HOME}" "${XDG_CONFIG_HOME}" "${GH_CONFIG_DIR}"

if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"
  umask 077
  printf '%s\n' "https://x-access-token:${TOKEN}@${GITHUB_HOST}" > "${OPENCLAW_HOME}/.git-credentials"
  chmod 600 "${OPENCLAW_HOME}/.git-credentials"
  GIT_CONFIG_GLOBAL="${OPENCLAW_HOME}/.gitconfig" git config --global credential.helper "store --file=${OPENCLAW_HOME}/.git-credentials"
  GIT_CONFIG_GLOBAL="${OPENCLAW_HOME}/.gitconfig" git config --global credential.useHttpPath true
fi

if [ "${OPENCLAW_AUTO_CONFIG}" = "true" ]; then
  # Required for gateway to start in local mode (idempotent).
  openclaw config set gateway.mode local

  # Enable Discord plugin when Discord envs are present.
  if [ -n "${DISCORD_BOT_TOKEN:-}" ] || [ -n "${DISCORD_GUILD_IDS:-}" ] || [ -n "${DISCORD_USER_IDS:-}" ] || [ -n "${DISCORD_CHANNEL_IDS:-}" ]; then
    openclaw plugins enable discord >/dev/null 2>&1 || true
  fi

  # Your preferred defaults
  openclaw config set 'agents.defaults.thinkingDefault' 'medium'
  openclaw config set 'messages.ackReaction' '👀'
  openclaw config set 'messages.ackReactionScope' 'group-all'
  openclaw config set 'messages.removeAckAfterReply' false
  openclaw config set 'commands.config' true
  openclaw config set 'channels.discord.configWrites' true

  # Discord allowlist (single guild + single user)
  if [ -n "${DISCORD_GUILD_IDS:-}" ] && [ -n "${DISCORD_USER_IDS:-}" ]; then
    GUILD_ID="$(printf '%s' "${DISCORD_GUILD_IDS}" | awk -F'[ ,]+' '{print $1}')"
    USER_ID="$(printf '%s' "${DISCORD_USER_IDS}" | awk -F'[ ,]+' '{print $1}')"

    openclaw config set 'channels.discord.groupPolicy' 'allowlist'
    openclaw config unset 'channels.discord.guilds' >/dev/null 2>&1 || true

    JSON_CONFIG="$(cat <<EOF
{
  "*": { "requireMention": true },
  "${GUILD_ID}": {
    "users": ["user:${USER_ID}"],
    "requireMention": false,
    "channels": { "*": { "allow": true, "requireMention": false } }
  }
}
EOF
)"
    if ! openclaw config set --json 'channels.discord.guilds' "${JSON_CONFIG}" >/dev/null 2>&1; then
      openclaw config set 'channels.discord.guilds' "${JSON_CONFIG}"
    fi
  fi
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

if [ -n "${OPENCLAW_GATEWAY_BIND}" ]; then
  exec openclaw gateway --port "${OPENCLAW_PORT}" --bind "${OPENCLAW_GATEWAY_BIND}"
fi
exec openclaw gateway --port "${OPENCLAW_PORT}"
