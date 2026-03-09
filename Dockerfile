FROM ubuntu:24.04

# 容器级默认变量：
# - OPENCLAW_HOME：非 root 用户的 OpenClaw 运行配置目录。
# - OPENCLAW_PORT：gateway 监听端口，可通过 -e OPENCLAW_PORT=xxxx 在运行时覆盖。
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    HOME=/home/node \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    PATH=/opt/venv/bin:$PATH \
    OPENCLAW_HOME=/home/node/.openclaw \
    XDG_CONFIG_HOME=/home/node/.openclaw/.config \
    GH_CONFIG_DIR=/home/node/.openclaw/.config/gh \
    OPENCLAW_PORT=18789

ARG OPENCLAW_VERSION=latest

# 使用 apt 安装运行时与工具链，并安装 Node.js 24 + GitHub CLI（gh）。
# - nodejs (v24)：openclaw CLI 依赖（通过 NodeSource 安装）。
# - python3/pip：Python 运行时与 boto3 依赖。
# - git/git-lfs/awscli(v2)：CI/CD 与仓库操作工具。
# - gh：GitHub CLI（按官方 apt 源安装）。
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gpg \
      git \
      git-lfs \
      mawk \
      python3 \
      python3-pip \
      python3-venv \
      tzdata \
      unzip && \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs gh; \
    rm -rf /var/lib/apt/lists/*

# 安装 AWS CLI v2（Ubuntu apt 的 awscli 往往是 v1）。
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64) aws_arch="x86_64" ;; \
      aarch64|arm64) aws_arch="aarch64" ;; \
      *) echo "Unsupported arch for AWS CLI v2: ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/aws /tmp/awscliv2.zip; \
    aws --version

# 全局安装 OpenClaw CLI / ClawHub / Gemini CLI，并安装 AWS 自动化常用的 boto3。
RUN node --version && npm --version && \
    npm install -g --no-audit "openclaw@${OPENCLAW_VERSION}" && \
    npm install -g --no-audit clawhub && \
    npm install -g --no-audit @google/gemini-cli && \
    npm cache clean --force && \
    python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip boto3 && \
    python3 --version && pip3 --version

# 在系统范围启用 Git LFS。
RUN git lfs install --system

# 创建非 root 用户，提升运行安全性。
RUN set -eux; \
    if ! id -u node >/dev/null 2>&1; then \
      uid=1000; \
      while getent passwd "${uid}" >/dev/null; do uid="$((uid+1))"; done; \
      useradd -m -u "${uid}" -s /usr/sbin/nologin node; \
    fi; \
    mkdir -p "${OPENCLAW_HOME}" "${XDG_CONFIG_HOME}" "${GH_CONFIG_DIR}"; \
    chown -R node:node /home/node; \
    chmod 700 "${OPENCLAW_HOME}"

# 启动脚本会自动应用 OpenClaw 默认配置与可选 Discord allowlist JSON，
# 若未传入自定义命令，则默认启动 openclaw gateway。
COPY docker/entrypoint.sh /usr/local/bin/openclaw-entrypoint.sh
RUN chmod +x /usr/local/bin/openclaw-entrypoint.sh

WORKDIR /home/node/workspace

# 确保非 root 用户在 /workspace 下可写（避免在容器内操作时报权限错误）。
RUN mkdir -p /home/node/workspace /home/node/.cache && chown -R node:node /home/node

USER node

# OpenClaw 官方 Docker 文档默认 gateway 端口为 18789。
EXPOSE 18789

# 基础健康检查：检查本地 gateway 端口是否可连通。
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD python3 -c "import os,socket; port=int(os.getenv('OPENCLAW_PORT','18789')); s=socket.create_connection(('127.0.0.1', port), timeout=3); s.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'); data=s.recv(32); s.close(); raise SystemExit(0 if data.startswith(b'HTTP/') else 1)" || exit 1

ENTRYPOINT ["/usr/local/bin/openclaw-entrypoint.sh"]
CMD []
