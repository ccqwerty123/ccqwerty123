#!/bin-bash

# ==============================================================================
# ==   Apache Guacamole 安全安装脚本 (带详细步骤验证与错误处理)         ==
# ==============================================================================
# ==   此脚本将引导您完成所有安装步骤，并在每一步后进行验证。           ==
# ==   如果任何步骤失败，脚本将立即停止并报告错误。                     ==
# ==============================================================================

# --- 设置颜色代码以便输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 封装好的打印函数 ---
print_step() {
    echo -e "\n${BLUE}=======================================================================${NC}"
    echo -e "${BLUE}== ${1}${NC}"
    echo -e "${BLUE}=======================================================================${NC}"
}

print_success() {
    echo -e "${GREEN}[✔] 成功: ${1}${NC}"
}

print_error() {
    echo -e "${RED}[✘] 失败: ${1}${NC}"
    echo -e "${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"
    exit 1
}

# --- 核心检查函数 ---
# 参数1: $? (上一个命令的退出码)
# 参数2: 错误信息字符串
check_success() {
    if [ $1 -eq 0 ]; then
        print_success "${2}"
    else
        print_error "${2}"
    fi
}

# --- 脚本主流程开始 ---

print_step "步骤 0/4：环境检查与准备"

# 检查是否以 root 权限运行，因为多数命令需要 sudo
if [[ $EUID -eq 0 ]]; then
   echo -e "${YELLOW}警告: 您正在以 root 用户身份运行。为安全起见，建议使用普通用户配合 sudo。${NC}"
fi

# 检查端口开放提示
echo -e "${YELLOW}重要提示: 请确保您已经在 Cloud Studio 的防火墙/安全组中，为本实例开放了 TCP 端口 8080。${NC}"
read -p "如果您已确认端口已开放，请按 Enter 键继续..."

sudo apt-get update
check_success $? "更新软件包列表"


# ==============================================================================
# == 第一部分：安装并运行 VNC 服务器 (桌面环境)
# ==============================================================================
print_step "步骤 1/4：安装 VNC 服务器和 XFCE 桌面环境"

sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator
check_success $? "安装 VNC 和 XFCE 核心组件"

# 验证 vncserver 命令是否可用
command -v vncserver > /dev/null 2>&1
check_success $? "确认 vncserver 命令已安装"

echo -e "${YELLOW}--- 用户操作：设置 VNC 密码 ---${NC}"
echo "接下来，系统将提示您设置 VNC 连接密码。这是 Guacamole 连接到桌面时需要用的密码。"
echo "1. 请输入一个 6-8 位的密码，然后按 Enter。"
echo "2. 系统会要求您再次输入以验证，请重复输入一次。"
echo "3. 当询问 'Would you like to enter a view-only password (y/n)?' 时，请输入 'n' 然后按 Enter。"
read -p "理解后，请按 Enter 键开始设置密码..."

vncserver :1
check_success $? "首次运行 vncserver 以生成配置文件"

vncserver -kill :1 > /dev/null 2>&1
check_success $? "临时关闭 VNC 会话以进行配置"

if [ ! -f ~/.vnc/xstartup ]; then
    print_error "VNC 配置文件 ~/.vnc/xstartup 未找到！"
fi

echo "startxfce4 &" >> ~/.vnc/xstartup
check_success $? "配置 VNC 启动脚本以加载 XFCE"

vncserver -localhost no :1
check_success $? "以正确的配置重新启动 VNC 服务器"

print_success "VNC 服务器已在 :1 (端口 5901) 上成功运行并加载 XFCE 桌面。"


# ==============================================================================
# == 第二部分：安装 guacd (Guacamole 后端)
# ==============================================================================
print_step "步骤 2/4：编译并安装 Guacamole 后端 (guacd)"

sudo apt-get install -y build-essential libcairo2-dev libjpeg-turbo8-dev \
libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev \
libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev \
libtelnet-dev libwebsockets-dev libpulse-dev
check_success $? "安装 guacd 编译所需的所有依赖项"

GUAC_VERSION="1.5.3"
wget https://apache.org/dyn/closer.lua/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz -O guacamole-server.tar.gz
check_success $? "下载 Guacamole Server ${GUAC_VERSION} 源代码"

tar -xzf guacamole-server.tar.gz
check_success $? "解压源代码"

cd guacamole-server-${GUAC_VERSION}
./configure --with-systemd-dir=/etc/systemd/system
check_success $? "运行 ./configure 脚本 (检查编译环境)"

make
check_success $? "编译源代码 (make)"

sudo make install
check_success $? "安装编译好的文件 (make install)"

sudo ldconfig
check_success $? "更新动态链接库缓存"

# 验证 guacd 是否已成功安装到标准路径
[ -f /usr/local/sbin/guacd ]
check_success $? "验证 guacd 可执行文件是否存在"

sudo systemctl enable guacd
check_success $? "设置 guacd 服务开机自启"

sudo systemctl start guacd
check_success $? "启动 guacd 服务"

# 最关键的验证：检查服务是否真的在运行
sudo systemctl is-active --quiet guacd
check_success $? "确认 guacd 服务正在后台运行 (active)"

cd ..
print_success "Guacamole 后端 (guacd) 已成功安装并运行。"


# ==============================================================================
# == 第三部分：安装 Tomcat 和 Guacamole Web 应用 (前端)
# ==============================================================================
print_step "步骤 3/4：安装 Tomcat 和 Guacamole Web 应用"

sudo apt-get install -y tomcat9
check_success $? "安装 Tomcat 9"

sudo systemctl is-active --quiet tomcat9
check_success $? "确认 Tomcat 服务正在运行"

sudo mkdir -p /etc/guacamole
check_success $? "创建 Guacamole 配置文件目录 /etc/guacamole"

wget https://apache.org/dyn/closer.lua/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war -O guacamole.war
check_success $? "下载 Guacamole Web 应用 (.war 文件)"

sudo mv guacamole.war /var/lib/tomcat9/webapps/
check_success $? "将 .war 文件部署到 Tomcat"

# 创建 Guacamole 核心配置文件
sudo bash -c 'cat > /etc/guacamole/guacamole.properties' << EOF
guacd-hostname: localhost
guacd-port:    4822
EOF
check_success $? "创建 guacamole.properties 配置文件"

# 创建用户连接映射文件
sudo bash -c 'cat > /etc/guacamole/user-mapping.xml' << EOF
<user-mapping>
    <authorize username="user" password="your_guac_password">
        <connection name="XFCE Desktop">
            <protocol>vnc</protocol>
            <param name="hostname">localhost</param>
            <param name="port">5901</param>
            <param name="password">your_vnc_password</param>
        </connection>
    </authorize>
</user-mapping>
EOF
check_success $? "创建 user-mapping.xml 配置文件"

echo -e "${YELLOW}--- 关键用户操作：修改连接密码 ---${NC}"
echo "配置文件 /etc/guacamole/user-mapping.xml 已创建。"
echo "您必须手动修改此文件中的密码！"
echo "  - your_guac_password: 这是您登录 Guacamole 网页时要用的密码。"
echo "  - your_vnc_password:  这是您在【步骤 1】中设置的 VNC 密码。"
echo "请打开一个新的终端，使用命令 'sudo nano /etc/guacamole/user-mapping.xml' 来编辑它。"
read -p "完成密码修改后，请返回此窗口并按 Enter 键继续..."

# 链接配置文件到 Tomcat 能找到的地方
if [ ! -L /usr/share/tomcat9/conf/guacamole.properties ]; then
  sudo ln -s /etc/guacamole/guacamole.properties /usr/share/tomcat9/conf/
  check_success $? "链接 guacamole.properties 配置文件"
else
  print_success "配置文件链接已存在，跳过创建。"
fi

# 重启 Tomcat 来加载 Guacamole Web 应用和配置
sudo systemctl restart tomcat9
check_success $? "重启 Tomcat 服务以应用所有更改"

# 再次验证 Tomcat 重启后是否正常运行
sudo systemctl is-active --quiet tomcat9
check_success $? "确认 Tomcat 服务在重启后仍然正常运行"


# ==============================================================================
# == 第四部分：完成
# ==============================================================================
print_step "步骤 4/4：安装完成！"

print_success "所有组件已成功安装并配置。"
echo -e "${YELLOW}您现在可以通过浏览器访问您的远程桌面了！${NC}"
echo ""
echo -e "  访问地址: ${GREEN}http://<您的CloudStudio公网IP>:8080/guacamole/${NC}"
echo -e "  用户名:   ${GREEN}user${NC}"
echo -e "  密码:     ${GREEN}您在 user-mapping.xml 中为 'your_guac_password' 设置的密码${NC}"
echo ""
echo "登录后，点击 'XFCE Desktop' 连接即可进入。"
echo "祝您使用愉快！"
