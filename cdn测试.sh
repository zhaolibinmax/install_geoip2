#!/bin/bash
set -eo pipefail

# ==================== Enhanced GeoIP2 Installation Script ====================
log_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

# ==================== 核心配置 ====================
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

# 初始化日志
mkdir -p /var/log
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行脚本"
    exit 1
fi

# ==================== 函数定义 ====================
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

# ==================== 1. 检测Nginx版本 ====================
log_info "1. 检测Nginx版本..."
if ! command -v nginx &> /dev/null; then
    log_error "未安装Nginx，正在自动安装（Ubuntu 24.04）..."
    apt-get update -o Acquire::Timeout=30 -y
    apt-get install -y nginx
fi

NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -z "$NGINX_VERSION" ]; then
    log_error "无法识别Nginx版本"
    exit 1
fi

NGINX_MODULES=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "/usr/lib/nginx/modules")
# 修复：检查模块路径权限
if [ ! -d "$NGINX_MODULES" ]; then
    mkdir -p "$NGINX_MODULES"
    chmod 755 "$NGINX_MODULES"
fi
log_info "✅ Nginx版本: $NGINX_VERSION, 模块路径: $NGINX_MODULES"

# ==================== 2. 安装依赖 ====================
log_info "2. 安装系统依赖..."
apt-get update -o Acquire::Timeout=30 -y
apt-get install -y build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git curl nginx-module-ssi
log_info "✅ 依赖安装完成"

# ==================== 3. 备份nginx.conf ====================
backup_nginx_config

# ==================== 4. 下载Nginx源码 ====================
log_info "3. 准备Nginx源码..."
cd /tmp
[ ! -f "nginx-$NGINX_VERSION.tar.gz" ] && \
    curl -s -L --connect-timeout 10 https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz \
    -o nginx-$NGINX_VERSION.tar.gz
[ ! -d "nginx-$NGINX_VERSION" ] && tar zxf nginx-$NGINX_VERSION.tar.gz
log_info "✅ Nginx源码准备完成"

# ==================== 5. 下载GeoIP2模块 ====================
log_info "4. 下载GeoIP2模块..."
[ ! -d "/tmp/$MODULE_NAME" ] && git clone -q "$MODULE_GIT_URL" /tmp/$MODULE_NAME
log_info "✅ GeoIP2模块下载完成"

# ==================== 6. 编译动态模块 ====================
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
if [ ! -f "objs/${MODULE_NAME}.so" ]; then
    log_error "❌ 模块文件未生成，编译失败"
    restore_nginx_config
    exit 1
fi
log_info "✅ 编译完成"

# ==================== 7. 安装模块 ====================
log_info "6. 安装模块到Nginx..."
cp objs/${MODULE_NAME}.so "$NGINX_MODULES/"
chmod 644 "$NGINX_MODULES/${MODULE_NAME}.so"
log_info "✅ 模块安装完成"

# ==================== 8. 加载模块 ====================
log_info "7. 加载GeoIP2模块..."
MODULE_LOAD="load_module modules/${MODULE_NAME}.so;"
if ! grep -qxF "$MODULE_LOAD" "$NGINX_CONF"; then
    sed -i "1i $MODULE_LOAD" "$NGINX_CONF"
    log_info "✅ 已加载GeoIP2模块"
else
    log_info "✅ 模块已存在，跳过"
fi

# ==================== 9. 获取Cloudflare IP ====================
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

# ==================== 10. 配置Cloudflare真实IP（修复正则匹配） ====================
log_info "9. 配置Cloudflare真实IP还原..."
if ! grep -q "# Cloudflare RealIP Configuration" "$NGINX_CONF"; then
    cp "$NGINX_CONF" "$TEMP_CONF"
    sed -i "/^[[:space:]]*http[[:space:]]*\{/a\
    # Cloudflare RealIP Configuration\
    real_ip_header CF-Connecting-IP;\
    real_ip_recursive on;" "$TEMP_CONF"
    
    chmod 600 "$TEMP_CONF"
    
    while IFS= read -r ip; do
        [ -n "$ip" ] && sed -i "/^[[:space:]]*real_ip_recursive on;/a\
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

# ==================== 11. 检查GeoIP数据库 ====================
log_info "10. 检查GeoIP数据库..."
if [ ! -f "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" ]; then
    log_info "正在自动下载GeoIP2数据库..."
    mkdir -p "$GEOIP_DB_PATH"
    curl -s -L --connect-timeout 10 https://github.com/zhaolibinmax/install_geoip2/raw/7956c1688da90cca740a3cf62865613ef8110ffa/GeoLite2-Country.mmdb \
    -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" || {
    log_warn "下载失败，尝试GitHub源1..."
    curl -s -L --connect-timeout 10 https://raw.githubusercontent.com/P3TERX/GeoLite2-Database/master/GeoLite2-Country.mmdb \
        -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" || {
        log_warn "下载失败，尝试官方源（需注册）..."
        curl -s -L --connect-timeout 10 https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=YOUR_LICENSE_KEY&suffix=mmdb \
            -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" || {
            log_error "自动下载失败，请手动下载：https://www.maxmind.com/en/geolite2/geolite2-free-geolocation-data"
            restore_nginx_config
            exit 1
        }
    }
}
fi
log_info "✅ GeoIP数据库检查完成"

# ==================== 12. 配置国家拦截 ====================
log_info "11. 配置国家拦截规则..."
if ! grep -q "geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb" "$NGINX_CONF"; then
    cp "$NGINX_CONF" "$TEMP_CONF"
    chmod 600 "$TEMP_CONF"
    sed -i "/^http {/a\
    geoip2 $GEOIP_DB_PATH\/GeoLite2-Country.mmdb {\
        auto_reload 5m;\
        \$geoip2_country_code country iso_code;\
    }\
    map \$geoip2_country_code \$allowed_country {\
        default yes;\
        CN      no;\
    }" "$TEMP_CONF"
    
    if nginx -t -c "$TEMP_CONF" 2>&1 | grep -q "successful"; then
        mv "$TEMP_CONF" "$NGINX_CONF"
        log_info "✅ 国家拦截配置完成"
    else
        log_error "❌ GeoIP2配置失败"
        rm -f "$TEMP_CONF"
        restore_nginx_config
        exit 1
    fi
else
    log_info "✅ 国家拦截已配置"
fi

# ==================== 13. 创建site配置文件 ====================
log_info "12. 创建site配置文件..."
mkdir -p /etc/nginx/conf.d

if [ ! -f "$SITE_CONF" ]; then
    cat > "$SITE_CONF" << 'SITEEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    fastcgi_intercept_errors on;
    error_page 403 /403.html;
    location = /403.html {
        root /var/www/html;
        internal;
        ssi on;
    }
    
    location / {
    if ($allowed_country = no) {
        return 403;
    }
        root /var/www/html;
        index index.html index.htm;
    }
}
SITEEOF
    log_info "✅ site配置文件创建完成"
else
    log_info "✅ site配置文件已存在"
fi

# ==================== 14. 创建403页面 ====================
log_info "13. 创建403错误页面..."
if ! nginx -V 2>&1 | grep -q "ngx_http_ssi_module"; then
    log_warn "⚠️ Nginx未启用SSI模块，已自动启用."
    sed -i "/^http {/a\    ssi on;" "$NGINX_CONF"
fi
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

# ==================== 15. 最终测试与重启 ====================
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

# ==================== 16. 清理临时文件====================
log_info "16. 清理临时文件..."
rm -rf /tmp/nginx-$NGINX_VERSION* /tmp/$MODULE_NAME "$TEMP_CONF" || true
log_info "✅ 清理完成"

# ==================== 完成 ====================
echo ""
echo "========================================"
log_info "✅ 脚本执行完成！"
log_info "✅ 功能：Cloudflare真实IP + GeoIP2 + 中国IP拦截"
log_info "✅ 状态：全部生效"
log_info "✅ 备份位置：$NGINX_CONF_BACKUP"
log_info "✅ 日志文件：$LOG_FILE"
echo "========================================"
echo ""
log_info "恢复方法: cp $NGINX_CONF_BACKUP $NGINX_CONF && systemctl restart nginx"