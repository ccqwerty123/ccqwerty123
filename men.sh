sudo bash -c '
# --- START: 这里是所有硬编码的配置 ---
# 钱包地址 (已根据您的要求填好)
WALLET_ADDRESS="47Z5E787p8bHJEEc2Bf878K86LHQcbKT6f8KEsU7ocmnQPKHNbHHdMNc4dW6drrR4egpHmkM2jTWkP1tg4wymd7DAtJD37L"
# XMRig 下载链接 (使用固定的 6.24.0 版本，避免动态获取失败)
XMRIG_URL="https://github.com/xmrig/xmrig/releases/download/v6.24.0/xmrig-6.24.0-linux-static-x64.tar.gz"
# 工作目录
WORKDIR="/tmp/xmrig-direct-run"
# --- END: 配置结束 ---

# 0. 确保以 root 身份执行
if [ "$(id -u)" != "0" ]; then
   echo "错误：此命令需要以 root 权限运行。"
   exit 1
fi

# 1. 清理并准备环境
echo "正在准备环境..."
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 1

# 2. 安装依赖 (如果已安装则会跳过)
echo "正在安装依赖工具..."
apt-get update > /dev/null 2>&1
apt-get install -y wget tar > /dev/null 2>&1

# 3. 下载并解压
echo "正在下载 XMRig v6.24.0..."
wget -q -O xmrig.tar.gz "$XMRIG_URL"
tar -zxf xmrig.tar.gz
cd xmrig-* || exit 1

# 4. 创建配置文件 (直接写入，不使用变量)
echo "正在创建配置文件..."
cat > config.json << EOF
{
    "autosave": false,
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
            "user": "47Z5E787p8bHJEEc2Bf878K86LHQcbKT6f8KEsU7ocmnQPKHNbHHdMNc4dW6drrR4egpHmkM2jTWkP1tg4wymd7DAtJD37L",
            "pass": "DirectRunTest",
            "tls": true,
            "keepalive": true
        }
    ],
    "donate-level": 1,
    "print-time": 30
}
EOF

# 5. 直接在前台运行 XMRig
echo "---------------------------------------------------------"
echo "准备就绪！正在启动 XMRig..."
echo "您将直接看到实时输出。要停止，请按 Ctrl + C。"
echo "---------------------------------------------------------"
./xmrig
'
