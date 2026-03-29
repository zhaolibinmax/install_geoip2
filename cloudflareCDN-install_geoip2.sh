#!/bin/bash
set -e

##############################################################################
# 使用本地 GeoIP 数据库 + 动态获取 Cloudflare IP
##############################################################################

# 日志函数
log_info() { echo -e "\n✅ $1"; }
log_warn() { echo -e "\n⚠️  $1"; }
log_error() { echo -e "\n❌ $1"; }

# 1. 动态获取已安装的Nginx版本
NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+')
if [ -z "$NGINX_VERSION" ]; then
    log_error "错误：无法检测到已安装的Nginx版本"
    exit 1
fi

MODULE_NAME="ngx_http_geoip2_module"
MODULE_GIT_URL="https://github.com/leev/ngx_http_geoip2_module.git"
GEOIP_DB_PATH="/usr/share/GeoIP"
NGINX_MODULES_PATH=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "/usr/lib/nginx/modules")
NGINX_CONF="/etc/nginx/nginx.conf"
SITE_CONF_EXAMPLE="/etc/nginx/conf.d/1.conf"
ERROR_PAGE_PATH="/403.html"
PAGE_ROOT="/var/www/html"

# 验证模块路径
if [ ! -d "$NGINX_MODULES_PATH" ]; then
    mkdir -p "$NGINX_MODULES_PATH" || { log_error "无法创建模块目录: $NGINX_MODULES_PATH"; exit 1; }
fi

echo "========================================"
echo "开始安装 Nginx GeoIP2 模块（Nginx版本：$NGINX_VERSION）"
echo "========================================"

# 1. 安装依赖
echo -e "\n1. 安装依赖..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ $ID == "ubuntu" || $ID == "debian" ]]; then
        sudo apt update -y
        sudo apt install -y build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git nginx curl jq
    elif [[ $ID == "centos" || $ID == "rhel" || $ID == "rocky" ]]; then
        sudo yum install -y gcc make pcre-devel zlib-devel libmaxminddb-devel git nginx curl jq
    fi
fi

# 2. 下载 Nginx 源码
echo -e "\n2. 下载 Nginx 源码..."
cd /tmp
[ ! -f "nginx-$NGINX_VERSION.tar.gz" ] && wget http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -q
[ ! -d "nginx-$NGINX_VERSION" ] && tar -zxvf nginx-$NGINX_VERSION.tar.gz > /dev/null

# 3. 下载模块
echo -e "\n3. 下载 GeoIP2 模块..."
[ ! -d "/tmp/$MODULE_NAME" ] && git clone "$MODULE_GIT_URL" "/tmp/$MODULE_NAME" -q

# 4. 编译模块
echo -e "\n4. 编译模块..."
cd /tmp/nginx-$NGINX_VERSION
./configure --with-compat --add-dynamic-module="/tmp/$MODULE_NAME" > /dev/null
make modules > /dev/null

# 5. 安装模块
echo -e "\n5. 安装模块..."
sudo cp "objs/${MODULE_NAME}.so" "$NGINX_MODULES_PATH/"
sudo chmod 644 "$NGINX_MODULES_PATH/${MODULE_NAME}.so"

# 6. 加载模块
echo -e "\n6. 加载模块..."
MODULE_LOAD_LINE="load_module modules/${MODULE_NAME}.so;"
if ! grep -qxF "$MODULE_LOAD_LINE" "$NGINX_CONF"; then
    sudo sed -i "1i $MODULE_LOAD_LINE" "$NGINX_CONF"
    log_info "已添加模块加载指令"
else
    log_info "模块加载指令已存在，跳过"
fi

# 7. 动态获取 Cloudflare IP
echo -e "\n7. 获取 Cloudflare IP 段..."
CF_IP_RANGES=()
if command -v curl &> /dev/null && command -v jq &> /dev/null; then
    echo "  从 Cloudflare API 获取最新 IP 段..."
    CF_IPV4=$(curl -s https://api.cloudflare.com/client/v4/ips | jq -r '.result.ipv4[]' 2>/dev/null)
    CF_IPV6=$(curl -s https://api.cloudflare.com/client/v4/ips | jq -r '.result.ipv6[]' 2>/dev/null)
    
    if [ -n "$CF_IPV4" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && CF_IP_RANGES+=("$ip")
        done <<< "$CF_IPV4"
        while IFS= read -r ip; do
            [ -n "$ip" ] && CF_IP_RANGES+=("$ip")
        done <<< "$CF_IPV6"
        log_info "成功获取 ${#CF_IP_RANGES[@]} 个 Cloudflare IP 段"
    else
        log_warn "API 获取失败，使用备用 IP 列表"
        CF_IP_RANGES=(
            "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22"
            "141.101.64.0/18" "108.162.192.0/18" "190.93.240.0/20" "188.114.96.0/20"
            "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13"
            "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22" "2400:cb00::/32"
            "2606:4700::/32" "2803:f800::/32" "2405:b500::/32" "2405:8100::/32"
            "2a06:98c0::/29" "2c0f:f248::/32"
        )
    fi
else
    log_warn "curl 或 jq 未安装，使用备用 IP 列表"
    CF_IP_RANGES=(
        "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22"
        "141.101.64.0/18" "108.162.192.0/18" "190.93.240.0/20" "188.114.96.0/20"
        "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13"
        "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22" "2400:cb00::/32"
        "2606:4700::/32" "2803:f800::/32" "2405:b500::/32" "2405:8100::/32"
        "2a06:98c0::/29" "2c0f:f248::/32"
    )
fi

# 8. Cloudflare 真实IP配置 (改进的 sed 处理)
echo -e "\n8. 配置 Cloudflare 真实IP..."
CF_CONFIG_MARKER="# Cloudflare 真实IP配置"
if ! grep -q "$CF_CONFIG_MARKER" "$NGINX_CONF"; then
    # 先检查http块是否存在 (更灵活的检测)
    if grep -q "^http\s*{" "$NGINX_CONF"; then
        # 使用临时文件替代 sed 以处理复杂的多行插入
        TEMP_CONF=$(mktemp)
        sudo cat "$NGINX_CONF" > "$TEMP_CONF"
        
        # 添加配置块
        sudo sed -i '/^http\s*{/a\    '"$CF_CONFIG_MARKER"'\n    real_ip_header CF-Connecting-IP;\n    real_ip_recursive on;' "$NGINX_CONF"
        
        # 循环添加IP段 (使用更安全的方式)
        for ip in "${CF_IP_RANGES[@]}"; do
            # 转义特殊字符
            ip_escaped=$(printf '%s\n' "$ip" | sed 's:[\/&]:\\&:g')
            sudo sed -i "/real_ip_recursive on;/a\    set_real_ip_from $ip_escaped;" "$NGINX_CONF"
        done
        log_info "已添加Cloudflare真实IP配置"
        rm -f "$TEMP_CONF"
    else
        log_error "nginx.conf中未找到http{}块"
        exit 1
    fi
else
    log_info "Cloudflare真实IP配置已存在，跳过"
fi

# 9. 检查本地 GeoIP 数据库
echo -e "\n9. 检查本地 GeoIP 数据库..."
if [ ! -f "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" ]; then
    log_warn "未找到本地数据库文件 $GEOIP_DB_PATH/GeoLite2-Country.mmdb"
    echo "请手动上传该文件到 $GEOIP_DB_PATH/ 目录后再继续！"
    exit 1
else
    log_info "本地 GeoIP 数据库已存在，直接使用"
fi

# 10. GeoIP2 规则
echo -e "\n10. 配置国家拦截规则..."
GEOIP_CONFIG_MARKER="geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb"
if ! grep -q "$GEOIP_CONFIG_MARKER" "$NGINX_CONF"; then
    if grep -q "^http\s*{" "$NGINX_CONF"; then
        db_path_escaped=$(printf '%s\n' "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" | sed 's:[\/&]:\\&:g')
        sudo sed -i '/^http\s*{/a\    '"$GEOIP_CONFIG_MARKER"' {\n        auto_reload 5m;\n        $geoip2_country_code country iso_code;\n    }\n    map $geoip2_country_code $allowed_country {\n        default yes;\n        CN      no;\n    }' "$NGINX_CONF"
        log_info "已添加GeoIP2国家拦截规则"
    else
        log_error "nginx.conf中未找到http{}块"
        exit 1
    fi
else
    log_info "GeoIP2国家拦截规则已存在，跳过"
fi

# 11. 站点配置 (自动创建如果不存在)
echo -e "\n11. 配置站点拦截..."
if [ ! -f "$SITE_CONF_EXAMPLE" ]; then
    log_warn "配置文件 $SITE_CONF_EXAMPLE 不存在，正在创建..."
    sudo mkdir -p "$(dirname "$SITE_CONF_EXAMPLE")"
    sudo cat > "$SITE_CONF_EXAMPLE" << 'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://backend;
    }
}
EOF
    log_info "已创建基础配置文件"
fi

# 检查并添加403错误页配置
if ! grep -q "error_page 403 $ERROR_PAGE_PATH;" "$SITE_CONF_EXAMPLE"; then
    if grep -q "^server\s*{" "$SITE_CONF_EXAMPLE"; then
        sudo sed -i '/^server\s*{/a\    fastcgi_intercept_errors on;\n    error_page 403 '"$ERROR_PAGE_PATH"';' "$SITE_CONF_EXAMPLE"
        log_info "已添加403错误页配置"
    else
        log_error "$SITE_CONF_EXAMPLE中未找到server{}块"
        exit 1
    fi
else
    log_info "403错误页配置已存在，跳过"
fi

# 检查并添加国家拦截逻辑
if ! grep -q '$allowed_country = no' "$SITE_CONF_EXAMPLE"; then
    if grep -q "location\s*/\s*{" "$SITE_CONF_EXAMPLE"; then
        sudo sed -i '/location\s*\/\s*{/a\        if ($allowed_country = no) {\n            return 403;\n        }' "$SITE_CONF_EXAMPLE"
        log_info "已添加站点国家拦截逻辑"
    else
        log_error "$SITE_CONF_EXAMPLE中未找到location / {}块"
        exit 1
    fi
else
    log_info "站点国家拦截逻辑已存在，跳过"
fi

# 检查并添加403页面location配置
if ! grep -q "location\s*=\s*$ERROR_PAGE_PATH" "$SITE_CONF_EXAMPLE"; then
    if grep -q "^server\s*{" "$SITE_CONF_EXAMPLE"; then
        error_page_escaped=$(printf '%s\n' "$ERROR_PAGE_PATH" | sed 's:[\/&]:\\&:g')
        page_root_escaped=$(printf '%s\n' "$PAGE_ROOT" | sed 's:[\/&]:\\&:g')
        sudo sed -i '/^server\s*{/a\    location = '"$error_page_escaped"' {\n        root '"$page_root_escaped"';\n        internal;\n        ssi on;\n    }' "$SITE_CONF_EXAMPLE"
        log_info "已添加403页面location配置"
    else
        log_error "$SITE_CONF_EXAMPLE中未找到server{}块"
        exit 1
    fi
else
    log_info "403页面location配置已存在，跳过"
fi

# 12. 创建 403 页面
echo -e "\n12. 创建 403 页面..."
sudo mkdir -p "$PAGE_ROOT"
if [ ! -f "$PAGE_ROOT/403.html" ]; then
    sudo cat > "$PAGE_ROOT/403.html" << 'EOF'
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
EOF
    sudo chmod 644 "$PAGE_ROOT/403.html"
    log_info "403页面已创建"
else
    log_info "403页面已存在，跳过创建"i

# 13. 测试并重启
echo -e "\n13. 测试 Nginx 配置..."
if sudo nginx -t; then
    sudo systemctl restart nginx
    log_info "Nginx配置测试通过，已重启"
else
    log_error "Nginx配置测试失败，请检查配置文件"
    exit 1
fi

# 清理
echo -e "\n14. 清理临时文件..."
sudo rm -rf /tmp/nginx* /tmp/"$MODULE_NAME"

echo -e "\n========================================"
log_info "安装完成！GeoIP 模式已生效"
log_info "中国IP拦截 + Cloudflare真实IP 正常工作"
echo "========================================"