#!/bin/bash

# ==============================================================================
# 脚本名称: setup_debian_xfce_crd_root_v6.sh (修复版)
# 脚本功能: 以 root 身份运行，通过智能机制 resiliently 安装 XFCE 桌面及
#           一系列常用软件。优先安装 Google Chrome。为新用户注入完整的
#           中文语言环境和输入法，并彻底解决 Fcitx5 多进程冲突问题。
# 版本: 6.0 - 修复 Fcitx5 双重启动问题，优化会话脚本。
# 作者: Gemini
# ==============================================================================

# --- 全局变量 ---
readonly NEW_USER="deskuser"
readonly NEW_PASS="deskuser"

# --- 辅助函数定义 ---
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

install_google_chrome() {
    echo "正在尝试安装 Google Chrome (最高优先级)..."
    apt install -y wget gpg
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt update
    if apt install -y google-chrome-stable; then
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
    locales-all \
    fonts-noto-cjk \
    fcitx5 fcitx5-chinese-addons

# FIX: 解决 Fcitx5 多进程冲突的根源
# Fcitx5 安装后会创建一个全局自启动文件，导致与我们的会话脚本重复启动。
# 我们将其重命名，从而禁用全局自启动，只保留我们脚本中的启动方式。
if [ -f /etc/xdg/autostart/org.fcitx.Fcitx5.desktop ]; then
    echo "禁用 Fcitx5 全局自启动项以避免冲突..."
    mv /etc/xdg/autostart/org.fcitx.Fcitx5.desktop /etc/xdg/autostart/org.fcitx.Fcitx5.desktop.bak
fi

# 3.5 智能安装常用软件
echo "=================================================="
echo "步骤 3.5: 智能、带优先级地安装常用软件"
echo "=================================================="
if ! install_google_chrome; then
    install_best_choice "网页浏览器" "chromium-browser" "chromium" "firefox-esr" "firefox"
fi
install_best_choice "文件管理器" "thunar" "nemo" "caja"
install_best_choice "文本编辑器" "mousepad" "gedit" "pluma"
install_best_choice "终端模拟器" "xfce4-terminal" "gnome-terminal"

# 4. (跳过) 系统级语言设置 (因为它在此环境无效)

# 5. 下载并安装 Chrome Remote Desktop
echo "=================================================="
echo "步骤 5: 下载并安装 Chrome Remote Desktop 服务"
echo "=================================================="
wget https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb
DEBIAN_FRONTEND=noninteractive apt-get install -y ./chrome-remote-desktop_current_amd64.deb
rm chrome-remote-desktop_current_amd64.deb

# 6. 自动创建用户
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

# 7. 为新用户预配置包含中文环境的桌面会话 (关键修复)
echo "=================================================="
echo "步骤 7: 为用户 ${NEW_USER} 预配置包含中文环境的桌面会话"
echo "=================================================="
# 这个多行配置会强制会话使用中文并以正确方式启动输入法
su -c 'cat <<EOF > /home/'${NEW_USER}'/.chrome-remote-desktop-session
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
# FIX: 使用官方推荐的守护进程模式启动 fcitx5
fcitx5 -d
# FIX: 使用标准的 XFCE 启动脚本
exec /usr/bin/startxfce4
EOF' "${NEW_USER}"

# --- 脚本完成 ---
echo "========================================================================"
echo -e "\033[1;32m🎉 恭喜！自动化安装和配置已全部完成！ 🎉\033[0m"
echo ""
echo -e "\033[1;31m重要：由于您的环境没有 systemd，请严格按照以下【全新】的步骤手动启动服务：\033[0m"
echo ""
echo "---------------------- 【最终操作指南】 ----------------------"
echo -e "1. \033[1;33m切换到新用户\033[0m，以完成授权："
echo -e "   \033[1;32msu - ${NEW_USER}\033[0m"
echo ""
echo "2. 在浏览器中打开 Chrome 远程桌面授权页面:"
echo "   https://remotedesktop.google.com/headless"
echo "   按照页面提示授权，并复制 Debian Linux 的那行设置命令。"
echo ""
echo -e "3. \033[1;33m将复制的命令粘贴到服务器终端中\033[0m (\033[1;31m确保当前是 '${NEW_USER}' 用户\033[0m)，"
echo "   回车执行并按提示设置 PIN 码。"
echo ""
echo -e "4. 授权完成后，\033[1;33m退回到原来的用户\033[0m (通常是 root)："
echo -e "   \033[1;32mexit\033[0m"
echo ""
echo -e "5. \033[1;33m手动启动服务\033[0m (\033[1;31m这是最关键的一步！\033[0m)："
echo -e "   \033[1;32msudo /etc/init.d/chrome-remote-desktop start\033[0m"
echo ""
echo "6. (可选) 检查服务是否在后台运行："
echo -e "   \033[1;32mps aux | grep crd\033[0m"
echo "   (看到有 'deskuser' 用户的进程就代表成功了)"
echo ""
echo -e "7. \033[1;32m现在，一切就绪！\033[0m 打开浏览器访问下面的链接，即可连接。"
echo -e "   \033[1;34mhttps://remotedesktop.google.com/access?pli=1\033[0m"
echo "------------------------------------------------------------------"
echo "注意：声音问题是当前环境的限制，无法解决。但图形界面和中文环境已配置完毕。"
echo "========================================================================"
