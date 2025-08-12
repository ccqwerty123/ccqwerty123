#!/bin-bash

# ==============================================================================
# ==    Apache Guacamole 健壮安装脚本 (v3 - 自动化密码与非交互式安装)     ==
# ==============================================================================
# ==  此脚本解决了 debconf 交互问题，并会自动处理密码配置，无需手动编辑。 ==
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

# --- 脚本主流程开始 ---
print_step "步骤 0/4：环境准备与非交互式配置"
export DEBIAN_FRONTEND=noninteractive
check_success $? "设置 DEBIAN_FRONTEND=noninteractive 以避免安装时提问"

echo -e "${YELLOW}重要提示: 请确保您已在 Cloud Studio 的防火墙/安全组中开放了 TCP 端口 8080。${NC}"
read -p "如果已确认，请按 Enter 键继续..."

echo "正在更新软件包列表 (为减少干扰，将隐藏详细输出)..."
sudo apt-get update > /dev/null
check_success $? "更新软件包列表"


# ==============================================================================
# == 第一部分：安装并运行 VNC 服务器 (桌面环境)
# ==============================================================================
print_step "步骤 1/4：安装 VNC 服务器和 XFCE 桌面"
echo "正在安装 VNC 和 XFCE (这可能需要一些时间)..."
sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator > /dev/null
check_success $? "安装 VNC 和 XFCE 核心组件"

command -v vncserver > /dev/null 2>&1
check_success $? "确认 vncserver 命令已安装"

echo -e "${YELLOW}--- 用户操作：设置 VNC 密码 ---${NC}"
echo "接下来，您需要设置一个密码，用于 Guacamole 连接到这个虚拟桌面。"
echo "1. 请输入一个 6-8 位的密码，然后按 Enter。"
echo "2. 系统会要求您再次输入以验证。"
echo "3. 当询问 'Would you like to enter a view-only password (y/n)?' 时，请输入 'n' 然后按 Enter。"
read -p "理解后，请按 Enter 键开始设置 VNC 密码..."
vncserver :1
check_success $? "首次运行 vncserver 以生成配置文件"
VNC_PASSWORD_SET=true # 标记密码已设置

vncserver -kill :1 > /dev/null 2>&1
check_success $? "临时关闭 VNC 会话以进行配置"

[ ! -f ~/.vnc/xstartup ] && print_error "VNC 配置文件 ~/.vnc/xstartup 未找到！"
echo "startxfce4 &" >> ~/.vnc/xstartup
check_success $? "配置 VNC 启动脚本以加载 XFCE"

vncserver -localhost no :1
check_success $? "以正确的配置重新启动 VNC 服务器"
print_success "VNC 服务器已在 :1 (端口 5901) 上成功运行。"


# ==============================================================================
# == 第二部分：安装 guacd (Guacamole 后端)
# ==============================================================================
print_step "步骤 2/4：编译并安装 Guacamole 后端 (guacd)"
echo "正在安装 guacd 编译所需的所有依赖项..."
sudo apt-get install -y build-essential libcairo2-dev libjpeg-turbo8-dev \
libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev \
libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev \
libtelnet-dev libwebsockets-dev libpulse-dev > /dev/null
check_success $? "安装 guacd 编译依赖项"

GUAC_VERSION="1.5.3"
echo "正在下载 Guacamole Server ${GUAC_VERSION} 源代码..."
wget https://apache.org/dyn/closer.lua/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz -O guacamole-server.tar.gz -q --show-progress
check_success $? "下载 Guacamole 源代码"
[ ! -f guacamole-server.tar.gz ] && print_error "Guacamole 源代码下载失败！"

tar -xzf guacamole-server.tar.gz
check_success $? "解压源代码"

cd guacamole-server-${GUAC_VERSION}
echo "正在配置编译环境 (./configure)..."
./configure --with-systemd-dir=/etc/systemd/system > /dev/null
check_success $? "运行 ./configure 脚本"

echo "正在编译源代码 (make)... 这需要几分钟时间。"
make > /dev/null
check_success $? "编译源代码 (make)"

echo "正在安装编译好的文件 (make install)..."
sudo make install > /dev/null
check_success $? "安装编译好的文件 (make install)"

sudo ldconfig
check_success $? "更新动态链接库缓存"

sudo systemctl enable guacd && sudo systemctl start guacd
check_success $? "启动并设置 guacd 服务开机自启"

sleep 2 # 等待服务启动
sudo systemctl is-active --quiet guacd
check_success $? "确认 guacd 服务正在后台运行 (active)"

cd ..
print_success "Guacamole 后端 (guacd) 已成功安装并运行。"


# ==============================================================================
# == 第三部分：安装 Tomcat 和 Guacamole Web 应用 (前端)
# ==============================================================================
print_step "步骤 3/4：安装 Tomcat 并自动化配置 Guacamole"
echo "正在安装 Tomcat 9..."
sudo apt-get install -y tomcat9 > /dev/null
check_success $? "安装 Tomcat 9"

sudo systemctl is-active --quiet tomcat9
check_success $? "确认 Tomcat 服务正在运行"

sudo mkdir -p /etc/guacamole && sudo chmod 755 /etc/guacamole
check_success $? "创建 Guacamole 配置文件目录 /etc/guacamole"

echo "正在下载 Guacamole Web 应用 (.war 文件)..."
wget https://apache.org/dyn/closer.lua/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war -O guacamole.war -q --show-progress
check_success $? "下载 Guacamole Web 应用 (.war 文件)"
[ ! -f guacamole.war ] && print_error "Guacamole .war 文件下载失败！"

sudo mv guacamole.war /var/lib/tomcat9/webapps/
check_success $? "将 .war 文件部署到 Tomcat"

# --- 自动化密码配置 ---
echo -e "${YELLOW}--- 自动化密码配置 ---${NC}"
read -sp "请为 Guacamole 网页登录设置一个新密码: " GUAC_PASS; echo
read -sp "请再次输入您在步骤1中设置的 VNC 密码: " VNC_PASS; echo

# 创建 guacamole.properties
sudo bash -c 'cat > /etc/guacamole/guacamole.properties' << EOF
guacd-hostname: localhost
guacd-port: 4822
user-mapping: /etc/guacamole/user-mapping.xml
EOF
check_success $? "创建 guacamole.properties 配置文件"

# 创建 user-mapping.xml 模板
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

# 使用 sed 安全地替换密码占位符
sudo sed -i "s|__GUAC_PASSWORD_PLACEHOLDER__|${GUAC_PASS}|g" /etc/guacamole/user-mapping.xml
check_success $? "自动填入 Guacamole 登录密码"
sudo sed -i "s|__VNC_PASSWORD_PLACEHOLDER__|${VNC_PASS}|g" /etc/guacamole/user-mapping.xml
check_success $? "自动填入 VNC 连接密码"

sudo chown tomcat:tomcat /etc/guacamole/ -R
check_success $? "设置配置文件权限"

echo "正在重启 Tomcat 以应用所有更改..."
sudo systemctl restart tomcat9
check_success $? "重启 Tomcat 服务"

echo "等待 15 秒，让 Guacamole Web 应用完成初始化..."
sleep 15

# --- 终极验证 ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/guacamole/)
if [ "$HTTP_CODE" -eq 200 ]; then
    print_success "终极验证通过！Guacamole 登录页面已成功上线。"
else
    print_error "终极验证失败！无法访问 Guacamole 登录页面 (HTTP Code: $HTTP_CODE)。请检查 Tomcat 日志: 'sudo journalctl -u tomcat9'"
fi


# ==============================================================================
# == 第四部分：完成
# ==============================================================================
print_step "步骤 4/4：安装完成！"

print_success "所有组件已成功安装并配置。"
echo -e "${YELLOW}您现在可以通过浏览器访问您的远程桌面了！${NC}"
echo ""
echo -e "  访问地址: ${GREEN}http://<您的CloudStudio公网IP>:8080/guacamole/${NC}"
echo -e "  用户名:   ${GREEN}user${NC}"
echo -e "  密码:     ${GREEN}您刚刚为 Guacamole 设置的网页登录密码${NC}"
echo ""
echo "登录后，点击 'XFCE Desktop' 连接即可进入。祝您使用愉快！"
