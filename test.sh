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

# GeoIP2 核心配置
NGINX_CONF="/etc/nginx/nginx.conf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NGINX_CONF_BACKUP="/var/backups/nginx.conf.backup.${TIMESTAMP}"
SITE_CONF_BACKUP="/var/backups/geoip2-block.conf.backup.${TIMESTAMP}"
MODULE_NAME="ngx_http_geoip2_module"
MODULE_GIT_URL="https://github.com/leev/ngx_http_geoip2_module.git"
GEOIP_DB_PATH="/usr/share/GeoIP"
SITE_CONF="/etc/nginx/conf.d/geoip2-block.conf"
ERROR_PAGE="/403.html"
PAGE_ROOT="/var/www/html"
TEMP_CONF="/tmp/nginx.conf.tmp.$$"
LOG_FILE="/var/log/cloudflareCDN_install_${TIMESTAMP}.log"

# LibreSpeed 默认配置
DEFAULT_SPEED_PORT=56789
SPEED_PORT=$DEFAULT_SPEED_PORT
BLOCKED_COUNTRIES="CN"
USE_CLOUDFLARE=false
CUSTOM_DOMAIN="localhost"
SSL_ENABLED=false
has_error=0

# ==================== 工具函数 ====================
check_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tulpn 2>/dev/null | grep -q ":$port "
    else
        netstat -tulpn 2>/dev/null | grep -q ":$port "
    fi
}

validate_country_code() {
    local code=$1
    [[ "$code" =~ ^[A-Z]{2}$ ]]
}

validate_domain() {
    local domain=$1
    [ "$domain" = "localhost" ] || [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

print_config_summary() {
    echo ""
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}         📋 配置信息确认             ${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "  🌐 访问域名：    ${GREEN}$CUSTOM_DOMAIN${NC}"
    echo -e "  🚀 测速端口：    ${GREEN}$SPEED_PORT${NC}"
    echo -e "  ☁️  Cloudflare： ${GREEN}$(if [ "$USE_CLOUDFLARE" = true ]; then echo "启用"; else echo "禁用"; fi)${NC}"
    echo -e "  🚫 拦截国家：    ${GREEN}$BLOCKED_COUNTRIES${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
}

backup_nginx_config() {
    mkdir -p "$(dirname "$NGINX_CONF_BACKUP")"
    cp "$NGINX_CONF" "$NGINX_CONF_BACKUP" || { log_error "nginx备份失败"; exit 1; }
    mkdir -p "$(dirname "$SITE_CONF_BACKUP")"
    [ -f "$SITE_CONF" ] && cp "$SITE_CONF" "$SITE_CONF_BACKUP"
    log_info "✅ Nginx配置备份完成"
}

restore_nginx_config() {
    [ -f "$NGINX_CONF_BACKUP" ] && cp "$NGINX_CONF_BACKUP" "$NGINX_CONF"
    [ -f "$SITE_CONF_BACKUP" ] && cp "$SITE_CONF_BACKUP" "$SITE_CONF"
    log_warn "✅ 配置已恢复"
}

test_nginx_config() {
    nginx -t &>/dev/null
}

# ==================== 命令行参数解析 ====================
SILENT_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) CUSTOM_DOMAIN="$2"; shift 2 ;;
        --port) SPEED_PORT="$2"; shift 2 ;;
        --cf) [[ "$2" =~ ^(true|yes|y|1)$ ]] && USE_CLOUDFLARE=true || USE_CLOUDFLARE=false; shift 2 ;;
        --block-countries) BLOCKED_COUNTRIES="$2"; shift 2 ;;
        --silent) SILENT_MODE=true; shift 1 ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo "  --domain <域名>        默认: localhost"
            echo "  --port <端口>          默认: 56789"
            echo "  --cf <true/false>      是否启用Cloudflare"
            echo "  --block-countries <代码> 拦截国家(逗号分隔)"
            echo "  --silent               静默模式"
            exit 0
            ;;
        *) log_error "无效参数: $1"; exit 1 ;;
    esac
done

# ==================== 初始化检查 ====================
[ "$(id -u)" -ne 0 ] && { log_error "请用root运行"; exit 1; }
mkdir -p /var/log && touch "$LOG_FILE"
exec &> >(tee -a "$LOG_FILE")

# ==================== 配置逻辑 ====================
if [ "$SILENT_MODE" = true ]; then
    log_info "✅ 静默模式启动"
    validate_domain "$CUSTOM_DOMAIN" || { log_error "域名不合法"; exit 1; }
    [ "$CUSTOM_DOMAIN" = "localhost" ] && { USE_CLOUDFLARE=false; log_info "✅ localhost自动禁用Cloudflare"; }
    [[ "$SPEED_PORT" =~ ^[0-9]+$ && $SPEED_PORT -ge 1 && $SPEED_PORT -le 65535 ]] || { log_error "端口不合法"; exit 1; }
    check_port_in_use "$SPEED_PORT" && { log_error "端口已占用"; exit 1; }

    INPUT_BLOCK_CLEAN=$(echo "$BLOCKED_COUNTRIES" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    BLOCKED_COUNTRIES_CLEAN=""
    IFS=',' read -ra arr <<< "$INPUT_BLOCK_CLEAN"
    for c in "${arr[@]}"; do
        validate_country_code "$c" && BLOCKED_COUNTRIES_CLEAN+="$c,"
    done
    BLOCKED_COUNTRIES=${BLOCKED_COUNTRIES_CLEAN%,}
    [ -z "$BLOCKED_COUNTRIES" ] && BLOCKED_COUNTRIES="CN"
    print_config_summary
else
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}   LibreSpeed + GeoIP2 一体化部署     ${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""

    # 域名
    echo -e "${GREEN}【1/4】基础配置 - 域名${NC}"
    while true; do
        read -p "$(echo -e "${YELLOW}请输入域名 [默认: localhost]${NC}\n域名：")" INPUT_DOMAIN
        [ -z "$INPUT_DOMAIN" ] && { CUSTOM_DOMAIN="localhost"; break; }
        validate_domain "$INPUT_DOMAIN" && { CUSTOM_DOMAIN="$INPUT_DOMAIN"; break; }
        log_error "域名格式错误！"
    done
    log_info "✅ 域名：$CUSTOM_DOMAIN"
    echo ""

    # 端口
    echo -e "${GREEN}【2/4】基础配置 - 端口${NC}"
    while true; do
        read -p "$(echo -e "${YELLOW}请输入端口 [默认: $DEFAULT_SPEED_PORT]${NC}\n端口：")" CUSTOM_PORT
        if [ -z "$CUSTOM_PORT" ]; then
            check_port_in_use "$DEFAULT_SPEED_PORT" || { SPEED_PORT=$DEFAULT_SPEED_PORT; break; }
            log_warn "默认端口被占用，请手动输入"
            continue
        fi
        [[ "$CUSTOM_PORT" =~ ^[0-9]+$ && $CUSTOM_PORT -ge 1 && $CUSTOM_PORT -le 65535 ]] || { log_error "端口必须1-65535"; continue; }
        check_port_in_use "$CUSTOM_PORT" || { SPEED_PORT=$CUSTOM_PORT; break; }
        log_error "端口已被占用！"
    done
    log_info "✅ 端口：$SPEED_PORT"
    echo ""

    # Cloudflare
    if [ "$CUSTOM_DOMAIN" = "localhost" ]; then
        USE_CLOUDFLARE=false
        log_info "✅ localhost自动禁用Cloudflare"
        echo ""
    else
        echo -e "${GREEN}【3/4】网络配置 - Cloudflare${NC}"
        while true; do
            read -p "$(echo -e "${YELLOW}使用Cloudflare？[默认: y]${NC}\n(y/n)：")" CF_USE
            [ -z "$CF_USE" ] && { USE_CLOUDFLARE=true; break; }
            CF_USE_LOWER=$(echo "$CF_USE" | tr 'A-Z' 'a-z')
            [[ "$CF_USE_LOWER" =~ ^(y|yes)$ ]] && { USE_CLOUDFLARE=true; break; }
            [[ "$CF_USE_LOWER" =~ ^(n|no)$ ]] && { USE_CLOUDFLARE=false; break; }
            log_error "请输入y/n"
        done
        log_info "✅ Cloudflare：$(if $USE_CLOUDFLARE;then echo "启用";else echo "禁用";fi)"
        echo ""
    fi

    # 国家拦截
    echo -e "${GREEN}【4/4】安全配置 - 访问控制${NC}"
    echo -e "${YELLOW}常用：CN(中国) US(美国) JP(日本)${NC}"
    read -p "$(echo -e "${YELLOW}拦截国家 [默认: CN]${NC}\n代码：")" INPUT_BLOCK
    echo ""

    BLOCKED_COUNTRIES_CLEAN=""
    if [ -n "$INPUT_BLOCK" ]; then
        INPUT_BLOCK_CLEAN=$(echo "$INPUT_BLOCK" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
        IFS=',' read -ra arr <<< "$INPUT_BLOCK_CLEAN"
        for c in "${arr[@]}"; do
            validate_country_code "$c" && BLOCKED_COUNTRIES_CLEAN+="$c," || log_warn "忽略无效代码：$c"
        done
        BLOCKED_COUNTRIES=${BLOCKED_COUNTRIES_CLEAN%,}
        [ -z "$BLOCKED_COUNTRIES" ] && BLOCKED_COUNTRIES="CN"
    else
        BLOCKED_COUNTRIES="CN"
    fi
    log_info "✅ 拦截国家：$BLOCKED_COUNTRIES"

    # 确认
    print_config_summary
    while true; do
        read -p "$(echo -e "${YELLOW}确认配置？[默认: y]${NC}\n(y/n)：")" CONFIRM
        [ -z "$CONFIRM" ] || [[ "${CONFIRM,,}" = "y" ]] && break
        [[ "${CONFIRM,,}" = "n" ]] && { log_info "脚本退出"; exit 0; }
        log_error "请输入y/n"
    done
fi

# ==================== 部署LibreSpeed ====================
log_info "===== 部署 LibreSpeed 测速服务 ====="
echo -e "${YELLOW}[1/3] 检查Docker...${NC}"
if ! command -v docker &>/dev/null; then
    log_info "安装Docker..."
    curl -fsSL --retry 3 https://get.docker.com | bash || { log_error "Docker安装失败"; exit 1; }
fi

echo -e "${YELLOW}[2/3] 启动Docker...${NC}"
systemctl enable --now docker || { log_error "Docker启动失败"; exit 1; }

echo -e "${YELLOW}[3/3] 部署容器...${NC}"
if docker ps -a --filter "name=^librespeed$" | grep -q librespeed; then
    log_info "容器已存在，检查端口"
    if ! docker inspect librespeed | grep -q "\"HostPort\":\"$SPEED_PORT\""; then
        log_warn "端口不匹配，重建容器"
        docker stop librespeed && docker rm librespeed
        docker run -d --restart always --name librespeed -p $SPEED_PORT:80 adolfintel/speedtest
    else
        docker start librespeed &>/dev/null
    fi
else
    docker run -d --restart always --name librespeed -p $SPEED_PORT:80 adolfintel/speedtest || { log_error "容器启动失败"; exit 1; }
fi
log_info "✅ LibreSpeed部署成功"
echo ""

# ==================== 部署GeoIP2 + Nginx ====================
log_info "===== 部署 GeoIP2 国家拦截 ====="
log_info "1. 检查Nginx..."
if ! command -v nginx &>/dev/null; then
    log_warn "安装Nginx..."
    apt update -o Acquire::Timeout=300 -y
    apt install -y nginx || { log_error "Nginx安装失败"; exit 1; }
fi

NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
NGINX_MODULES=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "/usr/lib/nginx/modules")
mkdir -p "$NGINX_MODULES"
log_info "✅ Nginx版本：$NGINX_VERSION"

log_info "2. 安装依赖（已修复包名）..."
apt update -o Acquire::Timeout=300 -y
apt install -y build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git curl libssl-dev || { log_error "依赖安装失败"; exit 1; }
log_info "✅ 依赖安装完成"

backup_nginx_config

log_info "3. 准备Nginx源码..."
cd /tmp
[ ! -f "nginx-$NGINX_VERSION.tar.gz" ] && curl -sL --retry 3 https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -o nginx-$NGINX_VERSION.tar.gz
[ ! -d "nginx-$NGINX_VERSION" ] && tar zxf nginx-$NGINX_VERSION.tar.gz

log_info "4. 下载GeoIP2模块..."
[ ! -d "/tmp/$MODULE_NAME" ] && git clone --depth 1 "$MODULE_GIT_URL" /tmp/$MODULE_NAME

log_info "5. 编译模块..."
cd /tmp/nginx-$NGINX_VERSION
./configure --with-compat --add-dynamic-module=/tmp/$MODULE_NAME || { log_error "配置失败"; restore_nginx_config; exit 1; }
make modules || { log_error "编译失败"; restore_nginx_config; exit 1; }
cp objs/${MODULE_NAME}.so "$NGINX_MODULES/"
chmod 644 "$NGINX_MODULES/${MODULE_NAME}.so"

log_info "6. 加载模块..."
MODULE_LOAD="load_module modules/${MODULE_NAME}.so;"
grep -qxF "$MODULE_LOAD" "$NGINX_CONF" || sed -i "1i $MODULE_LOAD" "$NGINX_CONF"
test_nginx_config || { restore_nginx_config; exit 1; }

# Cloudflare IP
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "7. 获取Cloudflare IP..."
    CF_IPV4=$(curl -s --retry 2 --connect-timeout 5 https://www.cloudflare.com/ips-v4)
    CF_IPV6=$(curl -s --retry 2 --connect-timeout 5 https://www.cloudflare.com/ips-v6)
    [ -z "$CF_IPV4" ] && CF_IPV4="173.245.48.0/20"
    CF_IPS="$CF_IPV4"$'\n'"$CF_IPV6"
fi

mkdir -p /etc/nginx/conf.d
[ ! -f "$SITE_CONF" ] && touch "$SITE_CONF"

# Cloudflare配置
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "8. 配置Cloudflare真实IP..."
    cat > "$TEMP_CONF" << EOL
# Cloudflare RealIP
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
EOL
    while IFS= read -r ip; do [ -n "$ip" ] && echo "set_real_ip_from $ip;" >> "$TEMP_CONF"; done <<< "$CF_IPS"
    cat "$TEMP_CONF" "$SITE_CONF" > "${SITE_CONF}.new" && mv "${SITE_CONF}.new" "$SITE_CONF"
    test_nginx_config || { restore_nginx_config; exit 1; }
fi

log_info "9. 检查GeoIP数据库..."
mkdir -p "$GEOIP_DB_PATH"
[ ! -f "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" ] && curl -sL --retry 3 https://raw.githubusercontent.com/P3TERX/GeoLite2-Database/master/GeoLite2-Country.mmdb -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb"

log_info "10. 生成拦截规则..."
sed -i '/geoip2.*Country.mmdb/,/}/d' "$SITE_CONF"
sed -i '/map.*geoip2_country_code/,/}/d' "$SITE_CONF"
cat > "$TEMP_CONF" << EOL
geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb {
    auto_reload 5m;
    \$geoip2_country_code country iso_code;
}
map \$geoip2_country_code \$allowed_country {
    default yes;
EOL
IFS=',' read -ra arr <<< "$BLOCKED_COUNTRIES"
for c in "${arr[@]}"; do echo "    $c no;" >> "$TEMP_CONF"; done
echo "}" >> "$TEMP_CONF"
cat "$TEMP_CONF" "$SITE_CONF" > "${SITE_CONF}.new" && mv "${SITE_CONF}.new" "$SITE_CONF"
rm -f "$TEMP_CONF"
test_nginx_config || { restore_nginx_config; exit 1; }

log_info "11. 生成站点配置..."
if ! grep -q "server {" "$SITE_CONF"; then
    SSL_ENABLED=false
    if [ "$CUSTOM_DOMAIN" != "localhost" ] && [ -f "/etc/letsencrypt/live/$CUSTOM_DOMAIN/fullchain.pem" ]; then
        SSL_ENABLED=true
        SSL_CONFIG="    ssl_certificate /etc/letsencrypt/live/$CUSTOM_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CUSTOM_DOMAIN/privkey.pem;"
    else
        SSL_CONFIG=""
    fi

    if [ "$SSL_ENABLED" = true ]; then
        cat >> "$SITE_CONF" << EOF
server {
    listen 80;
    server_name $CUSTOM_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $CUSTOM_DOMAIN;
$SSL_CONFIG
    location / {
        proxy_pass http://127.0.0.1:$SPEED_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        if (\$allowed_country = no) { return 403; }
    }
}
EOF
    else
        cat >> "$SITE_CONF" << EOF
server {
    listen 80;
    server_name $CUSTOM_DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$SPEED_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        if (\$allowed_country = no) { return 403; }
    }
}
EOF
    fi
fi

log_info "12. 创建403页面..."
mkdir -p "$PAGE_ROOT"
[ ! -f "$PAGE_ROOT/403.html" ] && cat > "$PAGE_ROOT/403.html" << 'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>403 Forbidden</title></head><body><h1>403 访问被禁止</h1><p>您所在的地区无法访问此服务</p></body></html>
EOF

log_info "13. 重启Nginx..."
test_nginx_config || { restore_nginx_config; exit 1; }
systemctl restart nginx || service nginx restart || { log_error "重启失败"; restore_nginx_config; exit 1; }

log_info "14. 清理临时文件..."
rm -rf /tmp/nginx-$NGINX_VERSION* /tmp/$MODULE_NAME $TEMP_CONF ${SITE_CONF}.new

# ==================== 完成 ====================
echo ""
echo "========================================"
log_info "✅ 脚本执行完成！"
log_info "🌐 域名：$CUSTOM_DOMAIN"
log_info "🚀 端口：$SPEED_PORT"
log_info "🚫 拦截：$BLOCKED_COUNTRIES"
echo "========================================"
