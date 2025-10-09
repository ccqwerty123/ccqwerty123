#!/usr/bin/env bash
# 自动安装并编译 VanitySearch（Ubuntu 24.04 适配，旧版 OpenSSL 强制链接）
# - 安装/编译 OpenSSL 1.0.1a 到 /opt/openssl-1.0.1a（no-fips，失败回退 no-asm）
# - 自动选择并安装可用的 gcc/g++ 版本
# - 自动检测 CUDA/ccap，优先 GPU 编译，失败回退 CPU-only
# - 强制 rpath 指向旧版 OpenSSL，避免运行期误连系统 OpenSSL 1.1/3.0
# - 对源码应用必要补丁（<cstdint>、byteswap 宏等）
# - Ubuntu 24.04 (noble) 亲测路径与机制

set -euo pipefail

SCRIPT_VERSION="4.3.0-zh-ubuntu24.04"
# 可通过环境变量覆盖
GITHUB_REPO="${GITHUB_REPO:-https://github.com/allinbit/VanitySearch.git}"
PROJECT_DIR="VanitySearch"

OPENSSL_VERSION="${OPENSSL_VERSION:-1.0.1a}"
OPENSSL_URL="${OPENSSL_URL:-https://www.openssl.org/source/old/1.0.1/openssl-${OPENSSL_VERSION}.tar.gz}"
OPENSSL_INSTALL_PATH="${OPENSSL_INSTALL_PATH:-/opt/openssl-${OPENSSL_VERSION}}"

USE_CN_MIRROR="${USE_CN_MIRROR:-0}"   # 设置为 1 切换为清华源
FORCE_CPU="${FORCE_CPU:-0}"           # 设置为 1 强制 CPU-only 构建

# 首选老版编译器以提高 OpenSSL 1.0.1a 兼容性；在 24.04 中 g++-12/13 常可用
C_COMPILER_CANDIDATES=("gcc-9" "gcc-12" "gcc-11" "gcc-10" "gcc-13" "gcc")
CXX_COMPILER_CANDIDATES=("g++-9" "g++-12" "g++-11" "g++-10" "g++-13" "g++")

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

install_or_pick_compiler() {
  pick_from_list() {
    local -n arr=$1
    local picked=""
    for c in "${arr[@]}"; do
      if command -v "$c" >/dev/null 2>&1; then picked="$c"; break; fi
    done
    echo "$picked"
  }

  install_first_available() {
    local -n arr=$1
    local picked="$(pick_from_list $1)"
    if [ -n "$picked" ]; then echo "$picked"; return 0; fi
    for c in "${arr[@]}"; do
      log "尝试安装编译器: $c ..."
      if run_sudo apt-get install -y "$c"; then
        ok "已安装: $c"
        echo "$c"
        return 0
      fi
      warn "安装 $c 失败，尝试下一候选。"
    done
    echo ""
  }

  log "选择/安装 C 与 C++ 编译器..."
  CHOSEN_CC="$(install_first_available C_COMPILER_CANDIDATES)"
  [ -n "$CHOSEN_CC" ] || err "未能安装/找到任何可用的 C 编译器。"
  CHOSEN_CXX="$(install_first_available CXX_COMPILER_CANDIDATES)"
  [ -n "$CHOSEN_CXX" ] || err "未能安装/找到任何可用的 C++ 编译器。"
  ok "C 编译器: $CHOSEN_CC, C++ 编译器: $CHOSEN_CXX"
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

  export CC="$(command -v "$CHOSEN_CC")"
  log "使用编译器: $CC"

  log "配置 OpenSSL（shared + no-fips）..."
  if ! ./config shared no-fips --prefix="${OPENSSL_INSTALL_PATH}"; then
    err "OpenSSL ./config 失败"
  fi

  log "编译 OpenSSL ..."
  if ! make -j"$(nproc)"; then
    warn "常规编译失败，使用 no-asm 回退重试（在新架构上常见）"
    make clean || true
    ./config shared no-asm no-fips --prefix="${OPENSSL_INSTALL_PATH}" || err "config(no-asm) 失败"
    make -j"$(nproc)" || err "OpenSSL 构建失败"
  fi

  log "安装 OpenSSL ..."
  run_sudo make install
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
  NVCC_VER=$(echo "$NVCC_VER_STR" | sed -n 's/.*release KATEX_INLINE_OPEN[0-9]\+KATEX_INLINE_CLOSE\.KATEX_INLINE_OPEN[0-9]\+KATEX_INLINE_CLOSE.*/\1.\2/p')
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
  # 粗略映射，覆盖常见版本（若不匹配将通过 -allow-unsupported-compiler 容错）
  local v="$1"
  local major="${v%%.*}"; local minor="${v##*.}"
  local max=13
  if [ -z "$v" ]; then echo 13; return; fi
  if [ "$major" -le 10 ]; then max=8
  elif [ "$major" -eq 11 ]; then
    if   [ "$minor" -le 4 ]; then max=10
    elif [ "$minor" -le 8 ]; then max=11
    else max=11
    fi
  elif [ "$major" -eq 12 ]; then
    if [ "$minor" -le 2 ]; then max=12
    else max=13
    fi
  else
    max=13
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
  # 依次找满足 <= max_allowed 的 g++-X
  for cxx in "${CXX_COMPILER_CANDIDATES[@]}"; do
    if ! command -v "$cxx" >/dev/null 2>&1; then continue; fi
    local ver=$("$cxx" -dumpversion | cut -d. -f1)
    if [ -z "$ver" ]; then continue; fi
    if [ "$ver" -le "$max_allowed" ]; then picked="$cxx"; break; fi
  done
  # 如果都没有，退而求其次：选一个可用的，并启用 -allow-unsupported-compiler
  if [ -z "$picked" ]; then
    warn "未找到满足 nvcc 支持范围的 g++，将使用 -allow-unsupported-compiler 容错。"
    picked="$(command -v "$CHOSEN_CXX" || true)"
    [ -n "$picked" ] || picked="$(command -v g++ || true)"
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

  # 为部分头文件添加 <cstdint>
  for f in "Timer.h" "hash/sha512.h" "hash/sha256.h"; do
    if [ -f "$f" ] && ! grep -qE '^\s*#include\s*<cstdint>' "$f"; then
      sed -i '1i #include <cstdint>\n' "$f"
      ok "已为 $f 添加 #include <cstdint>"
    fi
  done

  # 为 sha256.cpp 添加 _byteswap_ulong 兼容
  if [ -f "hash/sha256.cpp" ] && ! grep -q "_byteswap_ulong" "hash/sha256.cpp"; then
    sed -i '/#define WRITEBE32/i \
#ifdef __GNUC__\n#include <byteswap.h>\n#define _byteswap_ulong(x) bswap_32(x)\n#endif\n' "hash/sha256.cpp"
    ok "已为 sha256.cpp 添加 GNU byteswap 兼容定义"
  fi
  cd -
}

configure_makefile() {
  log "配置 Makefile 以使用旧版 OpenSSL 与 CUDA ..."
  cd "$PROJECT_DIR"
  [ -f Makefile ] || err "未找到 Makefile"

  # 设置 CUDA 路径与 nvcc 主机编译器
  if [ "${WANT_GPU}" = "1" ]; then
    sed -i "s|^CUDA[[:space:]]*=.*|CUDA       = ${DETECTED_CUDA_PATH}|" Makefile || true
    sed -i "s|^CXXCUDA[[:space:]]*=.*|CXXCUDA    = $(command -v "${DETECTED_CXXCUDA}")|" Makefile || true
    # 容错编译器版本（若超纲）
    if ! grep -q 'NVCCFLAGS' Makefile; then
      echo -e "\nNVCCFLAGS += -O3 -use_fast_math -allow-unsupported-compiler" >> Makefile
    elif ! grep -q 'allow-unsupported-compiler' Makefile; then
      sed -i 's|^NVCCFLAGS.*|& -allow-unsupported-compiler|' Makefile
    fi
  fi

  # 强制链接指定 OpenSSL
  if ! grep -q 'SSLROOT' Makefile; then
    cat >> Makefile <<EOF

# Injected by installer: force legacy OpenSSL
SSLROOT := ${OPENSSL_INSTALL_PATH}
CFLAGS  += -I\$(SSLROOT)/include
CXXFLAGS+= -I\$(SSLROOT)/include
LDFLAGS += -L\$(SSLROOT)/lib -Wl,-rpath,\$(SSLROOT)/lib
LDLIBS  += -lssl -lcrypto
EOF
  else
    # 若已有，确保包含 rpath 与包含目录
    sed -i "s|^SSLROOT.*|SSLROOT := ${OPENSSL_INSTALL_PATH}|" Makefile
    grep -q '\-Wl,\-rpath' Makefile || sed -i 's|^LDFLAGS.*|& -Wl,-rpath,$(SSLROOT)/lib|' Makefile
  fi

  cd -
  ok "Makefile 配置完成。"
}

build_project() {
  log "开始编译 VanitySearch ..."
  export CC="$(command -v "$CHOSEN_CC")"
  export CXX="$(command -v "$CHOSEN_CXX")"
  export LD_LIBRARY_PATH="${OPENSSL_INSTALL_PATH}/lib:${LD_LIBRARY_PATH:-}"

  cd "$PROJECT_DIR"
  make clean >/dev/null 2>&1 || true

  if [ "${WANT_GPU}" = "1" ]; then
    log "执行 GPU 构建：ccap=${DETECTED_CCAP}"
    if ! make -j"$(nproc)" gpu=1 ccap="${DETECTED_CCAP}" CC="$CC" CXX="$CXX" CXXCUDA="$(command -v "${DETECTED_CXXCUDA}")" all; then
      warn "GPU 构建失败，回退到 CPU-only 构建。"
      WANT_GPU=0
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
  log "校验动态库链接是否指向旧版 OpenSSL ..."
  if command -v ldd >/dev/null 2>&1; then
    ldd ./VanitySearch | egrep 'ssl|crypto' || true
  fi

  # 期望 libssl.so.1.0.0/libcrypto.so.1.0.0 来自 OPENSSL_INSTALL_PATH
  local bad_link=0
  if ldd ./VanitySearch | grep -q "libssl.so.3"; then bad_link=1; fi
  if ldd ./VanitySearch | grep -q "libcrypto.so.3"; then bad_link=1; fi
  if [ $bad_link -eq 1 ]; then
    warn "检测到仍链接到了系统 OpenSSL 3.x。请检查 Makefile 注入是否生效与 rpath 是否存在。"
    warn "已设置 LD_LIBRARY_PATH，可先尝试直接运行；如仍异常，请反馈 ldd 输出。"
  fi

  log "运行程序查看帮助输出 ..."
  ./VanitySearch -h | head -n 20 || true
  ok "验证完成。可执行文件路径：$(pwd)/VanitySearch"
  cd -
}

main() {
  echo -e "${C_BOLD}--- VanitySearch 自动安装脚本 v${SCRIPT_VERSION} (Ubuntu 24.04) ---${C_RESET}"
  need_sudo
  apt_update_once
  switch_to_cn_mirror
  install_common_deps
  install_or_pick_compiler
  install_openssl_legacy
  detect_cuda_env
  choose_cxx_for_nvcc
  download_source
  patch_source_code
  configure_makefile
  build_project
  validate_linkage_and_run

  echo -e "${C_BOLD}使用示例：${C_RESET}"
  echo -e "  ${C_YELLOW}cd ${PROJECT_DIR}${C_RESET}"
  echo -e "  ${C_YELLOW}./VanitySearch -stop -t 0 -gpu -bits 28 -r 50000 12jbtzBb54r97TCwW3G1gCFoumpckRAPdY${C_RESET}  # GPU 示例"
  echo -e "  ${C_YELLOW}./VanitySearch -stop -t 2 -bits 28 -r 5 12jbtzBb54r97TCwW3G1gCFoumpckRAPdY${C_RESET}      # CPU 示例"
  echo
  ok "安装与构建完成。祝你跑得快！"
}

main "$@"
