#!/bin/bash
set -eo pipefail

# 日志函数
log_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

# ==================== 核心配置（无需修改） ====================
NGINX_CONF="/etc/nginx/nginx.conf"
MODULE_NAME="ngx_http_geoip2_module"
MODULE_GIT_URL="https://github.com/leev/ngx_http_geoip2_module.git"
GEOIP_DB_PATH="/usr/share/GeoIP"
SITE_CONF="/etc/nginx/conf.d/1.conf"
ERROR_PAGE="/403.html"
PAGE_ROOT="/var/www/html"

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行脚本"
    exit 1
fi

# 1. 检测Nginx版本
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

# 2. 安装依赖
log_info "2. 安装系统依赖..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ $ID == "ubuntu" || $ID == "debian" ]]; then
        apt update -y >/dev/null 2>&1
        apt install -y build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git curl >/dev/null 2>&1
    elif [[ $ID == "centos" || $ID == "rhel" || $ID == "rocky" ]]; then
        yum install -y gcc make pcre-devel zlib-devel libmaxminddb-devel git curl >/dev/null 2>&1
    fi
fi

# 3. 下载Nginx源码
log_info "3. 准备Nginx源码..."
cd /tmp
[ ! -f "nginx-$NGINX_VERSION.tar.gz" ] && curl -s -L --connect-timeout 10 http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -o nginx-$NGINX_VERSION.tar.gz
[ ! -d "nginx-$NGINX_VERSION" ] && tar zxf nginx-$NGINX_VERSION.tar.gz >/dev/null 2>&1

# 4. 下载GeoIP2模块
log_info "4. 下载GeoIP2模块..."
[ ! -d "/tmp/$MODULE_NAME" ] && git clone -q "$MODULE_GIT_URL" /tmp/$MODULE_NAME >/dev/null 2>&1

# 5. 编译动态模块
log_info "5. 编译GeoIP2动态模块..."
cd /tmp/nginx-$NGINX_VERSION
./configure --with-compat --add-dynamic-module=/tmp/$MODULE_NAME >/dev/null 2>&1
make modules >/dev/null 2>&1

# 6. 安装模块
log_info "6. 安装模块到Nginx..."
mkdir -p "$NGINX_MODULES"
cp objs/${MODULE_NAME}.so "$NGINX_MODULES/"
chmod 644 "$NGINX_MODULES/${MODULE_NAME}.so"

# 加载模块（防重复）
MODULE_LOAD="load_module modules/${MODULE_NAME}.so;"
if ! grep -qxF "$MODULE_LOAD" "$NGINX_CONF"; then
    sed -i "1i $MODULE_LOAD" "$NGINX_CONF"
    log_info "✅ 已加载GeoIP2模块"
else
    log_info "✅ 模块已存在，跳过"
fi

##############################################################################
# 7. 获取 Cloudflare IP 段
##############################################################################
log_info "7. 获取 Cloudflare IP 段..."
unset CF_IP_RANGES
declare -a CF_IP_RANGES

log_info "从Cloudflare官方拉取最新IP（10秒超时）..."
CF_IPV4=$(curl -s --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
CF_IPV6=$(curl -s --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v6 2>/dev/null || true)

if [[ -n "$CF_IPV4" && -n "$CF_IPV6" ]]; then
    log_info "✅ 成功获取最新Cloudflare IP段"
    CF_IP_RANGES=($CF_IPV4 $CF_IPV6)
else
    log_warn "⚠️ 网络获取失败，使用内置最新官方IP段"
    CF_IP_RANGES=(
        "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22"
        "141.101.64.0/18" "108.162.192.0/18" "190.93.240.0/20" "188.114.96.0/20"
        "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13"
        "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22"
        "2400:cb00::/32" "2606:4700::/32" "2803:f800::/32" "2405:b500::/32"
        "2405:8100::/32" "2a06:98c0::/29" "2c0f:f248::/32"
    )
fi
log_info "✅ 加载完成，共 ${#CF_IP_RANGES[@]} 个Cloudflare IP段"

# 8. 配置Cloudflare真实IP
log_info "8. 配置Cloudflare真实IP还原..."
if ! grep -q "# Cloudflare RealIP" "$NGINX_CONF"; then
    if grep -q "^http {" "$NGINX_CONF"; then
        sed -i '/^http {/a \
    # Cloudflare RealIP \
    real_ip_header CF-Connecting-IP; \
    real_ip_recursive on; \
' "$NGINX_CONF"
        for ip in "${CF_IP_RANGES[@]}"; do
            sed -i "/real_ip_recursive on;/a \
    set_real_ip_from $ip;" "$NGINX_CONF"
        done
    else
        log_error "nginx.conf 不存在http块，脚本退出"
        exit 1
    fi
fi

# 9. 检查GeoIP数据库
log_info "9. 检查GeoIP数据库..."
if [ ! -f "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" ]; then
    log_error "未找到数据库文件：$GEOIP_DB_PATH/GeoLite2-Country.mmdb"
    log_error "请手动上传后重新运行脚本"
    exit 1
fi

# 10. 配置国家拦截（拦截中国）
log_info "10. 配置国家拦截规则..."
if ! grep -q "geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb" "$NGINX_CONF"; then
    sed -i '/^http {/a \
    geoip2 '"$GEOIP_DB_PATH"'/GeoLite2-Country.mmdb { \
        auto_reload 5m; \
        $geoip2_country_code country iso_code; \
    } \
    map $geoip2_country_code $allowed_country { \
        default yes; \
        CN      no; \
    } \
' "$NGINX_CONF"
fi

# 11. 配置站点拦截
log_info "11. 配置站点拦截规则..."
mkdir -p /etc/nginx/conf.d
touch "$SITE_CONF"

if ! grep -q "error_page 403" "$SITE_CONF"; then
    sed -i '/^server {/a \
    fastcgi_intercept_errors on; \
    error_page 403 '"$ERROR_PAGE"'; \
' "$SITE_CONF"
fi

if ! grep -q '$allowed_country = no' "$SITE_CONF"; then
    sed -i '/location \/ {/a \
        if ($allowed_country = no) { return 403; } \
' "$SITE_CONF"
fi

if ! grep -q "location = $ERROR_PAGE" "$SITE_CONF"; then
    sed -i '/^server {/a \
    location = '"$ERROR_PAGE"' { \
        root '"$PAGE_ROOT"'; \
        internal; ssi on; } \
' "$SITE_CONF"
fi

# 12. 创建403页面
log_info "12. 创建美观403拦截页面..."
mkdir -p "$PAGE_ROOT"
if [ ! -f "$PAGE_ROOT/403.html" ]; then
    cat > "$PAGE_ROOT/403.html" << EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>访问被拒绝</title>
<style>body{display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f4f4f4;font-family:Arial,sans-serif}.box{text-align:center;background:#fff;padding:40px;border-radius:12px;box-shadow:0 2px 10px rgba(0,0,0,0.1)}h1{color:#e53935;margin:0}p{color:#666;margin-top:10px}</style>
</head>
<body>
<div class="box"><h1>403 Forbidden</h1><p>您所在的地区无法访问此站点</p></div>
</body>
</html>
EOF
fi

# 13. 测试Nginx配置
log_info "13. 测试Nginx配置..."
if nginx -t; then
    systemctl restart nginx
    log_info "✅ Nginx重启成功"
else
    log_error "❌ Nginx配置错误，请检查"
    exit 1
fi

# 14. 清理临时文件
log_info "14. 清理临时文件..."
rm -rf /tmp/nginx* /tmp/$MODULE_NAME

echo -e "\n========================================"
log_info "✅ 脚本执行完成！"
log_info "✅ 功能：Cloudflare真实IP + GeoIP2 + 中国IP拦截"
log_info "✅ 状态：全部生效"
echo -e "========================================\n"
