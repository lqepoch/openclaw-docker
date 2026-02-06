FROM ubuntu:24.04

# 容器级默认变量：
# - OPENCLAW_HOME：非 root 用户的 OpenClaw 运行配置目录。
# - OPENCLAW_PORT：gateway 监听端口，可通过 -e OPENCLAW_PORT=xxxx 在运行时覆盖。
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    OPENCLAW_HOME=/home/node/.openclaw \
    GH_CONFIG_DIR=/home/node/.openclaw/gh \
    OPENCLAW_PORT=18789

ARG OPENCLAW_VERSION=latest
ARG NODE_MAJOR=24
ARG GH_VERSION=2.76.0
ARG GIT_LFS_VERSION=3.7.0

# 使用 Ubuntu 24.04（最新 LTS）并通过 apt 安装基础工具链。
# Node.js 通过 nodejs.org 官方 tarball 安装，避免第三方 apt 源不稳定导致构建失败。
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      xz-utils && \
    if ! apt-get install -y --no-install-recommends \
      git \
      git-lfs \
      awscli \
      python3 \
      python3-venv \
      python3-pip \
      gh; then \
      apt-get install -y --no-install-recommends \
        git \
        awscli \
        python3 \
        python3-venv \
        python3-pip; \
      arch="$(dpkg --print-architecture)"; \
      case "$arch" in \
        amd64|arm64) dl_arch="$arch" ;; \
        *) echo "unsupported arch for gh/git-lfs tarball: $arch" >&2; exit 1 ;; \
      esac; \
      curl -fsSLo /tmp/gh.tar.gz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${dl_arch}.tar.gz"; \
      tar -xzf /tmp/gh.tar.gz -C /tmp; \
      install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${dl_arch}/bin/gh" /usr/local/bin/gh; \
      rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_${dl_arch}"; \
      curl -fsSLo /tmp/git-lfs.tar.gz "https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/git-lfs-linux-${dl_arch}-v${GIT_LFS_VERSION}.tar.gz"; \
      mkdir -p /tmp/git-lfs; \
      tar -xzf /tmp/git-lfs.tar.gz -C /tmp/git-lfs; \
      lfs_install_script="$(find /tmp/git-lfs -maxdepth 3 -type f -name install.sh | head -n1)"; \
      [ -n "$lfs_install_script" ] && bash "$lfs_install_script"; \
      rm -rf /tmp/git-lfs /tmp/git-lfs.tar.gz; \
    fi && \
    python3 - <<'PY' >/tmp/node-version.txt
import json
import os
import urllib.request

major = int(os.environ.get("NODE_MAJOR", "24"))
with urllib.request.urlopen("https://nodejs.org/dist/index.json") as r:
    data = json.load(r)

best = None
best_str = None
for row in data:
    v = row.get("version", "").lstrip("v")
    parts = v.split(".")
    if len(parts) != 3:
        continue
    try:
        m, n, p = (int(parts[0]), int(parts[1]), int(parts[2]))
    except ValueError:
        continue
    if m != major:
        continue
    tup = (m, n, p)
    if best is None or tup > best:
        best = tup
        best_str = v

if not best_str:
    raise SystemExit(f"no Node.js versions found for major {major}")
print(best_str)
PY

RUN NODE_VERSION="$(cat /tmp/node-version.txt)" && \
    rm -f /tmp/node-version.txt && \
    arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) node_arch="x64" ;; \
      arm64) node_arch="arm64" ;; \
      *) echo "unsupported arch for Node.js tarball: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" && \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 && \
    rm -f /tmp/node.tar.xz && \
    rm -rf /var/lib/apt/lists/*

# 全局安装 OpenClaw CLI，并配置 python/pip 运行时。
RUN git lfs install --system && \
    node --version && npm --version && \
    python3 -m pip install --no-cache-dir boto3 && \
    ln -sf /usr/bin/python3 /usr/local/bin/python && \
    npm install -g --omit=dev --no-audit "openclaw@${OPENCLAW_VERSION}" && \
    npm cache clean --force

# 创建非 root 用户，提升运行安全性。
RUN useradd -m -u 1000 -s /usr/sbin/nologin node && \
    mkdir -p "${OPENCLAW_HOME}" && \
    chown -R node:node /home/node && \
    chmod 700 "${OPENCLAW_HOME}"

# 启动脚本会自动应用你要求的 OpenClaw 默认配置与可选 Discord allowlist JSON，
# 若未传入自定义命令，则默认启动 `openclaw gateway`。
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/openclaw-entrypoint.sh

WORKDIR /workspace
USER node

# OpenClaw 官方 Docker 文档默认 gateway 端口为 18789。
EXPOSE 18789

# 基础健康检查：检查本地 gateway 端口是否可连通。
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD python3 -c "import os,socket; s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1', int(os.getenv('OPENCLAW_PORT','18789')))); s.close()" || exit 1

ENTRYPOINT ["/usr/local/bin/openclaw-entrypoint.sh"]
CMD []
