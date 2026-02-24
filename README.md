# OpenClaw Docker 使用教程

本教程只讲如何使用镜像部署与初始化 OpenClaw。

## 0. 拉取镜像

```bash
docker pull lqepoch/openclaw:latest
```

## 1. 准备持久化数据（推荐）

OpenClaw 配置目录在容器内是 `/home/node/.openclaw`。建议使用 named volume 持久化，避免删容器后配置丢失。

可选方式 A：手动先创建 volume

```bash
docker volume create openclaw-data
```

可选方式 B：不手动创建，后续 `docker run -v openclaw-data:/home/node/.openclaw ...` 会自动创建同名 volume。

## 1.5（推荐）. 用 Compose 简化启动

本仓库提供 `compose.yaml` + `.env.example`，推荐用 `docker compose` 管理环境变量与 volume，避免命令行越来越长。

```bash
cp .env.example .env
# 编辑 .env 填入 GH_TOKEN / DISCORD_BOT_TOKEN 等
```

## 2. 首次初始化（必须先做）

先进入一个临时初始化容器：

```bash
docker compose run --rm -it openclaw sh
```

在容器里先做 GitHub 登录验证（必须先做）：

```bash
gh auth status -h github.com || printf '%s' "${GH_TOKEN}" | gh auth login --hostname github.com --with-token
```

说明：镜像默认将 `GH_CONFIG_DIR` 设置为 `/home/node/.openclaw/.config/gh`，因此这一步的 `gh auth` 状态会随 `openclaw-data` volume 持久化。

然后按顺序执行：

```bash
openclaw config set gateway.mode local
openclaw doctor --fix
openclaw onboard --install-daemon
```

如果你希望通过 `openclaw onboard` 配置 Discord，请确保镜像里包含 Discord channel（本仓库镜像默认包含）。

说明：
- 本镜像启动时会自动设置 `gateway.mode=local`，并启用 discord 插件，避免 `openclaw onboard` 里出现 “discord plugin not available / plugin disabled”。
- 若你打算用 Discord，推荐在启动容器时传入 `DISCORD_BOT_TOKEN`（或 `DISCORD_GUILD_IDS` 等 allowlist 变量），本镜像的 `docker/entrypoint.sh` 会在启动 gateway 前应用 allowlist 配置。
- 不要使用 `--entrypoint sh` 进入容器：这会绕过镜像自带的 entrypoint，导致自动配置（含启用 discord 插件）不生效；请使用 `... lqepoch/openclaw:latest sh` 或 `docker compose run ... sh`。
- 若你在“容器已运行、gateway 已启动”之后才执行 `openclaw plugins enable discord`，需要重启 gateway（最简单是重启容器）才能生效（插件启用是写入配置，gateway 不会热加载）。

执行 `openclaw onboard --install-daemon` 后通常不会自动退出交互界面。请按下面顺序结束初始化：

1. `Ctrl+C` 中断当前前台流程。
2. 执行 `exit` 退出容器。

说明：
- `gateway.mode local` 不设置时，gateway 可能会被拦截启动；本镜像会在启动时自动设置一次，手动执行也不会有副作用。
- `doctor --fix` 用于自动修复建议项。
- `openclaw onboard --install-daemon` 按你的要求保留在初始化流程中。

## 3. 启动服务

默认只映射 gateway 端口 `18789`。如需额外端口（例如 browser/canvas/node host 相关），在 `compose.yaml` 里按需添加 `ports:` 映射即可。

```bash
docker compose up -d
```

说明：
- 推荐使用 `GH_TOKEN`（GitHub CLI 的标准变量），也兼容 `GITHUB_TOKEN`。
- 只要传入 `GH_TOKEN`/`GITHUB_TOKEN`，容器启动时会自动完成：
  - GitHub HTTPS 凭据配置（写入 `~/.git-credentials` 并启用 `credential.helper store`）。
  - GitHub 登录验证（`gh auth status`，必要时自动 `gh auth login --with-token`）。
- 从本镜像版本起，`gh` 与 `git` 认证文件默认落在 `/home/node/.openclaw` 下，可随挂载 volume 持久化。
- `OPENCLAW_GITHUB_AUTH_REQUIRED=true` 会在缺少 token 或验证失败时直接退出，避免后续初始化步骤失败才暴露问题。
- `DISCORD_*_IDS` 支持逗号或空格分隔多个 ID。
- 如需映射端口区间或 UDP，在 `compose.yaml` 里添加对应的 `ports:`（例如 `"11001-20000:1001-10000/udp"`）。

## 4. 运行检查

```bash
docker compose ps
docker compose logs -f openclaw
```

如果 `docker compose ps` 看不到容器，检查：

```bash
docker compose ps -a
docker compose logs --tail=200 openclaw
```

## 5. 进入容器继续操作

```bash
docker compose exec openclaw sh
```

例如继续执行：

```bash
openclaw onboard --install-daemon
```

## 6. 常用运维命令

停止/启动：

```bash
docker stop openclaw
docker start openclaw
```

重启：

```bash
docker restart openclaw
```

删除容器（不删除配置卷）：

```bash
docker rm -f openclaw
```

升级镜像：

```bash
docker pull lqepoch/openclaw:latest
docker rm -f openclaw
# 然后按第 3 节命令重新启动
```

## 7. 自动更新镜像（北京时间每天 06:00）

推荐使用 Watchtower 定时检查并自动重建容器。

先启动 Watchtower（只监控一个容器 `openclaw`）：

```bash
docker run -d \
  --name watchtower \
  --restart unless-stopped \
  -e TZ=Asia/Shanghai \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower \
  --schedule "0 0 6 * * *" \
  --cleanup \
  --rolling-restart \
  openclaw
```

如果你要同时监控多个容器（例如 `openclaw-data-openai-1` 和 `openclaw-data-google`），把容器名都放到命令末尾：

```bash
docker run -d \
  --name watchtower \
  --restart unless-stopped \
  -e TZ=Asia/Shanghai \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower \
  --schedule "0 0 6 * * *" \
  --cleanup \
  --rolling-restart \
  openclaw-data-openai-1 openclaw-data-google
```

查看自动更新日志：

```bash
docker logs -f watchtower
```
