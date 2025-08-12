#!/bin-bash

# ==============================================================================
# ==    Apache Guacamole 透明安装脚本 (v4 - 完整输出与依赖预检)           ==
# ==============================================================================
# ==  此版本保留完整安装日志，并为每一步添加了详细的依赖项预检查。        ==
# ==============================================================================

# --- 设置颜色代码以便输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 封装好的打印函数 ---
print_step() { echo -e "\n${BLUE}=======================================================================\n== ${1}\n=======================================================================${NC}"; }
print_success() { echo -e "${GREEN}[✔] 成功: ${1}${NC}"; }
print_error() { echo -e "${RED}[✘] 失败: ${1}${NC}\n${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"; exit 1; }

# --- 核心检查函数 (上一个命令的退出码, 成功/失败信息) ---
check_success() { [ $1 -eq 0 ] && print_success "${2}" || print_error "${2}"; }

# --- 依赖项检查函数 ---
# 参数: 依赖项列表，用空格分隔
check_dependencies() {
    print_step "正在进行依赖项预检查..."
    local missing_deps=()
    for dep in "$@"; do
        if ! dpkg -s "$dep" >/dev/null 2>&1; then
            echo -e "${YELLOW}警告: 依赖项 '${dep}' 未安装。正在尝试安装...${NC}"
            sudo apt-get install -y "$dep"
            if ! dpkg -s "$dep" >/dev/null 2>&1; then
                missing_deps+=("$dep")
            fi
        else
            print_success "依赖项 '${dep}' 已就绪。"
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "以下核心依赖项安装失败: ${missing_deps[*]}. 无法继续。"
    else
        print_success "所有依赖项均已准备就绪。"
    fi
}

# --- 脚本主流程开始 ---
print_step "步骤 0/4：环境准备与非交互式配置"
sudo apt-get update
check_success $? "更新软件包列表"

echo "正在安装基础工具 (apt-utils)，解决 debconf 警告..."
sudo apt-get install -y apt-utils
check_success $? "安装 apt-utils"

export DEBIAN_FRONTEND=noninteractive
check_success $? "设置 DEBIAN_FRONTEND=noninteractive"

echo -e "${YELLOW}重要提示: 请确保您已在 Cloud Studio 的防火墙/安全组中开放了 TCP 端口 8080。${NC}"
read -p "如果已确认，请按 Enter 键继续..."


# ==============================================================================
# == 第一部分：安装并运行 VNC 服务器 (桌面环境)
# ==============================================================================
print_step "步骤 1/4：安装 VNC 服务器和 XFCE 桌面"
echo "正在预设键盘布局以避免交互式提问..."
sudo debconf-set-selections <<< "keyboard-configuration keyboard-configuration/layoutcode string us"
check_success $? "预设键盘布局为 'us' (美国)"

echo "正在安装 VNC 和 XFCE (您将看到完整的安装过程)..."
sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator
check_success $? "安装 VNC 和 XFCE 核心组件"

check_dependencies tigervnc-standalone-server xfce4

echo -e "${YELLOW}--- 用户操作：设置 VNC 密码 ---${NC}"
echo "接下来，您需要设置一个密码，用于 Guacamole 连接到这个虚拟桌面。"
read -p "理解后，请按 Enter 键开始设置 VNC 密码..."
vncserver :1
check_success $? "首次运行 vncserver 以生成配置文件"

vncserver -kill :1 > /dev/null 2>&1
check_success $? "临时关闭 VNC 会话以进行配置"

[ ! -f ~/.vnc/xstartup ] && print_error "VNC 配置文件 ~/.vnc/xstartup 未找到！"
echo "startxfce4 &" >> ~/.vnc/xstartup
check_success $? "配置 VNC 启动脚本以加载 XFCE"

vncserver -localhost no :1
check_success $? "以正确的配置重新启动 VNC 服务器"

sleep 2
if ! netstat -tuln | grep -q ':5901'; then
    print_error "VNC 服务器端口 5901 未被监听。服务可能启动失败。"
fi
print_success "VNC 服务器已在 :1 (端口 5901) 上成功运行并监听。"


# ==============================================================================
# == 第二部分：安装 guacd (Guacamole 后端)
# ==============================================================================
print_step "步骤 2/4：编译并安装 Guacamole 后端 (guacd)"
GUACD_DEPS="build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev libtelnet-dev libwebsockets-dev libpulse-dev"
echo "正在安装 guacd 编译所需的所有依赖项..."
sudo apt-get install -y $GUACD_DEPS
check_success $? "安装 guacd 编译依赖项命令执行完毕"

check_dependencies $GUACD_DEPS

GUAC_VERSION="1.5.3"
echo "正在下载 Guacamole Server ${GUAC_VERSION} 源代码..."
wget https://apache.org/dyn/closer.lua/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz -O guacamole-server.tar.gz
check_success $? "下载 Guacamole 源代码"

tar -xzf guacamole-server.tar.gz
check_success $? "解压源代码"

cd guacamole-server-${GUAC_VERSION}
echo "正在配置编译环境 (./configure)..."
./configure --with-systemd-dir=/etc/systemd/system
check_success $? "运行 ./configure 脚本"

echo "正在编译源代码 (make)... 这需要几分钟时间。"
make
check_success $? "编译源代码 (make)"

echo "正在安装编译好的文件 (make install)..."
sudo make install
check_success $? "安装编译好的文件 (make install)"

sudo ldconfig
check_success $? "更新动态链接库缓存"

sudo systemctl enable guacd && sudo systemctl start guacd
check_success $? "启动并设置 guacd 服务开机自启"

sleep 2
sudo systemctl is-active --quiet guacd
check_success $? "确认 guacd 服务正在后台运行 (active)"

if ! sudo netstat -tuln | grep -q ':4822'; then
    print_error "Guacd 端口 4822 未被监听。服务可能启动失败。请检查日志: 'sudo journalctl -u guacd'"
fi
print_success "Guacd 服务已成功运行并监听在端口 4822。"

cd ..


# ==============================================================================
# == 第三部分：安装 Tomcat 和 Guacamole Web 应用 (前端)
# ==============================================================================
print_step "步骤 3/4：安装 Tomcat 并自动化配置 Guacamole"
echo "正在安装 Tomcat 9..."
sudo apt-get install -y tomcat9
check_success $? "安装 Tomcat 9"

check_dependencies tomcat9

sudo mkdir -p /etc/guacamole && sudo chmod 755 /etc/guacamole
check_success $? "创建 Guacamole 配置文件目录 /etc/guacamole"

echo "正在下载 Guacamole Web 应用 (.war 文件)..."
wget https://apache.org/dyn/closer.lua/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war -O guacamole.war
check_success $? "下载 Guacamole Web 应用 (.war 文件)"

sudo mv guacamole.war /var/lib/tomcat9/webapps/
check_success $? "将 .war 文件部署到 Tomcat"

echo -e "${YELLOW}--- 自动化密码配置 ---${NC}"
read -sp "请为 Guacamole 网页登录设置一个新密码: " GUAC_PASS; echo
read -sp "请再次输入您在步骤1中设置的 VNC 密码: " VNC_PASS; echo

sudo bash -c 'cat > /etc/guacamole/guacamole.properties' << EOF
guacd-hostname: localhost
guacd-port: 4822
user-mapping: /etc/guacamole/user-mapping.xml
EOF
check_success $? "创建 guacamole.properties 配置文件"

sudo bash -c 'cat > /etc/guacamole/user-mapping.xml' << EOF
<user-mapping>
    <authorize username="user" password="__GUAC_PASSWORD_PLACEHOLDER__">
        <connection name="XFCE Desktop">
            <protocol>vnc</protocol>
            <param name="hostname">localhost</param>
            <param name="port">5901</param>
            <param name="password">__VNC_PASSWORD_PLACEHOLDER__</param>
        </connection>
    </authorize>
</user-mapping>
EOF
check_success $? "创建 user-mapping.xml 配置文件模板"

sudo sed -i "s|__GUAC_PASSWORD_PLACEHOLDER__|${GUAC_PASS}|g" /etc/guacamole/user-mapping.xml
check_success $? "自动填入 Guacamole 登录密码"
sudo sed -i "s|__VNC_PASSWORD_PLACEHOLDER__|${VNC_PASS}|g" /etc/guacamole/user-mapping.xml
check_success $? "自动填入 VNC 连接密码"

sudo chown tomcat:tomcat /etc/guacamole/ -R
check_success $? "设置配置文件权限"

echo "正在重启 Tomcat 以应用所有更改..."
sudo systemctl restart tomcat9
check_success $? "重启 Tomcat 服务"

echo "等待 20 秒，让 Guacamole Web 应用完成初始化..."
sleep 20

# --- 终极验证 ---
echo "正在进行最终验证，尝试访问 Guacamole 登录页面..."
HTTP_CODE=$(curl -s -L -o /dev/null -w "%{http_code}" http://localhost:8080/guacamole/)
if [ "$HTTP_CODE" -eq 200 ]; then
    print_success "终极验证通过！Guacamole 登录页面已成功上线 (HTTP Code: $HTTP_CODE)。"
else
    print_error "终极验证失败！无法访问 Guacamole 登录页面 (HTTP Code: $HTTP_CODE)。请检查 Tomcat 日志: 'sudo journalctl -u tomcat9'"
fi


# ==============================================================================
# == 第四部分：完成
# ==============================================================================
print_step "步骤 4/4：安装完成！"
print_success "所有组件已成功安装并配置。"
echo ""
echo -e "  访问地址: ${GREEN}http://<您的CloudStudio公网IP>:8080/guacamole/${NC}"
echo -e "  用户名:   ${GREEN}user${NC}"
echo -e "  密码:     ${GREEN}您刚刚为 Guacamole 设置的网页登录密码${NC}"
echo ""
echo "祝您使用愉快！"
