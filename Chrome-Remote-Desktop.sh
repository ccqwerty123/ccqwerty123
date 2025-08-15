#!/bin/bash

# ==============================================================================
# 脚本名称: setup_debian_xfce_crd_root_v4.sh
# 脚本功能: 以 root 身份运行，通过智能、带优先级的选择机制， resiliently 
#           安装 XFCE 桌面及一系列常用软件。优先尝试安装 Google Chrome。
#           在任何非核心组件安装失败时都不会中断。
# 版本: 4.0 - 引入可重用的智能安装函数，优先安装 Chrome，并扩展候选包列表。
# 作者: Gemini
# ==============================================================================

# --- 全局变量 ---
readonly NEW_USER="deskuser"
readonly NEW_PASS="deskuser"

# --- 辅助函数定义 ---

# 函数: install_best_choice
# 用途: 从一个软件包列表中，按顺序尝试安装第一个可用的软件包。
# 参数: $1=软件类别（用于打印信息），$2, $3...=软件包候选列表
install_best_choice() {
    local category="$1"
    shift
    for pkg in "$@"; do
        if apt-cache show "$pkg" &> /dev/null; then
            echo "找到可用的 [$category]: $pkg。正在安装..."
            if apt install -y "$pkg"; then
                echo "[$category] '$pkg' 安装成功。"
                return 0
            else
                echo "警告：尝试安装 '$pkg' 时出错，将尝试下一个候选软件。"
            fi
        fi
    done
    echo "警告：在为 [$category] 提供的所有候选列表中，均未找到可安装的软件包。"
    return 1
}

# 函数: install_google_chrome
# 用途: 尝试通过添加官方源的方式安装 Google Chrome。
install_google_chrome() {
    echo "正在尝试安装 Google Chrome (最高优先级)..."
    # 确保依赖已安装
    apt install -y wget gpg
    
    # 下载并添加 Google 的 GPG 密钥
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg
    
    # 添加 Chrome 的软件源
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    
    # 更新软件源并安装
    apt update
    if apt install -y google-chrome-stable; then
        echo "Google Chrome 安装成功。"
        return 0
    else
        echo "Google Chrome 安装失败。将尝试其他浏览器。"
        # 清理失败的配置
        rm -f /etc/apt/sources.list.d/google-chrome.list
        return 1
    fi
}


# --- 脚本主流程 ---

# --- 1. 系统准备与更新 ---
echo "=================================================="
echo "步骤 1: 更新系统软件包列表并修复任何依赖问题"
echo "=================================================="
apt update
apt --fix-broken install -y

# --- 2. 预配置键盘布局 ---
echo "=================================================="
echo "步骤 2: 预配置键盘布局以实现非交互式安装"
echo "=================================================="
debconf-set-selections <<'EOF'
keyboard-configuration keyboard-configuration/layoutcode string us
keyboard-configuration keyboard-configuration/modelcode string pc105
EOF

# --- 3. 安装核心桌面与中文支持 ---
echo "=================================================="
echo "步骤 3: 安装 XFCE 桌面、中文支持和核心组件"
echo "=================================================="
apt install -y \
    xfce4 \
    xfce4-goodies \
    task-xfce-desktop \
    dbus-x11 \
    locales-all \
    fonts-noto-cjk \
    fcitx5 fcitx5-chinese-addons

# --- 3.5 智能安装常用软件 ---
echo "=================================================="
echo "步骤 3.5: 智能、带优先级地安装常用软件"
echo "=================================================="

# 浏览器安装
if ! install_google_chrome; then
    install_best_choice "网页浏览器" "chromium-browser" "chromium" "firefox-esr" "firefox"
fi

# 其他软件安装
install_best_choice "文件管理器" "thunar" "nemo" "caja"
install_best_choice "文本编辑器" "mousepad" "gedit" "pluma"
install_best_choice "终端模拟器" "xfce4-terminal" "gnome-terminal"

# --- 4. 设置系统默认语言为中文 ---
echo "=================================================="
echo "步骤 4: 设置系统默认语言为简体中文 (zh_CN.UTF-8)"
echo "=================================================="
localectl set-locale LANG=zh_CN.UTF-8
export LANG=zh_CN.UTF-8

# --- 5. 下载并安装 Chrome Remote Desktop ---
echo "=================================================="
echo "步骤 5: 下载并安装 Chrome Remote Desktop 服务"
echo "=================================================="
wget https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb
DEBIAN_FRONTEND=noninteractive apt install -y ./chrome-remote-desktop_current_amd64.deb
rm chrome-remote-desktop_current_amd64.deb

# --- 6. 自动创建用户 ---
echo "=================================================="
echo "步骤 6: 自动创建远程桌面专用用户: ${NEW_USER}"
echo "=================================================="
if id "$NEW_USER" &>/dev/null; then
    echo "用户 '$NEW_USER' 已存在，跳过创建步骤。"
else
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_PASS" | chpasswd
    echo "用户 '$NEW_USER' 创建成功，密码已设置为 '$NEW_PASS'。"
fi
usermod -aG sudo "$NEW_USER"
usermod -aG chrome-remote-desktop "$NEW_USER"

# --- 7. 预配置桌面会话 ---
echo "=================================================="
echo "步骤 7: 为用户 ${NEW_USER} 预配置桌面会话"
echo "=================================================="
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
