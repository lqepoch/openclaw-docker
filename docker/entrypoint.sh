#!/usr/bin/env sh
set -eu

: "${OPENCLAW_HOME:=/home/node/.openclaw}"
: "${OPENCLAW_AUTO_CONFIG:=false}"
: "${GITHUB_HOST:=github.com}"
: "${XDG_CONFIG_HOME:=${OPENCLAW_HOME}/.config}"
: "${GH_CONFIG_DIR:=${XDG_CONFIG_HOME}/gh}"
: "${OPENCLAW_CLAWHUB_AUTO_INSTALL:=false}"
: "${OPENCLAW_CLAWHUB_EXTRA_SKILLS:=}"
: "${OPENCLAW_INIT_DIR:=${OPENCLAW_HOME}/.init}"
: "${OPENCLAW_CLAWHUB_SENTINEL:=${OPENCLAW_INIT_DIR}/clawhub-skills.installed}"
: "${OPENCLAW_GATEWAY_BIND:=}"
: "${OPENCLAW_PORT:=18789}"

log() {
  printf '%s\n' "[entrypoint] $*"
}

split_values() {
  python3 - "$1" <<'PY'
import re
import sys

raw = sys.argv[1]
for part in re.split(r"[\s,]+", raw.strip()):
    if part:
        print(part)
PY
}

build_discord_guilds_json() {
  python3 - "${DISCORD_GUILD_IDS:-}" "${DISCORD_USER_IDS:-}" <<'PY'
import json
import re
import sys

def parse(raw: str):
    return [item for item in re.split(r"[\s,]+", raw.strip()) if item]

guild_ids = parse(sys.argv[1])
user_ids = parse(sys.argv[2])

config = {"*": {"requireMention": True}}
for guild_id in guild_ids:
    config[guild_id] = {
        "users": [f"user:{user_id}" for user_id in user_ids],
        "requireMention": False,
        "channels": {"*": {"allow": True, "requireMention": False}},
    }

print(json.dumps(config, separators=(",", ":")))
PY
}

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
  log "applying explicit OpenClaw bootstrap config"
  openclaw config set gateway.mode local

  if [ -n "${DISCORD_BOT_TOKEN:-}" ] || [ -n "${DISCORD_GUILD_IDS:-}" ] || [ -n "${DISCORD_USER_IDS:-}" ] || [ -n "${DISCORD_CHANNEL_IDS:-}" ]; then
    openclaw plugins enable discord >/dev/null 2>&1 || true
  fi

  if [ -n "${DISCORD_GUILD_IDS:-}" ] && [ -n "${DISCORD_USER_IDS:-}" ]; then
    openclaw config set 'channels.discord.groupPolicy' 'allowlist'
    json_config="$(build_discord_guilds_json)"
    if ! openclaw config set --json 'channels.discord.guilds' "${json_config}" >/dev/null 2>&1; then
      log "openclaw config set --json unsupported; falling back to plain set for channels.discord.guilds"
      openclaw config set 'channels.discord.guilds' "${json_config}"
    fi
  fi
fi

if [ "${OPENCLAW_CLAWHUB_AUTO_INSTALL}" = "true" ] && [ ! -f "${OPENCLAW_CLAWHUB_SENTINEL}" ]; then
  mkdir -p "${OPENCLAW_HOME}/workspace" "${OPENCLAW_INIT_DIR}"
  skills_list="steipete/github ${OPENCLAW_CLAWHUB_EXTRA_SKILLS}"
  installed_any="false"
  for item in $(split_values "${skills_list}"); do
    slug="${item#https://clawhub.ai/}"
    slug="${slug#/}"
    [ -n "${slug}" ] || continue
    CLAWHUB_WORKDIR="${OPENCLAW_HOME}/workspace" clawhub install "${slug}" >/dev/null
    installed_any="true"
  done
  if [ "${installed_any}" = "true" ]; then
    : > "${OPENCLAW_CLAWHUB_SENTINEL}"
  fi
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

if [ -n "${OPENCLAW_GATEWAY_BIND}" ]; then
  exec openclaw gateway --port "${OPENCLAW_PORT}" --bind "${OPENCLAW_GATEWAY_BIND}"
fi

exec openclaw gateway --port "${OPENCLAW_PORT}"
