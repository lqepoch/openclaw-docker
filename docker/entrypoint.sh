#!/usr/bin/env sh
set -eu
umask 027

# OpenClaw 配置目录（默认与 Dockerfile 一致；也允许运行时覆盖）。
: "${OPENCLAW_HOME:=/home/node/.openclaw}"

# OpenClaw 文档中的默认 gateway 端口。
: "${OPENCLAW_PORT:=18789}"

# 如需在容器外完全自行管理 openclaw 配置，可设置为 false。
: "${OPENCLAW_AUTO_CONFIG:=true}"

# 是否重复应用基础配置（默认仅首次对 volume 应用一次）。
: "${OPENCLAW_CONFIG_REAPPLY:=false}"

# 是否强制要求 GitHub 登录验证（缺少 token 或验证失败会直接退出）。
: "${OPENCLAW_GITHUB_AUTH_REQUIRED:=false}"

# GitHub 相关配置（默认 github.com；企业版可覆盖）。
: "${GITHUB_HOST:=github.com}"

# 将 gh 与 XDG 配置写入 OPENCLAW_HOME，便于 volume 持久化。
: "${XDG_CONFIG_HOME:=${OPENCLAW_HOME}/.config}"
: "${GH_CONFIG_DIR:=${XDG_CONFIG_HOME}/gh}"
: "${OPENCLAW_INIT_DIR:=${OPENCLAW_HOME}/.init}"
: "${OPENCLAW_BASE_CONFIG_SENTINEL:=${OPENCLAW_INIT_DIR}/base-config.applied}"

# 为了易用性，同时兼容单数/复数两种环境变量命名。
if [ -n "${DISCORD_GUILD_ID:-}" ] && [ -z "${DISCORD_GUILD_IDS:-}" ]; then
  DISCORD_GUILD_IDS="${DISCORD_GUILD_ID}"
fi
if [ -n "${DISCORD_USER_ID:-}" ] && [ -z "${DISCORD_USER_IDS:-}" ]; then
  DISCORD_USER_IDS="${DISCORD_USER_ID}"
fi
if [ -n "${DISCORD_CHANNEL_ID:-}" ] && [ -z "${DISCORD_CHANNEL_IDS:-}" ]; then
  DISCORD_CHANNEL_IDS="${DISCORD_CHANNEL_ID}"
fi

maybe_enable_discord_plugin() {
  # OpenClaw 默认将 Discord 插件设为 disabled。
  # 这里在 gateway 启动前，根据环境变量自动启用，避免出现
  # “已 enable plugin 但还要手动重启 gateway 才生效”的困惑。
  if [ -n "${DISCORD_BOT_TOKEN:-}" ] || [ -n "${DISCORD_GUILD_IDS:-}" ] || [ -n "${DISCORD_USER_IDS:-}" ] || [ -n "${DISCORD_CHANNEL_IDS:-}" ]; then
    echo "[entrypoint] 检测到 Discord 环境变量，正在启用 discord 插件..."
    openclaw plugins enable discord >/dev/null
  fi
}

validate_port() {
  case "${OPENCLAW_PORT}" in
    ''|*[!0-9]*)
      echo "[entrypoint] OPENCLAW_PORT 非法（必须是数字）: ${OPENCLAW_PORT}" >&2
      exit 1
      ;;
  esac

  if [ "${OPENCLAW_PORT}" -lt 1 ] || [ "${OPENCLAW_PORT}" -gt 65535 ]; then
    echo "[entrypoint] OPENCLAW_PORT 超出范围（1-65535）: ${OPENCLAW_PORT}" >&2
    exit 1
  fi
}

resolve_github_token() {
  GITHUB_AUTH_TOKEN=""
  GITHUB_AUTH_TOKEN_SOURCE=""

  if [ -n "${GH_TOKEN:-}" ]; then
    GITHUB_AUTH_TOKEN="${GH_TOKEN}"
    GITHUB_AUTH_TOKEN_SOURCE="GH_TOKEN"
    return
  fi

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    GITHUB_AUTH_TOKEN="${GITHUB_TOKEN}"
    GITHUB_AUTH_TOKEN_SOURCE="GITHUB_TOKEN"
    return
  fi
}

prepare_auth_dirs() {
  mkdir -p "${OPENCLAW_HOME}" "${XDG_CONFIG_HOME}" "${GH_CONFIG_DIR}" "${OPENCLAW_INIT_DIR}"
  chmod 700 "${OPENCLAW_HOME}" "${XDG_CONFIG_HOME}" "${GH_CONFIG_DIR}" "${OPENCLAW_INIT_DIR}"
}

configure_git_auth() {
  if [ -z "${GITHUB_AUTH_TOKEN:-}" ]; then
    return
  fi

  GIT_CREDENTIALS_FILE="${OPENCLAW_HOME}/.git-credentials"
  GIT_CONFIG_GLOBAL_FILE="${OPENCLAW_HOME}/.gitconfig"
  GIT_CREDENTIALS_LINE="https://x-access-token:${GITHUB_AUTH_TOKEN}@${GITHUB_HOST}"

  # 仅使用标准 HTTPS 凭据存储，避免每次 git 操作都重复交互。
  GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL_FILE}" git config --global credential.helper "store --file=${GIT_CREDENTIALS_FILE}"
  GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL_FILE}" git config --global credential.useHttpPath true

  if [ -f "${GIT_CREDENTIALS_FILE}" ] && grep -Fqx "${GIT_CREDENTIALS_LINE}" "${GIT_CREDENTIALS_FILE}" 2>/dev/null; then
    echo "[entrypoint] GitHub token 凭据已存在，跳过写入（${GITHUB_AUTH_TOKEN_SOURCE}）"
    return
  fi

  umask 077
  printf '%s\n' "${GIT_CREDENTIALS_LINE}" > "${GIT_CREDENTIALS_FILE}"
  chmod 600 "${GIT_CREDENTIALS_FILE}"
  echo "[entrypoint] 已自动配置 GitHub token 凭据（${GITHUB_AUTH_TOKEN_SOURCE}）"
}

ensure_github_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    if [ "${OPENCLAW_GITHUB_AUTH_REQUIRED}" = "true" ]; then
      echo "[entrypoint] 缺少 gh 命令，无法进行 GitHub 登录验证（OPENCLAW_GITHUB_AUTH_REQUIRED=true）" >&2
      exit 1
    fi
    echo "[entrypoint] 未安装 gh，跳过 GitHub 登录验证"
    return
  fi

  if [ -z "${GITHUB_AUTH_TOKEN:-}" ]; then
    if [ "${OPENCLAW_GITHUB_AUTH_REQUIRED}" = "true" ]; then
      echo "[entrypoint] 缺少 GH_TOKEN 或 GITHUB_TOKEN，无法进行 GitHub 登录验证（OPENCLAW_GITHUB_AUTH_REQUIRED=true）" >&2
      exit 1
    fi
    echo "[entrypoint] 未提供 GH_TOKEN/GITHUB_TOKEN，跳过 GitHub 登录验证"
    return
  fi

  if gh auth status -h "${GITHUB_HOST}" >/dev/null 2>&1; then
    echo "[entrypoint] GitHub 登录验证通过（gh auth status -h ${GITHUB_HOST}）"
    return
  fi

  umask 077
  if printf '%s' "${GITHUB_AUTH_TOKEN}" | gh auth login --hostname "${GITHUB_HOST}" --with-token >/dev/null 2>&1; then
    echo "[entrypoint] 已完成 GitHub 登录验证（${GITHUB_AUTH_TOKEN_SOURCE} -> gh auth login）"
    return
  fi

  if [ "${OPENCLAW_GITHUB_AUTH_REQUIRED}" = "true" ]; then
    echo "[entrypoint] GitHub 登录验证失败（token 无效或权限不足？）" >&2
    exit 1
  fi

  echo "[entrypoint] GitHub 登录验证失败，继续启动（可设置 OPENCLAW_GITHUB_AUTH_REQUIRED=true 强制失败退出）" >&2
}

apply_base_config() {
  echo "[entrypoint] 正在应用 OpenClaw 基础配置..."
  # 与官方文档一致：避免 gateway 因 mode 未设置而启动受限。
  openclaw config set gateway.mode local

  openclaw config set 'agents.defaults.thinkingDefault' 'medium'
  openclaw config set 'messages.ackReaction' '👀'
  openclaw config set 'messages.ackReactionScope' 'group-all'
  openclaw config set 'messages.removeAckAfterReply' false
  openclaw config set 'commands.config' true
  openclaw config set 'channels.discord.configWrites' true

  # 让 onboard/配置向导能直接看到 Discord channel 可用（避免出现 plugin disabled / not available）。
  openclaw plugins enable discord >/dev/null

  openclaw config set 'channels.discord.groupPolicy' 'allowlist'
  openclaw config unset 'channels.discord.guilds' || true

  mkdir -p "${OPENCLAW_INIT_DIR}"
  : > "${OPENCLAW_BASE_CONFIG_SENTINEL}"
}

build_discord_guilds_json() {
  python3 - <<'PY'
import json
import os
import re


def parse_list(value: str):
    if not value:
        return []
    # 支持逗号和空白字符混合分隔格式。
    return [x for x in re.split(r"[\s,]+", value.strip()) if x]


def valid_discord_id(v: str) -> bool:
    # Discord snowflake 为纯数字，这里只接受数字，避免错误或脏数据写入配置。
    return v.isdigit()


guild_ids = [x for x in parse_list(os.getenv("DISCORD_GUILD_IDS", "")) if valid_discord_id(x)]
user_ids = [x for x in parse_list(os.getenv("DISCORD_USER_IDS", "")) if valid_discord_id(x)]
channel_ids = [x for x in parse_list(os.getenv("DISCORD_CHANNEL_IDS", "")) if valid_discord_id(x)]

cfg = {
    "*": {
        "requireMention": True
    }
}

for gid in guild_ids:
    users = [u if u.startswith("user:") else f"user:{u}" for u in user_ids]
    guild_cfg = {
        "users": users,
        "requireMention": False,
        "channels": {}
    }

    if channel_ids:
        for cid in channel_ids:
            guild_cfg["channels"][cid] = {"allow": True, "requireMention": False}
    else:
        guild_cfg["channels"]["*"] = {"allow": True, "requireMention": False}

    cfg[gid] = guild_cfg

print(json.dumps(cfg, separators=(",", ":")))
PY
}

validate_port
resolve_github_token
prepare_auth_dirs
configure_git_auth
ensure_github_auth

if [ "${OPENCLAW_AUTO_CONFIG}" = "true" ]; then
  if [ "${OPENCLAW_CONFIG_REAPPLY}" = "true" ] || [ ! -f "${OPENCLAW_BASE_CONFIG_SENTINEL}" ]; then
    apply_base_config
  else
    echo "[entrypoint] 检测到已应用基础配置，跳过（可设置 OPENCLAW_CONFIG_REAPPLY=true 重新应用）"
  fi

  maybe_enable_discord_plugin

  if [ -n "${DISCORD_GUILD_IDS:-}" ]; then
    JSON_CONFIG="$(build_discord_guilds_json)"
    echo "[entrypoint] 正在应用 Discord guild allowlist 配置..."
    openclaw config set 'channels.discord.guilds' "${JSON_CONFIG}"
  else
    echo "[entrypoint] DISCORD_GUILD_IDS 为空，跳过 channels.discord.guilds 配置"
  fi
fi

# 若用户传入自定义命令则直接执行，否则默认启动 gateway。
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

exec openclaw gateway --port "${OPENCLAW_PORT}"
