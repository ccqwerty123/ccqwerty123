#!/bin/bash

# ==============================================================================
# 脚本名称: setup_debian_xfce_crd_root_v2.sh
# 脚本功能: 以 root 身份运行，全自动安装 XFCE、中文环境、常用软件和
#           Chrome Remote Desktop，并自动创建固定的远程桌面用户。
# 版本: 2.0 - 修正了浏览器安装包名问题
# 作者: Gemini
# ==============================================================================

# --- 安全设置：任何命令失败，脚本立即退出 ---
set -e

# --- 全局变量：自动创建的用户名和密码 ---
# !!! 安全警告: 在脚本中硬编码密码存在风险。请确保您了解并接受此风险。!!!
readonly NEW_USER="deskuser"
readonly NEW_PASS="deskuser"

# --- 1. 系统准备与更新 ---
echo "=================================================="
echo "步骤 1: 更新系统软件包列表并修复任何依赖问题"
echo "=================================================="
apt update
apt --fix-broken install -y

# --- 2. 预配置键盘布局以避免安装过程中的交互提示 ---
echo "=================================================="
echo "步骤 2: 预配置键盘布局以实现非交互式安装"
echo "=================================================="
debconf-set-selections <<'EOF'
keyboard-configuration keyboard-configuration/layoutcode string us
keyboard-configuration keyboard-configuration/modelcode string pc105
EOF

# --- 3. 安装 XFCE 桌面环境及常用软件 ---
echo "=================================================="
echo "步骤 3: 安装 XFCE 桌面、中文支持和常用软件"
echo "=================================================="
# --- 修改点 ---
# 将 'firefox-esr' 替换为 'chromium-browser'
apt install -y \
    xfce4 \
    xfce4-goodies \
    task-xfce-desktop \
    dbus-x11 \
    thunar \
    chromium-browser \
    locales-all \
    fonts-noto-cjk \
    fcitx5 fcitx5-chinese-addons

# --- 4. 设置系统默认语言为中文 ---
echo "=================================================="
echo "步骤 4: 设置系统默认语言为简体中文 (zh_CN.UTF-8)"
echo "=================================================="
localectl set-locale LANG=zh_CN.UTF-8
export LANG=zh_CN.UTF-8

# --- 5. 下载并安装 Chrome Remote Desktop ---
echo "=================================================="
echo "步骤 5: 下载并安装 Chrome Remote Desktop"
echo "=================================================="
wget https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb
# 使用 DEBIAN_FRONTEND=noninteractive 确保即使预配置失败也不会卡住
DEBIAN_FRONTEND=noninteractive apt install -y ./chrome-remote-desktop_current_amd64.deb
# 清理下载的安装包
rm chrome-remote-desktop_current_amd64.deb

# --- 6. 自动创建新的远程桌面用户 ---
echo "=================================================="
echo "步骤 6: 自动创建远程桌面专用用户: ${NEW_USER}"
echo "=================================================="
# 检查用户是否已存在
if id "$NEW_USER" &>/dev/null; then
    echo "用户 '$NEW_USER' 已存在，跳过创建步骤。"
else
    # 使用 useradd (非交互式) 创建用户，并用 chpasswd 设置密码
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_PASS" | chpasswd
    echo "用户 '$NEW_USER' 创建成功，密码已设置为 '$NEW_PASS'。"
fi
# 确保用户在正确的用户组中
usermod -aG sudo "$NEW_USER"
usermod -aG chrome-remote-desktop "$NEW_USER"

# --- 7. 为新用户预配置 XFCE 桌面会话 ---
# 这一步至关重要，可以防止首次连接时因 XFCE 初始设置弹窗而断开
echo "=================================================="
echo "步骤 7: 为用户 ${NEW_USER} 预配置桌面会话"
echo "=================================================="
# 使用 su -c 以新用户的身份执行命令，在家目录下创建配置文件
su -c 'echo "exec /etc/X11/Xsession /usr/bin/xfce4-session" > ~/.chrome-remote-desktop-session' "$NEW_USER"
su -c 'echo "xfce4-session" > ~/.xsession' "$NEW_USER"

# --- 脚本完成 ---
echo "========================================================================"
echo -e "\033[1;32m🎉 恭喜！自动化安装和配置已全部完成！ 🎉\033[0m"
echo ""
echo "接下来，请您手动完成最后一步："
echo ""
echo -e "1. 切换到您自动创建的新用户: \033[1;33msu - ${NEW_USER}\033[0m"
echo ""
echo "2. 在浏览器中打开 Chrome 远程桌面授权页面:"
echo "   https://remotedesktop.google.com/headless"
echo ""
echo "3. 按照页面提示授权，并复制 Debian Linux 的那行设置命令。"
echo ""
echo -e "4. 将复制的命令粘贴到服务器终端中 (\033[1;31m请确保是在 '${NEW_USER}' 用户下\033[0m)，"
echo "   然后按回车执行。系统会提示您设置 PIN 码。"
echo ""
echo "完成后，您的远程桌面就可以使用了！"
echo "========================================================================"
