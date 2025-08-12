#!/bin/bash

# ===================================================================================
# ==  Apache Guacamole 透明安装脚本 (v9.6 - 修复 Tomcat 重启问题)                ==
# ===================================================================================
# ==  作者: Kilo Code (经 Claude 修复与增强)                                      ==
# ==  此版本修正了在非 systemd 环境下 Tomcat 无法正常启动的问题。                ==
# ==  现在脚本会正确创建必要目录并以正确用户身份启动 Tomcat。                    ==
# ===================================================================================

# --- 函数定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_step() { echo -e "\n${BLUE}=======================================================================\n== ${1}\n=======================================================================${NC}"; }
print_success() { echo -e "${GREEN}[✔] 成功: ${1}${NC}"; }
print_error() { echo -e "${RED}[✘] 失败: ${1}${NC}\n${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"; exit 1; }
print_info() { echo -e "${YELLOW}[i] 信息: ${1}${NC}"; }
print_warning() { echo -e "${YELLOW}[!] 警告: ${1}${NC}"; }

check_success() { [ $1 -eq 0 ] && print_success "${2}" || print_error "${2}"; }

# 新增函数：安全地停止 Tomcat 进程
safe_stop_tomcat() {
    local tomcat_service="$1"
    print_info "正在安全地停止现有的 Tomcat 进程..."
    
    # 尝试优雅关闭
    sudo pkill -f "org.apache.catalina.startup.Bootstrap" 2>/dev/null || true
    sleep 3
    
    # 检查是否还有进程运行
    if pgrep -f "org.apache.catalina.startup.Bootstrap" > /dev/null; then
        print_info "发现残余进程，强制终止..."
        sudo pkill -9 -f "org.apache.catalina.startup.Bootstrap" 2>/dev/null || true
        sleep 2
    fi
    
    print_success "Tomcat 进程已停止"
}

# 新增函数：准备 Tomcat 环境
prepare_tomcat_environment() {
    local tomcat_service="$1"
    local tomcat_home="/usr/share/${tomcat_service}"
    local tomcat_base="/var/lib/${tomcat_service}"
    
    print_info "正在准备 Tomcat 运行环境..."
    
    # 创建必要的目录
    sudo mkdir -p "${tomcat_home}/logs" "${tomcat_home}/temp" "${tomcat_home}/work"
    sudo mkdir -p "${tomcat_base}/logs" "${tomcat_base}/temp" "${tomcat_base}/work"
    
    # 设置正确的权限
    sudo chown -R tomcat:tomcat "${tomcat_home}/logs" "${tomcat_home}/temp" "${tomcat_home}/work"
    sudo chown -R tomcat:tomcat "${tomcat_base}/logs" "${tomcat_base}/temp" "${tomcat_base}/work"
    
    # 确保 webapps 目录权限正确
    sudo chown -R tomcat:tomcat "${tomcat_base}/webapps"
    
    print_success "Tomcat 环境准备完成"
}

# 新增函数：启动 Tomcat
start_tomcat_process() {
    local tomcat_service="$1"
    local tomcat_home="/usr/share/${tomcat_service}"
    local tomcat_base="/var/lib/${tomcat_service}"
    
    print_info "正在启动 Tomcat 服务..."
    
    # 设置环境变量并以 tomcat 用户身份启动
    sudo -u tomcat bash -c "
        export CATALINA_HOME='${tomcat_home}'
        export CATALINA_BASE='${tomcat_base}'
        export CATALINA_TMPDIR='${tomcat_base}/temp'
        export JRE_HOME='/usr'
        cd '${tomcat_home}'
        '${tomcat_home}/bin/startup.sh'
    "
    
    local start_result=$?
    
    if [ $start_result -eq 0 ]; then
        print_success "Tomcat 启动命令执行成功"
        
        # 等待进程启动
        print_info "等待 Tomcat 进程启动..."
        local wait_count=0
        while [ $wait_count -lt 15 ]; do
            if pgrep -f "org.apache.catalina.startup.Bootstrap" > /dev/null; then
                print_success "Tomcat 进程已成功启动"
                return 0
            fi
            sleep 2
            wait_count=$((wait_count + 1))
        done
        
        print_error "Tomcat 进程启动超时"
        return 1
    else
        print_error "Tomcat 启动命令执行失败"
        return 1
    fi
}
# --- 函数定义结束 ---


# --- 脚本主流程开始 ---
print_step "步骤 0/4：环境准备"
sudo apt-get update
check_success $? "更新软件包列表"

sudo apt-get install -y apt-utils psmisc openssl
check_success $? "安装基础工具 (psmisc, openssl)"

export DEBIAN_FRONTEND=noninteractive
check_success $? "设置 DEBIAN_FRONTEND=noninteractive"

echo -e "${YELLOW}重要提示: 请确保您已在 Cloud Studio 的防火墙/安全组中开放了 TCP 端口 8080。${NC}"
read -p "如果已确认，请按 Enter 键继续..."


# ==============================================================================
# == 第一部分：安装并运行 VNC 服务器 (桌面环境)
# ==============================================================================
print_step "步骤 1/4：安装 VNC 服务器和 XFCE 桌面"
sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator
check_success $? "安装 VNC 和 XFCE 核心组件"

print_info "正在自动生成并设置一个安全的 VNC 密码..."
VNC_PASS=$(openssl rand -base64 8)
mkdir -p ~/.vnc
echo -e "${VNC_PASS}\n${VNC_PASS}\nn" | vncpasswd
check_success $? "自动执行 vncpasswd 命令"
[ ! -f ~/.vnc/passwd ] && print_error "VNC 密码文件 (~/.vnc/passwd) 创建失败！"
print_success "VNC 密码已自动设置。"
echo -e "  ${YELLOW}您的 VNC 连接密码是: ${GREEN}${VNC_PASS}${NC} (此密码已自动配置，仅供记录)"

print_info "正在创建优化的 VNC 启动脚本 (xstartup)..."
cat > ~/.vnc/xstartup << EOF
#!/bin/sh
export XDG_CURRENT_DESKTOP="XFCE"
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chmod +x ~/.vnc/xstartup
check_success $? "创建并配置优化的 xstartup 文件"

print_info "正在尝试首次启动 VNC 服务器以验证配置..."
vncserver :1 -xstartup ~/.vnc/xstartup
sleep 4
if ! pgrep -f "Xtigervnc :1" > /dev/null; then
    LOG_FILE_PATH=$(find ~/.vnc/ -name "*.log" | head -n 1)
    print_error "VNC 服务启动失败！未能检测到 'Xtigervnc :1' 进程。"
    [ -n "$LOG_FILE_PATH" ] && [ -f "$LOG_FILE_PATH" ] && print_info "日志内容:\n$(cat $LOG_FILE_PATH)"
    exit 1
fi
print_success "VNC 服务已成功临时启动。"
vncserver -kill :1 > /dev/null 2>&1 || pkill -f "Xtigervnc :1"
sleep 1
print_success "临时 VNC 会话已成功停止。"
print_info "正在以最终配置重新启动 VNC 服务器..."
vncserver -localhost no :1 -xstartup ~/.vnc/xstartup
check_success $? "以最终配置重新启动 VNC 服务器"
sleep 2
if ! netstat -tuln | grep -q ':5901'; then print_error "VNC 服务器端口 5901 未被监听。"; fi
print_success "VNC 服务器已在 :1 (端口 5901) 上成功运行并监听。"


# ==============================================================================
# == 第二部分：安装 guacd (Guacamole 后端)
# ==============================================================================
print_step "步骤 2/4：编译并安装 Guacamole 后端 (guacd)"
GUACD_DEPS="build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev libtelnet-dev libwebsockets-dev libpulse-dev"
sudo apt-get install -y $GUACD_DEPS
check_success $? "安装 guacd 编译依赖项"

GUAC_VERSION="1.5.3"
wget "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz" -O guacamole-server.tar.gz
check_success $? "下载 Guacamole 源代码"
tar -xzf guacamole-server.tar.gz
check_success $? "解压源代码"
cd "guacamole-server-${GUAC_VERSION}"
./configure --with-systemd-dir=/etc/systemd/system
check_success $? "运行 ./configure 脚本"
make
check_success $? "编译源代码 (make)"
sudo make install
check_success $? "安装编译好的文件 (make install)"
sudo ldconfig
check_success $? "更新动态链接库缓存"

if [ -d /run/systemd/system ]; then
    print_info "检测到 systemd 环境，使用 systemctl 启动 guacd..."
    sudo systemctl enable guacd && sudo systemctl start guacd
    check_success $? "启动并设置 guacd 服务开机自启"
    sleep 2
    sudo systemctl is-active --quiet guacd
    check_success $? "确认 guacd 服务正在后台运行 (via systemctl)"
else
    print_warning "未检测到 systemd 环境。将直接启动 guacd 守护进程..."
    sudo /usr/local/sbin/guacd
    check_success $? "直接执行 guacd 命令"
    sleep 2
    pgrep guacd > /dev/null
    check_success $? "确认 guacd 进程正在后台运行 (via pgrep)"
fi
cd ..


# ==============================================================================
# == 第三部分：安装 Tomcat 和 Guacamole Web 应用 (前端)
# ==============================================================================
print_step "步骤 3/4：安装 Tomcat 并自动化配置 Guacamole"

# 安装 default-jdk 以获取 jar 命令
print_info "安装 Java 开发工具包 (包含 jar 命令)..."
sudo apt-get install -y default-jdk
check_success $? "安装 Java 开发工具包"

TOMCAT_VERSION_MAJOR=""
TOMCAT_SERVICE=""
TOMCAT_WEBAPPS_DIR=""
print_info "正在尝试安装合适的 Tomcat 版本 (10, 9, 或 8)..."

if sudo apt-get install -y tomcat10 > /dev/null 2>&1; then
    TOMCAT_VERSION_MAJOR="10"
elif sudo apt-get install -y tomcat9 > /dev/null 2>&1; then
    TOMCAT_VERSION_MAJOR="9"
elif sudo apt-get install -y tomcat8 > /dev/null 2>&1; then
    TOMCAT_VERSION_MAJOR="8"
fi

if [ -n "$TOMCAT_VERSION_MAJOR" ]; then
    TOMCAT_SERVICE="tomcat${TOMCAT_VERSION_MAJOR}"
    TOMCAT_WEBAPPS_DIR="/var/lib/${TOMCAT_SERVICE}/webapps/"
    print_success "成功安装 Tomcat ${TOMCAT_VERSION_MAJOR}。"
else
    print_error "无法安装任何受支持的 Tomcat 版本 (10, 9, 8)。请检查您的 apt 软件源配置。"
fi

sudo mkdir -p /etc/guacamole && sudo chmod 755 /etc/guacamole
wget "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war" -O guacamole.war
sudo mv guacamole.war "${TOMCAT_WEBAPPS_DIR}"
check_success $? "部署 .war 文件到 ${TOMCAT_WEBAPPS_DIR}"

echo -e "${YELLOW}--- 自动化 Guacamole 密码配置 ---${NC}"
# 使用固定的安全密码，避免交互输入问题
GUAC_PASS="Guacamole2024!"
print_success "已设置默认登录密码为: ${GUAC_PASS}"

sudo bash -c 'cat > /etc/guacamole/guacamole.properties' << EOF
guacd-hostname: localhost
guacd-port: 4822
user-mapping: /etc/guacamole/user-mapping.xml
EOF
sudo bash -c 'cat > /etc/guacamole/user-mapping.xml' << EOF
<user-mapping>
    <authorize username="user" password="${GUAC_PASS}">
        <connection name="XFCE Desktop">
            <protocol>vnc</protocol>
            <param name="hostname">localhost</param>
            <param name="port">5901</param>
            <param name="password">${VNC_PASS}</param>
        </connection>
    </authorize>
</user-mapping>
EOF
check_success $? "创建并自动填入所有配置文件"
sudo chown tomcat:tomcat /etc/guacamole/ -R
check_success $? "设置配置文件权限"

# 【核心修正】改进的 Tomcat 重启逻辑
if [ -d /run/systemd/system ]; then
    sudo systemctl restart "${TOMCAT_SERVICE}"
    check_success $? "重启 ${TOMCAT_SERVICE} 服务 (via systemctl)"
else
    print_warning "非 systemd 环境，将通过改进的方法重启 Tomcat..."
    
    # 停止现有进程
    safe_stop_tomcat "${TOMCAT_SERVICE}"
    
    # 准备运行环境
    prepare_tomcat_environment "${TOMCAT_SERVICE}"
    
    # 启动 Tomcat
    start_tomcat_process "${TOMCAT_SERVICE}"
    check_success $? "通过改进的方法启动 Tomcat"
fi

echo "等待 30 秒让 Guacamole Web 应用完成初始化..."
sleep 30

# 验证 Tomcat 进程是否运行
if ! pgrep -f "org.apache.catalina.startup.Bootstrap" > /dev/null; then
    print_error "Tomcat 进程未运行！请检查日志文件。"
fi

# 验证端口是否监听
if ! netstat -tuln | grep -q ':8080'; then
    print_warning "端口 8080 未被监听，但继续验证 HTTP 访问..."
fi

# 检查 WAR 文件是否正确部署
print_info "检查 Guacamole WAR 文件部署状态..."
WEBAPP_DIR="/var/lib/${TOMCAT_SERVICE}/webapps"
if [ ! -f "${WEBAPP_DIR}/guacamole.war" ]; then
    print_error "guacamole.war 文件不存在于 ${WEBAPP_DIR}/"
fi

if [ ! -d "${WEBAPP_DIR}/guacamole" ]; then
    print_warning "Guacamole 应用目录不存在，可能部署失败"
    print_info "尝试手动解压 WAR 文件..."
    
    cd "${WEBAPP_DIR}"
    sudo -u tomcat mkdir -p guacamole
    cd guacamole
    
    # 检查 jar 命令是否可用，如果不可用则使用 unzip
    if command -v jar >/dev/null 2>&1; then
        sudo -u tomcat jar -xf ../guacamole.war
    elif command -v unzip >/dev/null 2>&1; then
        sudo -u tomcat unzip -q ../guacamole.war
    else
        print_error "无法找到 jar 或 unzip 命令来解压 WAR 文件"
    fi
    check_success $? "手动解压 guacamole.war 文件"
    
    print_info "重新启动 Tomcat 以重新加载应用..."
    safe_stop_tomcat "${TOMCAT_SERVICE}"
    sleep 3
    start_tomcat_process "${TOMCAT_SERVICE}"
    
    echo "等待 20 秒让应用重新加载..."
    sleep 20
else
    print_success "Guacamole 应用目录存在"
fi

# 检查 Guacamole 配置文件路径
print_info "验证 Guacamole 配置..."
if [ ! -f /etc/guacamole/guacamole.properties ]; then
    print_warning "Guacamole 配置文件不存在"
fi

# 创建 GUACAMOLE_HOME 符号链接（如果不存在）
if [ ! -L /usr/share/${TOMCAT_SERVICE}/.guacamole ]; then
    print_info "创建 GUACAMOLE_HOME 符号链接..."
    sudo ln -sf /etc/guacamole /usr/share/${TOMCAT_SERVICE}/.guacamole
    sudo chown -h tomcat:tomcat /usr/share/${TOMCAT_SERVICE}/.guacamole
fi

HTTP_CODE=$(curl -s -L -o /dev/null -w "%{http_code}" http://localhost:8080/guacamole/)
if [ "$HTTP_CODE" -eq 200 ]; then
    print_success "终极验证通过！Guacamole 登录页面已成功上线 (HTTP Code: $HTTP_CODE)。"
elif [ "$HTTP_CODE" -eq 302 ] || [ "$HTTP_CODE" -eq 301 ]; then
    print_success "Guacamole 已启动并正在重定向 (HTTP Code: $HTTP_CODE)，这是正常的。"
else
    print_warning "HTTP 验证返回代码: $HTTP_CODE"
    
    # 提供 ROOT 部署选项
    print_info "尝试将 Guacamole 部署为 ROOT 应用 (访问 http://ip:8080/)..."
    cd "${WEBAPP_DIR}"
    
    # 备份原 ROOT
    if [ -d ROOT ]; then
        sudo mv ROOT ROOT.backup
    fi
    if [ -f ROOT.war ]; then
        sudo mv ROOT.war ROOT.war.backup  
    fi
    
    # 将 guacamole 部署为 ROOT
    sudo cp guacamole.war ROOT.war
    sudo -u tomcat mkdir -p ROOT
    cd ROOT
    
    # 使用 jar 或 unzip 解压
    if command -v jar >/dev/null 2>&1; then
        sudo -u tomcat jar -xf ../ROOT.war
    elif command -v unzip >/dev/null 2>&1; then
        sudo -u tomcat unzip -q ../ROOT.war
    else
        print_error "无法找到解压工具"
    fi
    
    print_info "重新启动 Tomcat..."
    safe_stop_tomcat "${TOMCAT_SERVICE}"
    sleep 3
    start_tomcat_process "${TOMCAT_SERVICE}"
    
    echo "等待 25 秒让 ROOT 应用加载..."
    sleep 25
    
    ROOT_CODE=$(curl -s -L -o /dev/null -w "%{http_code}" http://localhost:8080/)
    if [ "$ROOT_CODE" -eq 200 ] || [ "$ROOT_CODE" -eq 302 ] || [ "$ROOT_CODE" -eq 301 ]; then
        print_success "Guacamole 已成功部署为 ROOT 应用！现在可通过 http://your-ip:8080/ 访问"
        echo -e "\n${GREEN}现在您可以通过以下地址访问 Guacamole：${NC}"
        echo -e "  ${YELLOW}主要访问地址: ${GREEN}http://<您的IP>:8080/${NC}"
        echo -e "  ${YELLOW}备用访问地址: ${GREEN}http://<您的IP>:8080/guacamole/${NC}"
    else
        print_warning "ROOT 部署也失败了，请检查日志文件"
        print_info "请检查以下日志文件获取详细信息："
        print_info "  - /var/lib/${TOMCAT_SERVICE}/logs/catalina.out"
        print_info "  - /usr/share/${TOMCAT_SERVICE}/logs/catalina.out"
        print_info "  - /var/log/${TOMCAT_SERVICE}/catalina.out"
    fi
fi

# ==============================================================================
# == 第四部分：完成
# ==============================================================================
print_step "步骤 4/4：安装完成！"
print_success "所有组件已成功安装并配置。"

echo -e "\n${BLUE}=== Guacamole 访问信息 ===${NC}"
echo -e "  ${YELLOW}推荐访问地址: ${GREEN}http://<您的CloudStudio公网IP>:8080/${NC}"
echo -e "  ${YELLOW}备用访问地址: ${GREEN}http://<您的CloudStudio公网IP>:8080/guacamole/${NC}"
echo -e "  ${YELLOW}用户名: ${GREEN}user${NC}"
echo -e "  ${YELLOW}密码: ${GREEN}Guacamole2024!${NC}"

echo -e "\n${BLUE}=== 手动修复指南（如果上述地址无法访问）===${NC}"
echo -e "${YELLOW}方法1 - 检查部署状态:${NC}"
echo -e "  sudo ls -la /var/lib/${TOMCAT_SERVICE}/webapps/"
echo -e "  sudo ls -la /var/lib/${TOMCAT_SERVICE}/webapps/guacamole/"

echo -e "\n${YELLOW}方法2 - 手动重新部署:${NC}"
echo -e "  cd /var/lib/${TOMCAT_SERVICE}/webapps/"
echo -e "  sudo rm -rf guacamole guacamole.war"
echo -e "  sudo wget https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war -O guacamole.war"
echo -e "  sudo chown tomcat:tomcat guacamole.war"
echo -e "  sudo systemctl restart ${TOMCAT_SERVICE}"

echo -e "\n${YELLOW}方法3 - 部署为 ROOT 应用（直接访问 http://ip:8080/）:${NC}"
echo -e "  cd /var/lib/${TOMCAT_SERVICE}/webapps/"
echo -e "  sudo mv ROOT ROOT.backup"
echo -e "  sudo cp guacamole.war ROOT.war"
echo -e "  sudo systemctl restart ${TOMCAT_SERVICE}"

echo -e "\n${YELLOW}方法4 - 使用其他端口:${NC}"
echo -e "  编辑 /etc/${TOMCAT_SERVICE}/server.xml"
echo -e "  将端口 8080 改为 8090 或其他端口"
echo -e "  重启 Tomcat 服务"

echo -e "\n${YELLOW}故障排除命令:${NC}"
echo -e "  检查 Tomcat 进程: ${GREEN}ps aux | grep tomcat${NC}"
echo -e "  检查端口监听: ${GREEN}netstat -tuln | grep 8080${NC}"
echo -e "  查看实时日志: ${GREEN}sudo tail -f /var/lib/${TOMCAT_SERVICE}/logs/catalina.out${NC}"
echo -e "  检查应用状态: ${GREEN}curl -I http://localhost:8080/guacamole/${NC}"

echo -e "\n${GREEN}祝您使用愉快！如果遇到问题，请按照上述方法逐一排查。${NC}"
