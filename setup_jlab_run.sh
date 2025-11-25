#!/usr/bin/env bash
set -Eeuo pipefail

# ========= 可调参数 =========
INDEX_URL="${INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
PORT="${PORT:-8888}"
ROOT_DIR="${ROOT_DIR:-$PWD}"
EXTRA_JUPYTER_ARGS="${EXTRA_JUPYTER_ARGS:-}"
USE_SYSTEM_PIP="${USE_SYSTEM_PIP:-0}"

# venv 目录 & 日志文件
if [[ $EUID -eq 0 ]]; then 
    DEFAULT_VENV_DIR="/opt/jlab-venv"
    LOG_FILE="/var/log/jupyter_run.log"
else 
    DEFAULT_VENV_DIR="$HOME/.local/jlab-venv"
    LOG_FILE="$HOME/jupyter_run.log"
fi
VENV_DIR="${VENV_DIR:-$DEFAULT_VENV_DIR}"

# ========= 日志函数 =========
log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[FAIL]\033[0m $*" >&2; exit 1; }

ensure_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# ========= pip 安装（带多镜像回退） =========
pip_install_with_mirror_fallback() {
  local pkgs=("$@")
  local candidates=(
    "$INDEX_URL"
    "https://mirrors.aliyun.com/pypi/simple/"
    "https://pypi.org/simple"
  )
  for idx in "${candidates[@]}"; do
    log "尝试 pip 安装 (源: $idx)..."
    if "$PIP_BIN" install --no-cache-dir -i "$idx" "${pkgs[@]}"; then
      return 0
    fi
  done
  return 1
}

# ========= 1. 环境准备 =========
prepare_env() {
  ensure_cmd python3
  
  if [[ "$USE_SYSTEM_PIP" == "1" ]]; then
    log "使用系统 Python 环境"
    PIP_BREAK="--break-system-packages"
    PYTHON_BIN="$(command -v python3)"
    PIP_BIN="$PYTHON_BIN -m pip"
    JUPYTER_BIN="$(command -v jupyter || true)"
  else
    log "检查/创建 venv 环境: $VENV_DIR"
    mkdir -p "$VENV_DIR"
    if ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
      # 简单修复：Debian/Ubuntu 缺少 venv 时自动装依赖
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y python3-venv
      fi
      python3 -m venv "$VENV_DIR"
    fi
    PYTHON_BIN="$VENV_DIR/bin/python"
    PIP_BIN="$VENV_DIR/bin/pip"
    JUPYTER_BIN="$VENV_DIR/bin/jupyter"
    "$PYTHON_BIN" -m ensurepip >/dev/null 2>&1 || true
  fi
}

# ========= 2. 安装 Jupyter 组件 =========
install_jupyter() {
  log "检查并安装 Jupyter..."
  if [[ "$USE_SYSTEM_PIP" == "1" ]]; then
    $PIP_BIN install -U pip -i "$INDEX_URL" $PIP_BREAK || true
  else
    "$PIP_BIN" install -U pip -i "$INDEX_URL" || true
  fi
  
  local pkgs=(jupyterlab jupyterlab-language-pack-zh-CN jupyterlab-lsp jedi-language-server ipykernel)
  pip_install_with_mirror_fallback "${pkgs[@]}" || die "安装失败，请检查网络。"
}

# ========= 3. 后台启动 JupyterLab =========
start_background() {
  # 构造启动命令
  local cmd_str=""
  if [[ -x "$JUPYTER_BIN" ]]; then
    cmd_str="$JUPYTER_BIN lab"
  else
    cmd_str="$PYTHON_BIN -m jupyter lab"
  fi
  
  cmd_str="$cmd_str --allow-root"
  cmd_str="$cmd_str --ip=0.0.0.0 --port=$PORT"
  cmd_str="$cmd_str --ServerApp.root_dir=$ROOT_DIR"
  cmd_str="$cmd_str --ServerApp.token='' --ServerApp.password=''"
  cmd_str="$cmd_str --ServerApp.tornado_settings={'compress_response':False,'static_cache_max_age':2592000}"
  cmd_str="$cmd_str --no-browser"

  # 提高 IOPub 速率限制到 1GB/s（默认是 1MB/s）
  cmd_str="$cmd_str --ServerApp.iopub_data_rate_limit=1000000000"
  cmd_str="$cmd_str --ServerApp.rate_limit_window=3.0"

  # 允许通过 EXTRA_JUPYTER_ARGS 追加/覆盖参数（后面的会覆盖前面的）
  cmd_str="$cmd_str $EXTRA_JUPYTER_ARGS"

  log "正在启动 JupyterLab..."
  
  # 1. 杀掉旧进程 (防止端口冲突)
  pkill -f "jupyter-lab" >/dev/null 2>&1 || true
  
  # 2. 确保日志文件可写
  touch "$LOG_FILE" 2>/dev/null || true
  if [[ ! -w "$LOG_FILE" ]]; then
      warn "日志文件 $LOG_FILE 不可写，切换至 /tmp/jupyter_run.log"
      LOG_FILE="/tmp/jupyter_run.log"
      touch "$LOG_FILE" 2>/dev/null || die "无法创建日志文件：$LOG_FILE"
  fi

  # 3. 后台运行
  nohup $cmd_str >"$LOG_FILE" 2>&1 &
  
  sleep 2
  
  # 4. 检查是否存活
  if pgrep -f "jupyter-lab" >/dev/null 2>&1; then
      log "=============================================="
      log "✅ 启动成功 (后台模式)"
      log "🔗 访问地址: http://你的IP:$PORT"
      log "📂 工作目录: $ROOT_DIR"
      log "📝 日志位置: $LOG_FILE"
      log "❌ 停止服务: pkill -f jupyter-lab"
      log "=============================================="
  else
      die "启动失败，请查看日志: cat $LOG_FILE"
  fi
}

main() {
  prepare_env
  install_jupyter
  start_background
}

main "$@"
