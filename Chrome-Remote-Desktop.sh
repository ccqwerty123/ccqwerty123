#!/bin/bash

# ==============================================================================
# 脚本名称: setup_debian_xfce_crd_root_v7.sh (最终生产版)
# 脚本功能: 以 root 身份运行，全自动安装并配置一个稳定、安全的 XFCE 
#           中文远程桌面环境。彻底解决 Fcitx5 输入法冲突及用户权限问题。
# 版本: 7.0 - 增加最终权限修复步骤，预防所有“无法保存设置”的问题。
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

install_google_chrome() {
    echo "正在尝试安装 Google Chrome (最高优先级)..."
    apt-get install -y wget gpg
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg
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

# 4. [关键修复] 解决 Fcitx5 多进程冲突的根源
echo "=================================================="
echo "步骤 4: 禁用 Fcitx5 全局自启动以避免冲突"
echo "=================================================="
if [ -f /etc/xdg/autostart/org.fcitx.Fcitx5.desktop ]; then
    mv /etc/xdg/autostart/org.fcitx.Fcitx5.desktop /etc/xdg/autostart/org.fcitx.Fcitx5.desktop.bak
    echo "Fcitx5 全局自启动项已成功禁用。"
fi

# 5. 智能安装常用软件
echo "=================================================="
echo "步骤 5: 智能、带优先级地安装常用软件"
echo "=================================================="
if ! install_google_chrome; then
    install_best_choice "网页浏览器" "chromium-browser" "chromium" "firefox-esr" "firefox"
fi
install_best_choice "文件管理器" "thunar"
install_best_choice "文本编辑器" "mousepad"
install_best_choice "终端模拟器" "xfce4-terminal"

# 6. 下载并安装 Chrome Remote Desktop
echo "=================================================="
echo "步骤 6: 下载并安装 Chrome Remote Desktop 服务"
echo "=================================================="
wget https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb -O crd.deb
DEBIAN_FRONTEND=noninteractive apt-get install -y ./crd.deb
rm crd.deb

# 7. 自动创建用户
echo "=================================================="
echo "步骤 7: 自动创建远程桌面专用用户: ${NEW_USER}"
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

# 8. 为新用户预配置包含中文环境的桌面会话
echo "=================================================="
echo "步骤 8: 为用户 ${NEW_USER} 预配置桌面会话脚本"
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

# 9. [关键修复] 统一用户主目录权限，确保所有权正确
echo "=================================================="
echo "步骤 9: 修正用户 ${NEW_USER} 的主目录文件所有权"
echo "=================================================="
# 这一步是安全性和稳定性的关键。它确保由 root 脚本创建或影响的所有
# 配置文件，其所有权都最终归属于普通用户 deskuser，从根源上解决
# 所有“无法保存设置”（如终端粘贴警告）的问题。
chown -R "${NEW_USER}":"${NEW_USER}" "/home/${NEW_USER}"
echo "用户主目录权限已成功修正。"

# 10. 清理APT缓存
echo "=================================================="
echo "步骤 10: 清理软件包缓存以释放空间"
echo "=================================================="
apt-get clean

# --- 脚本完成 ---
echo "========================================================================"
echo -e "\033[1;32m🎉 恭喜！自动化安装和配置已全部完成！ 🎉\033[0m"
echo ""
echo -e "\033[1;31m重要：由于您的环境没有 systemd，请严格按照以下步骤手动启动服务：\033[0m"
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
echo -e "6. (可选) 检查服务是否在后台运行："
echo -e "   \033[1;32mps aux | grep crd\033[0m"
echo "   (看到有 'deskuser' 用户的进程就代表成功了)"
echo ""
echo -e "7. \033[1;32m现在，一切就绪！\033[0m 打开浏览器访问下面的链接，即可连接。"
echo -e "   \033[1;34mhttps://remotedesktop.google.com/access?pli=1\033[0m"
echo "------------------------------------------------------------------"
echo "注意：声音问题是当前云环境的技术限制，但图形界面和中文环境已配置完毕。"
echo "========================================================================"
