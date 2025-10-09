#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config & Globals
# =========================
REPO_URL="https://github.com/alek76-2/VanitySearch.git"
INSTALL_DIR="${HOME}/VanitySearch"
LOG_FILE="${HOME}/vanitysearch_install_$(date +%Y%m%d_%H%M%S).log"
REQUIRED_PKGS=(build-essential git pkg-config libssl-dev ocl-icd-opencl-dev gcc-12 g++-12)
UBUNTU_CODENAME="noble"   # Ubuntu 24.04
APT_LIST="/etc/apt/sources.list"
CUDA_PATH=""              # will detect
CUDA_BIN=""               # will detect nvcc
CCAP_INT=""               # e.g., 75
CCAP_DOT=""               # e.g., 7.5

# =========================
# Helpers
# =========================
info()  { echo -e "\033[1;32m[INFO]\033[0m $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "\033[1;31m[ERR ]\033[0m $*" | tee -a "$LOG_FILE"; }
die()   { err "$*"; err "安装未完成，详见日志: $LOG_FILE"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

retry() {
  local tries=$1; shift
  local n=1
  until "$@" >>"$LOG_FILE" 2>&1; do
    if (( n >= tries )); then return 1; fi
    warn "命令失败，$n/${tries} 次重试后继续...[$*]"
    sleep $((2*n))
    ((n++))
  done
}

require_root_or_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if ! need_cmd sudo; then
      die "需要 root 或 sudo 权限，请用 sudo 运行该脚本。"
    fi
  fi
}

sudo_run() {
  if [[ $EUID -ne 0 ]]; then sudo "$@"; else "$@"; fi
}

# =========================
# Step 0: 环境与日志准备
# =========================
info "日志文件: $LOG_FILE"
info "检查系统为 Ubuntu 24.04（noble）..."
if ! need_cmd lsb_release; then
  sudo_run apt-get update -o Acquire::Retries=3 >>"$LOG_FILE" 2>&1 || true
  sudo_run apt-get install -y lsb-release >>"$LOG_FILE" 2>&1 || true
fi
DISTRO=$(lsb_release -is 2>/dev/null || echo "Ubuntu")
CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
RELEASE=$(lsb_release -rs 2>/dev/null || echo "")
info "检测到: ${DISTRO} ${RELEASE} (${CODENAME})"
if [[ "${DISTRO}" != "Ubuntu" ]]; then
  die "非 Ubuntu 系统，脚本仅适配 Ubuntu 24.04（noble）。"
fi

require_root_or_sudo

# =========================
# Step 1: 修正 APT 源并更新（带回退）
# =========================
fix_apt_sources() {
  info "备份现有 APT 源到 ${APT_LIST}.bak.$(date +%s)"
  sudo_run cp -a "${APT_LIST}" "${APT_LIST}.bak.$(date +%s)" || true

  info "写入官方推荐源（优先 mirror:// 自动选择镜像）..."
  sudo_run bash -c "cat > '${APT_LIST}'" <<EOF
deb mirror://mirrors.ubuntu.com/mirrors.txt ${UBUNTU_CODENAME} main restricted universe multiverse
deb mirror://mirrors.ubuntu.com/mirrors.txt ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb mirror://mirrors.ubuntu.com/mirrors.txt ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${UBUNTU_CODENAME}-security main restricted universe multiverse
# 源码仓可按需开启：
# deb-src mirror://mirrors.ubuntu.com/mirrors.txt ${UBUNTU_CODENAME} main restricted universe multiverse
# deb-src http://security.ubuntu.com/ubuntu ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

  info "apt-get update（3 次重试）..."
  if ! retry 3 sudo_run apt-get update -o Acquire::Retries=3; then
    warn "mirror:// 更新失败，改用 archive.ubuntu.com 官方主站..."
    sudo_run bash -c "cat > '${APT_LIST}'" <<'EOF'
deb http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
    retry 3 sudo_run apt-get update -o Acquire::Retries=3 || die "apt-get update 仍失败，请检查网络或代理。"
  fi
  info "APT 源与更新准备就绪。"
}

fix_apt_sources

# =========================
# Step 2: 安装所需依赖
# =========================
info "安装依赖：${REQUIRED_PKGS[*]}"
retry 3 sudo_run apt-get install -y "${REQUIRED_PKGS[@]}" || die "依赖安装失败。"

# =========================
# Step 3: 检测 CUDA 与 nvcc
# =========================
detect_cuda() {
  if need_cmd nvcc; then
    CUDA_BIN=$(command -v nvcc)
    CUDA_PATH=$(dirname "$(dirname "$CUDA_BIN")")
  else
    # 常见默认路径回退
    for c in /usr/local/cuda /usr/local/cuda-12.0 /usr/local/cuda-12 /usr/local/cuda-11.8; do
      if [[ -x "$c/bin/nvcc" ]]; then CUDA_PATH="$c"; CUDA_BIN="$c/bin/nvcc"; break; fi
    done
  fi

  if [[ -z "${CUDA_BIN}" || ! -x "${CUDA_BIN}" ]]; then
    die "未检测到 nvcc（CUDA 编译器）。请确认已正确安装 CUDA Toolkit 12.0 并将 nvcc 加入 PATH。"
  fi

  info "检测到 CUDA: ${CUDA_PATH}, nvcc: ${CUDA_BIN}"
  export PATH="${CUDA_PATH}/bin:${PATH}"
  export LD_LIBRARY_PATH="${CUDA_PATH}/lib64:${LD_LIBRARY_PATH:-}"
}
detect_cuda

# =========================
# Step 4: 检测 GPU 计算能力（ccap）
# =========================
detect_ccap() {
  local cap=""
  if need_cmd nvidia-smi; then
    cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 || true)
  fi
  if [[ -z "$cap" ]]; then
    # 回退：通过名字猜测（你的机器是 Tesla T4）
    local name=""
    if need_cmd nvidia-smi; then
      name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
    fi
    if echo "$name" | grep -qi "T4"; then
      cap="7.5"
    else
      warn "无法从 nvidia-smi 读取 compute capability，默认使用 7.5（T4）。"
      cap="7.5"
    fi
  fi
  CCAP_DOT="$cap"
  CCAP_INT="$(echo "$cap" | tr -d '.')"
  info "GPU 计算能力: ${CCAP_DOT}（传参 CCAP=${CCAP_DOT} / ccap=${CCAP_INT}）"
}
detect_ccap

# =========================
# Step 5: 获取源码（alek76-2/VanitySearch）
# =========================
fetch_source() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "检测到已有仓库：${INSTALL_DIR}，执行 git pull..."
    (cd "${INSTALL_DIR}" && git fetch --all >>"$LOG_FILE" 2>&1 && git reset --hard origin/master >>"$LOG_FILE" 2>&1) || die "git 更新失败。"
  else
    info "克隆仓库到 ${INSTALL_DIR}..."
    git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}" >>"$LOG_FILE" 2>&1 || die "git clone 失败。"
  fi
}
fetch_source

# =========================
# Step 6: 构建（先 CPU，后 GPU）
# =========================
build_project() {
  local jobs
  jobs=$(nproc || echo 2)

  info "开始构建 CPU 版..."
  ( cd "${INSTALL_DIR}" && make clean >>"$LOG_FILE" 2>&1 || true
    if ! make -j"${jobs}" >>"$LOG_FILE" 2>&1; then
      die "CPU 版构建失败，请查看日志：${LOG_FILE}"
    fi
  )
  info "CPU 版构建完成。"

  # 尝试 GPU 版
  info "开始构建 GPU 版（nvcc 用 g++-12 作为宿主编译器）..."
  local cuda_arg="CUDA=${CUDA_PATH}"
  local cxxcuda_arg="CXXCUDA=/usr/bin/g++-12"
  local gpu_args=(gpu=1 all)
  # 同时传递两种 ccap 写法，兼容不同 Makefile 风格
  ( cd "${INSTALL_DIR}" && \
    if ! make -j"${jobs}" ${cuda_arg} ${cxxcuda_arg} ccap="${CCAP_INT}" CCAP="${CCAP_DOT}" "${gpu_args[@]}" >>"$LOG_FILE" 2>&1; then
      # 如果失败，尝试显式导出 PATH/LD_LIBRARY_PATH 后再来一次（处理环境变量问题）
      export PATH="${CUDA_PATH}/bin:${PATH}"
      export LD_LIBRARY_PATH="${CUDA_PATH}/lib64:${LD_LIBRARY_PATH:-}"
      warn "首次 GPU 构建失败，尝试在显式 CUDA 环境下重试..."
      make clean >>"$LOG_FILE" 2>&1 || true
      make -j"${jobs}" ${cuda_arg} ${cxxcuda_arg} ccap="${CCAP_INT}" CCAP="${CCAP_DOT}" "${gpu_args[@]}" >>"$LOG_FILE" 2>&1 || die "GPU 版构建失败，请查看日志：${LOG_FILE}"
    fi
  )
  info "GPU 版构建完成。"
}
build_project

# =========================
# Step 7: 生成环境文件与自检
# =========================
post_setup() {
  info "写入环境变量到 ${INSTALL_DIR}/env.sh"
  cat > "${INSTALL_DIR}/env.sh" <<EOF
# 加载 CUDA 运行库路径与可执行文件路径
export PATH="${CUDA_PATH}/bin:\$PATH"
export LD_LIBRARY_PATH="${CUDA_PATH}/lib64:\${LD_LIBRARY_PATH:-}"
EOF

  chmod +x "${INSTALL_DIR}/env.sh"

  info "自检：显示帮助与列出 CUDA 设备..."
  ( cd "${INSTALL_DIR}"
    source ./env.sh
    ./VanitySearch -h >/dev/null 2>&1 || warn "VanitySearch -h 返回非 0，但可能仅为帮助退出码。"
    if ./VanitySearch -l >/dev/null 2>&1; then
      info "已成功列出 CUDA 设备。"
    else
      warn "无法列出 CUDA 设备（./VanitySearch -l）。GPU 仍可能需要检查驱动/CUDA 环境。"
    fi
  )
}
post_setup

info "全部完成！"
echo
echo "接下来可按如下方式使用（示例）："
echo "  cd '${INSTALL_DIR}'"
echo "  source ./env.sh"
echo "  ./VanitySearch -l              # 列出 CUDA 设备"
echo "  ./VanitySearch -gpu -t 1 1YourPrefixHere"
echo
echo "若构建失败，请查看日志：${LOG_FILE}"
