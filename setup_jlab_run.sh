#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] exit=$? line=$LINENO: $BASH_COMMAND" >&2' ERR

# ========= 可调参数 =========
# 只保留直连相关参数
INDEX_URL="${INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
# 备用镜像
INDEX_URL="${INDEX_URL:-https://mirrors.cloud.tencent.com/pypi/simple}"
PORT="${PORT:-8888}"
ROOT_DIR="${ROOT_DIR:-$PWD}"
EXTRA_JUPYTER_ARGS="${EXTRA_JUPYTER_ARGS:-}"
USE_SYSTEM_PIP="${USE_SYSTEM_PIP:-0}"   # 1=用系统pip (不推荐)

# 服务名称 (Systemd 用)
SERVICE_NAME="jupyter-lab"

# venv 目录
if [[ $EUID -eq 0 ]]; then DEFAULT_VENV_DIR="/opt/jlab-venv"; else DEFAULT_VENV_DIR="$HOME/.local/jlab-venv"; fi
VENV_DIR="${VENV_DIR:-$DEFAULT_VENV_DIR}"

log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[FAIL]\033[0m $*" >&2; exit 1; }

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
  local pkgs=("$@")
  local candidates=(
    "$INDEX_URL"
    "https://mirrors.aliyun.com/pypi/simple/"
    "https://pypi.tuna.tsinghua.edu.cn/simple"
    "https://pypi.org/simple"
  )

  for idx in "${candidates[@]}"; do
    log "Trying pip install via: $idx"
    if "$PIP_BIN" install --no-cache-dir -i "$idx" "${pkgs[@]}"; then
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
    log "使用系统 pip"
    PIP_BREAK="--break-system-packages"
    PYTHON_BIN="$(command -v python3)"
    PIP_BIN="$PYTHON_BIN -m pip"
    JUPYTER_BIN="$(command -v jupyter || true)"
  else
    log "检查/创建 venv: $VENV_DIR"
    mkdir -p "$VENV_DIR"
    if ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
      detect_pkg_mgr
      # 尝试自动安装 venv 模块
      bash -lc "$PKG_INSTALL python3-venv || $PKG_INSTALL python3-virtualenv || true" >/dev/null 2>&1
      python3 -m venv "$VENV_DIR"
    fi
    PYTHON_BIN="$VENV_DIR/bin/python"
    PIP_BIN="$VENV_DIR/bin/pip"
    JUPYTER_BIN="$VENV_DIR/bin/jupyter"
    
    # 修复 venv 里的 pip
    "$PYTHON_BIN" -m ensurepip >/dev/null 2>&1 || true
  fi
}

# ========= 安装 Jupyter =========
install_python_stack() {
  log "升级 pip..."
  if [[ "$USE_SYSTEM_PIP" == "1" ]]; then
    $PIP_BIN install -U pip -i "$INDEX_URL" $PIP_BREAK || true
  else
    "$PIP_BIN" install -U pip -i "$INDEX_URL" || true
  fi

  local pkgs=(jupyterlab jupyterlab-language-pack-zh-CN jupyterlab-lsp jedi-language-server ipykernel)
  log "安装 Jupyter 组件..."
  if ! pip_install_with_mirror_fallback "${pkgs[@]}"; then
    die "安装失败，请检查网络或代理设置。"
  fi
}

# ========= 生成启动命令字符串 =========
get_start_cmd() {
  # 构造启动参数
  local cmd_str=""
  
  # 判断是用 venv 的 jupyter 还是 python -m jupyter
  if [[ -x "$JUPYTER_BIN" ]]; then
    cmd_str="$JUPYTER_BIN lab"
  else
    cmd_str="$PYTHON_BIN -m jupyter lab"
  fi

  # 追加参数
  # 注意：这里为了安全，建议以后加上 Token，但根据你原脚本保留空密码设置
  cmd_str="$cmd_str --allow-root --ip=0.0.0.0 --port=$PORT"
  cmd_str="$cmd_str --ServerApp.root_dir=$ROOT_DIR"
  cmd_str="$cmd_str --ServerApp.token='' --ServerApp.password=''"
  cmd_str="$cmd_str --ServerApp.tornado_settings={'compress_response':False,'static_cache_max_age':2592000}"
  cmd_str="$cmd_str --no-browser"
  cmd_str="$cmd_str $EXTRA_JUPYTER_ARGS"
  
  echo "$cmd_str"
}

# ========= 后台运行逻辑 =========
setup_background_service() {
  local start_cmd
  start_cmd=$(get_start_cmd)

  if [[ $EUID -eq 0 ]]; then
    # ---------------- Root 用户：使用 Systemd (推荐) ----------------
    log "当前为 Root 用户，正在创建 Systemd 服务..."
    
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    
    cat > "$service_file" <<EOF
[Unit]
Description=JupyterLab Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$ROOT_DIR
ExecStart=$start_cmd
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    log "Systemd 服务文件已创建: $service_file"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    
    log "=============================================="
    log "JupyterLab 已通过 Systemd 在后台启动！"
    log "访问地址: http://服务器IP:$PORT"
    log "----------------------------------------------"
    log "查看状态: systemctl status ${SERVICE_NAME}"
    log "停止服务: systemctl stop ${SERVICE_NAME}"
    log "查看日志: journalctl -u ${SERVICE_NAME} -f"
    log "=============================================="

  else
    # ---------------- 普通用户：使用 nohup ----------------
    log "当前为普通用户，使用 nohup 在后台运行..."
    
    local log_file="$HOME/jupyter_run.log"
    
    # 杀掉旧进程（如果有）
    pkill -f "jupyter-lab" || true
    
    # 后台运行
    nohup $start_cmd > "$log_file" 2>&1 &
    
    log "=============================================="
    log "JupyterLab 已通过 nohup 在后台启动！"
    log "访问地址: http://服务器IP:$PORT"
    log "----------------------------------------------"
    log "日志文件: $log_file"
    log "关闭方法: pkill -f jupyter-lab"
    log "=============================================="
  fi
}

# ========= 主流程 =========
main() {
  log "开始安装/配置 JupyterLab (纯净后台模式)..."
  
  # 1) 环境准备
  prepare_python_env
  
  # 2) 安装核心包
  install_python_stack

  # 3) 配置并启动后台服务
  setup_background_service
}

main "$@"
