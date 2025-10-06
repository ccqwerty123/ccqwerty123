#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] exit=$? line=$LINENO: $BASH_COMMAND" >&2' ERR

# ========= 可调参数（也可在运行时通过同名环境变量覆盖） =========
PROFILE="${PROFILE:-1}"        # 1=Jupyter直连(默认), 2=Jupyter+Nginx, 3=Jupyter+Caddy
INDEX_URL="${INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
PORT="${PORT:-8888}"           # Jupyter 后端端口
FRONT_PORT="${FRONT_PORT:-8080}"   # 反向代理对外端口(仅模式2/3)
ROOT_DIR="${ROOT_DIR:-$PWD}"
EXTRA_JUPYTER_ARGS="${EXTRA_JUPYTER_ARGS:-}"

# ========= 小工具函数 =========
log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
die() { echo -e "[FAIL] $*" >&2; exit 1; }

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_INSTALL='apt-get update -y && apt-get install -y'
    PKG_SVC_RELOAD='systemctl daemon-reload || true'
  elif command -v dnf >/dev/null 2>&1; then
    PKG_INSTALL='dnf install -y'
    PKG_SVC_RELOAD='systemctl daemon-reload || true'
  elif command -v yum >/dev/null 2>&1; then
    PKG_INSTALL='yum install -y'
    PKG_SVC_RELOAD='systemctl daemon-reload || true'
  elif command -v apk >/dev/null 2>&1; then
    PKG_INSTALL='apk add --no-cache'
    PKG_SVC_RELOAD='true'
  else
    die "未识别的包管理器，请手动安装依赖（nginx/caddy/python3-pip）。"
  fi
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

# ========= 安装 Python/Jupyter =========
install_python_stack() {
  ensure_cmd python3
  log "升级 pip（清华源）并安装 JupyterLab + 中文 + LSP + 内核"
  python3 -m pip install -U pip -i "$INDEX_URL"
  python3 -m pip install -U \
    jupyterlab \
    jupyterlab-language-pack-zh-CN \
    jupyterlab-lsp \
    jedi-language-server \
    ipykernel \
    -i "$INDEX_URL"
}

# ========= 写入/启用 Nginx 配置 =========
install_nginx_and_config() {
  detect_pkg_mgr
  if ! command -v nginx >/dev/null 2>&1; then
    log "安装 Nginx..."
    bash -lc "$PKG_INSTALL nginx"
  fi
  mkdir -p /var/cache/nginx/jupyter_static

  # 生成配置（放在 conf.d，通常被 http {} 引用）
  cat >/etc/nginx/conf.d/jupyter.conf <<NGX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream jupyter_upstream {
    server 127.0.0.1:${PORT};
    keepalive 64;
}

# 代理缓存路径，仅缓存静态资源
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

  # 目录权限（尽力处理，无则忽略）
  local_nginx_user="$(awk '/^user/ {print $2}' /etc/nginx/nginx.conf 2>/dev/null | tr -d ';' || true)"
  local_nginx_user="${local_nginx_user:-www-data}"
  chown -R "$local_nginx_user":"$local_nginx_user" /var/cache/nginx/jupyter_static 2>/dev/null || true

  log "检测并重载 Nginx 配置..."
  nginx -t
  systemctl enable --now nginx 2>/dev/null || service nginx start || true
  systemctl reload nginx 2>/dev/null || service nginx reload || true
}

# ========= 写入/启用 Caddy 配置 =========
install_caddy_and_config() {
  detect_pkg_mgr
  if ! command -v caddy >/dev/null 2>&1; then
    log "安装 Caddy..."
    # 尝试直接安装（多数发行版有包）
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

# ========= 启动 Jupyter（根据模式拼参数） =========
start_jupyter() {
  local bind_ip="$1"
  local extra=()
  if [[ "$bind_ip" == "127.0.0.1" ]]; then
    extra+=(--ServerApp.trust_xheaders=True)
  fi

  log "启动 JupyterLab（模式=${PROFILE}，端口=${PORT}，目录=${ROOT_DIR}）"
  exec jupyter lab \
    --allow-root \
    --ip="$bind_ip" \
    --port="$PORT" \
    --ServerApp.root_dir="$ROOT_DIR" \
    --ServerApp.token='' \
    --ServerApp.password='' \
    --ServerApp.tornado_settings='{
      "compress_response": false,
      "static_cache_max_age": 2592000
    }' \
    --ServerApp.iopub_data_rate_limit=1000000000 \
    --ServerApp.rate_limit_window=3.0 \
    --ServerApp.websocket_max_message_size=209715200 \
    "${extra[@]}" \
    $EXTRA_JUPYTER_ARGS
}

# ========= 主流程 =========
main() {
  [[ $EUID -eq 0 ]] || warn "建议以 root 运行（安装 Nginx/Caddy 需要 root）。"

  install_python_stack

  case "$PROFILE" in
    1)
      log "模式1：仅 Jupyter（内网优化，直连 0.0.0.0:${PORT)）"
      start_jupyter "0.0.0.0"
      ;;
    2)
      log "模式2：Jupyter + Nginx（Nginx侦听 :${FRONT_PORT}，上游 127.0.0.1:${PORT}）"
      install_nginx_and_config
      start_jupyter "127.0.0.1"
      ;;
    3)
      log "模式3：Jupyter + Caddy（Caddy侦听 :${FRONT_PORT}，上游 127.0.0.1:${PORT}）"
      install_caddy_and_config
      start_jupyter "127.0.0.1"
      ;;
    *)
      die "不支持的 PROFILE=${PROFILE}，请用 1/2/3"
      ;;
  esac
}

main
