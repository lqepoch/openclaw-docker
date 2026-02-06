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

## 2. 首次初始化（必须先做）

先进入一个临时初始化容器：

```bash
docker run --rm -it \
  -v openclaw-data:/home/node/.openclaw \
  --entrypoint sh \
  lqepoch/openclaw:latest
```

在容器里按顺序执行：

```bash
openclaw config set gateway.mode local
openclaw doctor --fix
openclaw onboard --install-daemon
```

执行 `openclaw onboard --install-daemon` 后通常不会自动退出交互界面。请按下面顺序结束初始化：

1. `Ctrl+C` 中断当前前台流程。
2. 执行 `exit` 退出容器。

说明：
- `gateway.mode local` 不设置时，gateway 可能会被拦截启动。
- `doctor --fix` 用于自动修复建议项。
- `openclaw onboard --install-daemon` 按你的要求保留在初始化流程中。

## 3. 启动服务

端口映射按你的要求：宿主机 `11001-20000` -> 容器 `1001-10000`。

```bash
docker run -d --name openclaw \
  --restart unless-stopped \
  -v openclaw-data:/home/node/.openclaw \
  -e DISCORD_GUILD_IDS="<YOUR_PRIVATE_GUILD_IDS>" \
  -e DISCORD_USER_IDS="<YOUR_PRIVATE_USER_IDS>" \
  -p 18789:18789 \
  -p 13000:3000 \
  -p 13001:3001 \
  -p 14000:4000 \
  -p 14001:4001 \
  lqepoch/openclaw:latest
```

说明：
- `DISCORD_*_IDS` 支持逗号或空格分隔多个 ID。
- 上述区间映射默认是 TCP；如需 UDP，请额外加 `-p 11001-20000:1001-10000/udp`。

## 4. 运行检查

```bash
docker ps
docker logs -f openclaw
```

如果 `docker ps` 看不到容器，检查：

```bash
docker ps -a
docker logs --tail=200 openclaw
```

## 5. 进入容器继续操作

```bash
docker exec -it openclaw sh
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
