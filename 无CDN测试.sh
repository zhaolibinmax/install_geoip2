#!/bin/bash
set -eo pipefail
# ==================== Enhanced GeoIP2 Installation Script (No CDN) ====================
# 仅适配Debian/Ubuntu 无CDN站点
# =====================================================================================
# 日志函数
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
LOG_FILE="/var/log/geoip2_install_${TIMESTAMP}.log"
# ==================== 日志和备份 ====================
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1
log_info "脚本启动时间: $(date)"
log_info "Nginx配置备份将保存到: $NGINX_CONF_BACKUP"
# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行脚本"
    exit 1
fi
# ==================== 函数定义 ====================
# 备份nginx.conf
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
# 恢复nginx.conf
restore_nginx_config() {
    if [ -f "$NGINX_CONF_BACKUP" ]; then
        log_warn "正在从备份恢复nginx.conf..."
        cp "$NGINX_CONF_BACKUP" "$NGINX_CONF"
        log_info "✅ 已恢复: $NGINX_CONF_BACKUP"
    fi
}
# 测试nginx配置
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
    log_error "未安装Nginx，请先安装"
    exit 1
fi
NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -z "$NGINX_VERSION" ]; then
    log_error "无法识别Nginx版本"
    exit 1
fi
NGINX_MODULES=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "/usr/lib/nginx/modules")
log_info "✅ Nginx版本: $NGINX_VERSION, 模块路径: $NGINX_MODULES"
# ==================== 2. 安装系统依赖====================
log_info "2. 安装系统依赖..."
apt-get update -y
if ! apt-get install -y build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git curl; then
    log_error "❌ 系统依赖安装失败，请检查网络或源"
    exit 1
fi
log_info "✅ 依赖安装完成"
# ==================== 3. 备份nginx.conf ====================
backup_nginx_config
# ==================== 4. 下载Nginx源码====================
log_info "3. 准备Nginx源码..."
cd /tmp
NGINX_TAR="nginx-$NGINX_VERSION.tar.gz"
NGINX_URL="https://nginx.org/download/$NGINX_TAR"
if [ ! -f "$NGINX_TAR" ]; then
    log_info "正在下载Nginx $NGINX_VERSION 源码..."
    if ! curl -f -L --connect-timeout 10 "$NGINX_URL" -o "$NGINX_TAR"; then
        log_error "❌ Nginx源码下载失败，请检查版本或网络"
        restore_nginx_config
        exit 1
    fi
fi
if [ ! -d "nginx-$NGINX_VERSION" ]; then
    if ! tar zxf "$NGINX_TAR"; then
        log_error "❌ Nginx源码解压失败，文件可能损坏"
        restore_nginx_config
        exit 1
    fi
fi
log_info "✅ Nginx源码准备完成"
# ==================== 5. 下载GeoIP2模块 ====================
log_info "4. 下载GeoIP2模块..."
[ ! -d "/tmp/$MODULE_NAME" ] && git clone "$MODULE_GIT_URL" /tmp/$MODULE_NAME
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
log_info "✅ 编译完成"
# ==================== 7. 安装模块 ====================
log_info "6. 安装模块到Nginx..."
mkdir -p "$NGINX_MODULES"
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
# ==================== 9. 检查GeoIP数据库 ====================
log_info "8. 检查GeoIP数据库..."
if [ ! -f "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" ]; then
    log_error "❌ 未找到数据库文件：$GEOIP_DB_PATH/GeoLite2-Country.mmdb"
    log_error "请从以下链接下载: https://www.maxmind.com/en/geolite2/geolite2-free-geolocation-data"
    restore_nginx_config
    exit 1
fi
log_info "✅ GeoIP数据库检查完成"
# ==================== 10. 配置国家拦截====================
log_info "9. 配置国家拦截规则..."
if ! grep -q "geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb" "$NGINX_CONF"; then
    cp "$NGINX_CONF" "$TEMP_CONF"
    sed -i "/^[[:space:]]*http {/a\\
    geoip2 $GEOIP_DB_PATH\/GeoLite2-Country.mmdb {\\
        auto_reload 5m;\\
        \$geoip2_country_code country iso_code;\\
    }\\
    map \$geoip2_country_code \$allowed_country {\\
        default yes;\\
        CN      no;\\
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
# ==================== 11. 创建site配置文件 ====================
log_info "10. 创建site配置文件..."
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
# ==================== 12. 创建403页面 ====================
log_info "11. 创建403错误页面..."
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
# ==================== 13. 最终测试与重启 ====================
log_info "12. 最终Nginx配置测试..."
if ! test_nginx_config; then
    log_error "Nginx配置测试失败，正在恢复..."
    restore_nginx_config
    exit 1
fi
log_info "13. 重启Nginx..."
if ! systemctl restart nginx; then
    log_error "❌ Nginx重启失败"
    restore_nginx_config
    exit 1
fi
if systemctl is-active --quiet nginx; then
    log_info "✅ Nginx已成功重启"
else
    log_error "❌ Nginx未成功启动"
    restore_nginx_config
    exit 1
fi
# ==================== 14. 清理临时文件 ====================
log_info "14. 清理临时文件..."
rm -rf /tmp/nginx* /tmp/$MODULE_NAME /tmp/*.tmp.* 2>/dev/null || true
log_info "✅ 清理完成"
# ==================== 完成 ====================
echo ""
echo "========================================"
log_info "✅ 脚本执行完成！"
log_info "✅ 功能：GeoIP2 国家IP拦截（无CDN）"
log_info "✅ 状态：全部生效"
log_info "✅ 备份位置：$NGINX_CONF_BACKUP"
log_info "✅ 日志文件：$LOG_FILE"
echo "========================================"
echo ""
log_info "恢复方法: cp $NGINX_CONF_BACKUP $NGINX_CONF && systemctl restart nginx"
