#!/bin/bash
set -e

##############################################################################
# 使用本地 GeoIP 数据库
##############################################################################

NGINX_VERSION="1.28.3"
MODULE_NAME="ngx_http_geoip2_module"
MODULE_GIT_URL="https://github.com/leev/ngx_http_geoip2_module.git"
GEOIP_DB_PATH="/usr/share/GeoIP"
NGINX_MODULES_PATH=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "/usr/lib/nginx/modules")
NGINX_CONF="/etc/nginx/nginx.conf"
SITE_CONF_EXAMPLE="/etc/nginx/conf.d/1.conf"
ERROR_PAGE_PATH="/403.html"
PAGE_ROOT="/var/www/html"

# Cloudflare 官方 IP 段 (最新完整版)
CF_IP_RANGES=(
    "173.245.48.0/20"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "141.101.64.0/18"
    "108.162.192.0/18"
    "190.93.240.0/20"
    "188.114.96.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
    "162.158.0.0/15"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "172.64.0.0/13"
    "131.0.72.0/22"
    "2400:cb00::/32"
    "2606:4700::/32"
    "2803:f800::/32"
    "2405:b500::/32"
    "2405:8100::/32"
    "2a06:98c0::/29"
    "2c0f:f248::/32"
)

echo "========================================"
echo "开始安装 Nginx GeoIP2 模块"
echo "========================================"

# 1. 安装依赖
echo -e "\n1. 安装依赖..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ $ID == "ubuntu" || $ID == "debian" ]]; then
        sudo apt update -y
        sudo apt install -y build-essential libpcre3-dev zlib1g-dev libmaxminddb-dev git nginx
    elif [[ $ID == "centos" || $ID == "rhel" || $ID == "rocky" ]]; then
        sudo yum install -y gcc make pcre-devel zlib-devel libmaxminddb-devel git nginx
    fi
fi

# 2. 下载 Nginx 源码
echo -e "\n2. 下载 Nginx 源码..."
cd /tmp
[ ! -f "nginx-$NGINX_VERSION.tar.gz" ] && wget http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -q
[ ! -d "nginx-$NGINX_VERSION" ] && tar -zxvf nginx-$NGINX_VERSION.tar.gz > /dev/null

# 3. 下载模块
echo -e "\n3. 下载 GeoIP2 模块..."
[ ! -d "/tmp/$MODULE_NAME" ] && git clone $MODULE_GIT_URL /tmp/$MODULE_NAME -q

# 4. 编译模块
echo -e "\n4. 编译模块..."
cd /tmp/nginx-$NGINX_VERSION
./configure --with-compat --add-dynamic-module=/tmp/$MODULE_NAME > /dev/null
make modules > /dev/null

# 5. 安装模块
echo -e "\n5. 安装模块..."
sudo cp objs/${MODULE_NAME}.so $NGINX_MODULES_PATH/
sudo chmod 644 $NGINX_MODULES_PATH/${MODULE_NAME}.so

# 6. 加载模块
echo -e "\n6. 加载模块..."
if ! grep -q "load_module modules/${MODULE_NAME}.so;" $NGINX_CONF; then
    sudo sed -i '1i load_module modules/'"${MODULE_NAME}"'.so;' $NGINX_CONF
fi

# 7. Cloudflare 真实IP配置
echo -e "\n7. 配置 Cloudflare 真实IP..."
if ! grep -q "CF-Connecting-IP" $NGINX_CONF; then
    sudo sed -i '/^http {/a \
    # Cloudflare 真实IP配置 \
    real_ip_header CF-Connecting-IP; \
    real_ip_recursive on; \
' $NGINX_CONF

    for ip in "${CF_IP_RANGES[@]}"; do
        sudo sed -i '/real_ip_recursive on;/a \
    set_real_ip_from '"$ip"'; \
' $NGINX_CONF
    done
fi

# 8. 使用本地文件
echo -e "\n8. 检查本地 GeoIP 数据库..."
if [ ! -f "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" ]; then
    echo "⚠️  警告：未找到本地数据库文件 $GEOIP_DB_PATH/GeoLite2-Country.mmdb"
    echo "请手动上传该文件后再继续！"
    exit 1
else
    echo "✅ 本地 GeoIP 数据库已存在，直接使用"
fi

# 9. GeoIP2 规则
echo -e "\n9. 配置国家拦截规则..."
if ! grep -q "geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb" $NGINX_CONF; then
    sudo sed -i '/^http {/a \
    geoip2 '"$GEOIP_DB_PATH"'/GeoLite2-Country.mmdb { \
        auto_reload 5m; \
        $geoip2_country_code country iso_code; \
    } \
    map $geoip2_country_code $allowed_country { \
        default yes; \
        CN      no; \
    } \
' $NGINX_CONF
fi

# 10. 站点配置
echo -e "\n10. 配置站点拦截..."
if ! grep -q "error_page 403 $ERROR_PAGE_PATH;" $SITE_CONF_EXAMPLE; then
    sudo sed -i '/^server {/a \
    fastcgi_intercept_errors on; \
    error_page 403 '"$ERROR_PAGE_PATH"'; \
' $SITE_CONF_EXAMPLE
fi

if ! grep -q '$allowed_country = no' $SITE_CONF_EXAMPLE; then
    sudo sed -i '/location \/ {/a \
        if ($allowed_country = no) { \
            return 403; \
        } \
' $SITE_CONF_EXAMPLE
fi

if ! grep -q "location = $ERROR_PAGE_PATH" $SITE_CONF_EXAMPLE; then
    sudo sed -i '/^server {/a \
    location = '"$ERROR_PAGE_PATH"' { \
        root '"$PAGE_ROOT"'; \
        internal; \
        ssi on; \
    } \
' $SITE_CONF_EXAMPLE
fi

# 11. 403页面
echo -e "\n11. 创建 403 页面..."
sudo mkdir -p $PAGE_ROOT
sudo cat > $PAGE_ROOT/403.html << EOF
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
sudo chmod 644 $PAGE_ROOT/403.html

# 12. 测试并重启
echo -e "\n12. 测试 Nginx 配置..."
sudo nginx -t
sudo systemctl restart nginx

# 清理
echo -e "\n13. 清理临时文件..."
sudo rm -rf /tmp/nginx* /tmp/$MODULE_NAME

echo -e "\n========================================"
echo "✅ 安装完成！GeoIP 模式已生效"
echo "✅ 中国IP拦截 + Cloudflare真实IP 正常工作"
echo "========================================"