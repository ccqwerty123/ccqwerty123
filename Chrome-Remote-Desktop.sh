#!/bin/bash

# ==============================================================================
# 脚本名称: setup_debian_xfce_crd_root_v11.sh (最终稳定版)
# 脚本功能: 启动时获取授权码，然后全自动安装并配置一个稳定、安全的 XFCE
#           中文远程桌面环境。本版本修复了所有已知问题。
# 版本: 11.0 - 修复 gpg 覆盖提示；恢复并强化所有关键步骤的注释。
# 作者: Gemini
# ==============================================================================

# --- 全局变量 ---
readonly NEW_USER="deskuser"
readonly NEW_PASS="deskuser"
readonly PIN_CODE="666666"

# --- 脚本启动时的初始交互 ---
clear

echo "========================================================================"
echo -e "\033[1;32m欢迎使用全自动 Debian 远程桌面安装脚本\033[0m"
echo "------------------------------------------------------------------------"
echo "本脚本将要求您预先提供 Chrome 远程桌面的授权码，"
echo "之后会进行全自动安装，无需任何进一步操作。"
echo "========================================================================"
echo ""
echo "1. 请在您的本地电脑浏览器中打开下面的链接进行授权："
echo -e "   \033[1;34mhttps://remotedesktop.google.com/headless\033[0m"
echo ""
echo "2. 按照页面提示操作，在“设置另一台计算机”页面底部，点击“授权”。"
echo "3. 复制“Debian Linux”下面显示的那行命令。"
echo ""
echo -e "\033[1;33m4. 将复制的命令完整粘贴到下方提示符后，然后按 Enter 键:\033[0m"
echo "------------------------------------------------------------------------"

AUTH_COMMAND=""
while [ -z "$AUTH_COMMAND" ]; do
    read -p "请在此处粘贴授权命令: " AUTH_COMMAND_RAW < /dev/tty
    AUTH_COMMAND=$(echo "${AUTH_COMMAND_RAW}" | xargs)
    if [ -z "$AUTH_COMMAND" ]; then
        echo -e "\033[1;31m输入不能为空，请重新粘贴命令！\033[0m"
    fi
done

echo ""
echo -e "\033[1;32m✅ 授权码已接收。脚本将开始全自动安装，请耐心等待...\033[0m"
sleep 3


# --- 辅助函数定义 ---
install_best_choice() {
    local category="$1"
    shift
    for pkg in "$@"; do
        if apt-cache show "$pkg" &> /dev/null; then
            echo "找到可用的 [$category]: $pkg。正在安装..."
            if apt-get install -y "$pkg"; then
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

# [CRITICAL FUNCTION - DO NOT MODIFY LOGIC]
# 此函数用于安装 Chrome，并处理了可能出现的交互提示。
install_google_chrome() {
    echo "正在尝试安装 Google Chrome (最高优先级)..."
    apt-get install -y wget gpg
    # [KEY FIX] 使用标准输出重定向 `>` 代替 `-o`，以强制覆盖现有文件，避免交互式提示。
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /usr/share/keyrings/google-chrome-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update
    if apt-get install -y google-chrome-stable; then
        echo "Google Chrome 安装成功。"
        return 0
    else
        echo "Google Chrome 安装失败。将尝试其他浏览器。"
        rm -f /etc/apt/sources.list.d/google-chrome.list
        return 1
    fi
}


# --- 脚本主流程 ---

# 1. 系统准备与更新
echo "=================================================="
echo "步骤 1: 更新系统软件包列表并修复任何依赖问题"
echo "=================================================="
apt-get update
apt-get --fix-broken install -y

# 2. 预配置键盘布局
# [CRITICAL STEP - DO NOT REMOVE]
# 此步骤至关重要，用于避免软件包安装过程中出现交互式对话框，确保全自动化。
echo "=================================================="
echo "步骤 2: 预配置键盘布局以实现非交互式安装"
echo "=================================================="
debconf-set-selections <<'EOF'
keyboard-configuration keyboard-configuration/layoutcode string us
keyboard-configuration keyboard-configuration/modelcode string pc105
EOF

# 3. 安装核心桌面与中文支持
echo "=================================================="
echo "步骤 3: 安装 XFCE 桌面、中文支持和核心组件"
echo "=================================================="
apt-get install -y \
    xfce4 \
    xfce4-goodies \
    task-xfce-desktop \
    dbus-x11 \
    locales \
    fonts-noto-cjk \
    fcitx5 fcitx5-chinese-addons

# 4. 设置系统全局中文环境
echo "=================================================="
echo "步骤 4: 生成并设置系统全局中文 Locale"
echo "=================================================="
sed -i '/zh_CN.UTF-8/s/^# //g' /etc/locale.gen
locale-gen zh_CN.UTF-8
update-locale LANG=zh_CN.UTF-8
echo "LANG=zh_CN.UTF-8" > /etc/default/locale
echo "系统默认语言已设置为中文。"

# 5. 解决 Fcitx5 多进程冲突的根源
# [CRITICAL STEP - DO NOT REMOVE]
# 这是确保中文输入法稳定运行的核心修复。
echo "=================================================="
echo "步骤 5: 禁用 Fcitx5 全局自启动以避免冲突"
echo "=================================================="
if [ -f /etc/xdg/autostart/org.fcitx.Fcitx5.desktop ]; then
    mv /etc/xdg/autostart/org.fcitx.Fcitx5.desktop /etc/xdg/autostart/org.fcitx.Fcitx5.desktop.bak
    echo "Fcitx5 全局自启动项已成功禁用。"
fi

# 6. 智能、带优先级地安装常用软件
# [CRITICAL STEP - DO NOT MODIFY LOGIC]
# 此步骤确保优先安装最佳软件，并在失败时有备用选项。
echo "=================================================="
echo "步骤 6: 智能、带优先级地安装常用软件"
echo "=================================================="
if ! install_google_chrome; then
    install_best_choice "网页浏览器" "chromium-browser" "chromium" "firefox-esr" "firefox"
fi
install_best_choice "文件管理器" "thunar"
install_best_choice "文本编辑器" "mousepad"
install_best_choice "终端模拟器" "xfce4-terminal"

# 7. 下载并安装 Chrome Remote Desktop
echo "=================================================="
echo "步骤 7: 下载并安装 Chrome Remote Desktop 服务"
echo "=================================================="
wget https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb -O crd.deb
DEBIAN_FRONTEND=noninteractive apt-get install -y ./crd.deb
rm crd.deb

# 8. 自动创建用户
echo "=================================================="
echo "步骤 8: 自动创建远程桌面专用用户: ${NEW_USER}"
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

# 9. 为新用户预配置包含中文环境的桌面会话
echo "=================================================="
echo "步骤 9: 为用户 ${NEW_USER} 预配置桌面会话脚本"
echo "=================================================="
su -c 'cat <<EOF > /home/'${NEW_USER}'/.chrome-remote-desktop-session
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
fcitx5 -d
exec /usr/bin/startxfce4
EOF' "${NEW_USER}"

# 10. 统一用户主目录权限
# [CRITICAL STEP - DO NOT REMOVE]
# 这是解决所有“无法保存设置”问题的根源，确保用户体验。
echo "=================================================="
echo "步骤 10: 修正用户 ${NEW_USER} 的主目录文件所有权"
echo "=================================================="
chown -R "${NEW_USER}":"${NEW_USER}" "/home/${NEW_USER}"
echo "用户主目录权限已成功修正。"

# 11. 清理APT缓存
echo "=================================================="
echo "步骤 11: 清理软件包缓存以释放空间"
echo "=================================================="
apt-get clean

# 12. 执行最终的自动化授权流程
echo "=================================================="
echo "步骤 12: 执行最终的自动化授权流程"
echo "=================================================="
AUTH_COMMAND_CLEANED=$(echo "$AUTH_COMMAND" | sed 's/DISPLAY=.*start-host/start-host/')
echo "正在为用户 ${NEW_USER} 自动执行授权..."
su - "${NEW_USER}" -c "echo -e '${PIN_CODE}\n${PIN_CODE}' | /opt/google/chrome-remote-desktop/${AUTH_COMMAND_CLEANED}"

if [ $? -eq 0 ]; then
    echo -e "\033[1;32m授权命令执行成功！\033[0m"
    echo "正在启动远程桌面服务..."
    
    if [ -f /etc/init.d/chrome-remote-desktop ]; then
        /etc/init.d/chrome-remote-desktop start
        sleep 2
        if ps aux | grep crd | grep -v grep | grep "${NEW_USER}" > /dev/null; then
            echo -e "\033[1;32m✅ 服务已成功启动！\033[0m"
        else
            echo -e "\033[1;31m❌ 服务启动失败，请手动检查。尝试运行: /etc/init.d/chrome-remote-desktop start\033[0m"
            exit 1
        fi
    else
        echo -e "\033[1;31m错误：未找到 /etc/init.d/chrome-remote-desktop 启动脚本。\033[0m"
        exit 1
    fi

    echo ""
    echo "======================= 【 🎉 大功告成 🎉 】 ======================="
    echo "现在，您可以通过任何设备访问下面的链接来连接到您的远程桌面了："
    echo -e "\033[1;34mhttps://remotedesktop.google.com/access\033[0m"
    echo "========================================================================"

else
    echo -e "\033[1;31m❌ 授权命令执行失败！请检查您粘贴的命令是否正确。\033[0m"
    exit 1
fi
