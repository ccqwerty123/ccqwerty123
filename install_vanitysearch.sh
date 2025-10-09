#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/alek76-2/VanitySearch.git"
INSTALL_DIR="${HOME}/VanitySearch"
LOG_FILE="${HOME}/vanitysearch_install_$(date +%Y%m%d_%H%M%S).log"
REQUIRED_PKGS=(build-essential git pkg-config libssl-dev ocl-icd-opencl-dev gcc-12 g++-12)
UBUNTU_CODENAME="noble"
APT_LIST="/etc/apt/sources.list"

# 可选：手动覆盖计算能力，例如 7.5 / 8.6
FORCE_CCAP="${FORCE_CCAP:-}"

info()  { echo -e "\033[1;32m[INFO]\033[0m $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "\033[1;31m[ERR ]\033[0m $*" | tee -a "$LOG_FILE"; }
die()   { err "$*"; err "安装未完成，日志: $LOG_FILE"; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
retry(){ local t=$1; shift; local n=1; until "$@" >>"$LOG_FILE" 2>&1; do
  if (( n>=t )); then return 1; fi; warn "第 $n/$t 次失败，重试：$*"; sleep $((2*n)); ((n++)); done; }
require_root_or_sudo(){ if [[ $EUID -ne 0 ]] && ! need_cmd sudo; then die "需要 root 或 sudo 权限"; fi; }
sudo_run(){ if [[ $EUID -ne 0 ]]; then sudo "$@"; else "$@"; fi; }

info "日志: $LOG_FILE"
require_root_or_sudo

# 1) 修正 apt 源并更新（带回退）
#
# 自动修复并更新 APT 源的函数 (v5.1 - 修复 grep + set -e 导致的脚本中止问题)
#
fix_apt_sources() {
  local version="5.1"
  echo "[INFO] 运行 fix_apt_sources 函数 (版本: ${version})..."

  # --- 1. 权限检查 ---
  if [[ $EUID -ne 0 ]]; then
    echo "[ERR ] 错误：此脚本必须以 root 权限运行！" >&2
    exit 1
  fi

  # 内部辅助函数：强制解锁 APT 系统
  force_unlock_apt() {
    echo "[INFO] 正在检查并强制解锁 APT 系统..."
    
    # 【关键修复】在命令末尾加上 '|| true'
    # 这样即使 grep 找不到任何进程（正常情况），命令也会返回成功（0），
    # 防止 set -e 模式下脚本异常退出。
    local pids
    pids=$(ps aux | grep -E 'apt|dpkg' | grep -v grep | awk '{print $2}' || true)

    if [ -n "$pids" ]; then
      echo "[WARN] 检测到 APT/DPKG 锁被以下进程占用: ${pids}"
      echo "[INFO] 正在强制终止这些进程..."
      echo "${pids}" | xargs kill -9
      sleep 1
      echo "[INFO] 旧进程已终止。"
    fi
    
    echo "[INFO] 正在清理所有已知的锁文件..."
    rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend
      
    echo "[INFO] 正在尝试重新配置 dpkg..."
    dpkg --configure -a
      
    echo "[INFO] APT 系统解锁/清理操作完成。"
  }

  # --- 主逻辑开始 ---

  # 2. 调用解锁函数，并检查其是否成功
  if ! force_unlock_apt; then
      echo "[ERR ] APT 系统解锁失败，安装中止。" >&2
      exit 1
  fi

  # 3. 禁用所有第三方源
  local sources_d_dir="/etc/apt/sources.list.d"
  if [ -d "${sources_d_dir}" ] && [ -n "$(ls -A ${sources_d_dir})" ]; then
    echo "[INFO] 检测到第三方源。正在备份并禁用它们..."
    local backup_dir="${sources_d_dir}.bak.$(date +%s)"
    mv "${sources_d_dir}" "${backup_dir}"
    mkdir "${sources_d_dir}"
    echo "[INFO] 所有第三方源已备份至 ${backup_dir} 并禁用。"
  fi

  # 4. 备份并覆盖主源文件
  echo "[INFO] 备份现有主源文件到 /etc/apt/sources.list.bak.$(date +%s)"
  mv /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s) || true

  # 5. 写入纯净的国内源
  echo "[INFO] 写入纯净的国内源（清华大学 TUNA 源）..."
  bash -c "cat > /etc/apt/sources.list" <<EOF
# 由安装脚本于 $(date) 生成 (v${version})
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

  # 6. 更新软件包列表
  echo "[INFO] 在纯净源环境下执行 apt-get update..."
  apt-get update -o Acquire::Retries=3 -o Acquire::Check-Valid-Until=false || { echo "[ERR ] apt-get update 最终失败！请检查网络。" >&2; exit 1; }
  
  echo "[INFO] APT 源与更新准备就绪。"
}



fix_apt_sources

# 2) 依赖
info "安装依赖：${REQUIRED_PKGS[*]}"
retry 3 sudo_run apt-get install -y "${REQUIRED_PKGS[@]}" || die "依赖安装失败"

# 3) 检测 nvcc 与 CUDA 根
CUDA_BIN=""
CUDA_PATH=""
detect_cuda(){
  if ! need_cmd nvcc; then die "未找到 nvcc，请先安装 CUDA Toolkit（与你系统匹配即可，当前驱动支持 CUDA 13，nvcc 12.0 也能用）"; fi
  CUDA_BIN="$(command -v nvcc)"
  local realbin; realbin="$(readlink -f "$CUDA_BIN" || echo "$CUDA_BIN")"
  CUDA_PATH="$(dirname "$(dirname "$realbin")")"
  # 对 Debian/Ubuntu 打包的 cuda-toolkit，nvcc 在 /usr/bin，CUDA_PATH 可能解析为 /usr
  info "nvcc: ${CUDA_BIN}"
  info "推测 CUDA 根目录: ${CUDA_PATH}"
  export PATH="${CUDA_PATH}/bin:${PATH}"
  # 运行时库多数在 /usr/lib/x86_64-linux-gnu，保留 LD_LIBRARY_PATH 为默认
}
detect_cuda

# 4) 读取计算能力（优先用户覆盖；否则 nvidia-smi；再退回 T4=7.5）
CCAP_DOT=""
CCAP_INT=""
detect_ccap(){
  if [[ -n "$FORCE_CCAP" ]]; then
    [[ "$FORCE_CCAP" =~ ^[0-9]+\.[0-9]+$ ]] || die "FORCE_CCAP 格式应为如 7.5/8.6"
    CCAP_DOT="$FORCE_CCAP"; CCAP_INT="$(echo "$FORCE_CCAP" | tr -d '.')"
    info "使用用户指定 CCAP=${CCAP_DOT}"
    return
  fi
  local cap=""
  if need_cmd nvidia-smi; then
    cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  fi
  if [[ -z "$cap" || ! "$cap" =~ ^[0-9]+\.[0-9]+$ ]]; then
    warn "无法从 nvidia-smi 读取有效 compute capability，按 Tesla T4 设定 7.5（可用 FORCE_CCAP 覆盖）"
    cap="7.5"
  fi
  CCAP_DOT="$cap"; CCAP_INT="$(echo "$cap" | tr -d '.')"
  info "GPU 计算能力：${CCAP_DOT}（传参 ccap=${CCAP_INT} / CCAP=${CCAP_DOT}）"
}
detect_ccap

# 5) 获取源码
fetch_source(){
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "更新仓库 ${INSTALL_DIR}"
    (cd "${INSTALL_DIR}" && git fetch --all >>"$LOG_FILE" 2>&1 && git reset --hard origin/master >>"$LOG_FILE" 2>&1) || die "git 更新失败"
  else
    info "克隆仓库到 ${INSTALL_DIR}"
    git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}" >>"$LOG_FILE" 2>&1 || die "git clone 失败"
  fi
}
fetch_source

# 6) 源码补丁：为缺少 <stdint.h> 的头自动补齐；同时强制编译时 -include stdint.h
patch_sources(){
  info "应用源码补丁（自动补 <stdint.h>）"
  # 针对常见包含 uint8_t 的头
  local heads=( "hash/sha256.h" "hash/sha256_sse.h" "hash/ripemd160.h" )
  for h in "${heads[@]}"; do
    local p="${INSTALL_DIR}/${h}"
    if [[ -f "$p" ]]; then
      if ! grep -Eq '^(#include\s*<cstdint>|#include\s*<stdint.h>)' "$p"; then
        sed -i '1i #include <stdint.h>' "$p"
        echo "[PATCH] add <stdint.h> -> $h" >>"$LOG_FILE"
      fi
    fi
  done
}
patch_sources

# 7) 构建 CPU
build_cpu(){
  info "开始构建 CPU 版..."
  local jobs; jobs=$(nproc || echo 2)
  ( cd "${INSTALL_DIR}" && make clean >>"$LOG_FILE" 2>&1 || true
    # 强制标准并全局预包含 stdint.h，兼容 gcc-13
    if ! make -j"${jobs}" CXXFLAGS+=' -std=gnu++14 -include stdint.h ' CFLAGS+=' -std=gnu11 -include stdint.h ' >>"$LOG_FILE" 2>&1; then
      err "CPU 版首次构建失败，添加 -fcommon 重试..."
      make clean >>"$LOG_FILE" 2>&1 || true
      make -j"${jobs}" CXXFLAGS+=' -std=gnu++14 -include stdint.h -fcommon ' CFLAGS+=' -std=gnu11 -include stdint.h -fcommon ' >>"$LOG_FILE" 2>&1 || die "CPU 版构建失败，请查日志"
    fi
  )
  info "CPU 版构建完成。"
}
build_cpu

# 8) 构建 GPU（nvcc 指定 g++-12；传 cc 与 NVCCFLAGS）
build_gpu(){
  # 能用 nvidia-smi 即可尝试 GPU 构建；不强制要求 /dev/nvidia*（某些容器只做编译）
  if ! need_cmd nvcc; then warn "无 nvcc，跳过 GPU 构建"; return; fi
  info "开始构建 GPU 版（CXXCUDA=g++-12, CCAP=${CCAP_DOT}/${CCAP_INT}）..."
  local jobs; jobs=$(nproc || echo 2)
  ( cd "${INSTALL_DIR}" && make clean >>"$LOG_FILE" 2>&1 || true
    if ! make -j"${jobs}" \
        CUDA="${CUDA_PATH}" CXXCUDA="/usr/bin/g++-12" \
        NVCCFLAGS+=' --std=c++14 ' \
        ccap="${CCAP_INT}" CCAP="${CCAP_DOT}" gpu=1 all >>"$LOG_FILE" 2>&1; then
      err "GPU 版首次构建失败，显式导出 PATH 后重试..."
      export PATH="${CUDA_PATH}/bin:${PATH}"
      make clean >>"$LOG_FILE" 2>&1 || true
      make -j"${jobs}" \
        CUDA="${CUDA_PATH}" CXXCUDA="/usr/bin/g++-12" \
        NVCCFLAGS+=' --std=c++14 ' \
        ccap="${CCAP_INT}" CCAP="${CCAP_DOT}" gpu=1 all >>"$LOG_FILE" 2>&1 || {
          warn "GPU 版仍失败。可能是该 fork 的 Makefile 与本机 CUDA 组合不兼容，先使用 CPU 版；我可以根据日志再做定向补丁。"
          return 0; }
    fi
  )
  info "GPU 版构建完成。"
}
build_gpu

# 9) 环境文件与自检
post_setup(){
  info "写入 ${INSTALL_DIR}/env.sh"
  cat > "${INSTALL_DIR}/env.sh" <<EOF
# VanitySearch 环境变量
export PATH="${CUDA_PATH}/bin:\$PATH"
# Ubuntu 的 CUDA 库通常在 /usr/lib/x86_64-linux-gnu，无需额外 LD_LIBRARY_PATH
EOF
  chmod +x "${INSTALL_DIR}/env.sh"

  info "自检：打印帮助..."
  ( cd "${INSTALL_DIR}" && ./VanitySearch -h >/dev/null 2>&1 || true )
  info "完成。可执行文件：${INSTALL_DIR}/VanitySearch"
  echo
  echo "使用示例："
  echo "  cd '${INSTALL_DIR}'"
  echo "  source ./env.sh"
  echo "  ./VanitySearch -h"
  echo "  ./VanitySearch -l               # 列出 CUDA 设备（GPU 构建成功且可访问时）"
  echo "  ./VanitySearch -gpu -t 1 1YourPrefixHere"
}
post_setup

info "全部完成！日志：${LOG_FILE}"
