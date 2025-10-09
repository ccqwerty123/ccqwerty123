#!/usr/bin/env bash
# VanitySearch 自动安装脚本 - Ubuntu 24.04 优化版
# 根据官方文档要求：VanitySearch 需要 gcc >= 7
# OpenSSL 1.0.1a 仅构建库，不构建测试

set -euo pipefail

SCRIPT_VERSION="4.4.0-zh-ubuntu24.04-official"
GITHUB_REPO="${GITHUB_REPO:-https://github.com/alek76-2/VanitySearch.git}"
PROJECT_DIR="VanitySearch"

OPENSSL_VERSION="${OPENSSL_VERSION:-1.0.1a}"
OPENSSL_URL="${OPENSSL_URL:-https://www.openssl.org/source/old/1.0.1/openssl-${OPENSSL_VERSION}.tar.gz}"
OPENSSL_INSTALL_PATH="${OPENSSL_INSTALL_PATH:-/opt/openssl-${OPENSSL_VERSION}}"

USE_CN_MIRROR="${USE_CN_MIRROR:-0}"
FORCE_CPU="${FORCE_CPU:-0}"

# 官方要求 VanitySearch 使用 gcc >= 7
# OpenSSL 1.0.1a 用老版本编译更稳定
OPENSSL_CC_CANDIDATES=("gcc-8" "gcc-9" "gcc-10" "gcc-7" "gcc")
VANITYSEARCH_CC_CANDIDATES=("gcc-13" "gcc-12" "gcc-11" "gcc-10" "gcc-9" "gcc-8" "gcc-7" "gcc")
VANITYSEARCH_CXX_CANDIDATES=("g++-13" "g++-12" "g++-11" "g++-10" "g++-9" "g++-8" "g++-7" "g++")

# 彩色输出
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'
log() { echo -e "${C_CYAN}[信息]${C_RESET} $*"; }
ok()  { echo -e "${C_GREEN}[成功]${C_RESET} ${C_BOLD}$*${C_RESET}"; }
warn(){ echo -e "${C_YELLOW}[警告]${C_RESET} $*"; }
err() { echo -e "${C_RED}[错误]${C_RESET} $*" >&2; exit 1; }

trap 'echo -e "\n${C_RED}脚本异常终止。请上滚查看报错信息。${C_RESET}"' ERR

need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      err "需要 root 权限或 sudo，请以 root 运行或安装 sudo。"
    fi
  fi
}

run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

apt_update_once() {
  log "更新 APT 索引..."
  run_sudo apt-get update -y
}

switch_to_cn_mirror() {
  if [ "$USE_CN_MIRROR" = "1" ]; then
    log "切换到清华镜像源（Ubuntu 24.04 noble）..."
    local codename; codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    [ "$codename" = "noble" ] || warn "系统代号不是 noble（实际: $codename），仍将尝试写 sources.list。"
    run_sudo tee /etc/apt/sources.list >/dev/null <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-security main restricted universe multiverse
EOF
    apt_update_once
    ok "APT 镜像切换完成。"
  else
    log "使用系统默认 APT 源（可用 USE_CN_MIRROR=1 切换国内镜像）。"
  fi
}

install_common_deps() {
  log "安装常用构建依赖..."
  run_sudo apt-get install -y build-essential git ca-certificates wget curl xz-utils perl pkg-config zlib1g-dev make
  ok "常用依赖安装完成。"
}

pick_compiler_from_list() {
  local -n arr=$1
  local min_version=${2:-0}
  local picked=""
  
  for c in "${arr[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then continue; fi
    
    # 检查版本号
    local ver=$("$c" -dumpversion 2>/dev/null | cut -d. -f1)
    if [ -z "$ver" ]; then continue; fi
    if [ "$ver" -ge "$min_version" ]; then
      picked="$c"
      break
    fi
  done
  echo "$picked"
}

install_first_available() {
  local -n arr=$1
  local min_version=${2:-0}
  
  # 先尝试找已安装的
  local picked="$(pick_compiler_from_list $1 $min_version)"
  if [ -n "$picked" ]; then echo "$picked"; return 0; fi
  
  # 尝试安装
  for c in "${arr[@]}"; do
    log "尝试安装编译器: $c ..."
    if run_sudo apt-get install -y "$c" 2>/dev/null; then
      local ver=$("$c" -dumpversion 2>/dev/null | cut -d. -f1 || echo "0")
      if [ "$ver" -ge "$min_version" ]; then
        ok "已安装: $c (版本 $ver)"
        echo "$c"
        return 0
      fi
    fi
    warn "安装 $c 失败或版本不满足要求，尝试下一候选。"
  done
  echo ""
}

install_compilers() {
  log "选择/安装编译器..."
  
  # OpenSSL 编译器（无版本要求）
  OPENSSL_CC="$(install_first_available OPENSSL_CC_CANDIDATES 0)"
  [ -n "$OPENSSL_CC" ] || err "未能安装/找到 OpenSSL 的 C 编译器。"
  
  # VanitySearch 编译器（需要 gcc >= 7）
  CHOSEN_CC="$(install_first_available VANITYSEARCH_CC_CANDIDATES 7)"
  [ -n "$CHOSEN_CC" ] || err "未能找到 gcc >= 7。VanitySearch 官方要求使用 gcc 7 或更高版本。"
  
  CHOSEN_CXX="$(install_first_available VANITYSEARCH_CXX_CANDIDATES 7)"
  [ -n "$CHOSEN_CXX" ] || err "未能找到 g++ >= 7。"
  
  local gcc_ver=$("$CHOSEN_CC" -dumpversion)
  ok "OpenSSL 编译器: $OPENSSL_CC"
  ok "VanitySearch C 编译器: $CHOSEN_CC (版本 $gcc_ver)"
  ok "VanitySearch C++ 编译器: $CHOSEN_CXX"
}

install_openssl_legacy() {
  if [ -x "${OPENSSL_INSTALL_PATH}/bin/openssl" ]; then
    ok "检测到旧版 OpenSSL 已安装: ${OPENSSL_INSTALL_PATH}"
    return
  fi

  log "准备从源码安装 OpenSSL ${OPENSSL_VERSION} 到 ${OPENSSL_INSTALL_PATH} ..."
  local build_dir; build_dir=$(mktemp -d)
  pushd "$build_dir" >/dev/null

  log "下载 OpenSSL 源码: ${OPENSSL_URL}"
  wget -q "${OPENSSL_URL}" -O "openssl-${OPENSSL_VERSION}.tar.gz" || err "下载 OpenSSL 失败"
  tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
  cd "openssl-${OPENSSL_VERSION}"

  # 使用老版本 gcc 编译 OpenSSL，禁用 LTO
  export CC="$(command -v "$OPENSSL_CC")"
  export CFLAGS="-fno-lto -fno-use-linker-plugin -O2"
  export LDFLAGS="-fno-lto -fno-use-linker-plugin"
  
  log "使用编译器: $CC (已禁用 LTO)"

  # 配置：shared + no-fips + no-asm（最稳定）
  log "配置 OpenSSL（shared, no-fips, no-asm）..."
  if ! ./config shared no-asm no-fips --prefix="${OPENSSL_INSTALL_PATH}"; then
    err "OpenSSL ./config 失败"
  fi

  # 关键：只构建库，不构建测试（避免链接问题）
  log "编译 OpenSSL 库（跳过测试）..."
  if ! make -j"$(nproc)" build_libs build_apps; then
    err "OpenSSL 库构建失败"
  fi

  log "安装 OpenSSL ..."
  run_sudo make install_sw  # install_sw 只安装软件，不安装文档和测试
  run_sudo ldconfig "${OPENSSL_INSTALL_PATH}/lib" || true

  popd >/dev/null
  rm -rf "$build_dir"

  ok "OpenSSL ${OPENSSL_VERSION} 安装完成：${OPENSSL_INSTALL_PATH}"
  "${OPENSSL_INSTALL_PATH}/bin/openssl" version -a || true
}

detect_cuda_env() {
  WANT_GPU=1
  [ "$FORCE_CPU" = "1" ] && { warn "FORCE_CPU=1 已设置，跳过 GPU 检测。"; WANT_GPU=0; return; }

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "未检测到 nvidia-smi，将编译 CPU 版本。"
    WANT_GPU=0; return
  fi
  if ! command -v nvcc >/dev/null 2>&1; then
    warn "未检测到 nvcc（CUDA Toolkit），将编译 CPU 版本。"
    WANT_GPU=0; return
  fi

  NVCC_VER_STR=$(nvcc --version | grep -i "release" || true)
  NVCC_VER=$(echo "$NVCC_VER_STR" | sed -n 's/.*release \([0-9]\+\)\.\([0-9]\+\).*/\1.\2/p')
  log "检测到 CUDA nvcc 版本: ${NVCC_VER_STR}"

  # 检测 compute capability
  local cap=""
  cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d '. ' || true)
  if [ -z "$cap" ]; then
    local maj min
    maj=$(nvidia-smi --query-gpu=compute_capability.major --format=csv,noheader 2>/dev/null | head -n1 || true)
    min=$(nvidia-smi --query-gpu=compute_capability.minor --format=csv,noheader 2>/dev/null | head -n1 || true)
    if [ -n "${maj:-}" ] && [ -n "${min:-}" ]; then
      cap="${maj}${min}"
    fi
  fi
  if [ -z "$cap" ]; then
    warn "无法自动获得 compute capability，默认使用 75（Turing）。"
    DETECTED_CCAP="75"
  else
    DETECTED_CCAP="$cap"
  fi
  ok "GPU compute capability: ${DETECTED_CCAP}"

  # CUDA 路径
  if [ -L /usr/local/cuda ]; then
    DETECTED_CUDA_PATH="$(readlink -f /usr/local/cuda)"
  else
    local nvcc_path; nvcc_path="$(command -v nvcc)"
    DETECTED_CUDA_PATH="$(dirname "$(dirname "$(readlink -f "$nvcc_path")")")"
  fi
  ok "CUDA 安装路径: ${DETECTED_CUDA_PATH}"
}

max_supported_gxx_for_cuda() {
  local v="$1"
  local major="${v%%.*}"
  local max=13
  
  if [ -z "$v" ]; then echo 13; return; fi
  
  # CUDA 版本与 GCC 兼容性映射
  if [ "$major" -le 10 ]; then max=8
  elif [ "$major" -eq 11 ]; then max=11
  elif [ "$major" -eq 12 ]; then max=13
  else max=13
  fi
  echo "$max"
}

choose_cxx_for_nvcc() {
  if [ "${WANT_GPU}" != "1" ]; then
    DETECTED_CXXCUDA=""
    return
  fi
  
  local max_allowed; max_allowed=$(max_supported_gxx_for_cuda "${NVCC_VER:-}")
  log "nvcc 允许的最大 g++ 主版本约为: ${max_allowed}"
  
  local picked=""
  # 找满足 nvcc 要求且 >= 7 的编译器
  for cxx in "${VANITYSEARCH_CXX_CANDIDATES[@]}"; do
    if ! command -v "$cxx" >/dev/null 2>&1; then continue; fi
    local ver=$("$cxx" -dumpversion | cut -d. -f1)
    if [ -z "$ver" ]; then continue; fi
    if [ "$ver" -ge 7 ] && [ "$ver" -le "$max_allowed" ]; then
      picked="$cxx"
      break
    fi
  done
  
  # 如果没找到合适的，用 CHOSEN_CXX 并启用容错
  if [ -z "$picked" ]; then
    warn "未找到同时满足 nvcc 和 VanitySearch(>=7) 要求的 g++，将使用 $CHOSEN_CXX 并启用 -allow-unsupported-compiler"
    picked="$CHOSEN_CXX"
  fi
  
  [ -n "$picked" ] || err "未能为 nvcc 选择 C++ 编译器。"
  DETECTED_CXXCUDA="$picked"
  ok "nvcc 主机编译器: ${DETECTED_CXXCUDA}"
}

download_source() {
  log "拉取源代码仓库: ${GITHUB_REPO}"
  [ -d "$PROJECT_DIR" ] && { warn "存在旧目录 $PROJECT_DIR，将删除。"; run_sudo rm -rf "$PROJECT_DIR"; }
  git clone --depth 1 "$GITHUB_REPO" "$PROJECT_DIR" || err "Git 克隆失败"
  ok "源代码下载完成。"
}

patch_source_code() {
  log "应用源码兼容性补丁..."
  cd "$PROJECT_DIR"

  # 添加 <cstdint> 头文件
  for f in "Timer.h" "hash/sha512.h" "hash/sha256.h"; do
    if [ -f "$f" ] && ! grep -qE '^\s*#include\s*<cstdint>' "$f"; then
      sed -i '1i #include <cstdint>\n' "$f"
      ok "已为 $f 添加 #include <cstdint>"
    fi
  done

  # 添加 byteswap 兼容
  if [ -f "hash/sha256.cpp" ] && ! grep -q "_byteswap_ulong" "hash/sha256.cpp"; then
    sed -i '/#define WRITEBE32/i \
#ifdef __GNUC__\n#include <byteswap.h>\n#define _byteswap_ulong(x) bswap_32(x)\n#endif\n' "hash/sha256.cpp"
    ok "已为 sha256.cpp 添加 GNU byteswap 兼容定义"
  fi
  cd -
}

configure_makefile() {
  log "配置 Makefile..."
  cd "$PROJECT_DIR"
  [ -f Makefile ] || err "未找到 Makefile"

  # 配置 CUDA（如果需要）
  if [ "${WANT_GPU}" = "1" ]; then
    sed -i "s|^CUDA[[:space:]]*=.*|CUDA       = ${DETECTED_CUDA_PATH}|" Makefile || true
    sed -i "s|^CXXCUDA[[:space:]]*=.*|CXXCUDA    = $(command -v "${DETECTED_CXXCUDA}")|" Makefile || true
    
    # 添加 NVCC 标志
    if ! grep -q 'NVCCFLAGS' Makefile; then
      echo -e "\nNVCCFLAGS += -O3 -use_fast_math -allow-unsupported-compiler" >> Makefile
    elif ! grep -q 'allow-unsupported-compiler' Makefile; then
      sed -i 's|^NVCCFLAGS.*|& -allow-unsupported-compiler|' Makefile
    fi
  fi

  # 配置 OpenSSL（关键部分）
  if ! grep -q 'SSLROOT' Makefile; then
    cat >> Makefile <<EOF

# 由安装脚本注入：强制使用旧版 OpenSSL
SSLROOT := ${OPENSSL_INSTALL_PATH}
CFLAGS  += -I\$(SSLROOT)/include
CXXFLAGS+= -I\$(SSLROOT)/include
LDFLAGS += -L\$(SSLROOT)/lib -Wl,-rpath,\$(SSLROOT)/lib
LDLIBS  += -lssl -lcrypto
EOF
  else
    sed -i "s|^SSLROOT.*|SSLROOT := ${OPENSSL_INSTALL_PATH}|" Makefile
    grep -q '\-Wl,\-rpath' Makefile || sed -i 's|^LDFLAGS.*|& -Wl,-rpath,$(SSLROOT)/lib|' Makefile
  fi

  cd -
  ok "Makefile 配置完成。"
}

build_project() {
  log "开始编译 VanitySearch（使用 gcc >= 7）..."
  
  export CC="$(command -v "$CHOSEN_CC")"
  export CXX="$(command -v "$CHOSEN_CXX")"
  export LD_LIBRARY_PATH="${OPENSSL_INSTALL_PATH}/lib:${LD_LIBRARY_PATH:-}"

  cd "$PROJECT_DIR"
  make clean >/dev/null 2>&1 || true

  if [ "${WANT_GPU}" = "1" ]; then
    log "执行 GPU 构建：ccap=${DETECTED_CCAP}"
    if make -j"$(nproc)" gpu=1 ccap="${DETECTED_CCAP}" CC="$CC" CXX="$CXX" CXXCUDA="$(command -v "${DETECTED_CXXCUDA}")" all; then
      ok "GPU 版本编译成功"
    else
      warn "GPU 构建失败，回退到 CPU-only 构建。"
      WANT_GPU=0
      make clean >/dev/null 2>&1 || true
    fi
  fi

  if [ "${WANT_GPU}" != "1" ]; then
    log "执行 CPU-only 构建 ..."
    make -j"$(nproc)" CC="$CC" CXX="$CXX" all
  fi

  if [ -x ./VanitySearch ]; then
    ok "编译成功：$(pwd)/VanitySearch"
  else
    err "未生成可执行文件 VanitySearch。"
  fi
  cd -
}

validate_linkage_and_run() {
  cd "$PROJECT_DIR"
  log "校验动态库链接..."
  
  if command -v ldd >/dev/null 2>&1; then
    echo "--- 链接的 OpenSSL 库 ---"
    ldd ./VanitySearch | egrep 'ssl|crypto' || true
  fi

  # 检查是否错误链接到系统 OpenSSL
  local bad_link=0
  if ldd ./VanitySearch 2>/dev/null | grep -E "libssl\.so\.[^1]|libcrypto\.so\.[^1]" | grep -qv "${OPENSSL_INSTALL_PATH}"; then
    bad_link=1
  fi
  
  if [ $bad_link -eq 1 ]; then
    warn "⚠️  检测到可能链接了错误的 OpenSSL 版本"
    warn "已设置 LD_LIBRARY_PATH，运行时应该没问题"
  else
    ok "✓ OpenSSL 链接正确"
  fi

  log "运行程序验证..."
  if ./VanitySearch -h >/dev/null 2>&1; then
    ok "✓ 程序运行正常"
    ./VanitySearch -h | head -n 15
  else
    warn "程序运行出现问题，但可能仅是参数错误"
  fi
  
  cd -
}

main() {
  echo -e "${C_BOLD}╔════════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_BOLD}║  VanitySearch 自动安装脚本 v${SCRIPT_VERSION}  ║${C_RESET}"
  echo -e "${C_BOLD}║  Ubuntu 24.04 优化版 - 遵循官方文档要求           ║${C_RESET}"
  echo -e "${C_BOLD}╚════════════════════════════════════════════════════════════╝${C_RESET}"
  echo
  
  need_sudo
  apt_update_once
  switch_to_cn_mirror
  install_common_deps
  install_compilers
  install_openssl_legacy
  detect_cuda_env
  choose_cxx_for_nvcc
  download_source
  patch_source_code
  configure_makefile
  build_project
  validate_linkage_and_run

  echo
  echo -e "${C_BOLD}╔════════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_BOLD}║  安装完成！使用示例：                                 ║${C_RESET}"
  echo -e "${C_BOLD}╚════════════════════════════════════════════════════════════╝${C_RESET}"
  echo -e "  ${C_CYAN}cd ${PROJECT_DIR}${C_RESET}"
  echo
  if [ "${WANT_GPU}" = "1" ]; then
    echo -e "  ${C_YELLOW}# GPU 模式（推荐）${C_RESET}"
    echo -e "  ${C_GREEN}./VanitySearch -stop -t 0 -gpu -bits 28 -r 50000 1YourBitcoinAddress${C_RESET}"
  else
    echo -e "  ${C_YELLOW}# CPU 模式${C_RESET}"
    echo -e "  ${C_GREEN}./VanitySearch -stop -t 4 -bits 28 -r 5 1YourBitcoinAddress${C_RESET}"
  fi
  echo
  ok "🎉 所有步骤完成！"
}

main "$@"
