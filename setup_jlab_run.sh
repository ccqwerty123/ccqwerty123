#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] exit=$? line=$LINENO: $BASH_COMMAND" >&2' ERR

# ========= 可调参数 =========
PROFILE="${PROFILE:-1}"                 # 1=Jupyter直连(默认), 2=Jupyter+Nginx, 3=Jupyter+Caddy
INDEX_URL="${INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
INDEX_URL="${INDEX_URL:-https://mirrors.cloud.tencent.com/pypi/simple}"
PORT="${PORT:-8888}"
FRONT_PORT="${FRONT_PORT:-8080}"
ROOT_DIR="${ROOT_DIR:-$PWD}"
EXTRA_JUPYTER_ARGS="${EXTRA_JUPYTER_ARGS:-}"
USE_SYSTEM_PIP="${USE_SYSTEM_PIP:-0}"   # 1=用系统pip并加 --break-system-packages（不推荐）

# venv 目录
if [[ $EUID -eq 0 ]]; then DEFAULT_VENV_DIR="/opt/jlab-venv"; else DEFAULT_VENV_DIR="$HOME/.local/jlab-venv"; fi
VENV_DIR="${VENV_DIR:-$DEFAULT_VENV_DIR}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt; PKG_INSTALL='apt-get update -y && apt-get install -y';
  elif command -v dnf >/dev/null 2>&1; then PKG_MGR=dnf; PKG_INSTALL='dnf install -y';
  elif command -v yum >/dev/null 2>&1; then PKG_MGR=yum; PKG_INSTALL='yum install -y';
  elif command -v apk >/dev/null 2>&1; then PKG_MGR=apk; PKG_INSTALL='apk add --no-cache';
  else PKG_MGR=unknown; PKG_INSTALL='echo'; fi
}

ensure_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# ------- pip 安装尝试（带镜像/策略回退）-------
pip_install_with_mirror_fallback() {
  # $1... = packages
  local pkgs=("$@")
  local candidates=(
    "$INDEX_URL"
    "https://mirrors.aliyun.com/pypi/simple/"
    "https://pypi.tuna.tsinghua.edu.cn/simple"
    "https://pypi.org/simple"
    "https://pypi.mirrors.ustc.edu.cn/simple/"
    "https://pypi.doubanio.com/simple/"
  )

  # 1) wheels-only（不构建），优先稳定与速度
  for idx in "${candidates[@]}"; do
    log "pip install (wheels only) via: $idx"
    if "$PIP_BIN" install --only-binary=:all: -i "$idx" "${pkgs[@]}"; then
      EFFECTIVE_INDEX="$idx"
      return 0
    fi
  done

  # 2) 允许构建（若必须），注意：某些镜像可能缺 setuptools；此步尽量最后再试
  for idx in "${candidates[@]}"; do
    log "pip install (allow build) via: $idx"
    if "$PIP_BIN" install -i "$idx" "${pkgs[@]}"; then
      EFFECTIVE_INDEX="$idx"
      return 0
    fi
  done

  return 1
}

# ========= 准备 Python/venv =========
prepare_python_env() {
  ensure_cmd python3

  if [[ "$USE_SYSTEM_PIP" == "1" ]]; then
    log "使用系统 pip（将加 --break-system-packages）"
    PIP_BREAK="--break-system-packages"
    PYTHON_BIN="$(command -v python3)"
    PIP_BIN="$PYTHON_BIN -m pip"
    JUPYTER_BIN="$(command -v jupyter || true)"
  else
    log "创建/复用 venv: $VENV_DIR"
    mkdir -p "$VENV_DIR"
    if ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
      detect_pkg_mgr
      case "$PKG_MGR" in
        apt)  bash -lc "$PKG_INSTALL python3-venv";;
        apk)  bash -lc "$PKG_INSTALL python3 py3-virtualenv";;
        dnf|yum) bash -lc "$PKG_INSTALL python3";;
        *) warn "无法自动安装 venv 依赖，请手动确保 'python3 -m venv' 可用";;
      esac
      python3 -m venv "$VENV_DIR"
    fi
    PYTHON_BIN="$VENV_DIR/bin/python"
    PIP_BIN="$VENV_DIR/bin/pip"
    JUPYTER_BIN="$VENV_DIR/bin/jupyter"

    # 确保 venv 内有 pip
    "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
}

# ========= 安装 Jupyter 到 venv/系统 =========
install_python_stack() {
  if [[ "$USE_SYSTEM_PIP" == "1" ]]; then
    log "升级 pip（系统环境）"
    $PIP_BIN install -U pip -i "$INDEX_URL" $PIP_BREAK || true
  else
    log "升级 pip（venv）"
    "$PIP_BIN" install -U pip -i "$INDEX_URL" || true
  fi

  local pkgs=(jupyterlab jupyterlab-language-pack-zh-CN jupyterlab-lsp jedi-language-server ipykernel)
  log "安装 Jupyter 组件（优先 wheels-only，必要时切换镜像）"
  if ! pip_install_with_mirror_fallback "${pkgs[@]}"; then
    die "安装失败：所有镜像尝试均未成功。你可能在内网需要代理；可设置 HTTPS_PROXY/HTTP_PROXY 环境变量后重试。"
  fi
  log "使用镜像: ${EFFECTIVE_INDEX:-unknown}"
}

# ========= 写 Nginx 配置 =========
install_nginx_and_config() {
  [[ $EUID -eq 0 ]] || die "模式2需要 root (安装/写 /etc/nginx)。"
  detect_pkg_mgr
  command -v nginx >/dev/null 2>&1 || { log "安装 Nginx..."; bash -lc "$PKG_INSTALL nginx"; }
  mkdir -p /var/cache/nginx/jupyter_static

  cat >/etc/nginx/conf.d/jupyter.conf <<'NGX'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

upstream jupyter_upstream {
    server 127.0.0.1:__PORT__;
    keepalive 64;
}

proxy_cache_path /var/cache/nginx/jupyter_static levels=1:2
                 keys_zone=jupyter_static:64m max_size=1g inactive=7d
                 use_temp_path=off;

server {
    listen __FRONT_PORT__;
    server_name _;

    client_max_body_size 200m;

    location ~* ^/static/ {
        proxy_pass http://jupyter_upstream;

        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";

        proxy_buffering on;
        proxy_buffers 64 64k;
        proxy_busy_buffers_size 256k;

        proxy_cache jupyter_static;
        proxy_cache_valid 200 301 302 12h;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        add_header X-Cache $upstream_cache_status always;

        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable";
    }

    location ~ ^/api/kernels/[^/]+/channels {
        proxy_pass http://jupyter_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 7d; proxy_send_timeout 7d; proxy_buffering off;
    }

    location ~ ^/terminals/websocket/? {
        proxy_pass http://jupyter_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 7d; proxy_send_timeout 7d; proxy_buffering off;
    }

    location / {
        proxy_pass http://jupyter_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_buffering on;
        proxy_buffers 64 64k;
        proxy_busy_buffers_size 256k;
        proxy_read_timeout 86400; proxy_send_timeout 86400;
    }
}
NGX
  # 填入端口
  sed -i "s/__PORT__/$PORT/g; s/__FRONT_PORT__/$FRONT_PORT/g" /etc/nginx/conf.d/jupyter.conf

  nginx -t
  systemctl enable --now nginx 2>/dev/null || service nginx start || nginx || true
  systemctl reload nginx 2>/dev/null || nginx -s reload || service nginx reload || true
}

# ========= 写 Caddy 配置 =========
install_caddy_and_config() {
  [[ $EUID -eq 0 ]] || die "模式3需要 root (安装/写 /etc/caddy)。"
  detect_pkg_mgr
  command -v caddy >/dev/null 2>&1 || { log "安装 Caddy..."; bash -lc "$PKG_INSTALL caddy" || die "安装 Caddy 失败"; }

  cat >/etc/caddy/Caddyfile <<'CADDY'
:__FRONT_PORT__ {
    @static path /static/*
    header @static Cache-Control "public, max-age=2592000, immutable"

    reverse_proxy 127.0.0.1:__PORT__ {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto http
        flush_interval -1
        transport http { versions 1.1; keepalive 30s }
    }
}
CADDY
  sed -i "s/__PORT__/$PORT/g; s/__FRONT_PORT__/$FRONT_PORT/g" /etc/caddy/Caddyfile

  systemctl enable --now caddy 2>/dev/null || true
  caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || systemctl restart caddy || true
}

# ========= 启动 Jupyter =========
start_jupyter() {
  local bind_ip="$1"
  local extra=()
  if [[ "$bind_ip" == "127.0.0.1" ]]; then extra+=(--ServerApp.trust_xheaders=True); fi

  log "启动 JupyterLab（模式=${PROFILE}，端口=${PORT}，目录=${ROOT_DIR}）"
  # 若 jupyter 可执行不存在（极少数环境），退回模块方式
  if [[ -x "$JUPYTER_BIN" ]]; then
    exec "$JUPYTER_BIN" lab \
      --allow-root --ip="$bind_ip" --port="$PORT" \
      --ServerApp.root_dir="$ROOT_DIR" \
      --ServerApp.token='' --ServerApp.password='' \
      --ServerApp.tornado_settings="{'compress_response': False, 'static_cache_max_age': 2592000}" \
      --ServerApp.iopub_data_rate_limit=1000000000 \
      --ServerApp.rate_limit_window=3.0 \
      --ServerApp.websocket_max_message_size=209715200 \
      "${extra[@]}" $EXTRA_JUPYTER_ARGS
  else
    exec "$PYTHON_BIN" -m jupyter lab \
      --allow-root --ip="$bind_ip" --port="$PORT" \
      --ServerApp.root_dir="$ROOT_DIR" \
      --ServerApp.token='' --ServerApp.password='' \
      --ServerApp.tornado_settings="{'compress_response': False, 'static_cache_max_age': 2592000}" \
      --ServerApp.iopub_data_rate_limit=1000000000 \
      --ServerApp.rate_limit_window=3.0 \
      --ServerApp.websocket_max_message_size=209715200 \
      "${extra[@]}" $EXTRA_JUPYTER_ARGS
  fi
}

# ========= 主流程 =========
main() {
  [[ $PROFILE =~ ^[123]$ ]] || die "不支持的 PROFILE=${PROFILE}，请用 1/2/3"

  # 1) Python 环境
  prepare_python_env
  install_python_stack

  # 2) 反代（按模式）
  case "$PROFILE" in
    1) log "模式1：仅 Jupyter（内网优化，直连 0.0.0.0:${PORT})"; start_jupyter "0.0.0.0" ;;
    2) log "模式2：Jupyter + Nginx（:${FRONT_PORT} → 127.0.0.1:${PORT})"; install_nginx_and_config; start_jupyter "127.0.0.1" ;;
    3) log "模式3：Jupyter + Caddy（:${FRONT_PORT} → 127.0.0.1:${PORT})"; install_caddy_and_config; start_jupyter "127.0.0.1" ;;
  esac
}

main "$@"
