#!/bin/bash
set -eo pipefail
# ==================== 通用配置与颜色定义 ====================
# 日志/颜色
log_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
# GeoIP2 核心配置
NGINX_CONF="/etc/nginx/nginx.conf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NGINX_CONF_BACKUP="/var/backups/nginx.conf.backup.${TIMESTAMP}"
# 备份DEFAULT_CONF
DEFAULT_CONF_BACKUP="/var/backups/default.conf.backup.${TIMESTAMP}"
MODULE_NAME="ngx_http_geoip2_module"
MODULE_GIT_URL="https://github.com/leev/ngx_http_geoip2_module.git"
GEOIP_DB_PATH="/usr/share/GeoIP"
DEFAULT_CONF="/etc/nginx/conf.d/default.conf"
ERROR_PAGE="/403.html"
PAGE_ROOT="/var/www/html"
TEMP_CONF="/tmp/nginx.conf.tmp.$$"
LOG_FILE="/var/log/cloudflareCDN_install_${TIMESTAMP}.log"
# LibreSpeed 默认配置
DEFAULT_SPEED_PORT=56789
SPEED_PORT=$DEFAULT_SPEED_PORT
# 拦截国家代码全局变量
BLOCKED_COUNTRIES="CN"
# Cloudflare CDN 使用标记
USE_CLOUDFLARE=false
# 自定义域名全局变量默认值localhost
CUSTOM_DOMAIN="localhost"
# ==================== 初始化检查 ====================
# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行脚本"
    exit 1
fi
# 初始化日志
trap '
    # 删除当前进程的临时文件（TEMP_CONF含$$）
    [ -n "$TEMP_CONF" ] && rm -f "$TEMP_CONF"
    rm -f "${DEFAULT_CONF}.new"
    # 仅删除当前脚本生成的Nginx源码/模块（加前缀）
    [ -n "$NGINX_VERSION" ] && rm -rf "/tmp/nginx-${NGINX_VERSION}_$$" "/tmp/$MODULE_NAME"
    rm -f "/tmp/nginx-*.tar.gz_$$"
    log_info "✅ 脚本退出，已清理临时文件";
' EXIT INT TERM
mkdir -p /var/log /var/backups
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
# 日志重定向
exec > >(tee -a "$LOG_FILE") 2>&1
# ==================== 函数定义 (GeoIP2 相关) ====================
# 官方仓库安装Nginx
install_nginx_official_repo() {
    log_info "===== 开始通过nginx.org官方仓库安装Nginx ====="
    
    if [ "$PM" = "apt-get" ]; then
        # ------------------------------ Debian/Ubuntu 系 ------------------------------
        if [ -f /etc/debian_version ] && ! grep -s "Ubuntu" /etc/os-release; then
            # ========== Debian 官方安装步骤 ==========
            log_info "检测到Debian系统，执行官方安装流程"
            
            # 1. 安装前置依赖
            $PM $PM_INSTALL curl gnupg2 ca-certificates lsb-release debian-archive-keyring
            
            # 2. 导入并校验官方GPG密钥
            log_info "导入nginx官方GPG密钥..."
            curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
                | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
            
            # 校验密钥指纹（官方要求）
            local expected_fingerprint="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
            local actual_fingerprint=$(gpg --dry-run --no-keyring --import --import-options import-show \
                /usr/share/keyrings/nginx-archive-keyring.gpg | grep -oP "$expected_fingerprint" || true)
            
            if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
                log_error "GPG密钥指纹校验失败！预期：$expected_fingerprint"
                exit 1
            fi
            log_info "✅ GPG密钥校验通过"
            
            # 3. 配置稳定版apt仓库
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/debian `lsb_release -cs` nginx" \
                | sudo tee /etc/apt/sources.list.d/nginx.list
            
            # 4. 设置仓库优先级（优先使用nginx官方包）
            echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
                | sudo tee /etc/apt/preferences.d/99nginx
            
        else
            # ========== Ubuntu 官方安装步骤 ==========
            log_info "检测到Ubuntu系统，执行官方安装流程"
            
            # 1. 安装前置依赖
            $PM $PM_INSTALL curl gnupg2 ca-certificates lsb-release ubuntu-keyring
            
            # 2. 导入并校验官方GPG密钥
            log_info "导入nginx官方GPG密钥..."
            curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
                | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
            
            # 校验密钥指纹（官方要求）
            local expected_fingerprint="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
            local actual_fingerprint=$(gpg --dry-run --no-keyring --import --import-options import-show \
                /usr/share/keyrings/nginx-archive-keyring.gpg | grep -oP "$expected_fingerprint" || true)
            
            if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
                log_error "GPG密钥指纹校验失败！预期：$expected_fingerprint"
                exit 1
            fi
            log_info "✅ GPG密钥校验通过"
            
            # 3. 配置稳定版apt仓库
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu `lsb_release -cs` nginx" \
                | sudo tee /etc/apt/sources.list.d/nginx.list
            
            # 4. 设置仓库优先级（优先使用nginx官方包）
            echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
                | sudo tee /etc/apt/preferences.d/99nginx
        fi
        
        # 5. 更新源并安装nginx
        log_info "更新apt源并安装nginx..."
        $PM $PM_UPDATE
        $PM $PM_INSTALL nginx
        
    elif [ "$PM" = "yum" ] || [ "$PM" = "dnf" ]; then
        # ------------------------------ CentOS/RHEL 系 ------------------------------
        log_info "检测到CentOS/RHEL系系统，执行官方安装流程"
        
        # 1. 安装前置依赖
        $PM $PM_INSTALL yum-utils
        
        # 2. 创建官方yum仓库配置文件
        log_info "创建nginx官方yum仓库配置..."
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
        
        # 3. 安装nginx（默认稳定版，自动接受GPG密钥）
        log_info "安装nginx（稳定版）..."
        # 临时禁用gpgcheck的交互式提示，自动导入官方密钥
        $PM $PM_INSTALL --nogpgcheck nginx
        # 重新启用gpgcheck并验证安装
        sed -i 's/gpgcheck=0/gpgcheck=1/' /etc/yum.repos.d/nginx.repo || true
    fi
    
    # 验证安装结果
    if command -v nginx; then
        log_info "✅ nginx官方仓库安装成功"
    else
        log_error "❌ nginx安装失败，请检查仓库配置"
        exit 1
    fi
}
backup_nginx_config() {
    mkdir -p "$(dirname "$NGINX_CONF_BACKUP")"
    if cp "$NGINX_CONF" "$NGINX_CONF_BACKUP"; then
        log_info "✅ nginx.conf 备份完成: $NGINX_CONF_BACKUP"
    else
        log_error "nginx.conf备份失败，脚本退出"
        exit 1
    fi
    # 备份DEFAULT_CONF
    mkdir -p "$(dirname "$DEFAULT_CONF_BACKUP")"
    if [ -f "$DEFAULT_CONF" ]; then
        cp "$DEFAULT_CONF" "$DEFAULT_CONF_BACKUP"
        log_info "✅ default.conf 备份完成: $DEFAULT_CONF_BACKUP"
    else
        log_info "✅ default.conf 不存在，跳过备份"
    fi
}
restore_nginx_config() {
    local restore_ok=0
    if [ -f "$NGINX_CONF_BACKUP" ]; then
        log_warn "正在从备份恢复nginx.conf..."
        cp "$NGINX_CONF_BACKUP" "$NGINX_CONF" && restore_ok=1
        log_info "✅ 已恢复: $NGINX_CONF_BACKUP"
    fi
    if [ -f "$DEFAULT_CONF_BACKUP" ]; then
        log_warn "正在从备份恢复default.conf..."
        cp "$DEFAULT_CONF_BACKUP" "$DEFAULT_CONF" && restore_ok=1
        log_info "✅ 已恢复: $DEFAULT_CONF_BACKUP"
    fi
    # 恢复后测试配置
    if [ $restore_ok -eq 1 ]; then
        if ! test_nginx_config; then
            log_error "恢复配置后Nginx校验失败，请手动检查备份文件"
            exit 1
        fi
    fi
}
test_nginx_config() {
    if ! nginx -t 2>&1; then
        log_error "❌ Nginx配置测试失败!"
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
        # CentOS 9 / Stream 9 专用适配
        if grep -E "9|Stream 9" /etc/redhat-release; then
            PM="dnf"
            PM_INSTALL="install -y"
            PM_UPDATE="makecache --refresh"
            # 自动启用 CRB + EPEL 仓库
            dnf config-manager --set-enabled crb -y
            dnf install epel-release -y
        else
            # CentOS 7/8
            PM="yum"
            PM_INSTALL="install -y"
            PM_UPDATE="makecache"
            yum install epel-release -y
        fi
    else
        log_error "不支持的系统发行版（仅支持Debian/Ubuntu/CentOS/RHEL）"
        exit 1
    fi
}
# 域名合法性校验函数
validate_domain() {
    local domain=$1
    # 兼容localhost、标准域名、IPv4、IPv6地址
    if [ "$domain" = "localhost" ] \
        || [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]] \
        || [[ "$domain" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || [[ "$domain" =~ ^([0-9a-fA-F:]+:+)+[0-9a-fA-F]+$ ]]; then
        return 0
    else
        return 1
    fi
}
# 调用包管理器检测函数
detect_package_manager
USE_DEFAULT_CERT=true  # 默认值
SSL_ENABLED=false

# ==================== 交互配置封装函数 ====================
interactive_config() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}   LibreSpeed + GeoIP2 一体化部署     ${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
    # 1. 自定义域名输入（带合法性校验）
    while true; do
        read -p "$(echo -e "${YELLOW}请输入要配置的域名 [默认: localhost]${NC}\n域名：")" INPUT_DOMAIN
        # 未输入则使用默认localhost
        if [ -z "$INPUT_DOMAIN" ]; then
            CUSTOM_DOMAIN="localhost"
            break
        fi
        # 校验域名合法性
        if validate_domain "$INPUT_DOMAIN"; then
            CUSTOM_DOMAIN="$INPUT_DOMAIN"
            break
        else
            log_error "错误：域名格式不合法！请输入如 speed.test.com 这样的有效域名"
            echo ""
        fi
    done
    log_info "✅ 确认使用域名：$CUSTOM_DOMAIN"
    # localhost跳过Cloudflare和证书路径交互
    SKIP_CF_CERT=false
    if [ "$CUSTOM_DOMAIN" = "localhost" ]; then
        SKIP_CF_CERT=true
        USE_CLOUDFLARE=false  # localhost强制不使用Cloudflare
        USE_DEFAULT_CERT=true # localhost强制使用默认证书（跳过SSL配置）
        log_info "⚠️ 检测到域名为localhost，自动跳过Cloudflare和SSL证书配置"
    fi
    echo ""
    # 0. Cloudflare CDN 使用确认
    while true; do
    # localhost直接跳过
        if [ "$SKIP_CF_CERT" = true ]; then
            break
        fi
        read -p "$(echo -e "${YELLOW}是否使用了 Cloudflare CDN？(y/n) [默认: y]${NC}\n选择：")" CF_USE
        # 未输入则使用默认y
        if [ -z "$CF_USE" ]; then
            USE_CLOUDFLARE=true
            break
        fi
        # 转换为小写
        CF_USE_LOWER=$(echo "$CF_USE" | tr '[:upper:]' '[:lower:]')
        if [ "$CF_USE_LOWER" = "y" ] || [ "$CF_USE_LOWER" = "yes" ]; then
            USE_CLOUDFLARE=true
            break
        elif [ "$CF_USE_LOWER" = "n" ] || [ "$CF_USE_LOWER" = "no" ]; then
            USE_CLOUDFLARE=false
            break
        else
            log_error "错误：请输入 y (是) 或 n (否)！请重新输入"
            echo ""
        fi
    done
    if [ "$USE_CLOUDFLARE" = true ]; then
        log_info "✅ 确认使用 Cloudflare CDN，将配置真实IP还原"
    else
        log_info "✅ 确认未使用 Cloudflare CDN，将跳过真实IP配置"
    fi
    echo ""
    # 1. 测速端口配置（带合法性校验：1-65535纯数字）
    while true; do
        read -p "$(echo -e "${YELLOW}请输入 LibreSpeed 测速服务端口 [默认: $DEFAULT_SPEED_PORT]${NC}\n端口号：")" CUSTOM_PORT
        # 未输入则使用默认端口
        if [ -z "$CUSTOM_PORT" ]; then
            SPEED_PORT=$DEFAULT_SPEED_PORT
            break
        fi
        # 校验端口为纯数字且在合法范围
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 1 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
            SPEED_PORT=$CUSTOM_PORT
            break
        else
            log_error "错误：端口必须是1-65535之间的纯数字！请重新输入"
            echo ""
        fi
    done
    log_info "✅ 确认 LibreSpeed 端口：$SPEED_PORT"
    echo ""
    # 2. 自定义拦截国家代码（逗号分隔，自动去空格、转大写，默认CN）
    echo -e "${YELLOW}📌 国家代码参考：CN(中国)、US(美国)、JP(日本)、SG(新加坡)、DE(德国)、GB(英国)、KR(韩国)、HK(香港)、TW(台湾)${NC}"
    read -p "$(echo -e "${YELLOW}请输入要拦截的国家代码 [逗号分隔，默认: CN]${NC}\n国家代码：")" INPUT_BLOCK
    echo ""
    # 处理输入：去空格、转大写，未输入则用默认CN
    if [ -n "$INPUT_BLOCK" ]; then
        BLOCKED_COUNTRIES=$(echo "$INPUT_BLOCK" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
        if [ -z "$BLOCKED_COUNTRIES" ]; then
        log_warn "输入的国家代码为空，使用默认值 CN"
        BLOCKED_COUNTRIES="CN"
        fi
    fi
    if [ -z "$BLOCKED_COUNTRIES" ]; then
    BLOCKED_COUNTRIES="CN"
    fi
    echo ""
    # 3. 自定义SSL证书路径
    while true; do
        # localhost直接跳过
        if [ "$SKIP_CF_CERT" = true ]; then
            break
        fi
        read -p "$(echo -e "${YELLOW}是否使用默认Let's Encrypt证书路径？(y/n) [默认: y]${NC}\n选择：")" USE_DEFAULT_CERT
        # 未输入则使用默认y
        if [ -z "$USE_DEFAULT_CERT" ]; then
            USE_DEFAULT_CERT=true
            break
        fi
        # 转换为小写
        USE_DEFAULT_CERT_LOWER=$(echo "$USE_DEFAULT_CERT" | tr '[:upper:]' '[:lower:]')
        if [ "$USE_DEFAULT_CERT_LOWER" = "y" ] || [ "$USE_DEFAULT_CERT_LOWER" = "yes" ]; then
            USE_DEFAULT_CERT=true
            break
        elif [ "$USE_DEFAULT_CERT_LOWER" = "n" ] || [ "$USE_DEFAULT_CERT_LOWER" = "no" ]; then
            USE_DEFAULT_CERT=false
            break
        else
            log_error "错误：请输入 y (是) 或 n (否)！请重新输入"
            echo ""
        fi
    done

    # 初始化自定义证书路径变量
    CUSTOM_CERT=""
    CUSTOM_KEY=""

    if [ "$USE_DEFAULT_CERT" = false ]; then
        # 输入自定义证书路径
while true; do
    read -p "$(echo -e "${YELLOW}请输入SSL证书文件完整路径：${NC}\n证书路径：")" CUSTOM_CERT
    if [ -n "$CUSTOM_CERT" ] && [ -f "$CUSTOM_CERT" ]; then
        break
    else
        log_error "错误：证书路径不能为空且文件必须存在！请重新输入"
        echo ""
    fi
done
# 输入自定义私钥路径
while true; do
    read -p "$(echo -e "${YELLOW}请输入SSL私钥文件完整路径：${NC}\n私钥路径：")" CUSTOM_KEY
    if [ -n "$CUSTOM_KEY" ] && [ -f "$CUSTOM_KEY" ]; then
        break
    else
        log_error "错误：私钥路径不能为空且文件必须存在！请重新输入"
        echo ""
    fi
done
        log_info "✅ 确认自定义证书路径：$CUSTOM_CERT"
        log_info "✅ 确认自定义私钥路径：$CUSTOM_KEY"
    else
        log_info "✅ 确认使用默认Let's Encrypt证书路径"
    fi
    log_info "✅ 确认拦截国家/地区代码：$BLOCKED_COUNTRIES"
    sleep 1
    echo ""
}
# ==================== 步骤1: 交互配置 + 确认环节 ====================
# 循环执行交互配置，直到确认
while true; do
    # 调用交互配置函数
    interactive_config

# 显示配置汇总确认界面
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
    # 直接回车 = 默认为y，确认继续
    if [ -z "$CONFIRM" ]; then
        echo -e "${GREEN}✅ 已确认配置...${NC}"
        sleep 1
        break 2
    fi
    # 转小写判断
    CONFIRM_LOWER=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
    if [ "$CONFIRM_LOWER" = "y" ] || [ "$CONFIRM_LOWER" = "yes" ]; then
        echo -e "${GREEN}✅ 已确认配置...${NC}"
        sleep 1
        break 2
    elif [ "$CONFIRM_LOWER" = "n" ] || [ "$CONFIRM_LOWER" = "no" ]; then
        log_warn "🔄 您选择重新配置，请重新填写信息..."
        sleep 1
        break
    else
        log_error "错误：请输入 y (是) 或 n (否)！请重新输入"
        echo ""
    fi
done
done

# ==================== 步骤2: 安装 LibreSpeed (Docker) ====================
log_info "===== 开始部署 LibreSpeed 测速服务 ====="
# 安装 Docker
echo -e "${YELLOW}[1/3] 正在安装 Docker 环境...${NC}"
if command -v docker; then
    log_info "Docker 已安装，跳过安装步骤"
else
    curl -fL --connect-timeout 10 --max-time 30 https://get.docker.com | bash
    if [ $? -ne 0 ]; then
        log_error "Docker 安装失败，请检查网络！"
        exit 1
    fi
fi
# 启动 Docker
echo -e "${YELLOW}[2/3] 启动 Docker 并设置开机自启...${NC}"
if command -v systemctl; then
    systemctl enable docker
    systemctl start docker
else
    # CentOS 6 / Debian 8 等非 systemd 系统
    if [ -f /etc/redhat-release ]; then
        chkconfig docker on  # CentOS 6
    else
        update-rc.d -f docker defaults  # Debian 8
    fi
    service docker start
fi
if [ $? -ne 0 ]; then
    log_error "Docker 启动失败！"
    exit 1
fi
# 部署 LibreSpeed 容器
echo -e "${YELLOW}[3/3] 部署 LibreSpeed 容器...${NC}"
# 判断：容器已存在则跳过重装，仅检查运行状态
if docker ps -a --format "{{.Names}}" | grep "^librespeed$"; then
    log_info "✅ LibreSpeed 容器已存在，跳过删除与重装"
    # 如果容器未运行，则启动
    if ! docker ps --format "{{.Names}}" | grep "^librespeed$"; then
        docker start librespeed
        log_info "✅ 已启动原有 LibreSpeed 容器"
    fi
else
    # 容器不存在，全新创建
    docker run -d \
      --restart always \
      --name librespeed \
      -p 127.0.0.1:$SPEED_PORT:80 \
      adolfintel/speedtest
    if [ $? -ne 0 ]; then
        log_error "LibreSpeed 容器启动失败！"
        exit 1
    fi
    log_info "✅ LibreSpeed 容器新建完成"
fi
log_info "✅ LibreSpeed 部署成功，访问地址：http://服务器IP:$SPEED_PORT"
echo ""
# ==================== 步骤3: 部署 GeoIP2 + Cloudflare 真实IP ====================
log_info "===== 开始部署 GeoIP2 + Cloudflare 真实IP ====="
# 3.1 检测/安装 Nginx
log_info "1. 检测Nginx版本..."
if ! command -v nginx; then
    log_warn "未安装Nginx，正在通过nginx.org官方仓库安装..."
    install_nginx_official_repo  # 调用官方安装函数
fi
NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -z "$NGINX_VERSION" ]; then
    log_error "无法识别Nginx版本"
    exit 1
fi
# Nginx模块路径兼容源码编译版本
NGINX_MODULES=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "")
if [ -z "$NGINX_MODULES" ] || [ ! -d "$NGINX_MODULES" ]; then
    # 区分CentOS 64位和Debian系路径
    if [ -f /etc/redhat-release ] && [ $(uname -m) = "x86_64" ]; then
        NGINX_MODULES="/usr/lib64/nginx/modules"
    else
        NGINX_MODULES="/usr/lib/nginx/modules"
    fi
    mkdir -p "$NGINX_MODULES" && chmod 755 "$NGINX_MODULES"
fi
log_info "✅ Nginx版本: $NGINX_VERSION, 模块路径: $NGINX_MODULES"
# 3.2 安装系统依赖
log_info "2. 安装系统依赖..."
$PM $PM_UPDATE
if [ "$PM" = "apt-get" ]; then
    $PM $PM_INSTALL build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git curl libssl-dev
else
    # CentOS/RHEL 适配
    $PM $PM_INSTALL gcc gcc-c++ make pcre-devel zlib-devel libmaxminddb-devel git curl openssl-devel
    # CentOS 8+ 需先安装EPEL源（libmaxminddb-devel依赖）
    if [ "$PM" = "yum" ]; then
        $PM $PM_INSTALL epel-release -y
    fi
fi
log_info "✅ 依赖安装完成"
# 3.3 备份nginx.conf + DEFAULT_CONF
backup_nginx_config
# 删除旧的 default.conf
if [ -f "$DEFAULT_CONF" ]; then
    rm -f "$DEFAULT_CONF"
    log_info "🗑️ 已删除旧的 default.conf 配置文件"
fi
# 3.4 下载Nginx源码
log_info "3. 准备Nginx源码..."
cd /tmp || { log_error "无法进入/tmp目录"; exit 1; }
NGINX_SRC_TAR="nginx-$NGINX_VERSION.tar.gz_$$"
# 解压后默认目录名
NGINX_SRC_DIR_ORIG="nginx-$NGINX_VERSION"
# 目标临时目录名（带$$后缀）
NGINX_SRC_DIR="nginx-$NGINX_VERSION_$$"
# 下载+完整性校验
if [ ! -f "$NGINX_SRC_TAR" ] || [ ! -d "$NGINX_SRC_DIR" ] || [ ! -f "$NGINX_SRC_DIR/auto/options" ]; then
    # 删除残缺文件/目录（包括默认目录和目标目录）
    rm -rf "$NGINX_SRC_TAR" "$NGINX_SRC_DIR" "$NGINX_SRC_DIR_ORIG"
    log_info "正在下载 Nginx $NGINX_VERSION 源码..."
    # 官方源 + 自动重试3次 + 关闭静默模式
    if ! curl -L --connect-timeout 20 --max-time 30 --retry 3 \
        "https://nginx.org/download/${NGINX_SRC_TAR%_$$}" -o "$NGINX_SRC_TAR"; then
        log_error "❌ Nginx源码下载失败！"
        rm -rf "$NGINX_SRC_TAR"
        exit 1
    fi
    # 解压并校验核心文件（检查tar退出码）
    log_info "正在解压 Nginx 源码..."
    if ! tar zxf "$NGINX_SRC_TAR"; then
        log_error "❌ Nginx源码解压失败（压缩包损坏/权限不足）！"
        rm -rf "$NGINX_SRC_TAR" "$NGINX_SRC_DIR_ORIG"
        exit 1
    fi
    # 将默认解压目录重命名为带$$后缀的目标目录
    if ! mv "$NGINX_SRC_DIR_ORIG" "$NGINX_SRC_DIR"; then
        log_error "❌ 无法重命名Nginx源码目录！"
        rm -rf "$NGINX_SRC_TAR" "$NGINX_SRC_DIR_ORIG"
        exit 1
    fi
    # 校验核心文件是否存在
    if [ ! -f "$NGINX_SRC_DIR/auto/options" ]; then
        log_error "❌ Nginx源码解压后缺失核心文件auto/options，下载的包损坏！"
        rm -rf "$NGINX_SRC_TAR" "$NGINX_SRC_DIR"
        exit 1
    fi
fi
log_info "✅ Nginx源码准备完成"
# 3.5 下载GeoIP2模块
log_info "4. 下载GeoIP2模块..."
if [ ! -d "/tmp/$MODULE_NAME" ]; then
    git clone "$MODULE_GIT_URL" /tmp/$MODULE_NAME
fi
log_info "✅ GeoIP2模块下载完成"
# 3.6 编译动态模块
log_info "5. 编译GeoIP2动态模块..."
cd "$NGINX_SRC_DIR"
# 1. 提取原始configure参数
RAW_CONFIG_ARGS=$(nginx -V 2>&1 | grep -oP '(?<=configure arguments: ).*')
# 2. 过滤参数（兼容所有Linux，无grep报错）
FILTERED_CONFIG_ARGS=$(echo "$RAW_CONFIG_ARGS" | grep -o -- '--[[:alnum:]_-]\+' | tr '\n' ' ')
# 3. 转换为数组
IFS=' ' read -ra NGINX_CONFIG_ARGS_ARR <<< "$FILTERED_CONFIG_ARGS"
# 4. 执行configure
./configure "${NGINX_CONFIG_ARGS_ARR[@]}" --with-compat --add-dynamic-module=/tmp/$MODULE_NAME || {
    log_error "编译配置失败"
    restore_nginx_config
    exit 1
}
make modules || {
    log_error "编译失败"
    restore_nginx_config
    exit 1
}
if [ ! -f "objs/${MODULE_NAME}.so" ]; then
    log_error "❌ 模块文件未生成，编译失败"
    restore_nginx_config
    exit 1
fi
log_info "✅ 编译完成"
# 3.7 安装模块
log_info "6. 安装模块到Nginx..."
cp objs/${MODULE_NAME}.so "$NGINX_MODULES/"
chmod 644 "$NGINX_MODULES/${MODULE_NAME}.so"
log_info "✅ 模块安装完成"
# 3.8 加载模块（main块指令，必须在nginx.conf顶部）
log_info "7. 加载GeoIP2模块..."
MODULE_LOAD="load_module $NGINX_MODULES/${MODULE_NAME}.so;"
# 先删除所有已有的加载该模块的行（兼容任意路径、任意空格）
sed -i "/^[[:space:]]*load_module[[:space:]]\+.*\/${MODULE_NAME}\.so[[:space:]]*;/d" "$NGINX_CONF"
# 在文件开头添加新的加载指令
sed -i "1i $MODULE_LOAD" "$NGINX_CONF"
log_info "✅ 已加载GeoIP2模块（已自动清理旧配置）"
# 测试Nginx配置
log_info "测试Nginx配置（加载模块后）..."
if ! test_nginx_config; then
    restore_nginx_config
    exit 1
fi
# 3.9 获取Cloudflare IP (仅当使用CF时执行)
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "8. 获取 Cloudflare IP 段..."
    CF_IPV4=$(curl --fail --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v4 || true)
    CF_IPV6=$(curl --fail --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v6 || true)
    if [[ -n "$CF_IPV4" && -n "$CF_IPV6" ]]; then
        log_info "✅ 成功获取最新Cloudflare IP段"
        CF_IPS="$CF_IPV4"$'\n'"$CF_IPV6"
    else
        log_warn "⚠️ 网络获取失败，使用内置最新官方IP段"
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
    log_info "8. 未使用Cloudflare CDN，跳过获取Cloudflare IP段"
fi
# 3.10 确保 DEFAULT_CONF 文件及父目录存在
log_info "9. 初始化站点配置文件..."
mkdir -p /etc/nginx/conf.d
if [ ! -f "$DEFAULT_CONF" ]; then
    touch "$DEFAULT_CONF"
    log_info "✅ 已创建空配置文件: $DEFAULT_CONF"
fi
# 3.11 配置Cloudflare真实IP (仅当使用CF时执行) - 写入DEFAULT_CONF
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "10. 配置Cloudflare真实IP还原..."
    # 检查DEFAULT_CONF中是否已有Cloudflare RealIP配置
    if ! grep "# Cloudflare RealIP Configuration" "$DEFAULT_CONF"; then
        # 生成RealIP配置到临时文件
        cat > "$TEMP_CONF" << EOL
# Cloudflare RealIP Configuration
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
EOL
        # 添加CF IP段
        while IFS= read -r ip; do
            [ -n "$ip" ] && echo "set_real_ip_from $ip;" >> "$TEMP_CONF"
        done <<< "$CF_IPS"
        echo "" >> "$TEMP_CONF"
        
        # 将新配置插入到DEFAULT_CONF开头
        cat "$TEMP_CONF" "$DEFAULT_CONF" > "${DEFAULT_CONF}.new"
        mv "${DEFAULT_CONF}.new" "$DEFAULT_CONF"
        
        log_info "✅ Cloudflare真实IP配置完成"
    else
        log_info "✅ Cloudflare真实IP已配置，跳过"
    fi
    log_info "测试Nginx配置（Cloudflare IP）..."
    if ! test_nginx_config; then
        restore_nginx_config
        exit 1
    fi
else
    log_info "10. 未使用Cloudflare CDN，跳过配置Cloudflare真实IP还原"
fi
# 3.12 检查GeoIP数据库
log_info "11. 检查GeoIP数据库..."
# 定义数据库路径
DB_FILE="$GEOIP_DB_PATH/GeoLite2-Country.mmdb"
# 校验旧文件
if [ -f "$DB_FILE" ]; then
    log_info "检测到已存在GeoIP数据库，正在校验文件有效性..."
    # 校验：文件大小≥1MB
    if [ $(stat -c%s "$DB_FILE" || echo 0) -ge 1048576 ]; then
        log_info "✅ 现有数据库文件校验通过，跳过下载"
    else
        log_warn "⚠️ 现有数据库文件损坏/过小，正在删除并重新下载..."
        rm -f "$DB_FILE" # 删除无效旧文件
    fi
fi
# 文件不存在/已删除，开始逐源下载+校验
if [ ! -f "$DB_FILE" ]; then
    log_info "正在自动下载GeoIP2数据库..."
    mkdir -p "$GEOIP_DB_PATH"
    # 定义3个下载源（按顺序尝试）
    GEOIP_DB_URLS=(
        "https://github.com/zhaolibinmax/install_geoip2/raw/refs/heads/main/GeoLite2-Country.mmdb"
        "https://cdn.jsdelivr.net/gh/P3TERX/GeoLite2-CN@release/GeoLite2-Country.mmdb"
        "https://raw.githubusercontent.com/P3TERX/GeoLite2-CN/release/GeoLite2-Country.mmdb"
    )
    download_success=0
    # 逐个下载 → 立即校验 → 失败删文件 → 换下一个
    for url in "${GEOIP_DB_URLS[@]}"; do
        log_info "尝试从源 $url 下载..."
        # 下载文件
        curl -L --connect-timeout 100 --max-time 300 "$url" -o "$DB_FILE"
        # 下载后立即校验（文件存在 + 大小≥1MB）
        if [ -f "$DB_FILE" ] && [ $(stat -c%s "$DB_FILE" || echo 0) -ge 1048576 ]; then
            download_success=1
            log_info "✅ 数据库下载并校验成功"
            break  # 校验成功，停止尝试后续源
        else
            log_warn "⚠️ 当前源下载/校验失败，删除损坏文件，尝试下一个源..."
            rm -f "$DB_FILE"  # 校验失败，清理损坏文件
        fi
    done
    # 所有源均失败，退出脚本
    if [ $download_success -ne 1 ]; then
        log_error "❌ 所有下载源均失败，请手动下载至 $GEOIP_DB_PATH"
        restore_nginx_config
        exit 1
    fi
fi
log_info "✅ GeoIP数据库检查完成"
# 3.13 生成GeoIP2拦截规则 - 写入DEFAULT_CONF
log_info "12. 配置国家拦截规则..."
# 先删除DEFAULT_CONF中旧的GeoIP2配置，避免冲突
sed -i '/geoip2.*GeoLite2-Country.mmdb/,/}/d' "$DEFAULT_CONF"
sed -i '/map.*geoip2_country_code/,/}/d' "$DEFAULT_CONF"
# 生成干净的GeoIP2配置
cat > "$TEMP_CONF" << EOL
# GeoIP2 Country Configuration
geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb {
    auto_reload 5m;
    \$geoip2_country_code country iso_code;
}
map \$geoip2_country_code \$allowed_country {
    default yes;
EOL
# 添加拦截国家
local OLD_IFS=$IFS
local IFS=','
read -ra COUNTRY_ARR <<< "$BLOCKED_COUNTRIES"
IFS=$OLD_IFS
for c in "${COUNTRY_ARR[@]}"; do
    [ -z "$c" ] && continue  # 跳过空元素
    echo "    $c no;" >> "$TEMP_CONF"
done
IFS=$OLD_IFS
echo "}" >> "$TEMP_CONF"
echo "" >> "$TEMP_CONF"
# 将GeoIP2配置插入到DEFAULT_CONF开头
cat "$TEMP_CONF" "$DEFAULT_CONF" > "${DEFAULT_CONF}.new"
mv "${DEFAULT_CONF}.new" "$DEFAULT_CONF"
rm -f "$TEMP_CONF"
log_info "✅ GeoIP2国家拦截配置成功"
# 测试配置
log_info "测试Nginx配置（GeoIP2拦截）..."
if ! test_nginx_config; then
    restore_nginx_config
    exit 1
fi
# 3.14 创建/完善 site 配置文件（Server块）【证书检查+条件生成SSL配置】
log_info "13. 检查并完善站点Server配置..."
# 检查配置文件中是否包含 server 块关键字，如果没有则追加完整配置
if ! grep "server {" "$DEFAULT_CONF"; then
    # 定义SSL配置片段（根据域名是否为localhost+证书存在性决定是否启用）
    SSL_CONFIG=""
    QUIC_CONFIG=""
    SSL_ENABLED=false  # SSL启用状态标记
    if [ "$CUSTOM_DOMAIN" != "localhost" ]; then
# 定义证书完整路径：优先使用自定义路径，否则用默认Let's Encrypt路径
if [ -n "$CUSTOM_CERT" ] && [ -n "$CUSTOM_KEY" ]; then
    CERT_FILE="$CUSTOM_CERT"
    KEY_FILE="$CUSTOM_KEY"
else
    CERT_FILE="/etc/letsencrypt/live/$CUSTOM_DOMAIN/fullchain.pem"
    KEY_FILE="/etc/letsencrypt/live/$CUSTOM_DOMAIN/privkey.pem"
fi
        
        # 证书存在性检查
        if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
            SSL_ENABLED=true
            SSL_CONFIG="    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
            
            # 自动检测 QUIC/HTTP3 模块
            if nginx -V 2>&1 | grep "http_v3_module"; then
                log_info "✅ 检测到 Nginx QUIC 模块，启用 HTTP3 配置"
                QUIC_CONFIG="    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    http3 on;
    quic_gso on;"
            else
                log_info "✅ Nginx 无 QUIC 模块，自动跳过 HTTP3 配置"
                QUIC_CONFIG=""
            fi
            log_info "✅ 找到 SSL 证书，启用 SSL/HTTPS 完整配置"
        else
    log_warn "⚠️ 未找到 SSL 证书文件（$CERT_FILE 或 $KEY_FILE）"
    log_info "建议执行以下命令安装 Let's Encrypt 证书："
    log_info "certbot certonly --nginx -d $CUSTOM_DOMAIN"
    log_warn "⚠️ 自动跳过 SSL/HTTPS 配置"
    SSL_CONFIG=""
    QUIC_CONFIG=""
    SSL_ENABLED=false
fi
    else
        log_warn "⚠️ 域名为 localhost，跳过 SSL/QUIC 配置（无合法证书）"
        SSL_CONFIG=""
        QUIC_CONFIG=""
        SSL_ENABLED=false
    fi

    # 条件性生成Server配置：证书存在生成HTTPS配置，无证书仅生成HTTP配置
    if [ "$SSL_ENABLED" = true ]; then
        # 证书存在：完整HTTPS配置
        cat >> "$DEFAULT_CONF" << SITEEOF
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets on;
ssl_buffer_size 4k;
ssl_protocols TLSv1.3;
ssl_ciphers TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20_POLY1305;
ssl_ecdh_curve auto;
#tcp_nopush on;
#tcp_nodelay on;
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
        log_info "✅ default.conf配置文件创建完成（已启用SSL，适配域名 $CUSTOM_DOMAIN 和端口 $SPEED_PORT）"
    else
        # 无证书/localhost：仅生成80端口HTTP配置
        cat >> "$DEFAULT_CONF" << SITEEOF
#tcp_nopush on;
#tcp_nodelay on;
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
        log_info "✅ default.conf配置文件创建完成（未启用SSL，仅80端口，适配域名 $CUSTOM_DOMAIN 和端口 $SPEED_PORT）"
    fi
else
    # 若配置文件已存在，仅更新域名和端口
    log_info "${YELLOW}✅ default.conf配置文件已存在，正在更新域名与端口...${NC}"
    # 使用更精确的替换，避免误杀
    sed -i "s/server_name _;/server_name $CUSTOM_DOMAIN;/g" "$DEFAULT_CONF"
    sed -i "s/server_name localhost;/server_name $CUSTOM_DOMAIN;/g" "$DEFAULT_CONF"
    # 尝试更新 proxy_pass 端口
    sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:$SPEED_PORT;|g" "$DEFAULT_CONF"
    log_info "✅ 配置更新完成，请手动检查确认"
fi
# 测试最终站点配置
log_info "测试Nginx配置（Server块）..."
if ! test_nginx_config; then
    restore_nginx_config
    exit 1
fi
# 3.15 创建403页面
log_info "14. 创建403错误页面..."
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
chmod 644 "$ERROR_PAGE"
    log_info "✅ 403错误页面创建完成"
else
    log_info "✅ 403错误页面已存在"
fi
# 3.16 最终测试与重启
log_info "15. 最终Nginx配置测试..."
if ! test_nginx_config; then
    log_error "Nginx配置测试失败，正在恢复..."
    restore_nginx_config
    exit 1
fi
log_info "16. 重启Nginx..."
if ! systemctl restart nginx; then
    log_warn "systemctl重启失败，尝试service命令..."
    if ! service nginx restart; then
        log_error "❌ Nginx重启失败"
        restore_nginx_config
        exit 1
    fi
fi
if systemctl is-active nginx || service nginx status | grep "running"; then
    log_info "✅ Nginx已成功重启"
else
    log_error "❌ Nginx未成功启动"
    restore_nginx_config
    exit 1
fi
# 3.17 清理临时文件
log_info "17. 清理临时文件..."
# 安全清理 Nginx 编译目录
if [ -n "$NGINX_VERSION" ] && [ -d "/tmp/nginx-$NGINX_VERSION" ]; then
    rm -rf "/tmp/nginx-$NGINX_VERSION"
    rm -f "/tmp/nginx-$NGINX_VERSION.tar.gz"
fi
# 安全清理 GeoIP2 模块目录
[ -d "/tmp/$MODULE_NAME" ] && rm -rf "/tmp/$MODULE_NAME"
# 清理临时配置文件
[ -e "$TEMP_CONF" ] && rm -f "$TEMP_CONF"
[ -e "${DEFAULT_CONF}.new" ] && rm -f "${DEFAULT_CONF}.new"
log_info "✅ 清理完成"
# ==================== 完成 ====================
echo ""
echo "========================================"
log_info "✅ 一体化脚本执行完成！"
log_info "✅ 功能1：LibreSpeed 测速服务（端口：$SPEED_PORT）"
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "✅ 功能2：Cloudflare真实IP + GeoIP2 国家拦截（拦截：$BLOCKED_COUNTRIES）"
else
    log_info "✅ 功能2：GeoIP2 国家拦截（拦截：$BLOCKED_COUNTRIES）（未配置Cloudflare真实IP）"
fi
log_info "✅ 功能3：自定义域名配置（域名：$CUSTOM_DOMAIN）"
log_info "✅ 备份位置：$NGINX_CONF_BACKUP | $DEFAULT_CONF_BACKUP"
log_info "✅ 日志文件：$LOG_FILE"
echo "========================================"
echo ""
log_info "LibreSpeed 直连访问地址：http://服务器IP:$SPEED_PORT"
# 适配SSL状态输出对应访问地址
if [ "$SSL_ENABLED" = true ] && [ "$CUSTOM_DOMAIN" != "localhost" ]; then
    log_info "域名访问地址：https://$CUSTOM_DOMAIN（已自动配置SSL证书）"
elif [ "$CUSTOM_DOMAIN" != "localhost" ]; then
    log_info "域名访问地址：http://$CUSTOM_DOMAIN（未启用SSL，证书不存在）"
else
    log_info "⚠️ 域名为localhost，仅支持直连访问：http://服务器IP:$SPEED_PORT"
fi
log_info "Nginx 配置恢复方法: cp $NGINX_CONF_BACKUP $NGINX_CONF && cp $DEFAULT_CONF_BACKUP $DEFAULT_CONF && systemctl restart nginx"
log_info "LibreSpeed 容器管理命令："
log_info "  查看状态：docker ps | grep librespeed"
log_info "  停止服务：docker stop librespeed"
log_info "  启动服务：docker start librespeed"
log_info "  删除服务：docker rm -f librespeed"
