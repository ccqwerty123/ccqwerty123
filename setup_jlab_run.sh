#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] exit=$? line=$LINENO: $BASH_COMMAND" >&2' ERR

# ========= 可调参数（可用环境变量覆盖） =========
PROFILE="${PROFILE:-1}"                 # 1=Jupyter直连(默认), 2=Jupyter+Nginx, 3=Jupyter+Caddy
INDEX_URL="${INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
PORT="${PORT:-8888}"                    # Jupyter 后端端口
FRONT_PORT="${FRONT_PORT:-8080}"        # 反代对外端口(仅模式2/3)
ROOT_DIR="${ROOT_DIR:-$PWD}"
EXTRA_JUPYTER_ARGS="${EXTRA_JUPYTER_ARGS:-}"
USE_SYSTEM_PIP="${USE_SYSTEM_PIP:-0}"   # 1=强行用系统pip（会加 --break-system-packages；不推荐）

# venv 默认路径（root用 /opt，普通用户用 $HOME/.local）
if [[ $EUID -eq 0 ]]; then
  DEFAULT_VENV_DIR="/opt/jlab-venv"
else
  DEFAULT_VENV_DIR="$HOME/.local/jlab-venv"
fi
VENV_DIR="${VENV_DIR:-$DEFAULT_VENV_DIR}"

# ========= 工具函数 =========
log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR=apt
    PKG_INSTALL='apt-get update -y && apt-get install -y'
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR=dnf
    PKG_INSTALL='dnf install -y'
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR=yum
    PKG_INSTALL='yum install -y'
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR=apk
    PKG_INSTALL='apk add --no-cache'
  else
    PKG_MGR=unknown
    PKG_INSTALL='echo'
  fi
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

# ========= 准备 Python/venv =========
prepare_python_env() {
  ensure_cmd python3

  if [[ "$USE_SYSTEM_PIP" == "1" ]]; then
    log "使用系统 pip（将启用 --break-system-packages，可能影响系统Python）"
    PIP_BREAK="--break-system-packages"
    PYTHON_BIN="$(command -v python3)"
    PIP_BIN="$PYTHON_BIN -m pip"
    JUPYTER_BIN="$(command -v jupyter || true)"
  else
    log "创建/复用 venv: $VENV_DIR"
    mkdir -p "$VENV_DIR"
    # 直接尝试创建 venv；失败再按发行版补包
    if ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
      detect_pkg_mgr
      case "$PKG_MGR" in
        apt)  bash -lc "$PKG_INSTALL python3-venv";;
        apk)  bash -lc "$PKG_INSTALL python3 py3-virtualenv";;
        dnf|yum) bash -lc "$PKG_INSTALL python3";;   # venv 通常随 python3 自带
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

# ========= 安装 Jupyter 到 venv 或系统（取决于上一步） =========
install_python_stack() {
  if [[ "$USE_SYSTEM_PIP" == "1" ]]; then
    log "系统环境安装 Jupyter（带 $PIP_BREAK）"
    $PIP_BIN install -U pip setuptools wheel -i "$INDEX_URL" $PIP_BREAK
    $PIP_BIN install -U \
      jupyterlab \
      jupyterlab-language-pack-zh-CN \
      jupyterlab-lsp \
      jedi-language-server \
      ipykernel \
      -i "$INDEX_URL" $PIP_BREAK
  else
    log "在 venv 安装 Jupyter（不触碰系统Python）"
    "$PIP_BIN" install -U pip setuptools wheel -i "$INDEX_URL"
    "$PIP_BIN" install -U \
      jupyterlab \
      jupyterlab-language-pack-zh-CN \
      jupyterlab-lsp \
      jedi-language-server \
      ipykernel \
      -i "$INDEX_URL"
  fi
}

# ========= 写入/启用 Nginx 配置 =========
install_nginx_and_config() {
  [[ $EUID -eq 0 ]] || die "模式2需要 root (安装/写入 /etc/nginx)。"
  detect_pkg_mgr
  if ! command -v nginx >/dev/null 2>&1; then
    log "安装 Nginx..."
    bash -lc "$PKG_INSTALL nginx"
  fi
  mkdir -p /var/cache/nginx/jupyter_static

  cat >/etc/nginx/conf.d/jupyter.conf <<NGX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream jupyter_upstream {
    server 127.0.0.1:${PORT};
    keepalive 64;
}

proxy_cache_path /var/cache/nginx/jupyter_static levels=1:2
                 keys_zone=jupyter_static:64m max_size=1g inactive=7d
                 use_temp_path=off;

server {
    listen ${FRONT_PORT};
    server_name _;

    client_max_body_size 200m;

    # 静态资源：强缓存 + 本地代理缓存
    location ~* ^/static/ {
        proxy_pass http://jupyter_upstream;

        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";

        proxy_buffering on;
        proxy_buffers 64 64k;
        proxy_busy_buffers_size 256k;

        proxy_cache jupyter_static;
        proxy_cache_valid 200 301 302 12h;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        add_header X-Cache \$upstream_cache_status always;

        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable";
    }

    # WebSocket：kernel 通道
    location ~ ^/api/kernels/[^/]+/channels {
        proxy_pass http://jupyter_upstream;

        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }

    # WebSocket：终端
    location ~ ^/terminals/websocket/? {
        proxy_pass http://jupyter_upstream;

        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }

    # 其他请求
    location / {
        proxy_pass http://jupyter_upstream;

        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";

        proxy_buffering on;
        proxy_buffers 64 64k;
        proxy_busy_buffers_size 256k;

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
NGX

  log "检测并重载 Nginx 配置..."
  nginx -t
  systemctl enable --now nginx 2>/dev/null || service nginx start || nginx || true
  systemctl reload nginx 2>/dev/null || nginx -s reload || service nginx reload || true
}

# ========= 写入/启用 Caddy 配置 =========
install_caddy_and_config() {
  [[ $EUID -eq 0 ]] || die "模式3需要 root (安装/写入 /etc/caddy)。"
  detect_pkg_mgr
  if ! command -v caddy >/dev/null 2>&1; then
    log "安装 Caddy..."
    bash -lc "$PKG_INSTALL caddy" || die "安装 Caddy 失败，请改用模式2(Nginx)或手动安装 Caddy。"
  fi

  cat >/etc/caddy/Caddyfile <<CADDY
:${FRONT_PORT} {
    @static path /static/*
    header @static Cache-Control "public, max-age=2592000, immutable"

    reverse_proxy 127.0.0.1:${PORT} {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto http
        flush_interval -1
        transport http {
            versions 1.1
            keepalive 30s
        }
    }
}
CADDY

  log "重载 Caddy..."
  systemctl enable --now caddy 2>/dev/null || true
  caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || systemctl restart caddy || true
}

# ========= 启动 Jupyter =========
start_jupyter() {
  local bind_ip="$1"
  local extra=()
  if [[ "$bind_ip" == "127.0.0.1" ]]; then
    extra+=(--ServerApp.trust_xheaders=True)
  fi

  log "启动 JupyterLab（模式=${PROFILE}，端口=${PORT}，目录=${ROOT_DIR}）"
  exec "$JUPYTER_BIN" lab \
    --allow-root \
    --ip="$bind_ip" \
    --port="$PORT" \
    --ServerApp.root_dir="$ROOT_DIR" \
    --ServerApp.token='' \
    --ServerApp.password='' \
    --ServerApp.tornado_settings="{'compress_response': False, 'static_cache_max_age': 2592000}" \
    --ServerApp.iopub_data_rate_limit=1000000000 \
    --ServerApp.rate_limit_window=3.0 \
    --ServerApp.websocket_max_message_size=209715200 \
    "${extra[@]}" \
    $EXTRA_JUPYTER_ARGS
}

# ========= 主流程 =========
main() {
  [[ $PROFILE =~ ^[123]$ ]] || die "不支持的 PROFILE=${PROFILE}，请用 1/2/3"
  prepare_python_env
  install_python_stack

  case "$PROFILE" in
    1)
      log "模式1：仅 Jupyter（内网优化，直连 0.0.0.0:${PORT})"
      start_jupyter "0.0.0.0"
      ;;
    2)
      log "模式2：Jupyter + Nginx（侦听 :${FRONT_PORT}，上游 127.0.0.1:${PORT})"
      install_nginx_and_config
      start_jupyter "127.0.0.1"
      ;;
    3)
      log "模式3：Jupyter + Caddy（侦听 :${FRONT_PORT}，上游 127.0.0.1:${PORT})"
      install_caddy_and_config
      start_jupyter "127.0.0.1"
      ;;
  esac
}

main "$@"
