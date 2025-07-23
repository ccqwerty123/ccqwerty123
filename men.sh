#!/bin/bash

# --- START: 请在此处修改配置 ---
# 将下面的地址替换为您自己的门罗币 (XMR) 钱包地址
MY_WALLET_ADDRESS="47Z5E787p8bHJEEc2Bf878K86LHQcbKT6f8KEsU7ocmnQPKHNbHHdMNc4dW6drrR4egpHmkM2jTWkP1tg4wymd7DAtJD37L"
# --- END: 修改结束 ---


# --- 脚本参数 ---
# 获取最新的 XMRig 版本号
LATEST_VERSION=$(curl -s "https://api.github.com/repos/xmrig/xmrig/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")' | sed 's/v//')
# 构建下载链接 (使用兼容性最好的 linux-static 版本)
DOWNLOAD_URL="https://github.com/xmrig/xmrig/releases/download/v${LATEST_VERSION}/xmrig-${LATEST_VERSION}-linux-static-x64.tar.gz"
# 定义工作目录
WORKDIR="/tmp/xmrig-official-test"
# 后台会话名称
SESSION_NAME="official-xmrig-test"

# 1. 安全检查：检查钱包地址是否已修改
if [ "$MY_WALLET_ADDRESS" == "47Z5E787p8bHJEEc2Bf878K86LHQcbKT6f8KEsU7ocmnQPKHNbHHdMNc4dW6drrR4egpHmkM2jTWkP1tg4wymd7DAtJD37L" ]; then
    echo "错误：请先编辑此脚本，将 MY_WALLET_ADDRESS 替换为您的真实钱包地址。"
    # 使用 return 代替 exit，只停止脚本，不关闭会话
    return 1
fi

echo "正在准备官方 XMRig 基准测试环境..."
# 确保以 root 权限运行后续命令
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限以获得最佳性能，正在尝试使用 sudo..."
   # 如果不是 root，则用 sudo 重新运行整个脚本
   sudo bash "$0" "$@"
   # 使用 return 结束当前非 root 进程
   return
fi

# 2. 清理并创建工作目录
echo "清理旧的测试目录..."
screen -X -S "$SESSION_NAME" quit > /dev/null 2>&1 # 停止旧的测试会话
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || return

# 3. 安装依赖
echo "安装依赖工具..."
apt-get update > /dev/null 2>&1
apt-get install -y wget tar screen curl > /dev/null 2>&1

# 4. 下载并解压官方 XMRig
echo "正在从官方地址下载最新版本 XMRig (v${LATEST_VERSION})..."
wget -q -O xmrig.tar.gz "$DOWNLOAD_URL"
tar -zxf xmrig.tar.gz
# 进入解压后的目录
cd xmrig-* || return

# 5. 创建一个最简化的、用于测试的配置文件
echo "创建稳定测试配置文件..."
cat > config.json << EOF
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "rdmsr": true,
        "wrmsr": true,
        "max-threads-hint": 75
    },
    "pools": [
        {
            "algo": "rx/0",
            "url": "pool.supportxmr.com:443",
            "user": "${MY_WALLET_ADDRESS}",
            "pass": "OfficialTest",
            "tls": true,
            "keepalive": true
        }
    ],
    "donate-level": 1
}
EOF

# 6. 在后台启动官方 XMRig
echo "正在后台启动官方 XMRig..."
screen -d -m -S "$SESSION_NAME" ./xmrig

# 7. 最终确认
sleep 2
if screen -list | grep -q "$SESSION_NAME"; then
    echo "---------------------------------------------------------"
    echo "成功！官方 XMRig 已在后台启动，正在进行测速。"
    echo "会话名称: $SESSION_NAME"
    echo "工作目录: `pwd`"
    echo ""
    echo "请等待1-2分钟后，使用以下命令查看实时输出："
    echo "screen -r $SESSION_NAME"
    echo "---------------------------------------------------------"
else
    echo "错误：无法启动后台服务。请手动进入 `pwd` 目录并运行 './xmrig' 检查错误。"
fi
