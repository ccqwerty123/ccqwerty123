#!/bin/bash
#
# KeyHunt (CPU) 和 BitCrack (GPU) 的全自动安装与验证脚本
# 版本: 1.7.0 - 集成社区版 BitCrack 并简化编译流程
#
# 特性:
# 1.  APT 源自动修复: 脚本启动时自动切换到国内清华源，并解决常见的锁问题。
# 2.  版本控制: 启动时显示版本号。
# 3.  幂等性: 重复运行会跳过已完成的安装。
# 4.  智能验证: 通过捕获帮助命令的输出来判断是否成功，并显示输出。
# 5.  COMPUTE_CAP 检查: 自动检测并更新 BitCrack Makefile 中的 COMPUTE_CAP 值。
# 6.  embedcl 修复: (此部分已移除，新的代码库不再需要此步骤)。
# 7.  最终总结: 在脚本末尾明确报告每个工具的最终安装状态。
#

# --- 脚本版本 ---
SCRIPT_VERSION="1.7.0 - 集成社区版 BitCrack"

# --- Bash 颜色代码 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 脚本在遇到任何错误时立即停止执行 ---
set -e

# --- 用于最终总结的状态变量 ---
KEYHUNT_SUCCESS=false
BITCRACK_SUCCESS=false

# --- 函数：自动修复并更新 APT 源 ---
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
  
  local UBUNTU_CODENAME
  UBUNTU_CODENAME=$(lsb_release -cs)
  if [ -z "$UBUNTU_CODENAME" ]; then
      echo -e "${RED}错误: 无法确定 Ubuntu 版本代号。${NC}" >&2
      exit 1
  fi
  echo "[INFO] 检测到 Ubuntu 版本代号: ${UBUNTU_CODENAME}"
  
  bash -c "cat > /etc/apt/sources.list" <<EOF
# 由安装脚本于 $(date) 生成 (v${version})
# 腾讯云源 (Tencent Cloud Mirror)
deb http://mirrors.tencentyun.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://mirrors.tencentyun.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://mirrors.tencentyun.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://mirrors.tencentyun.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse

# 清华大学 TUNA 源 (Tsinghua University TUNA Mirror) - 已注释
#deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
#deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
#deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
#deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

  # 6. 更新软件包列表
  echo "[INFO] 在纯净源环境下执行 apt-get update..."
  apt-get update -o Acquire::Retries=3 -o Acquire::Check-Valid-Until=false || { echo "[ERR ] apt-get update 最终失败！请检查网络。" >&2; exit 1; }
  
  echo "[INFO] APT 源与更新准备就绪。"
}

# --- 函数：检测 NVIDIA GPU 的计算能力 ---
detect_compute_capability() {
    if ! command -v nvidia-smi &> /dev/null; then
        echo -e "${RED}错误: 未找到 'nvidia-smi' 命令。请确保 NVIDIA 驱动已正确安装。${NC}" >&2
        exit 1
    fi
    local COMPUTE_CAP
    COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits | head -n 1 | tr -d '.')
    if [ -z "$COMPUTE_CAP" ]; then
        echo -e "${RED}错误: 无法确定 GPU 计算能力。${NC}" >&2
        exit 1
    fi
    echo "$COMPUTE_CAP"
}

# --- 修改说明：以下函数被移除，因为用户指定的新版 BitCrack 仓库简化了编译流程，不再需要这些复杂的预处理步骤。---
# --- 已移除 build_embedcl() 函数 ---
# --- 已移除 process_opencl_kernels() 函数 ---
# --- 已移除 compile_bitcrack() 函数 ---
# --- 已移除 check_and_update_compute_cap() 函数，其核心逻辑被整合到主函数中，使流程更清晰。---

# --- 主脚本逻辑 ---
main() {
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${CYAN}  运行安装脚本 ${SCRIPT_VERSION}               ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    # 0. 自动修复并更新 APT 源
    echo -e "\n${YELLOW}---> 第 0 步: 自动修复并更新 APT 源...${NC}"
    fix_apt_sources
    echo -e "${GREEN}---> APT 源已成功修复并更新。${NC}"

    # 1. 安装系统依赖
    echo -e "\n${YELLOW}---> 第 1 步: 检查并安装系统依赖包...${NC}"
    # --- 修改说明：根据新版 BitCrack 的依赖需求，移除了 ocl-icd-opencl-dev 和 nvidia-opencl-dev，因为我们主要关注 CUDA 版本。---
    apt-get install -y build-essential git cmake python3 python3-pip \
        libgmp-dev libsecp256k1-dev nvidia-cuda-toolkit
    echo -e "${GREEN}---> 依赖包检查与安装完成。${NC}"

    # 2. 安装 KeyHunt
    echo -e "\n${YELLOW}---> 第 2 步: 检查并安装 KeyHunt (用于 CPU)...${NC}"
    if [ ! -f "keyhunt/keyhunt" ]; then
        echo -e "未找到 keyhunt 可执行文件，开始全新安装..."
        [ -d "keyhunt" ] && rm -rf keyhunt
        git clone https://github.com/albertobsd/keyhunt.git
        cd keyhunt
        make clean || true
        make -j$(nproc)
        cd ..
        echo -e "${GREEN}---> KeyHunt 全新安装完成！${NC}"
    else
        echo -e "${GREEN}---> 检测到 keyhunt 已安装，跳过安装步骤。${NC}"
    fi
    
    # 验证 KeyHunt
    echo -e "${YELLOW}---> 正在验证 KeyHunt...${NC}"
    validation_output=$(./keyhunt/keyhunt -h 2>/dev/null || true)
    if [ -n "$validation_output" ]; then
        echo -e "${CYAN}--- KeyHunt 帮助信息 (前10行) ---${NC}"
        echo "$validation_output" | head -n 10
        echo -e "${CYAN}--------------------------${NC}"
        KEYHUNT_SUCCESS=true
    else
        echo -e "${RED}---> KeyHunt 验证失败：无法执行或没有帮助信息输出。${NC}"
    fi

    # 3. 安装/检查 BitCrack
    echo -e "\n${YELLOW}---> 第 3 步: 检查并安装 BitCrack (用于 GPU)...${NC}"
    
    # 检测当前 GPU 的计算能力
    echo -e "${YELLOW}---> 正在检测 NVIDIA GPU 计算能力...${NC}"
    local DETECTED_CAP
    DETECTED_CAP=$(detect_compute_capability)
    echo -e "${GREEN}---> 已检测到计算能力为: ${DETECTED_CAP}${NC}"
    
    local needs_install=false
    local makefile_path="BitCrack/Makefile"

    # 检查 BitCrack 是否需要安装或重新编译
    if [ ! -f "BitCrack/bin/cuBitCrack" ]; then
        echo -e "未找到 BitCrack 可执行文件，需要进行全新安装。"
        needs_install=true
    else
        echo -e "${GREEN}---> 检测到 BitCrack 已安装，正在检查 COMPUTE_CAP 设置...${NC}"
        if [ ! -f "$makefile_path" ]; then
            echo -e "${YELLOW}---> Makefile 文件丢失，需要重新安装。${NC}"
            needs_install=true
        else
            # 从 Makefile 中提取当前的 COMPUTE_CAP 值
            local makefile_cap
            makefile_cap=$(grep -m1 '^[[:space:]]*COMPUTE_CAP[[:space:]]*=' "$makefile_path" 2>/dev/null | sed -E 's/^[[:space:]]*COMPUTE_CAP[[:space:]]*=[[:space:]]*//' | tr -d '[:space:]' | sed 's/#.*//' || true)
            echo -e "Makefile 中的 COMPUTE_CAP=${makefile_cap:-<未设置>}"
            echo -e "当前 GPU 的 COMPUTE_CAP=${DETECTED_CAP}"
            
            if [ "$makefile_cap" != "$DETECTED_CAP" ]; then
                echo -e "${YELLOW}---> COMPUTE_CAP 值不匹配，需要重新编译！${NC}"
                needs_install=true
            else
                echo -e "${GREEN}---> COMPUTE_CAP 值正确，无需重新编译。${NC}"
            fi
        fi
    fi
    
    # 如果需要安装或重新编译，则执行以下步骤
    if [ "$needs_install" = true ]; then
        # --- 新增说明：在重新安装前，彻底删除旧目录，确保一个干净的编译环境。---
        echo -e "${YELLOW}---> 准备全新安装环境...${NC}"
        [ -d "BitCrack" ] && rm -rf BitCrack
        
        # --- 修改说明：更换为用户指定的、编译流程更简单的 BitCrack 仓库地址。---
        echo -e "${YELLOW}---> 正在克隆 BitCrack 项目...${NC}"
        git clone https://github.com/ccqwerty123/BitCrack.git

        cd BitCrack
        
        # --- 新增说明：这是此脚本的核心功能之一。自动将检测到的GPU算力写入Makefile，避免手动修改的麻烦。---
        echo -e "${YELLOW}---> 正在自动更新 Makefile 中的 COMPUTE_CAP=${DETECTED_CAP}...${NC}"
        sed -i "s/^\s*COMPUTE_CAP\s*=.*/COMPUTE_CAP=${DETECTED_CAP}/" Makefile
        echo -e "${GREEN}---> Makefile 更新完成。${NC}"
        
        # --- 修改说明：使用用户提供的、经过测试的简化编译命令，专注于编译 CUDA 版本。---
        echo -e "${YELLOW}---> 开始编译 BitCrack (CUDA)...${NC}"
        make clean || true
        make BUILD_CUDA=1 -j$(nproc)
        
        cd ..
        echo -e "${GREEN}---> BitCrack 安装/编译完成！${NC}"
    fi
    
    # 验证 BitCrack
    echo -e "${YELLOW}---> 正在验证 BitCrack...${NC}"
    if [ -f "BitCrack/bin/cuBitCrack" ]; then
        validation_output=$(./BitCrack/bin/cuBitCrack --help 2>/dev/null || true)
        if [ -n "$validation_output" ]; then
            echo -e "${CYAN}--- BitCrack (CUDA) 帮助信息 (前10行) ---${NC}"
            echo "$validation_output" | head -n 10
            echo -e "${CYAN}---------------------------${NC}"
            BITCRACK_SUCCESS=true
        else
            # --- 新增说明：如果文件存在但无法执行，给出更详细的错误提示。---
            echo -e "${RED}---> BitCrack 验证失败：可执行文件存在，但无法运行或没有帮助信息输出。可能是编译失败或运行时依赖问题。${NC}"
        fi
    else
        echo -e "${RED}---> BitCrack 验证失败：在 BitCrack/bin/ 目录下未找到可执行文件 cuBitCrack。${NC}"
    fi

    # --- 最终总结 ---
    echo -e "\n${CYAN}=====================================================${NC}"
    echo -e "${CYAN}                     安装总结                      ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    if [ "$KEYHUNT_SUCCESS" = true ]; then
        echo -e "  [ ${GREEN}成功${NC} ] KeyHunt (CPU)"
        echo -e "          路径: $(pwd)/keyhunt/keyhunt"
    else
        echo -e "  [ ${RED}失败${NC} ] KeyHunt (CPU)"
    fi

    if [ "$BITCRACK_SUCCESS" = true ]; then
        echo -e "  [ ${GREEN}成功${NC} ] BitCrack (GPU) - COMPUTE_CAP: ${DETECTED_CAP}"
        if [ -f "BitCrack/bin/cuBitCrack" ]; then
            echo -e "          CUDA 路径: $(pwd)/BitCrack/bin/cuBitCrack"
        fi
    else
        echo -e "  [ ${RED}失败${NC} ] BitCrack (GPU)"
    fi
    echo -e "${CYAN}=====================================================${NC}"

    echo -e "\n${GREEN}安装脚本执行完成 (版本: ${SCRIPT_VERSION})。${NC}"
}

# --- 运行主函数 ---
main
