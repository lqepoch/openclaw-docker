FROM public.ecr.aws/amazonlinux/amazonlinux:2023

# 容器级默认变量：
# - OPENCLAW_HOME：非 root 用户的 OpenClaw 运行配置目录。
# - OPENCLAW_PORT：gateway 监听端口，可通过 -e OPENCLAW_PORT=xxxx 在运行时覆盖。
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    OPENCLAW_HOME=/home/node/.openclaw \
    OPENCLAW_PORT=18789

ARG OPENCLAW_VERSION=latest
ARG TARGETOS
ARG TARGETARCH
ARG NODE_MAJOR=20

# 使用 dnf 安装运行时与工具链（包管理优先）：
# - python3/pip：Python 运行时与 boto3 依赖。
# - git/git-lfs：你要求的 CI/CD 与仓库操作工具。
RUN set -eux; \
    dnf install -y --setopt=install_weak_deps=False \
      python3 \
      python3-pip \
      git \
      git-lfs \
      ca-certificates \
      curl-minimal \
      findutils \
      grep \
      gzip \
      tar \
      unzip \
      xz \
      shadow-utils; \
    python3 --version; \
    dnf clean all; \
    rm -rf /var/cache/dnf

# 安装 Node.js 20+（openclaw CLI 依赖）
# 避免 Amazon Linux repo 的 nodejs 版本漂移，使用 Node.js 官方二进制发行版。
RUN set -eux; \
    case "${TARGETARCH:-$(uname -m)}" in \
      amd64|x86_64) NODE_ARCH="x64" ;; \
      arm64|aarch64) NODE_ARCH="arm64" ;; \
      *) echo "Unsupported arch for node: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
    esac; \
    PYBIN="$(command -v python3 || command -v python)"; \
    NODE_VERSION="$("${PYBIN}" - <<'PY'\nimport json\nimport sys\nimport urllib.request\n\nmajor = int(sys.argv[1])\nurl = 'https://nodejs.org/dist/index.json'\nreq = urllib.request.Request(url, headers={'User-Agent': 'openclaw-docker'})\nwith urllib.request.urlopen(req, timeout=30) as resp:\n    data = json.load(resp)\n\n# index.json 按版本从新到旧排序：选第一个匹配 major 的版本。\nfor item in data:\n    v = (item.get('version') or '').lstrip('v')\n    if v.split('.', 1)[0].isdigit() and int(v.split('.', 1)[0]) == major:\n        print(v)\n        raise SystemExit(0)\n\nprint(f'Failed to resolve node v{major} version', file=sys.stderr)\nraise SystemExit(1)\nPY\n\"${NODE_MAJOR}\")"; \
    tmp="$(mktemp -d)"; \
    cd "${tmp}"; \
    node_tgz="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    curl -fsSLO "${base}/${node_tgz}"; \
    curl -fsSLO "${base}/SHASUMS256.txt"; \
    grep " ${node_tgz}\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "${node_tgz}" -C /usr/local --strip-components=1; \
    /usr/local/bin/node --version; \
    /usr/local/bin/npm --version; \
    cd /; \
    rm -rf "${tmp}"

# 安装 AWS CLI v2（官方安装包，避免不同 Amazon Linux repo 包名差异导致失败）
RUN set -eux; \
    case "${TARGETARCH:-$(uname -m)}" in \
      amd64|x86_64) AWS_ARCH="x86_64" ;; \
      arm64|aarch64) AWS_ARCH="aarch64" ;; \
      *) echo "Unsupported arch for awscli: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; \
    cd "${tmp}"; \
    curl -fsSLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"; \
    unzip -q awscliv2.zip; \
    ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update; \
    /usr/local/bin/aws --version; \
    cd /; \
    rm -rf "${tmp}"

# 安装 GitHub CLI（gh）
# 按 GitHub 官方 RPM 指南安装（兼容 Amazon Linux）。
RUN set -eux; \
    dnf install -y --setopt=install_weak_deps=False 'dnf-command(config-manager)'; \
    dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo; \
    dnf install -y --setopt=install_weak_deps=False gh; \
    gh --version; \
    dnf clean all; \
    rm -rf /var/cache/dnf

# 全局安装 OpenClaw CLI，并安装 AWS 自动化常用的 boto3。
RUN node --version && npm --version && \
    npm install -g --omit=dev --no-audit "openclaw@${OPENCLAW_VERSION}" && \
    npm cache clean --force && \
    python3 -m pip install --no-cache-dir --upgrade pip boto3

# 统一 python/pip 命令名，避免版本差异导致命令不一致。
RUN ln -sf /usr/bin/python3 /usr/local/bin/python3 && \
    ln -sf /usr/bin/python3 /usr/local/bin/python && \
    ln -sf /usr/bin/pip3 /usr/local/bin/pip3 && \
    ln -sf /usr/bin/pip3 /usr/local/bin/pip

# 在系统范围启用 Git LFS。
RUN git lfs install --system

# 创建非 root 用户，提升运行安全性。
RUN useradd -m -u 1000 -s /sbin/nologin node && \
    mkdir -p "${OPENCLAW_HOME}" && \
    chown -R node:node /home/node && \
    chmod 700 "${OPENCLAW_HOME}"

# 启动脚本会自动应用你要求的 OpenClaw 默认配置与可选 Discord allowlist JSON，
# 若未传入自定义命令，则默认启动 `openclaw gateway`。
COPY docker/entrypoint.sh /usr/local/bin/openclaw-entrypoint.sh
RUN chmod +x /usr/local/bin/openclaw-entrypoint.sh

WORKDIR /workspace
USER node

# OpenClaw 官方 Docker 文档默认 gateway 端口为 18789。
EXPOSE 18789

# 基础健康检查：检查本地 gateway 端口是否可连通。
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD python3 -c "import os,socket; s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1', int(os.getenv('OPENCLAW_PORT','18789')))); s.close()" || exit 1

ENTRYPOINT ["/usr/local/bin/openclaw-entrypoint.sh"]
CMD []
