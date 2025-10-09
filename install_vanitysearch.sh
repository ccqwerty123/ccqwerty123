#!/bin/bash

#=================================================================================
# 脚本名称: install_compilers.sh
# 脚本功能: 为 VanitySearch 项目准备多版本 GCC/G++ 编译环境
# 适用系统: Ubuntu 及其衍生版 (如 18.04, 20.04)
#=================================================================================

# --- 颜色定义，用于美化输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 函数：检查是否以 root 权限运行 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本需要以 root 权限运行。${NC}"
        echo -e "${YELLOW}请使用 'sudo ./install_compilers.sh' 来执行。${NC}"
        exit 1
    fi
}

# --- 函数：设置国内软件源 (清华源) ---
setup_sources() {
    echo -e "${BLUE}>>> 步骤 1: 开始设置国内软件源 (清华大学镜像源)...${NC}"
    
    # 获取 Ubuntu 版本代号，例如 bionic (18.04), focal (20.04)
    UBUNTU_CODENAME=$(lsb_release -cs)
    
    if [ -z "$UBUNTU_CODENAME" ]; then
        echo -e "${RED}错误: 无法检测到您的 Ubuntu 版本代号。脚本终止。${NC}"
        exit 1
    fi
    echo -e "${GREEN}检测到您的 Ubuntu 版本代号为: ${UBUNTU_CODENAME}${NC}"

    # 备份原始的 sources.list 文件
    echo "备份当前的 /etc/apt/sources.list 文件为 /etc/apt/sources.list.bak..."
    mv /etc/apt/sources.list /etc/apt/sources.list.bak
    
    # 创建新的 sources.list 文件
    echo "正在写入新的清华大学镜像源配置..."
    cat > /etc/apt/sources.list <<EOF
# 默认注释了源码镜像以提高速度
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

    echo -e "${GREEN}软件源配置成功！正在更新软件包列表...${NC}"
    apt-get update
    echo -e "${GREEN}软件包列表更新完成。${NC}"
}

# --- 函数：安装多版本编译器 ---
install_compilers() {
    echo -e "\n${BLUE}>>> 步骤 2: 开始安装多版本 GCC/G++ 编译器...${NC}"

    # 安装 'software-properties-common' 以便使用 'add-apt-repository'
    echo "安装 'software-properties-common'..."
    apt-get install -y software-properties-common
    
    # 添加 ubuntu-toolchain-r/test PPA，这是获取不同版本GCC的主要来源
    echo "添加 PPA: 'ppa:ubuntu-toolchain-r/test'..."
    add-apt-repository ppa:ubuntu-toolchain-r/test -y
    
    echo "再次更新软件包列表..."
    apt-get update

    # --- 尝试安装 GCC/G++ 7 ---
    echo -e "\n${YELLOW}--- 正在尝试安装 gcc-7 和 g++-7... ---${NC}"
    apt-get install -y gcc-7 g++-7
    
    # 检查 g++-7 是否安装成功
    if command -v g++-7 &> /dev/null; then
        echo -e "${GREEN}成功: g++-7 已成功安装！${NC}"
        g++-7 --version | head -n 1
    else
        echo -e "${RED}失败: 未能成功安装 g++-7。请检查上面的错误信息。${NC}"
    fi

    # --- 尝试安装 GCC/G++ 4.8 ---
    # 注意: 在较新的 Ubuntu 系统 (如 20.04+) 上，这步有很大概率会失败
    echo -e "\n${YELLOW}--- 正在尝试安装 gcc-4.8 和 g++-4.8... ---${NC}"
    echo -e "${YELLOW}注意: 在新的 Ubuntu 系统上，这步很可能会失败。如果失败是正常的。${NC}"
    apt-get install -y gcc-4.8 g++-4.8
    
    # 检查 g++-4.8 是否安装成功
    if command -v g++-4.8 &> /dev/null; then
        echo -e "${GREEN}成功: g++-4.8 已成功安装！${NC}"
        g++-4.8 --version | head -n 1
    else
        echo -e "${RED}失败: 未能成功安装 g++-4.8。这在较新的系统上是预期行为。${NC}"
        echo -e "${YELLOW}如果编译 CUDA 需要旧版编译器，您可能需要使用 Docker 等容器化技术来创建一个旧版系统环境。${NC}"
    fi
}


# --- 主程序逻辑 ---
main() {
    check_root
    setup_sources
    install_compilers

    echo -e "\n\n${BLUE}===================== 脚本执行完毕 =====================${NC}"
    echo -e "请检查上面的输出确认编译器安装情况。"
    echo -e "您现在可以通过版本号直接调用它们，例如：\n  ${GREEN}g++-7 -v${NC}\n  ${GREEN}g++-4.8 -v${NC} (如果安装成功的话)"
    echo -e "\n下一步是修改 VanitySearch 的 Makefile 文件，将 CXXCUDA 指向您需要的旧版本编译器路径，例如 /usr/bin/g++-4.8。"
    echo -e "${YELLOW}如果 g++-4.8 安装失败，您将无法继续编译需要旧版编译器的 CUDA 部分。${NC}"
    echo -e "${BLUE}========================================================${NC}"
}

# --- 运行主程序 ---
main
