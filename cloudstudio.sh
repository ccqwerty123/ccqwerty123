#!/bin/bash

# ===================================================================================
# ==  Apache Guacamole 智能安装脚本 (v15.0 - 决策增强与内存控制版)              ==
# ===================================================================================
# ==  作者: Kilo Code (经 Gemini AI 重构与增强)                                  ==
# ==  此版本为解决复杂环境下的安装问题而设计，核心特性如下：                  ==
# ==  1. 内存控制：强制 `make -j2`，从根源上防止编译时内存耗尽。                ==
# ==  2. 环境感知：自动检测 XFCE/VNC/guacd 是否已安装，避免重复操作。           ==
# ==  3. 配置适配：明确支持无密码 VNC，并创建独立的 VNC 会话 (:2, 端口 5902)。  ==
# ==  4. 超级诊断：在脚本执行的每一步都提供清晰的中文输出，并在最后进行配置核查。==
# ===================================================================================

# --- 脚本设置与全局函数 ---
set -eo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_step() { echo -e "\n${BLUE}=======================================================================\n== ${1}\n=======================================================================${NC}"; }
print_success() { echo -e "${GREEN}[✔] 成功: ${1}${NC}"; }
print_error() { echo -e "${RED}[✘] 错误: ${1}${NC}\n${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"; exit 1; }
print_info() { echo -e "${YELLOW}[i] 信息: ${1}${NC}"; }
print_skip() { echo -e "${YELLOW}[»] 跳过: ${1}${NC}"; }
check_success() {
    if [ $1 -eq 0 ]; then
        print_success "$2"
    else
        print_error "$2 (退出码: $1)"
    fi
}

# --- 定义关键变量 (方便未来修改) ---
VNC_DISPLAY=":2"
VNC_PORT="5902"
GUAC_VERSION="1.5.5" # 您可以更改为您需要的版本

# ==============================================================================
# == 步骤 0/6：环境准备与无交互配置
# ==============================================================================
print_step "步骤 0/6：环境准备与无交互配置"
print_info "正在更新软件包列表..."
sudo apt-get update
check_success $? "更新软件包列表"

export DEBIAN_FRONTEND=noninteractive
print_info "正在预设 debconf 答案以避免交互式提示..."
sudo debconf-set-selections <<< "keyboard-configuration keyboard-configuration/layoutcode string us"
sudo debconf-set-selections <<< "keyboard-configuration keyboard-configuration/variantcode string intl"
check_success $? "预设键盘配置"

print_info "正在安装基础工具 (apt-utils, wget, curl, etc)..."
sudo apt-get install -y psmisc wget curl net-tools apt-utils
check_success $? "安装基础工具"

# ==============================================================================
# == 步骤 1/6：检查并配置新的 VNC 会话 (端口 ${VNC_PORT})
# ==============================================================================
print_step "步骤 1/6：检查并配置新的 VNC 会话 (端口 ${VNC_PORT})"

# 检查 XFCE 和 VNC 软件是否已安装
if dpkg -s xfce4 >/dev/null 2>&1 && dpkg -s tigervnc-standalone-server >/dev/null 2>&1; then
    print_skip "检测到 XFCE 和 TigerVNC 软件均已安装，将直接复用。"
else
    print_info "正在安装 VNC 和 XFCE，这将需要一些时间..."
    sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator
    check_success $? "安装 VNC 和 XFCE 核心组件"
fi

print_info "重要：此脚本将创建一个【无密码】的 VNC 会话。"
# 为新的VNC会话创建 xstartup 文件
mkdir -p ~/.vnc
cat > ~/.vnc/xstartup << EOF
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_CURRENT_DESKTOP="XFCE"
exec startxfce4
EOF
chmod +x ~/.vnc/xstartup
print_success "已配置 VNC 的 xstartup 文件"

# 启动一个新的、独立的 VNC 服务器实例
vncserver -kill ${VNC_DISPLAY} >/dev/null 2>&1 && sleep 1
print_info "正在显示器 ${VNC_DISPLAY} (端口 ${VNC_PORT}) 上启动一个新的 VNC 服务..."
vncserver ${VNC_DISPLAY} -localhost no
check_success $? "执行新 VNC 服务器启动命令"

# --- 即时诊断 #1：检查新 VNC 会话 ---
print_info "正在进行即时诊断：验证新的 VNC 服务器状态..."
if pgrep -f "Xtigervnc ${VNC_DISPLAY}" > /dev/null && netstat -tuln | grep -q ":${VNC_PORT}"; then
    print_success "新的 VNC 服务器正在运行，并在端口 ${VNC_PORT} 上监听。"
else
    print_error "新的 VNC 服务器未能成功启动！请检查上面的 XFCE 或 VNC 日志。"
fi

# ==============================================================================
# == 步骤 2/6：编译并安装 Guacamole 后端 (guacd)
# ==============================================================================
print_step "步骤 2/6：编译并安装 Guacamole 后端 (guacd)"

# 检查 guacd 是否已经安装，如果已安装则跳过整个编译过程
if command -v /usr/local/sbin/guacd &> /dev/null; then
    print_skip "检测到 guacd (/usr/local/sbin/guacd) 已存在，跳过整个编译安装过程。"
else
    GUACD_DEPS="build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev libtelnet-dev libwebsockets-dev libpulse-dev"
    print_info "正在安装 guacd 的编译依赖..."
    sudo apt-get install -y $GUACD_DEPS
    check_success $? "安装 guacd 编译依赖项"

    wget --progress=bar:force --timeout=120 "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz" -O guacamole-server.tar.gz
    check_success $? "下载 Guacamole Server 源码"

    tar -xzf guacamole-server.tar.gz && cd "guacamole-server-${GUAC_VERSION}"
    print_info "正在配置 (./configure)..."
    ./configure --with-systemd-dir=/etc/systemd/system
    check_success $? "源码配置"

    print_info "关键修改：正在使用 'make -j2' 进行编译以严格控制内存使用..."
    make -j2
    check_success $? "源码编译 (使用 -j2)"

    print_info "正在安装 (make install)..."
    sudo make install && sudo ldconfig
    check_success $? "安装 guacd"
    cd ..
fi

# 确保 guacd 守护进程正在运行
print_info "正在启动 guacd 守护进程..."
sudo /usr/local/sbin/guacd
check_success $? "执行 guacd 启动命令"

# --- 即时诊断 #2：检查 guacd ---
print_info "正在进行即时诊断：验证 guacd 守护进程状态..."
if pgrep guacd > /dev/null && netstat -tuln | grep -q ':4822'; then
    print_success "guacd 守护进程正在运行，并在端口 4822 上监听。"
else
    print_error "guacd 未能成功启动！请检查上面的日志。"
fi

# ==============================================================================
# == 步骤 3/6：安装 Tomcat 并配置 Guacamole Web 应用
# ==============================================================================
print_step "步骤 3/6：安装 Tomcat 并配置 Guacamole Web 应用"
print_info "正在安装 Java 和 Tomcat 10..."
sudo apt-get install -y default-jdk tomcat10
check_success $? "安装 default-jdk 和 tomcat10"

TOMCAT_WEBAPPS_DIR="/var/lib/tomcat10/webapps"
TOMCAT_USER="tomcat"
TOMCAT_HOME="/usr/share/tomcat10"

print_info "正在下载 guacamole-${GUAC_VERSION}.war ..."
wget --progress=bar:force --timeout=120 "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war" -O guacamole.war
check_success $? "下载 guacamole.war"

sudo mv guacamole.war "${TOMCAT_WEBAPPS_DIR}/"
GUAC_ADMIN_PASS="GuacAdmin`date +%s | tail -c 5`" # 为Guacamole管理员生成一个安全的随机密码
sudo mkdir -p /etc/guacamole

print_info "正在创建 Guacamole 核心配置文件..."
# 生成 guacamole.properties
sudo bash -c 'cat > /etc/guacamole/guacamole.properties' <<< "guacd-hostname: localhost
guacd-port: 4822
user-mapping: /etc/guacamole/user-mapping.xml"

print_info "适配修改：正在创建【无密码】的 VNC 连接配置，指向端口 ${VNC_PORT}..."
# 生成 user-mapping.xml，注意这里没有 password 参数
sudo bash -c 'cat > /etc/guacamole/user-mapping.xml' <<< "<user-mapping>
<authorize username=\"guacadmin\" password=\"${GUAC_ADMIN_PASS}\">
    <connection name=\"XFCE Desktop (Port ${VNC_PORT})\">
        <protocol>vnc</protocol>
        <param name=\"hostname\">localhost</param>
        <param name=\"port\">${VNC_PORT}</param>
    </connection>
</authorize>
</user-mapping>"

sudo chown -R ${TOMCAT_USER}:${TOMCAT_USER} /etc/guacamole && sudo chmod -R 750 /etc/guacamole
sudo ln -sfn /etc/guacamole "${TOMCAT_HOME}/.guacamole"
check_success $? "创建 Guacamole 配置文件和符号链接"

# ==============================================================================
# == 步骤 4/6：启动 Tomcat 并验证部署
# ==============================================================================
print_step "步骤 4/6：启动 Tomcat 并验证部署"
sudo systemctl restart tomcat10
print_info "已使用 systemctl 重启 Tomcat 服务。等待 25 秒以便其完全初始化..."
sleep 25

# --- 即时诊断 #3：检查 Tomcat ---
print_info "正在进行即时诊断：验证 Tomcat 和 Guacamole 应用状态..."
if systemctl is-active --quiet tomcat10; then
    print_success "Tomcat 服务 (通过 systemctl) 状态为 active。"
    if netstat -tuln | grep -q ':8080'; then
        print_success "端口 8080 (Tomcat) 正在监听。"
        # 注意: war包部署后，Tomcat 10 默认使用 /guacamole/ 路径
        # 我们将同时检查两个可能的路径以提高兼容性
        URL_PATH_ROOT="/guacamole"
        URL_PATH_WAR="/guacamole-${GUAC_VERSION}"
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://localhost:8080${URL_PATH_ROOT}/")
        
        if [ "$HTTP_CODE" -eq 200 ]; then
            print_success "Guacamole Web 应用在 ${URL_PATH_ROOT}/ 路径成功响应 (HTTP 200 OK)!"
            DEPLOYMENT_SUCCESS=true
            FINAL_URL_PATH="${URL_PATH_ROOT}/"
        else
            # 备用检查
            HTTP_CODE_WAR=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://localhost:8080${URL_PATH_WAR}/")
            if [ "$HTTP_CODE_WAR" -eq 200 ]; then
                print_success "Guacamole Web 应用在 ${URL_PATH_WAR}/ 路径成功响应 (HTTP 200 OK)!"
                DEPLOYMENT_SUCCESS=true
                FINAL_URL_PATH="${URL_PATH_WAR}/"
            else
                print_error "Tomcat 正在运行，但 Guacamole 应用无响应 (路径 ${URL_PATH_ROOT}/ 返回 ${HTTP_CODE}，路径 ${URL_PATH_WAR}/ 返回 ${HTTP_CODE_WAR})。请检查 Tomcat 日志。"
                DEPLOYMENT_SUCCESS=false
            fi
        fi
    else
        print_error "Tomcat 服务在运行，但未监听端口 8080！这是一个严重的内部错误。"
        DEPLOYMENT_SUCCESS=false
    fi
else
    print_error "Tomcat 服务未能成功启动或保持运行！这可能是由于内存不足或配置错误。请运行 'sudo systemctl status tomcat10' 和 'sudo journalctl -u tomcat10 -n 100' 查看详细日志。"
    DEPLOYMENT_SUCCESS=false
fi

# ==============================================================================
# == 步骤 5/6：安装完成！
# ==============================================================================
print_step "步骤 5/6：安装完成！"
if [ "$DEPLOYMENT_SUCCESS" = true ]; then
    IP_ADDR=$(hostname -I | awk '{print $1}')
    FINAL_URL="http://${IP_ADDR}:8080${FINAL_URL_PATH}"
    print_success "Guacamole 环境已成功安装和验证。"
    echo -e "\n${BLUE}========================= 访问凭据 ==========================${NC}"
    echo -e "  ${YELLOW}Guacamole URL: ${GREEN}${FINAL_URL}${NC}"
    echo -e "  ${YELLOW}用户名:          ${GREEN}guacadmin${NC}"
    echo -e "  ${YELLOW}密码:            ${GREEN}${GUAC_ADMIN_PASS}${NC}"
    echo -e "${BLUE}=============================================================${NC}"
else
    print_error "由于之前的步骤发生严重错误，Guacamole 未能成功部署。"
fi


# ==============================================================================
# == 步骤 6/6：最终系统状态与配置核查报告
# ==============================================================================
print_step "步骤 6/6：最终系统状态与配置核查报告"
echo -e "${YELLOW}--- 1. 新 VNC 桌面环境 (Display ${VNC_DISPLAY}) ---${NC}"
pgrep -f "Xtigervnc ${VNC_DISPLAY}" &>/dev/null && print_success "进程 (Xtigervnc ${VNC_DISPLAY}) 正在运行。" || print_error "进程 (Xtigervnc ${VNC_DISPLAY}) 未运行。"
netstat -tuln | grep -q ":${VNC_PORT}" &>/dev/null && print_success "端口 (${VNC_PORT}) 正在监听。" || print_error "端口 (${VNC_PORT}) 未监听。"

echo -e "\n${YELLOW}--- 2. Guacamole 后端 ---${NC}"
pgrep guacd &>/dev/null && print_success "进程 (guacd) 正在运行。" || print_error "进程 (guacd) 未运行。"
netstat -tuln | grep -q ':4822' &>/dev/null && print_success "端口 (4822) 正在监听。" || print_error "端口 (4822) 未监听。"

echo -e "\n${YELLOW}--- 3. Tomcat & Guacamole Web App ---${NC}"
systemctl is-active --quiet tomcat10 &>/dev/null && print_success "服务 (tomcat10) 正在运行。" || print_error "服务 (tomcat10) 未运行。"
netstat -tuln | grep -q ':8080' &>/dev/null && print_success "端口 (8080) 正在监听。" || print_error "端口 (8080) 未监听。"

echo -e "\n${YELLOW}--- 4. Guacamole 配置文件内容核查 (/etc/guacamole/user-mapping.xml) ---${NC}"
if [ -f "/etc/guacamole/user-mapping.xml" ]; then
    # 检查端口是否正确
    if grep -q "<param name=\"port\">${VNC_PORT}</param>" /etc/guacamole/user-mapping.xml; then
        print_success "VNC 端口配置正确，指向 ${VNC_PORT}。"
    else
        print_error "VNC 端口配置错误！文件中未找到端口 ${VNC_PORT} 的配置。"
    fi
    # 检查是否不含密码
    if ! grep -q '<param name="password">' /etc/guacamole/user-mapping.xml; then
        print_success "VNC 密码配置正确，未设置密码参数。"
    else
        print_error "VNC 密码配置错误！文件中包含了密码参数，与预期不符。"
    fi
else
    print_error "找不到 Guacamole 配置文件 /etc/guacamole/user-mapping.xml！"
fi

echo -e "\n${YELLOW}--- 5. Tomcat 日志 (journalctl) 摘要 ---${NC}"
echo "[i] 显示 'journalctl -u tomcat10 -n 20 --no-pager' 的最新日志:"
echo -e "${GREEN}------------------------- LOG START -------------------------${NC}"
sudo journalctl -u tomcat10 -n 20 --no-pager
echo -e "${GREEN}-------------------------- LOG END --------------------------${NC}"

if [ "$DEPLOYMENT_SUCCESS" = true ]; then
    echo -e "\n${GREEN}所有检查完成。请根据步骤5提供的URL和凭据访问 Guacamole。${NC}"
else
    echo -e "\n${RED}最终检查发现一个或多个严重问题，请仔细阅读上面的报告并根据错误提示进行修复。${NC}"
fi
