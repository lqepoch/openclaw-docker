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
    OPENCLAW_HOME=/home/node/.openclaw \
    OPENCLAW_PORT=18789

ARG OPENCLAW_VERSION=latest
ARG GH_VERSION=latest
ARG TARGETOS
ARG TARGETARCH

# 使用 dnf 安装运行时与工具链（包管理优先）：
# - nodejs24：openclaw CLI 依赖。
# - python3.13/pip：Python 运行时与 boto3 依赖。
# - git/git-lfs/awscli-2：你要求的 CI/CD 与仓库操作工具。
RUN dnf install -y --setopt=install_weak_deps=False \
      nodejs24 \
      nodejs24-npm \
      python3.13 \
      python3.13-pip \
      git \
      git-lfs \
      awscli-2 \
      ca-certificates \
      curl-minimal \
      coreutils \
      findutils \
      grep \
      gzip \
      tar \
      shadow-utils && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# 安装 GitHub CLI（gh）
# Amazon Linux 的 repo 不一定包含 gh，因此使用官方 release 的静态二进制包安装。
RUN set -eux; \
    case "${TARGETARCH:-$(uname -m)}" in \
      amd64|x86_64) GH_ARCH="amd64" ;; \
      arm64|aarch64) GH_ARCH="arm64" ;; \
      *) echo "Unsupported arch for gh: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
    esac; \
    if [ "${GH_VERSION}" = "latest" ]; then \
      PYBIN="$(command -v python3.13 || command -v python3 || command -v python)"; \
      echo "Resolve GH_VERSION=latest via ${PYBIN}"; \
      GH_VERSION="$("${PYBIN}" - <<'PY'\nimport json\nimport sys\nimport urllib.request\n\nurl = 'https://api.github.com/repos/cli/cli/releases/latest'\nreq = urllib.request.Request(url, headers={'User-Agent': 'openclaw-docker'})\nwith urllib.request.urlopen(req, timeout=30) as resp:\n    data = json.load(resp)\ntag = data.get('tag_name') or ''\nif tag.startswith('v'):\n    tag = tag[1:]\nif not tag:\n    print('Failed to resolve gh latest version', file=sys.stderr)\n    sys.exit(1)\nprint(tag)\nPY)"; \
    fi; \
    tmp="$(mktemp -d)"; \
    cd "${tmp}"; \
    gh_tgz="gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz"; \
    gh_url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${gh_tgz}"; \
    sums_url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"; \
    curl -fsSLO "${gh_url}"; \
    curl -fsSLO "${sums_url}"; \
    grep " ${gh_tgz}\$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c -; \
    tar -xzf "${gh_tgz}"; \
    install -m 0755 gh_"${GH_VERSION}"_linux_"${GH_ARCH}"/bin/gh /usr/local/bin/gh; \
    /usr/local/bin/gh --version; \
    cd /; \
    rm -rf "${tmp}"

# 全局安装 OpenClaw CLI，并安装 AWS 自动化常用的 boto3。
RUN if ! command -v node >/dev/null 2>&1 && command -v node-24 >/dev/null 2>&1; then ln -sf /usr/bin/node-24 /usr/local/bin/node; fi && \
    if ! command -v npm >/dev/null 2>&1 && command -v npm-24 >/dev/null 2>&1; then ln -sf /usr/bin/npm-24 /usr/local/bin/npm; fi && \
    node --version && npm --version && \
    npm install -g --omit=dev --no-audit "openclaw@${OPENCLAW_VERSION}" && \
    npm cache clean --force && \
    python3.13 -m pip install --no-cache-dir --upgrade pip boto3

# 统一 python/pip 命令名，避免版本差异导致命令不一致。
RUN ln -sf /usr/bin/python3.13 /usr/local/bin/python3 && \
    ln -sf /usr/bin/python3.13 /usr/local/bin/python && \
    ln -sf /usr/bin/pip3.13 /usr/local/bin/pip3 && \
    ln -sf /usr/bin/pip3.13 /usr/local/bin/pip

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
  CMD python3.13 -c "import os,socket; s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1', int(os.getenv('OPENCLAW_PORT','18789')))); s.close()" || exit 1

ENTRYPOINT ["/usr/local/bin/openclaw-entrypoint.sh"]
CMD []
