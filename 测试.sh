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
# 拦截国家代码全局变量
BLOCKED_COUNTRIES="CN"
# Cloudflare CDN 使用标记
USE_CLOUDFLARE=false
# 自定义域名全局变量
CUSTOM_DOMAIN="localhost"  # 默认值保留localhost
# ==================== 初始化检查 ====================
# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行脚本"
    exit 1
fi
# 初始化日志
mkdir -p /var/log
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1
# ==================== 函数定义 (GeoIP2 相关) ====================
backup_nginx_config() {
    mkdir -p "$(dirname "$NGINX_CONF_BACKUP")"
    if cp "$NGINX_CONF" "$NGINX_CONF_BACKUP"; then
        log_info "✅ nginx.conf 备份完成: $NGINX_CONF_BACKUP"
        return 0
    else
        log_error "备份失败，脚本退出"
        exit 1
    fi
}
restore_nginx_config() {
    if [ -f "$NGINX_CONF_BACKUP" ]; then
        log_warn "正在从备份恢复nginx.conf..."
        cp "$NGINX_CONF_BACKUP" "$NGINX_CONF"
        log_info "✅ 已恢复: $NGINX_CONF_BACKUP"
    fi
}
test_nginx_config() {
    if ! nginx -t 2>&1; then
        log_error "❌ Nginx配置测试失败!"
        return 1
    fi
    return 0
}
# 域名合法性校验函数
validate_domain() {
    local domain=$1
    # 简单域名正则校验（支持多级域名、含连字符、数字）
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    else
        return 1
    fi
}
# ==================== 步骤1: 交互配置（域名输入 + Cloudflare + 端口 + 拦截国家） ====================
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
echo ""

# 0. Cloudflare CDN 使用确认
while true; do
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

# 处理用户输入：去空格、转大写，未输入则用默认CN
if [ -n "$INPUT_BLOCK" ]; then
    BLOCKED_COUNTRIES=$(echo "$INPUT_BLOCK" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
fi
log_info "✅ 确认拦截国家/地区代码：$BLOCKED_COUNTRIES"
sleep 1
echo ""

# ==================== 步骤2: 安装 LibreSpeed (Docker) ====================
log_info "===== 开始部署 LibreSpeed 测速服务 ====="
# 安装 Docker
echo -e "${YELLOW}[1/3] 正在安装 Docker 环境...${NC}"

if command -v docker &> /dev/null; then
    log_info "Docker 已安装，跳过安装步骤"
else
    curl -fsSL https://get.docker.com | bash
    if [ $? -ne 0 ]; then
        log_error "Docker 安装失败，请检查网络！"
        exit 1
    fi
fi

# 启动 Docker
echo -e "${YELLOW}[2/3] 启动 Docker 并设置开机自启...${NC}"
systemctl enable docker
systemctl start docker
if [ $? -ne 0 ]; then
    log_error "Docker 启动失败！"
    exit 1
fi
# 部署 LibreSpeed 容器
echo -e "${YELLOW}[3/3] 部署 LibreSpeed 容器...${NC}"
docker rm -f librespeed
docker run -d \
  --restart always \
  --name librespeed \
  -p 0.0.0.0:$SPEED_PORT:80 \
  adolfintel/speedtest
if [ $? -ne 0 ]; then
    log_error "LibreSpeed 容器启动失败！"
    exit 1
fi
log_info "✅ LibreSpeed 部署成功，访问地址：http://服务器IP:$SPEED_PORT"
echo ""

# ==================== 步骤3: 部署 GeoIP2 + Cloudflare 真实IP ====================
log_info "===== 开始部署 GeoIP2 + Cloudflare 真实IP ====="
# 3.1 检测/安装 Nginx
log_info "1. 检测Nginx版本..."
if ! command -v nginx &> /dev/null; then
    log_warn "未安装Nginx，正在自动安装..."
    apt-get update -o Acquire::Timeout=30 -y
    apt-get install -y nginx
fi
NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -z "$NGINX_VERSION" ]; then
    log_error "无法识别Nginx版本"
    exit 1
fi
NGINX_MODULES=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "/usr/lib/nginx/modules")
[ ! -d "$NGINX_MODULES" ] && mkdir -p "$NGINX_MODULES" && chmod 755 "$NGINX_MODULES"
log_info "✅ Nginx版本: $NGINX_VERSION, 模块路径: $NGINX_MODULES"

# 3.2 安装依赖
log_info "2. 安装系统依赖..."
apt-get update -o Acquire::Timeout=30 -y
apt-get install -y build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git curl
log_info "✅ 依赖安装完成"

# 3.3 备份nginx.conf
backup_nginx_config

# 3.4 下载Nginx源码
log_info "3. 准备Nginx源码..."
cd /tmp
[ ! -f "nginx-$NGINX_VERSION.tar.gz" ] && \
    curl -s -L --connect-timeout 10 https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz \
    -o nginx-$NGINX_VERSION.tar.gz
[ ! -d "nginx-$NGINX_VERSION" ] && tar zxf nginx-$NGINX_VERSION.tar.gz
log_info "✅ Nginx源码准备完成"

# 3.5 下载GeoIP2模块
log_info "4. 下载GeoIP2模块..."
[ ! -d "/tmp/$MODULE_NAME" ] && git clone "$MODULE_GIT_URL" /tmp/$MODULE_NAME
log_info "✅ GeoIP2模块下载完成"

# 3.6 编译动态模块
log_info "5. 编译GeoIP2动态模块..."
cd /tmp/nginx-$NGINX_VERSION
./configure --with-compat --add-dynamic-module=/tmp/$MODULE_NAME || {
    log_error "编译配置失败"
    restore_nginx_config
    exit 1
}
make modules || {
    log_error "编译失败"
    restore_nginx_config
    exit 1
}
[ ! -f "objs/${MODULE_NAME}.so" ] && {
    log_error "❌ 模块文件未生成，编译失败"
    restore_nginx_config
    exit 1
}
log_info "✅ 编译完成"

# 3.7 安装模块
log_info "6. 安装模块到Nginx..."
cp objs/${MODULE_NAME}.so "$NGINX_MODULES/"
chmod 644 "$NGINX_MODULES/${MODULE_NAME}.so"
log_info "✅ 模块安装完成"

# 3.8 加载模块
log_info "7. 加载GeoIP2模块..."
MODULE_LOAD="load_module modules/${MODULE_NAME}.so;"
if ! grep -qxF "$MODULE_LOAD" "$NGINX_CONF"; then
    sed -i "1i $MODULE_LOAD" "$NGINX_CONF"
    log_info "✅ 已加载GeoIP2模块"
else
    log_info "✅ 模块已存在，跳过"
fi

# 3.9 获取Cloudflare IP (仅当使用CF时执行)
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "8. 获取 Cloudflare IP 段..."
    CF_IPV4=$(curl -s --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
    CF_IPV6=$(curl -s --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v6 2>/dev/null || true)
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

# 3.10 配置Cloudflare真实IP (仅当使用CF时执行)
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "9. 配置Cloudflare真实IP还原..."
    if ! grep -q "# Cloudflare RealIP Configuration" "$NGINX_CONF"; then
        cp "$NGINX_CONF" "$TEMP_CONF"
        sed -i "/^http {/a\\
        # Cloudflare RealIP Configuration\\
        real_ip_header CF-Connecting-IP;\\
        real_ip_recursive on;" "$TEMP_CONF"
        while IFS= read -r ip; do
            [ -n "$ip" ] && sed -i "/real_ip_recursive on;/a\\
        set_real_ip_from $ip;" "$TEMP_CONF"
        done <<< "$CF_IPS"
        if nginx -t -c "$TEMP_CONF" 2>&1 | grep -q "successful"; then
            mv "$TEMP_CONF" "$NGINX_CONF"
            log_info "✅ Cloudflare真实IP配置完成"
        else
            log_error "❌ 配置验证失败"
            rm -f "$TEMP_CONF"
            restore_nginx_config
            exit 1
        fi
    else
        log_info "✅ Cloudflare真实IP已配置"
    fi
else
    log_info "9. 未使用Cloudflare CDN，跳过配置Cloudflare真实IP还原"
fi

# 3.11 检查GeoIP数据库
log_info "10. 检查GeoIP数据库..."
if [ ! -f "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" ]; then
    log_info "正在自动下载GeoIP2数据库..."
    mkdir -p "$GEOIP_DB_PATH"
    curl -s -L --connect-timeout 10 https://github.com/zhaolibinmax/install_geoip2/raw/7956c1688da90cca70a3cf62865613ef8110ffa/GeoLite2-Country.mmdb \
    -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" || {
    log_warn "下载失败，尝试GitHub源1..."
    curl -s -L --connect-timeout 10 https://raw.githubusercontent.com/P3TERX/GeoLite2-Database/master/GeoLite2-Country.mmdb \
        -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" || {
        log_warn "下载失败，尝试官方源（需注册）..."
        curl -s -L --connect-timeout 10 https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=YOUR_LICENSE_KEY&suffix=mmdb \
            -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" || {
            log_error "自动下载失败，请手动下载：https://www.maxmind.com/en/geolite2/geolite2-free-geolocation-data 至/usr/share/GeoIP"
            restore_nginx_config
            exit 1
        }
    }
}
fi
log_info "✅ GeoIP数据库检查完成"

# 3.12 生成GeoIP2拦截规则
log_info "11. 配置国家拦截规则..."

# 先删除旧配置，避免冲突
sed -i '/geoip2.*GeoLite2-Country.mmdb/,/}/d' "$NGINX_CONF"
sed -i '/map.*geoip2_country_code/,/}/d' "$NGINX_CONF"

# 生成干净的配置
cat > "$TEMP_CONF" << EOL
geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb {
    auto_reload 5m;
    \$geoip2_country_code country iso_code;
}

map \$geoip2_country_code \$allowed_country {
    default yes;
EOL

# 添加拦截国家
IFS=',' read -ra COUNTRY_ARR <<< "$BLOCKED_COUNTRIES"
for c in "${COUNTRY_ARR[@]}"; do
    echo "    $c no;" >> "$TEMP_CONF"
done
echo "}" >> "$TEMP_CONF"

# 插入到 http { 下方
sed -i "/^http {/r $TEMP_CONF" "$NGINX_CONF"

# 测试配置
if nginx -t; then
    log_info "✅ GeoIP2国家拦截配置成功"
else
    log_error "❌ GeoIP2配置失败，已自动恢复备份"
    restore_nginx_config
    exit 1
fi
rm -f "$TEMP_CONF"

# 3.13 创建site配置文件（替换localhost为自定义域名）
log_info "12. 创建site配置文件..."
mkdir -p /etc/nginx/conf.d
if [ ! -f "$SITE_CONF" ]; then
    cat > "$SITE_CONF" << SITEEOF
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
    server_name $CUSTOM_DOMAIN;  # 替换为自定义域名
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    server_name $CUSTOM_DOMAIN;  # 替换为自定义域名
    http2 on;
    http3 on;
    quic_gso on;
    ssl_certificate /etc/nginx/fullchain.pem;
    ssl_certificate_key /etc/nginx/privkey.pem;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    location = /403.html {
        root /var/www/html;
        internal;
        ssi on;
        }
    location /xhttp3 {
        grpc_pass grpc://127.0.0.1:11111;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header TE trailers;
        grpc_read_timeout 300s;
        grpc_send_timeout 300s;
        grpc_connect_timeout 10s;
        }
    proxy_buffering off;
    proxy_cache off;
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
    log_info "✅ site配置文件创建完成（已适配自定义端口 $SPEED_PORT 和域名 $CUSTOM_DOMAIN）"
else
    # 若配置文件已存在，自动替换其中的localhost为新域名
    sed -i "s/localhost/$CUSTOM_DOMAIN/g" "$SITE_CONF"
    log_info "${YELLOW}✅ site配置文件已存在，已自动替换域名为 $CUSTOM_DOMAIN（请注意检查端口是否为 $SPEED_PORT）${NC}"
fi

# 3.14 创建403页面
log_info "13. 创建403错误页面..."
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
    log_info "✅ 403错误页面创建完成"
else
    log_info "✅ 403错误页面已存在"
fi

# 3.15 最终测试与重启
log_info "14. 最终Nginx配置测试..."
if ! test_nginx_config; then
    log_error "Nginx配置测试失败，正在恢复..."
    restore_nginx_config
    exit 1
fi
log_info "15. 重启Nginx..."
if ! systemctl restart nginx; then
    log_warn "systemctl重启失败，尝试service命令..."
    if ! service nginx restart; then
        log_error "❌ Nginx重启失败"
        restore_nginx_config
        exit 1
    fi
fi
if systemctl is-active --quiet nginx || service nginx status | grep -q "running"; then
    log_info "✅ Nginx已成功重启"
else
    log_error "❌ Nginx未成功启动"
    restore_nginx_config
    exit 1
fi

# 3.16 清理临时文件
log_info "16. 清理临时文件..."
rm -rf /tmp/nginx-$NGINX_VERSION* /tmp/$MODULE_NAME "$TEMP_CONF" || true
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
log_info "✅ 备份位置：$NGINX_CONF_BACKUP"
log_info "✅ 日志文件：$LOG_FILE"
echo "========================================"
echo ""
log_info "LibreSpeed 直连访问地址：http://服务器IP:$SPEED_PORT"
log_info "域名访问地址：https://$CUSTOM_DOMAIN（需确保域名解析到服务器IP并正确配置证书）"
log_info "Nginx 配置恢复方法: cp $NGINX_CONF_BACKUP $NGINX_CONF && systemctl restart nginx"
log_info "LibreSpeed 容器管理命令："
log_info "  查看状态：docker ps | grep librespeed"
log_info "  停止服务：docker stop librespeed"
log_info "  启动服务：docker start librespeed"
log_info "  删除服务：docker rm -f librespeed"
