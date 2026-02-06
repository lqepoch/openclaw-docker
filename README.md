# openclaw-docker

用于构建和发布 OpenClaw Docker 镜像（Amazon Linux 2023，`dnf` 包管理优先）。
镜像内预装：Node.js 24、Python 3.13、`git-lfs`、AWS CLI v2、`boto3`、`openclaw` CLI。

## 1. 文件说明

- `Dockerfile`：镜像构建定义（已加详细注释）
- `docker/entrypoint.sh`：容器启动时自动执行 OpenClaw 配置
- `.github/workflows/docker-publish.yml`：自动构建并推送 Docker Hub + GHCR

## 2. 构建镜像

```bash
docker build -t openclaw:local .
```

## 2.1 安全加固（已内置）

- 默认使用非 root 用户（UID 1000）运行。
- 启动脚本会校验 `OPENCLAW_PORT`（必须是 `1-65535` 的数字）。
- Discord 的 `guild/user/channel` ID 仅接受纯数字，非法值会被自动过滤。
- 镜像安装过程关闭弱依赖并清理包缓存，减少攻击面。
- 已内置 `HEALTHCHECK`，用于检测 gateway 端口可用性。

## 3. 启动时自动配置 OpenClaw（你要求的参数）

容器启动时会自动执行以下配置：

```bash
openclaw config set 'agents.defaults.thinkingDefault' 'medium'
openclaw config set 'messages.ackReaction' '👀'
openclaw config set 'messages.ackReactionScope' 'group-all'
openclaw config set 'messages.removeAckAfterReply' false
openclaw config set 'commands.config' true
openclaw config set 'channels.discord.configWrites' true

openclaw config set 'channels.discord.groupPolicy' 'allowlist'
openclaw config unset 'channels.discord.guilds'
```

然后根据环境变量动态构建并写入 `channels.discord.guilds` JSON（支持多个 guild/user/channel ID）。

## 4. Discord allowlist 配置（支持多个 ID）

### 4.1 环境变量

- `DISCORD_GUILD_IDS`：多个 guild id，支持逗号或空格分隔
- `DISCORD_USER_IDS`：多个 user id，支持逗号或空格分隔
- `DISCORD_CHANNEL_IDS`：多个 channel id，支持逗号或空格分隔

兼容单值变量（只填一个时也可用）：
- `DISCORD_GUILD_ID`
- `DISCORD_USER_ID`
- `DISCORD_CHANNEL_ID`

### 4.2 启动示例（多 ID）

```bash
docker run --rm -it \
  -e DISCORD_GUILD_IDS="111111111111111111,222222222222222222" \
  -e DISCORD_USER_IDS="333333333333333333 444444444444444444" \
  -e DISCORD_CHANNEL_IDS="555555555555555555,666666666666666666" \
  -p 18789:18789 \
  openclaw:local
```

脚本会生成等价于你给出的 JSON 结构：
- 默认 `"*": { "requireMention": true }`
- 每个 guild 下：
  - `users: ["user:<id>", ...]`
  - `requireMention: false`
  - `channels` 按你传入的 channel ID 全量 allow

如果没传 `DISCORD_CHANNEL_IDS`，会自动设置该 guild 的 `channels."*"` 为 allow。
如果传入了非数字 ID，会被自动忽略（不会写入配置）。

## 5. 端口映射教程（你要的双区间）

你要求的映射是：
- 原服务器 A：`3001-4000` -> 容器 `3001-4000`
- 原服务器 B：`4001-5000` -> 容器 `4001-5000`

单机 Docker 启动命令如下（TCP）：

```bash
docker run --rm -it \
  -e DISCORD_GUILD_IDS="111111111111111111" \
  -e DISCORD_USER_IDS="333333333333333333" \
  -p 18789:18789 \
  -p 3001-4000:3001-4000/tcp \
  -p 4001-5000:4001-5000/tcp \
  openclaw:local
```

如果业务还需要 UDP，再补：

```bash
-p 3001-4000:3001-4000/udp \
-p 4001-5000:4001-5000/udp
```

## 6. 什么时候配置最合适

- 构建阶段（`docker build`）：只安装依赖和 CLI，不写死你的 Discord ID。
- 启动阶段（`docker run`）：通过环境变量注入 guild/user/channel ID，entrypoint 自动写配置。
- 原因：ID 属于运行环境数据，不应固化在镜像里，便于同一镜像部署到不同服务器/群组。

## 7. 关闭自动配置（可选）

如果你想手动管理配置：

```bash
docker run --rm -it \
  -e OPENCLAW_AUTO_CONFIG=false \
  -p 18789:18789 \
  openclaw:local
```

## 7.1 安全启动参数（推荐）

生产环境建议增加以下 Docker 安全参数：

```bash
docker run --rm -it \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop=ALL \
  --security-opt no-new-privileges:true \
  --pids-limit 256 \
  -p 18789:18789 \
  openclaw:local
```

## 8. GitHub Actions 自动发布

工作流：`.github/workflows/docker-publish.yml`

触发条件：
- push 到 `main`
- push tag（如 `v1.0.0`）
- 手动触发（`workflow_dispatch`）

构建与发布策略（已启用）：
- 并行分机（两个 runner）分别构建并测试：`linux/amd64`、`linux/arm64`。
- 两个架构都测试成功后，才会进入最终推送步骤（Docker Hub + GHCR）。
- 任一架构构建或测试失败：不会推送任何镜像标签。
- 内置测试包含：
  - 基础命令测试（`node/npm/python/pip/git/aws/openclaw --version`）
  - 端口校验测试（`OPENCLAW_PORT=70000` 必须失败）
- 构建缓存使用 `type=gha`，同一 Dockerfile 结构下会持续复用缓存层。

需要仓库 Secrets：
- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

推送目标：
- `docker.io/<DOCKERHUB_USERNAME>/openclaw`
- `ghcr.io/<GITHUB_OWNER>/openclaw`
