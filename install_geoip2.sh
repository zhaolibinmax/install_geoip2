#!/bin/bash
set -eo pipefail
# ==================== 通用配置与颜色定义 ====================
log_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
NGINX_CONF="/etc/nginx/nginx.conf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NGINX_CONF_BACKUP="/var/backups/nginx.conf.backup.${TIMESTAMP}"
DEFAULT_CONF_BACKUP="/var/backups/default.conf.backup.${TIMESTAMP}"
MODULE_NAME="ngx_http_geoip2_module"
MODULE_GIT_URL="https://github.com/leev/ngx_http_geoip2_module.git"
GEOIP_DB_PATH="/usr/share/GeoIP"
DEFAULT_CONF="/etc/nginx/conf.d/default.conf"
ERROR_PAGE="/403.html"
PAGE_ROOT="/var/www/html"
TEMP_CONF="/tmp/nginx.conf.tmp.$$"
DEFAULT_CONF_TMP="/tmp/default.conf.tmp.$$"
LOG_FILE="/var/log/cloudflareCDN_install_${TIMESTAMP}.log"
DEFAULT_SPEED_PORT=56789
SPEED_PORT=$DEFAULT_SPEED_PORT
BLOCKED_COUNTRIES="CN"
USE_CLOUDFLARE=false
CUSTOM_DOMAIN="localhost"
# ==================== 初始化检查 ====================
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行脚本"
    exit 1
fi
mkdir -p /var/log /var/backups
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
# ==================== 临时文件清理配置 ====================
cleanup_temp_files() {
    log_info "${BLUE}===== 开始清理/tmp临时文件 =====${NC}"
    if [ -f "$TEMP_CONF" ]; then
        rm -f "$TEMP_CONF"
        log_info "${GREEN}✅ 已删除: $TEMP_CONF${NC}"
    fi
    if [ -f "$DEFAULT_CONF_TMP" ]; then
        rm -f "$DEFAULT_CONF_TMP"
        log_info "${GREEN}✅ 已删除: $DEFAULT_CONF_TMP${NC}"
    fi
    if [ -n "$NGINX_SRC_TAR" ] && [ -f "/tmp/$NGINX_SRC_TAR" ]; then
        rm -f "/tmp/$NGINX_SRC_TAR"
        log_info "${GREEN}✅ 已删除: /tmp/$NGINX_SRC_TAR${NC}"
    fi
    if [ -n "$NGINX_SRC_DIR" ] && [ -d "/tmp/$NGINX_SRC_DIR" ]; then
        rm -rf "/tmp/$NGINX_SRC_DIR"
        log_info "${GREEN}✅ 已删除: /tmp/$NGINX_SRC_DIR${NC}"
    fi
    if [ -d "/tmp/$MODULE_NAME" ]; then
        rm -rf "/tmp/$MODULE_NAME"
        log_info "${GREEN}✅ 已删除: /tmp/$MODULE_NAME${NC}"
    fi
    if [ -n "$NGINX_SRC_DIR_ORIG" ] && [ -d "/tmp/$NGINX_SRC_DIR_ORIG" ]; then
        rm -rf "/tmp/$NGINX_SRC_DIR_ORIG"
        log_info "${GREEN}✅ 已删除残留: /tmp/$NGINX_SRC_DIR_ORIG${NC}"
    fi
    log_info "${BLUE}===== /tmp临时文件清理完成 =====${NC}"
}
trap cleanup_temp_files EXIT INT TERM
# ==================== 函数定义 (GeoIP2 相关) ====================
install_nginx_official_repo() {
    log_info "${BLUE}===== 开始通过nginx.org官方仓库安装Nginx =====${NC}"
    
    if [ "$PM" = "apt-get" ]; then
        if [ -f /etc/debian_version ] && ! grep -s "Ubuntu" /etc/os-release; then
            log_info "${YELLOW}检测到Debian系统，执行官方安装流程${NC}"
            $PM $PM_INSTALL curl gnupg2 ca-certificates lsb-release debian-archive-keyring
            log_info "${YELLOW}导入nginx官方GPG密钥...${NC}"
            curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
                | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
            local expected_fingerprint="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
            local actual_fingerprint=$(gpg --dry-run --no-keyring --import --import-options import-show \
                /usr/share/keyrings/nginx-archive-keyring.gpg | grep -oP "$expected_fingerprint" || true)
            
            if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
                log_error "${RED}GPG密钥指纹校验失败！预期：$expected_fingerprint${NC}"
                exit 1
            fi
            log_info "${GREEN}✅ GPG密钥校验通过${NC}"
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/debian `lsb_release -cs` nginx" \
                | sudo tee /etc/apt/sources.list.d/nginx.list
            echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
                | sudo tee /etc/apt/preferences.d/99nginx
        else
            log_info "${YELLOW}检测到Ubuntu系统，执行官方安装流程${NC}"
            $PM $PM_INSTALL curl gnupg2 ca-certificates lsb-release ubuntu-keyring
            log_info "${YELLOW}导入nginx官方GPG密钥...${NC}"
            curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
                | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
            local expected_fingerprint="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
            local actual_fingerprint=$(gpg --dry-run --no-keyring --import --import-options import-show \
                /usr/share/keyrings/nginx-archive-keyring.gpg | grep -oP "$expected_fingerprint" || true)
            
            if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
                log_error "${RED}GPG密钥指纹校验失败！预期：$expected_fingerprint${NC}"
                exit 1
            fi
            log_info "${GREEN}✅ GPG密钥校验通过${NC}"
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu `lsb_release -cs` nginx" \
                | sudo tee /etc/apt/sources.list.d/nginx.list
            echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
                | sudo tee /etc/apt/preferences.d/99nginx
        fi
        log_info "${YELLOW}更新apt源并安装nginx...${NC}"
        $PM $PM_UPDATE
        $PM $PM_INSTALL nginx
        
    elif [ "$PM" = "yum" ] || [ "$PM" = "dnf" ]; then
        log_info "${YELLOW}检测到CentOS/RHEL系系统，执行官方安装流程${NC}"
        $PM $PM_INSTALL yum-utils
        log_info "${YELLOW}创建nginx官方yum仓库配置...${NC}"
        cat > /etc/yum.repos.d/nginx.repo << 'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
        log_info "${YELLOW}安装nginx（稳定版）...${NC}"
        $PM $PM_INSTALL --nogpgcheck nginx
        sed -i 's/gpgcheck=0/gpgcheck=1/' /etc/yum.repos.d/nginx.repo || true
    fi
    if command -v nginx; then
        log_info "${GREEN}✅ nginx官方仓库安装成功${NC}"
    else
        log_error "${RED}❌ nginx安装失败，请检查仓库配置${NC}"
        exit 1
    fi
}
backup_nginx_config() {
    mkdir -p "$(dirname "$NGINX_CONF_BACKUP")"
    if cp "$NGINX_CONF" "$NGINX_CONF_BACKUP"; then
        log_info "${GREEN}✅ nginx.conf 备份完成: $NGINX_CONF_BACKUP${NC}"
    else
        log_error "${RED}nginx.conf备份失败，脚本退出${NC}"
        exit 1
    fi
    mkdir -p "$(dirname "$DEFAULT_CONF_BACKUP")"
    if [ -f "$DEFAULT_CONF" ]; then
        cp "$DEFAULT_CONF" "$DEFAULT_CONF_BACKUP"
        log_info "${GREEN}✅ default.conf 备份完成: $DEFAULT_CONF_BACKUP${NC}"
    else
        log_info "${YELLOW}✅ default.conf 不存在，跳过备份${NC}"
    fi
}
restore_nginx_config() {
    local restore_ok=0
    if [ -f "$NGINX_CONF_BACKUP" ]; then
        log_warn "${YELLOW}正在从备份恢复nginx.conf...${NC}"
        cp "$NGINX_CONF_BACKUP" "$NGINX_CONF" && restore_ok=1
        log_info "${GREEN}✅ 已恢复: $NGINX_CONF_BACKUP${NC}"
    fi
    if [ -f "$DEFAULT_CONF_BACKUP" ]; then
        log_warn "${YELLOW}正在从备份恢复default.conf...${NC}"
        cp "$DEFAULT_CONF_BACKUP" "$DEFAULT_CONF" && restore_ok=1
        log_info "${GREEN}✅ 已恢复: $DEFAULT_CONF_BACKUP${NC}"
    fi
    if [ $restore_ok -eq 1 ]; then
        if ! test_nginx_config; then
            log_error "${RED}恢复配置后Nginx校验失败，请手动检查备份文件${NC}"
            exit 1
        fi
    fi
}
test_nginx_config() {
    if ! nginx -t 2>&1; then
        log_error "${RED}❌ Nginx配置测试失败!${NC}"
        return 1
    fi
    return 0
}
detect_package_manager() {
    if [ -f /etc/debian_version ]; then
        PM="apt-get"
        PM_INSTALL="install -y"
        PM_UPDATE="update -o Acquire::Timeout=300 -y"
    elif [ -f /etc/redhat-release ]; then
        if grep -E "9|Stream 9" /etc/redhat-release; then
            PM="dnf"
            PM_INSTALL="install -y"
            PM_UPDATE="makecache --refresh"
            dnf config-manager --set-enabled crb -y
            dnf install epel-release -y
        else
            PM="yum"
            PM_INSTALL="install -y"
            PM_UPDATE="makecache"
            yum install epel-release -y
        fi
    else
        log_error "${RED}不支持的系统发行版（仅支持Debian/Ubuntu/CentOS/RHEL）${NC}"
        exit 1
    fi
}
validate_domain() {
    local domain=$1
    if [ "$domain" = "localhost" ] \
        || [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]] \
        || [[ "$domain" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || [[ "$domain" =~ ^([0-9a-fA-F:]+:+)+[0-9a-fA-F]+$ ]]; then
        return 0
    else
        return 1
    fi
}
detect_package_manager
USE_DEFAULT_CERT=true
SSL_ENABLED=false
# ==================== 交互配置封装函数 ====================
interactive_config() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}   LibreSpeed + GeoIP2 一体化部署     ${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
    while true; do
        read -p "$(echo -e "${YELLOW}请输入要配置的域名 [默认: localhost]${NC}\n域名：")" INPUT_DOMAIN
        if [ -z "$INPUT_DOMAIN" ]; then
            CUSTOM_DOMAIN="localhost"
            break
        fi
        if validate_domain "$INPUT_DOMAIN"; then
            CUSTOM_DOMAIN="$INPUT_DOMAIN"
            break
        else
            log_error "${RED}错误：域名格式不合法！请输入如 speed.test.com 这样的有效域名${NC}"
            echo ""
        fi
    done
    log_info "${GREEN}✅ 确认使用域名：$CUSTOM_DOMAIN${NC}"
    SKIP_CF_CERT=false
    if [ "$CUSTOM_DOMAIN" = "localhost" ]; then
        SKIP_CF_CERT=true
        USE_CLOUDFLARE=false
        USE_DEFAULT_CERT=true
        log_info "${YELLOW}⚠️ 检测到域名为localhost，自动跳过Cloudflare和SSL证书配置${NC}"
    fi
    echo ""
    while true; do
        if [ "$SKIP_CF_CERT" = true ]; then
            break
        fi
        read -p "$(echo -e "${YELLOW}是否使用了 Cloudflare CDN？(y/n) [默认: y]${NC}\n选择：")" CF_USE
        if [ -z "$CF_USE" ]; then
            USE_CLOUDFLARE=true
            break
        fi
        CF_USE_LOWER=$(echo "$CF_USE" | tr '[:upper:]' '[:lower:]')
        if [ "$CF_USE_LOWER" = "y" ] || [ "$CF_USE_LOWER" = "yes" ]; then
            USE_CLOUDFLARE=true
            break
        elif [ "$CF_USE_LOWER" = "n" ] || [ "$CF_USE_LOWER" = "no" ]; then
            USE_CLOUDFLARE=false
            break
        else
            log_error "${RED}错误：请输入 y (是) 或 n (否)！请重新输入${NC}"
            echo ""
        fi
    done
    if [ "$USE_CLOUDFLARE" = true ]; then
        log_info "${GREEN}✅ 确认使用 Cloudflare CDN，将配置真实IP还原${NC}"
    else
        log_info "${GREEN}✅ 确认未使用 Cloudflare CDN，将跳过真实IP配置${NC}"
    fi
    echo ""
    while true; do
        read -p "$(echo -e "${YELLOW}请输入 LibreSpeed 测速服务端口 [默认: $DEFAULT_SPEED_PORT]${NC}\n端口号：")" CUSTOM_PORT
        if [ -z "$CUSTOM_PORT" ]; then
            SPEED_PORT=$DEFAULT_SPEED_PORT
            break
        fi
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 1 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
            SPEED_PORT=$CUSTOM_PORT
            break
        else
            log_error "${RED}错误：端口必须是1-65535之间的纯数字！请重新输入${NC}"
            echo ""
        fi
    done
    log_info "${GREEN}✅ 确认 LibreSpeed 端口：$SPEED_PORT${NC}"
    echo ""
    echo -e "${YELLOW}📌 国家代码参考：CN(中国)、US(美国)、JP(日本)、SG(新加坡)、DE(德国)、GB(英国)、KR(韩国)、HK(香港)、TW(台湾)${NC}"
    read -p "$(echo -e "${YELLOW}请输入要拦截的国家代码 [逗号分隔，默认: CN]${NC}\n国家代码：")" INPUT_BLOCK
    echo ""
    BLOCKED_COUNTRIES="CN"
    if [ -n "$INPUT_BLOCK" ]; then
        local processed_input=$(echo "$INPUT_BLOCK" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
        if [ -n "$processed_input" ]; then
            BLOCKED_COUNTRIES="$processed_input"
            log_info "${GREEN}✅ 已设置拦截国家：$BLOCKED_COUNTRIES${NC}"
        else
            log_warn "${YELLOW}⚠️ 输入的国家代码无效，使用默认值：CN${NC}"
        fi
    else
        log_info "${GREEN}✅ 使用默认拦截国家：CN${NC}"
    fi
    echo ""
    while true; do
        if [ "$SKIP_CF_CERT" = true ]; then
            break
        fi
        read -p "$(echo -e "${YELLOW}是否使用默认Let's Encrypt证书路径？(y/n) [默认: y]${NC}\n选择：")" USE_DEFAULT_CERT
        if [ -z "$USE_DEFAULT_CERT" ]; then
            USE_DEFAULT_CERT=true
            break
        fi
        USE_DEFAULT_CERT_LOWER=$(echo "$USE_DEFAULT_CERT" | tr '[:upper:]' '[:lower:]')
        if [ "$USE_DEFAULT_CERT_LOWER" = "y" ] || [ "$USE_DEFAULT_CERT_LOWER" = "yes" ]; then
            USE_DEFAULT_CERT=true
            break
        elif [ "$USE_DEFAULT_CERT_LOWER" = "n" ] || [ "$USE_DEFAULT_CERT_LOWER" = "no" ]; then
            USE_DEFAULT_CERT=false
            break
        else
            log_error "${RED}错误：请输入 y (是) 或 n (否)！请重新输入${NC}"
            echo ""
        fi
    done
    CUSTOM_CERT=""
    CUSTOM_KEY=""
    if [ "$USE_DEFAULT_CERT" = false ]; then
while true; do
    read -p "$(echo -e "${YELLOW}请输入SSL证书文件完整路径：${NC}\n证书路径：")" CUSTOM_CERT
    if [ -n "$CUSTOM_CERT" ] && [ -f "$CUSTOM_CERT" ]; then
        break
    else
        log_error "${RED}错误：证书路径不能为空且文件必须存在！请重新输入${NC}"
        echo ""
    fi
done
while true; do
    read -p "$(echo -e "${YELLOW}请输入SSL私钥文件完整路径：${NC}\n私钥路径：")" CUSTOM_KEY
    if [ -n "$CUSTOM_KEY" ] && [ -f "$CUSTOM_KEY" ]; then
        break
    else
        log_error "${RED}错误：私钥路径不能为空且文件必须存在！请重新输入${NC}"
        echo ""
    fi
done
        log_info "${GREEN}✅ 确认自定义证书路径：$CUSTOM_CERT${NC}"
        log_info "${GREEN}✅ 确认自定义私钥路径：$CUSTOM_KEY${NC}"
    else
        log_info "${GREEN}✅ 确认使用默认Let's Encrypt证书路径${NC}"
    fi
    log_info "${GREEN}✅ 确认拦截国家/地区代码：$BLOCKED_COUNTRIES${NC}"
    sleep 1
    echo ""
}
# ==================== 步骤1: 交互配置 + 确认环节 ====================
while true; do
    interactive_config
clear
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}                    配置确认               ${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "${YELLOW}以下是您填写的配置信息，请确认：${NC}"
echo -e "   🌐  访问域名：${GREEN}$CUSTOM_DOMAIN${NC}"
echo -e "   ☁️  Cloudflare CDN：${GREEN}$([ "$USE_CLOUDFLARE" = true ] && echo "是" || echo "否")${NC}"
echo -e "   🚀  测速端口：${GREEN}$SPEED_PORT${NC}"
echo -e "   🚫  拦截国家：${GREEN}$BLOCKED_COUNTRIES${NC}"
if [ "$CUSTOM_DOMAIN" != "localhost" ]; then
    echo -e "   🔐  使用默认Let's Encrypt证书：${GREEN}$([ "$USE_DEFAULT_CERT" = true ] && echo "是" || echo "否")${NC}"
    if [ "$USE_DEFAULT_CERT" = false ]; then
        echo -e "   🔐  SSL证书路径：${GREEN}$CUSTOM_CERT${NC}"
        echo -e "   🔑  SSL私钥路径：${GREEN}$CUSTOM_KEY${NC}"
    fi
fi
echo ""
while true; do
    read -p "$(echo -e "${YELLOW}以上配置是否正确？(y/n) [默认: y]${NC}\n选择：")" CONFIRM
    if [ -z "$CONFIRM" ]; then
        echo -e "${GREEN}✅ 已确认配置...${NC}"
        sleep 1
        break 2
    fi
    CONFIRM_LOWER=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
    if [ "$CONFIRM_LOWER" = "y" ] || [ "$CONFIRM_LOWER" = "yes" ]; then
        echo -e "${GREEN}✅ 已确认配置...${NC}"
        sleep 1
        break 2
    elif [ "$CONFIRM_LOWER" = "n" ] || [ "$CONFIRM_LOWER" = "no" ]; then
        log_warn "${YELLOW}🔄 您选择重新配置，请重新填写信息...${NC}"
        sleep 1
        break
    else
        log_error "${RED}错误：请输入 y (是) 或 n (否)！请重新输入${NC}"
        echo ""
    fi
done
done
# ==================== 步骤2: 安装 LibreSpeed (Docker) ====================
log_info "${BLUE}===== 开始部署 LibreSpeed 测速服务 =====${NC}"
echo -e "${YELLOW}[1/3] 正在安装 Docker 环境...${NC}"
if command -v docker; then
    log_info "${GREEN}Docker 已安装，跳过安装步骤${NC}"
else
    curl -fL --connect-timeout 10 --max-time 60 --retry 3 https://get.docker.com | bash
    if [ $? -ne 0 ]; then
        log_error "${RED}Docker 安装失败，请检查网络！${NC}"
        exit 1
    fi
fi
echo -e "${YELLOW}[2/3] 启动 Docker 并设置开机自启...${NC}"
if command -v systemctl; then
    systemctl enable docker
    systemctl start docker
else
    if [ -f /etc/redhat-release ]; then
        chkconfig docker on
    else
        update-rc.d -f docker defaults
    fi
    service docker start
fi
if [ $? -ne 0 ]; then
    log_error "${RED}Docker 启动失败！${NC}"
    exit 1
fi
echo -e "${YELLOW}[3/3] 部署 LibreSpeed 容器...${NC}"
if docker ps -a --format "{{.Names}}" | grep "^librespeed$"; then
    log_info "${GREEN}✅ LibreSpeed 容器已存在，跳过删除与重装${NC}"
    if ! docker ps --format "{{.Names}}" | grep "^librespeed$"; then
        docker start librespeed
        log_info "${GREEN}✅ 已启动原有 LibreSpeed 容器${NC}"
    fi
else
    log_info "${YELLOW}🔒 安全提示：LibreSpeed 将绑定到 127.0.0.1，仅允许本地 Nginx 反向代理访问${NC}"
    docker run -d \
      --restart always \
      --name librespeed \
      -p 127.0.0.1:$SPEED_PORT:80 \
      adolfintel/speedtest
    if [ $? -ne 0 ]; then
        log_error "${RED}LibreSpeed 容器启动失败！${NC}"
        exit 1
    fi
    log_info "${GREEN}✅ LibreSpeed 容器新建完成${NC}"
fi
log_info "${GREEN}✅ LibreSpeed 部署成功（仅本地可访问，通过 Nginx 反向代理对外提供服务）${NC}"
echo ""
# ==================== 步骤3: 部署 GeoIP2 + Cloudflare 真实IP ====================
log_info "${BLUE}===== 开始部署 GeoIP2 + Cloudflare 真实IP =====${NC}"
log_info "${YELLOW}1. 检测Nginx版本...${NC}"
if ! command -v nginx; then
    log_warn "${YELLOW}未安装Nginx，正在通过nginx.org官方仓库安装...${NC}"
    install_nginx_official_repo
fi
NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -z "$NGINX_VERSION" ]; then
    log_error "${RED}无法识别Nginx版本${NC}"
    exit 1
fi
NGINX_MODULES=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "")
if [ -z "$NGINX_MODULES" ] || [ ! -d "$NGINX_MODULES" ]; then
    if [ -f /etc/redhat-release ] && [ $(uname -m) = "x86_64" ]; then
        NGINX_MODULES="/usr/lib64/nginx/modules"
    else
        NGINX_MODULES="/usr/lib/nginx/modules"
    fi
    mkdir -p "$NGINX_MODULES" && chmod 755 "$NGINX_MODULES"
fi
log_info "${GREEN}✅ Nginx版本: $NGINX_VERSION, 模块路径: $NGINX_MODULES${NC}"
log_info "${YELLOW}2. 安装系统依赖...${NC}"
$PM $PM_UPDATE
if [ "$PM" = "apt-get" ]; then
    $PM $PM_INSTALL build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git curl libssl-dev
else
    $PM $PM_INSTALL gcc gcc-c++ make pcre-devel zlib-devel libmaxminddb-devel git curl openssl-devel
    if [ "$PM" = "yum" ]; then
        $PM $PM_INSTALL epel-release -y
    fi
fi
log_info "${GREEN}✅ 依赖安装完成${NC}"
backup_nginx_config
if [ -f "$DEFAULT_CONF" ]; then
    rm -f "$DEFAULT_CONF"
    log_info "${YELLOW}🗑️ 已删除旧的 default.conf 配置文件${NC}"
fi
log_info "${YELLOW}3. 准备Nginx源码...${NC}"
cd /tmp || { log_error "${RED}无法进入/tmp目录${NC}"; exit 1; }
NGINX_SRC_TAR="nginx-$NGINX_VERSION.tar.gz_$$"
NGINX_SRC_DIR_ORIG="nginx-$NGINX_VERSION"
NGINX_SRC_DIR="nginx-$NGINX_VERSION_$$"
if [ ! -f "$NGINX_SRC_TAR" ] || [ ! -d "$NGINX_SRC_DIR" ] || [ ! -f "$NGINX_SRC_DIR/auto/options" ]; then
    rm -rf "$NGINX_SRC_TAR" "$NGINX_SRC_DIR" "$NGINX_SRC_DIR_ORIG"
    log_info "${YELLOW}正在下载 Nginx $NGINX_VERSION 源码...${NC}"
    if ! curl -L --connect-timeout 20 --max-time 30 --retry 3 \
        "https://nginx.org/download/${NGINX_SRC_TAR%_$$}" -o "$NGINX_SRC_TAR"; then
        log_error "${RED}❌ Nginx源码下载失败！${NC}"
        rm -rf "$NGINX_SRC_TAR"
        exit 1
    fi
    log_info "${YELLOW}正在解压 Nginx 源码...${NC}"
    if ! tar zxf "$NGINX_SRC_TAR"; then
        log_error "${RED}❌ Nginx源码解压失败（压缩包损坏/权限不足）！${NC}"
        rm -rf "$NGINX_SRC_TAR" "$NGINX_SRC_DIR_ORIG"
        exit 1
    fi
    if ! mv "$NGINX_SRC_DIR_ORIG" "$NGINX_SRC_DIR"; then
        log_error "${RED}❌ 无法重命名Nginx源码目录！${NC}"
        rm -rf "$NGINX_SRC_TAR" "$NGINX_SRC_DIR_ORIG"
        exit 1
    fi
    if [ ! -f "$NGINX_SRC_DIR/auto/options" ]; then
        log_error "${RED}❌ Nginx源码解压后缺失核心文件auto/options，下载的包损坏！${NC}"
        rm -rf "$NGINX_SRC_TAR" "$NGINX_SRC_DIR"
        exit 1
    fi
fi
log_info "${GREEN}✅ Nginx源码准备完成${NC}"
log_info "${YELLOW}4. 下载GeoIP2模块...${NC}"
if [ ! -d "/tmp/$MODULE_NAME" ]; then
    git clone "$MODULE_GIT_URL" /tmp/$MODULE_NAME
fi
log_info "${GREEN}✅ GeoIP2模块下载完成${NC}"
log_info "${YELLOW}5. 编译GeoIP2动态模块...${NC}"
cd "$NGINX_SRC_DIR"
./configure --with-compat --add-dynamic-module=/tmp/$MODULE_NAME || {
    log_error "${RED}编译配置失败${NC}"
    restore_nginx_config
    exit 1
}
make modules || {
    log_error "${RED}编译失败${NC}"
    restore_nginx_config
    exit 1
}
if [ ! -f "objs/${MODULE_NAME}.so" ]; then
    log_error "${RED}❌ 模块文件未生成，编译失败${NC}"
    restore_nginx_config
    exit 1
fi
log_info "${GREEN}✅ 编译完成${NC}"
log_info "${YELLOW}6. 安装模块到Nginx...${NC}"
cp objs/${MODULE_NAME}.so "$NGINX_MODULES/"
chmod 644 "$NGINX_MODULES/${MODULE_NAME}.so"
log_info "${GREEN}✅ 模块安装完成${NC}"
log_info "${YELLOW}7. 加载GeoIP2模块...${NC}"
MODULE_LOAD="load_module $NGINX_MODULES/${MODULE_NAME}.so;"
sed -i "/^[[:space:]]*load_module[[:space:]]\+.*\/${MODULE_NAME}\.so[[:space:]]*;/d" "$NGINX_CONF"
sed -i "1i $MODULE_LOAD" "$NGINX_CONF"
log_info "${GREEN}✅ 已加载GeoIP2模块（已自动清理旧配置）${NC}"
log_info "${YELLOW}测试Nginx配置（加载模块后）...${NC}"
if ! test_nginx_config; then
    restore_nginx_config
    exit 1
fi
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "${YELLOW}8. 获取 Cloudflare IP 段...${NC}"
    CF_IPV4=$(curl --fail --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v4 || true)
    CF_IPV6=$(curl --fail --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v6 || true)
    if [[ -n "$CF_IPV4" && -n "$CF_IPV6" ]]; then
        log_info "${GREEN}✅ 成功获取最新Cloudflare IP段${NC}"
        CF_IPS="$CF_IPV4"$'\n'"$CF_IPV6"
    else
        log_warn "${YELLOW}⚠️ 网络获取失败，使用内置最新官方IP段${NC}"
        CF_IPS="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
    fi
else
    log_info "${YELLOW}8. 未使用Cloudflare CDN，跳过获取Cloudflare IP段${NC}"
fi
log_info "${YELLOW}9. 初始化站点配置文件...${NC}"
mkdir -p /etc/nginx/conf.d
if [ ! -f "$DEFAULT_CONF" ]; then
    touch "$DEFAULT_CONF"
    log_info "${GREEN}✅ 已创建空配置文件: $DEFAULT_CONF${NC}"
fi
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "${YELLOW}10. 配置Cloudflare真实IP还原...${NC}"
    if ! grep "# Cloudflare RealIP Configuration" "$DEFAULT_CONF"; then
        cat > "$TEMP_CONF" << EOL
# Cloudflare RealIP Configuration
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
EOL
        while IFS= read -r ip; do
            [ -n "$ip" ] && echo "set_real_ip_from $ip;" >> "$TEMP_CONF"
        done <<< "$CF_IPS"
        echo "" >> "$TEMP_CONF"
        cat "$TEMP_CONF" "$DEFAULT_CONF" > "$DEFAULT_CONF_TMP"
        mv "$DEFAULT_CONF_TMP" "$DEFAULT_CONF"
        
        log_info "${GREEN}✅ Cloudflare真实IP配置完成${NC}"
    else
        log_info "${GREEN}✅ Cloudflare真实IP已配置，跳过${NC}"
    fi
    log_info "${YELLOW}测试Nginx配置（Cloudflare IP）...${NC}"
    if ! test_nginx_config; then
        restore_nginx_config
        exit 1
    fi
else
    log_info "${YELLOW}10. 未使用Cloudflare CDN，跳过配置Cloudflare真实IP还原${NC}"
fi
log_info "${YELLOW}11. 检查GeoIP数据库...${NC}"
DB_FILE="$GEOIP_DB_PATH/GeoLite2-Country.mmdb"
if [ -f "$DB_FILE" ]; then
    log_info "${YELLOW}检测到已存在GeoIP数据库，正在校验文件有效性...${NC}"
    if [ $(stat -c%s "$DB_FILE" || echo 0) -ge 1048576 ]; then
        log_info "${GREEN}✅ 现有数据库文件校验通过，跳过下载${NC}"
    else
        log_warn "${YELLOW}⚠️ 现有数据库文件损坏/过小，正在删除并重新下载...${NC}"
        rm -f "$DB_FILE"
    fi
fi
if [ ! -f "$DB_FILE" ]; then
    log_info "${YELLOW}正在自动下载GeoIP2数据库...${NC}"
    mkdir -p "$GEOIP_DB_PATH"
    GEOIP_DB_URLS=(
        "https://github.com/zhaolibinmax/install_geoip2/raw/refs/heads/main/GeoLite2-Country.mmdb"
        "https://cdn.jsdelivr.net/gh/P3TERX/GeoLite2-CN@release/GeoLite2-Country.mmdb"
        "https://raw.githubusercontent.com/P3TERX/GeoLite2-CN/release/GeoLite2-Country.mmdb"
    )
    download_success=0
    for url in "${GEOIP_DB_URLS[@]}"; do
        log_info "${YELLOW}尝试从源 $url 下载...${NC}"
        curl -L --connect-timeout 100 --max-time 300 "$url" -o "$DB_FILE"
        if [ -f "$DB_FILE" ] && [ $(stat -c%s "$DB_FILE" || echo 0) -ge 1048576 ]; then
            download_success=1
            log_info "${GREEN}✅ 数据库下载并校验成功${NC}"
            break
        else
            log_warn "${YELLOW}⚠️ 当前源下载/校验失败，删除损坏文件，尝试下一个源...${NC}"
            rm -f "$DB_FILE"
        fi
    done
    if [ $download_success -ne 1 ]; then
        log_error "${RED}❌ 所有下载源均失败，请手动下载至 $GEOIP_DB_PATH${NC}"
        restore_nginx_config
        exit 1
    fi
fi
log_info "${GREEN}✅ GeoIP数据库检查完成${NC}"
log_info "${YELLOW}12. 配置国家拦截规则...${NC}"
sed -i '/geoip2.*GeoLite2-Country.mmdb/,/}/d' "$DEFAULT_CONF"
sed -i '/map.*geoip2_country_code/,/}/d' "$DEFAULT_CONF"
cat > "$TEMP_CONF" << EOL
# GeoIP2 Country Configuration
geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb {
    auto_reload 5m;
    \$geoip2_country_code country iso_code;
}
map \$geoip2_country_code \$allowed_country {
    default yes;
EOL
(
    IFS=','
    for c in $BLOCKED_COUNTRIES; do
        [ -z "$c" ] && continue
        echo "    $c no;" >> "$TEMP_CONF"
    done
)
echo "}" >> "$TEMP_CONF"
echo "" >> "$TEMP_CONF"
cat "$TEMP_CONF" "$DEFAULT_CONF" > "$DEFAULT_CONF_TMP"
mv "$DEFAULT_CONF_TMP" "$DEFAULT_CONF"
rm -f "$TEMP_CONF"
log_info "${GREEN}✅ GeoIP2国家拦截配置成功${NC}"
log_info "${YELLOW}测试Nginx配置（GeoIP2拦截）...${NC}"
if ! test_nginx_config; then
    restore_nginx_config
    exit 1
fi
log_info "${YELLOW}13. 检查并完善站点Server配置...${NC}"
if ! grep "server {" "$DEFAULT_CONF"; then
    SSL_CONFIG=""
    QUIC_CONFIG=""
    SSL_ENABLED=false
    if [ "$CUSTOM_DOMAIN" != "localhost" ]; then
if [ -n "$CUSTOM_CERT" ] && [ -n "$CUSTOM_KEY" ]; then
    CERT_FILE="$CUSTOM_CERT"
    KEY_FILE="$CUSTOM_KEY"
else
    CERT_FILE="/etc/letsencrypt/live/$CUSTOM_DOMAIN/fullchain.pem"
    KEY_FILE="/etc/letsencrypt/live/$CUSTOM_DOMAIN/privkey.pem"
fi
        if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
            SSL_ENABLED=true
            SSL_CONFIG="    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
            if nginx -V 2>&1 | grep "http_v3_module"; then
                log_info "${GREEN}✅ 检测到 Nginx QUIC 模块，启用 HTTP3 配置${NC}"
                QUIC_CONFIG="    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    http3 on;
    quic_gso on;"
            else
                log_info "${YELLOW}✅ Nginx 无 QUIC 模块，自动跳过 HTTP3 配置${NC}"
                QUIC_CONFIG=""
            fi
            log_info "${GREEN}✅ 找到 SSL 证书，启用 SSL/HTTPS 完整配置${NC}"
        else
    log_warn "${YELLOW}⚠️ 未找到 SSL 证书文件（$CERT_FILE 或 $KEY_FILE）${NC}"
    log_info "${YELLOW}建议执行以下命令安装 Let's Encrypt 证书：${NC}"
    log_info "${YELLOW}certbot certonly --nginx -d $CUSTOM_DOMAIN${NC}"
    log_warn "${YELLOW}⚠️ 自动跳过 SSL/HTTPS 配置${NC}"
    SSL_CONFIG=""
    QUIC_CONFIG=""
    SSL_ENABLED=false
fi
    else
        log_warn "${YELLOW}⚠️ 域名为 localhost，跳过 SSL/QUIC 配置（无合法证书）${NC}"
        SSL_CONFIG=""
        QUIC_CONFIG=""
        SSL_ENABLED=false
    fi
    if [ "$SSL_ENABLED" = true ]; then
        cat >> "$DEFAULT_CONF" << SITEEOF
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets on;
ssl_buffer_size 4k;
ssl_protocols TLSv1.3;
ssl_ciphers TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20_POLY1305;
ssl_ecdh_curve auto;
tcp_nopush on;
tcp_nodelay on;
resolver 1.1.1.1 8.8.8.8 [2606:4700:4700::1111] valid=300s;
resolver_timeout 5s;
fastcgi_intercept_errors on;
error_page 403 /403.html;
server {
    listen 80;
    listen [::]:80;
    server_name $CUSTOM_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
$QUIC_CONFIG
    server_name $CUSTOM_DOMAIN;
    http2 on;
$SSL_CONFIG
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    location = /403.html {
        root /var/www/html;
        internal;
        ssi on;
        }
    location / {
        proxy_pass http://127.0.0.1:$SPEED_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        if (\$allowed_country = no) {
        return 403;
        }
    }
    location /download/ {
        alias /download/;
        try_files \$uri =404;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        location ~* \.(php|jsp|asp|sh|cgi)$ {
        deny all;
        }
    }
}
SITEEOF
        log_info "${GREEN}✅ default.conf配置文件创建完成（已启用SSL，适配域名 $CUSTOM_DOMAIN 和端口 $SPEED_PORT）${NC}"
    else
        cat >> "$DEFAULT_CONF" << SITEEOF
tcp_nopush on;
tcp_nodelay on;
resolver 1.1.1.1 8.8.8.8 [2606:4700:4700::1111] valid=300s;
resolver_timeout 5s;
fastcgi_intercept_errors on;
error_page 403 /403.html;
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $CUSTOM_DOMAIN;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    location = /403.html {
        root /var/www/html;
        internal;
        ssi on;
        }
    location / {
        proxy_pass http://127.0.0.1:$SPEED_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        if (\$allowed_country = no) {
        return 403;
        }
    }
    location /download/ {
        alias /download/;
        try_files \$uri =404;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        location ~* \.(php|jsp|asp|sh|cgi)$ {
        deny all;
        }
    }
}
SITEEOF
        log_info "${GREEN}✅ default.conf配置文件创建完成（未启用SSL，仅80端口，适配域名 $CUSTOM_DOMAIN 和端口 $SPEED_PORT）${NC}"
    fi
else
    log_info "${YELLOW}✅ default.conf配置文件已存在，正在更新域名与端口...${NC}"
    sed -i "s/server_name _;/server_name $CUSTOM_DOMAIN;/g" "$DEFAULT_CONF"
    sed -i "s/server_name localhost;/server_name $CUSTOM_DOMAIN;/g" "$DEFAULT_CONF"
    sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:$SPEED_PORT;|g" "$DEFAULT_CONF"
    log_info "${GREEN}✅ 配置更新完成，请手动检查确认${NC}"
fi
log_info "${YELLOW}测试Nginx配置（Server块）...${NC}"
if ! test_nginx_config; then
    restore_nginx_config
    exit 1
fi
log_info "${YELLOW}14. 创建403错误页面...${NC}"
mkdir -p "$PAGE_ROOT"
if [ ! -f "$PAGE_ROOT/403.html" ]; then
    cat > "$PAGE_ROOT/403.html" << 'PAGEEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>403 - Access Forbidden</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; font-family: 'Segoe UI', Roboto, Arial, sans-serif; }
        body { min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #f8f9fa; color: #333; padding: 20px; }
        .container { max-width: 600px; width: 100%; background: #fff; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); padding: 40px; text-align: center; }
        .error-code { font-size: 80px; font-weight: 700; color: #dc3545; margin-bottom: 20px; }
        .error-title { font-size: 24px; font-weight: 600; margin-bottom: 15px; color: #212529; }
        .error-desc { font-size: 16px; color: #6c757d; line-height: 1.6; margin-bottom: 30px; }
        .info-card { background: #f1f3f5; border-radius: 8px; padding: 20px; text-align: left; margin-top: 20px; font-size: 14px; }
        .info-card p { margin: 8px 0; color: #495057; }
        .info-card span { font-weight: 600; color: #212529; }
        @media (max-width: 480px) {
            .container { padding: 30px 20px; }
            .error-code { font-size: 60px; }
            .error-title { font-size: 20px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="error-code">403</div>
        <h1 class="error-title">Access Forbidden</h1>
        <p class="error-desc">Your region or IP address is not authorized to access this resource.</p>
        <div class="info-card">
            <p><span>Your IP:</span> <!--# echo var="remote_addr" --></p>
            <p><span>Real IP (CF):</span> <!--# echo var="http_cf_connecting_ip" --></p>
            <p><span>Request URL:</span> <!--# echo var="scheme" -->://<!--# echo var="host" --><!--# echo var="request_uri" --></p>
            <p><span>Access Time:</span> <!--# echo var="time_local" --></p>
        </div>
    </div>
</body>
</html>
PAGEEOF
chmod 644 "$PAGE_ROOT/403.html"
    log_info "${GREEN}✅ 403错误页面创建完成${NC}"
else
    log_info "${GREEN}✅ 403错误页面已存在${NC}"
fi
log_info "${YELLOW}15. 最终Nginx配置测试...${NC}"
if ! test_nginx_config; then
    log_error "${RED}Nginx配置测试失败，正在恢复...${NC}"
    restore_nginx_config
    exit 1
fi
log_info "${YELLOW}16. 重启Nginx...${NC}"
if ! systemctl restart nginx; then
    log_warn "${YELLOW}systemctl重启失败，尝试service命令...${NC}"
    if ! service nginx restart; then
        log_error "${RED}❌ Nginx重启失败${NC}"
        restore_nginx_config
        exit 1
    fi
fi
if systemctl is-active nginx || service nginx status | grep "running"; then
    log_info "${GREEN}✅ Nginx已成功重启${NC}"
else
    log_error "${RED}❌ Nginx未成功启动${NC}"
    restore_nginx_config
    exit 1
fi
# ==================== 完成 ====================
log_info "${BLUE}LibreSpeed 容器管理命令：${NC}"
log_info "${BLUE}  查看状态：docker ps | grep librespeed${NC}"
log_info "${BLUE}  停止服务：docker stop librespeed${NC}"
log_info "${BLUE}  启动服务：docker start librespeed${NC}"
log_info "${BLUE}  删除服务：docker rm -f librespeed${NC}"
echo -e "${BLUE}================================================${NC}"
echo -e "${GREEN}              部署完成！🎉${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "${GREEN}📋 部署信息汇总：${NC}"
echo -e "   ${BLUE}🌐  访问地址：${NC}$([ "$SSL_ENABLED" = true ] && echo "https://$CUSTOM_DOMAIN" || echo "http://$CUSTOM_DOMAIN:$SPEED_PORT")"
echo -e "   ${BLUE}🚫  拦截国家：${NC}$BLOCKED_COUNTRIES"
echo -e "   ${BLUE}☁️  Cloudflare CDN：${NC}$([ "$USE_CLOUDFLARE" = true ] && echo "已启用" || echo "未启用")"
echo -e "   ${BLUE}🔒  SSL/HTTPS：${NC}$([ "$SSL_ENABLED" = true ] && echo "已启用" || echo "未启用")"
echo -e "   ${BLUE}📄  日志文件：${NC}$LOG_FILE"
echo -e "   ${BLUE}🔧  Nginx配置：${NC}$DEFAULT_CONF"
echo -e "   ${BLUE}💾  备份位置：${NC}$NGINX_CONF_BACKUP | $DEFAULT_CONF_BACKUP"
echo ""
echo -e "${YELLOW}⚠️  注意事项：${NC}"
echo -e "   1. 若需修改拦截国家，请编辑 $DEFAULT_CONF 中的 GeoIP2 配置段"
echo -e "   2. 若SSL证书过期，请重新申请Let's Encrypt证书：certbot renew"
echo -e "   3. 403错误页面路径："$PAGE_ROOT/403.html"（可自定义修改）"
echo ""
log_info "${BLUE}===== 所有操作完成，脚本执行结束 =====${NC}"
