# OpenClaw Docker 教程（docker run）

目标：GitHub Actions 构建并推送镜像到 Docker Hub；服务器侧只需要 `docker pull` + `docker run`。

重要安全提示：不要把 `GH_TOKEN` / `DISCORD_BOT_TOKEN` / `CLOUDFLARE_API_TOKEN` 贴到任何聊天/Issue/日志里；一旦泄露请立刻撤销并重发。

## 1) 拉取镜像

```bash
docker pull lqepoch/openclaw:latest
```

## 2) 准备持久化 volume

OpenClaw 配置目录在容器内：`/home/node/.openclaw`。推荐用 named volume：

```bash
docker volume create openclaw-data-openai-1
```

## 3) `gateway.mode=local` 是什么？

`gateway.mode=local` 是 OpenClaw 的网关运行模式设置：让 gateway 以 “local” 模式启动（通常用于本机/本容器可达的使用方式）。不设置时，gateway 可能无法正常启动或行为受限，所以本镜像会在启动时自动写入一次（重复写入无副作用）。

## 4) 首次初始化（交互式）

不要用 `--entrypoint sh`（会绕过镜像的 entrypoint，自动配置不会执行）。

```bash
docker run --rm -it \
  -v openclaw-data-openai-1:/home/node/.openclaw \
  -e GH_TOKEN="***" \
  -e DISCORD_BOT_TOKEN="***" \
  -e DISCORD_GUILD_IDS="1467171769424281802" \
  -e DISCORD_USER_IDS="705990299771732028" \
  lqepoch/openclaw:latest sh
```

容器内执行：

```bash
gh auth status -h github.com || printf '%s' "${GH_TOKEN}" | gh auth login --hostname github.com --with-token
openclaw doctor --fix
openclaw onboard --install-daemon
```

退出容器：

```bash
exit
```

## 5) 常驻运行（daemon）

如果你要从宿主机访问 `18789`，建议显式设置 `OPENCLAW_GATEWAY_BIND=lan`（让容器内监听 `0.0.0.0`）。

```bash
docker run -d --name openclaw-data-openai-1 \
  --restart unless-stopped \
  -v openclaw-data-openai-1:/home/node/.openclaw \
  -e GH_TOKEN="***" \
  -e DISCORD_BOT_TOKEN="***" \
  -e DISCORD_GUILD_IDS="1467171769424281802" \
  -e DISCORD_USER_IDS="705990299771732028" \
  -e OPENCLAW_GATEWAY_BIND=lan \
  -p 18789:18789 \
  lqepoch/openclaw:latest
```

## 6) 本镜像启动时会自动写入哪些配置？

`docker/entrypoint.sh` 会按以下顺序写入（尽量贴近你给的清单）：

1. `openclaw config set gateway.mode local`
2. 检测到 Discord 环境变量时启用插件：`openclaw plugins enable discord`
3. Discord allowlist（单 guild + 单 user）：
   - `openclaw config set 'channels.discord.groupPolicy' 'allowlist'`
   - `openclaw config unset 'channels.discord.guilds'`
   - `openclaw config set --json 'channels.discord.guilds' "$JSON_CONFIG"`（若不支持 `--json` 会自动回退到普通 `config set`）
4. 其余偏好项：
   - `agents.defaults.thinkingDefault=medium`
   - `messages.ackReaction=👀`
   - `messages.ackReactionScope=group-all`
   - `messages.removeAckAfterReply=false`
   - `commands.config=true`
   - `channels.discord.configWrites=true`

## 7) 检查与排障

查看日志：

```bash
docker logs -f openclaw-data-openai-1
```

检查 Discord guilds 配置：

```bash
docker exec -it openclaw-data-openai-1 sh -lc "openclaw config get --json 'channels.discord.guilds'"
```

如果你修改了配置需要生效：
- 最稳妥方式：`docker restart openclaw-data-openai-1`
- 或进入容器尝试：`openclaw gateway restart`（若你的 OpenClaw 版本支持该命令）
