#!/usr/bin/env sh
set -eu

: "${OPENCLAW_HOME:=/home/node/.openclaw}"
: "${OPENCLAW_AUTO_CONFIG:=true}"
: "${GITHUB_HOST:=github.com}"

# Persist gh/git config under OPENCLAW_HOME (volume-friendly)
: "${XDG_CONFIG_HOME:=${OPENCLAW_HOME}/.config}"
: "${GH_CONFIG_DIR:=${XDG_CONFIG_HOME}/gh}"

# Optional: install ClawHub skills at boot.
# 默认会自动安装 GitHub skill（steipete/github）。
# 你也可以通过 OPENCLAW_CLAWHUB_EXTRA_SKILLS 额外安装多个 skill（逗号/空格分隔，支持 URL 或 owner/slug）。
: "${OPENCLAW_CLAWHUB_AUTO_INSTALL:=true}"
: "${OPENCLAW_CLAWHUB_EXTRA_SKILLS:=}"
: "${OPENCLAW_INIT_DIR:=${OPENCLAW_HOME}/.init}"
: "${OPENCLAW_CLAWHUB_SENTINEL:=${OPENCLAW_INIT_DIR}/clawhub-skills.installed}"

# Optional: try to update OpenClaw before starting gateway.
# Note: only runs in non-interactive mode when the CLI supports a yes flag.
: "${OPENCLAW_AUTO_UPDATE:=true}"
: "${OPENCLAW_AUTO_UPDATE_REQUIRED:=false}"
: "${OPENCLAW_DAILY_UPDATE:=true}"
: "${OPENCLAW_DAILY_UPDATE_TZ:=Asia/Shanghai}"
: "${OPENCLAW_DAILY_UPDATE_TIME:=05:00}"

# Optional: pass through to `openclaw gateway --bind ...` (e.g. lan/loopback/auto)
: "${OPENCLAW_GATEWAY_BIND:=}"

OPENCLAW_PORT="18789"

mkdir -p "${OPENCLAW_HOME}" "${XDG_CONFIG_HOME}" "${GH_CONFIG_DIR}"
chmod 700 "${OPENCLAW_HOME}" "${XDG_CONFIG_HOME}" "${GH_CONFIG_DIR}"

openclaw_update_once() {
  update_help="$(openclaw update --help 2>&1 || true)"
  if printf '%s' "${update_help}" | grep -q -- '--yes'; then
    openclaw update --yes
    return $?
  fi
  if printf '%s' "${update_help}" | grep -Eq -- '(^|[[:space:]])-y([[:space:]]|$)'; then
    openclaw update -y
    return $?
  fi
  return 2
}

start_daily_update_loop() {
  (
    set -eu
    while true; do
      now_epoch="$(TZ="${OPENCLAW_DAILY_UPDATE_TZ}" date +%s)"
      today_target_epoch="$(TZ="${OPENCLAW_DAILY_UPDATE_TZ}" date -d "today ${OPENCLAW_DAILY_UPDATE_TIME}" +%s)"
      if [ "${now_epoch}" -ge "${today_target_epoch}" ]; then
        next_target_epoch="$(TZ="${OPENCLAW_DAILY_UPDATE_TZ}" date -d "tomorrow ${OPENCLAW_DAILY_UPDATE_TIME}" +%s)"
      else
        next_target_epoch="${today_target_epoch}"
      fi

      sleep_seconds="$((next_target_epoch - now_epoch))"
      if [ "${sleep_seconds}" -gt 0 ]; then
        sleep "${sleep_seconds}"
      fi

      if [ "${OPENCLAW_AUTO_UPDATE}" = "true" ]; then
        if ! openclaw_update_once >/dev/null 2>&1; then
          if [ "${OPENCLAW_AUTO_UPDATE_REQUIRED}" = "true" ]; then
            echo "[entrypoint] openclaw daily update failed (required)" >&2
            exit 1
          fi
        fi
      fi
    done
  ) &
}

if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"
  umask 077
  printf '%s\n' "https://x-access-token:${TOKEN}@${GITHUB_HOST}" > "${OPENCLAW_HOME}/.git-credentials"
  chmod 600 "${OPENCLAW_HOME}/.git-credentials"
  GIT_CONFIG_GLOBAL="${OPENCLAW_HOME}/.gitconfig" git config --global credential.helper "store --file=${OPENCLAW_HOME}/.git-credentials"
  GIT_CONFIG_GLOBAL="${OPENCLAW_HOME}/.gitconfig" git config --global credential.useHttpPath true
fi

if [ "${OPENCLAW_AUTO_UPDATE}" = "true" ]; then
  if ! openclaw_update_once >/dev/null 2>&1; then
    rc="$?"
    if [ "${rc}" = "2" ]; then
      echo "[entrypoint] openclaw update has no non-interactive flag; skipping. Rebuild/pull a newer image instead." >&2
      if [ "${OPENCLAW_AUTO_UPDATE_REQUIRED}" = "true" ]; then
        exit 1
      fi
    elif [ "${OPENCLAW_AUTO_UPDATE_REQUIRED}" = "true" ]; then
      echo "[entrypoint] openclaw update failed (required)" >&2
      exit 1
    fi
  fi
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

if [ "${OPENCLAW_CLAWHUB_AUTO_INSTALL}" = "true" ] && [ ! -f "${OPENCLAW_CLAWHUB_SENTINEL}" ]; then
  mkdir -p "${OPENCLAW_HOME}/workspace" "${OPENCLAW_INIT_DIR}"
  skills_list="steipete/github ${OPENCLAW_CLAWHUB_EXTRA_SKILLS}"
  skills_list="$(printf '%s' "${skills_list}" | tr ',\t\r\n' '    ')"
  for item in ${skills_list}; do
    [ -n "${item}" ] || continue
    slug="${item#https://clawhub.ai/}"
    slug="${slug#/}"
    CLAWHUB_WORKDIR="${OPENCLAW_HOME}/workspace" clawhub install "${slug}" >/dev/null 2>&1 || true
  done
  : > "${OPENCLAW_CLAWHUB_SENTINEL}"
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

if [ "${OPENCLAW_DAILY_UPDATE}" = "true" ]; then
  start_daily_update_loop
fi

if [ -n "${OPENCLAW_GATEWAY_BIND}" ]; then
  exec openclaw gateway --port "${OPENCLAW_PORT}" --bind "${OPENCLAW_GATEWAY_BIND}"
fi
exec openclaw gateway --port "${OPENCLAW_PORT}"
