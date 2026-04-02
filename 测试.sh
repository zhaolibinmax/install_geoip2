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
# 备份SITE_CONF
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
# 拦截国家代码全局变量
BLOCKED_COUNTRIES="CN"
# Cloudflare CDN 使用标记
USE_CLOUDFLARE=false
# 自定义域名全局变量默认值localhost
CUSTOM_DOMAIN="localhost"
# SSL 启用状态标记（全局作用域）
SSL_ENABLED=false

# ==================== 【新增】优化工具函数 ====================
# 端口占用检测
check_port_in_use() {
    local port=$1
    if ss -tulpn 2>/dev/null | grep -q ":$port "; then
        return 0 # 被占用
    elif netstat -tulpn 2>/dev/null | grep -q ":$port "; then
        return 0 # 被占用
    else
        return 1 # 未占用
    fi
}

# 国家代码格式校验 (ISO 3166-1 alpha-2)
validate_country_code() {
    local code=$1
    if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 域名合法性校验
validate_domain() {
    local domain=$1
    if [ "$domain" = "localhost" ] || [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 打印配置确认
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

# ==================== 【新增】命令行参数解析 ====================
SILENT_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            CUSTOM_DOMAIN="$2"
            shift 2
            ;;
        --port)
            SPEED_PORT="$2"
            shift 2
            ;;
        --cf)
            # 接受 true/false 或 yes/no
            if [[ "$2" =~ ^(true|yes|y|1)$ ]]; then
                USE_CLOUDFLARE=true
            else
                USE_CLOUDFLARE=false
            fi
            shift 2
            ;;
        --block-countries)
            BLOCKED_COUNTRIES="$2"
            shift 2
            ;;
        --silent)
            SILENT_MODE=true
            shift 1
            ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --domain <域名>        设置访问域名 (默认: localhost)"
            echo "  --port <端口>          设置测速端口 (默认: 56789)"
            echo "  --cf <true/false>      是否使用 Cloudflare (默认: true)"
            echo "  --block-countries <代码> 拦截国家代码，逗号分隔 (默认: CN)"
            echo "  --silent               静默模式，无交互直接执行"
            echo "  -h, --help             显示此帮助信息"
            exit 0
            ;;
        *)
            log_error "无效参数: $1 (使用 -h 查看帮助)"
            exit 1
            ;;
    esac
done

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
# 日志重定向
exec &> >(tee -a "$LOG_FILE")

# ==================== 【新增】优化后的配置逻辑入口 ====================
# ==================== 【新增】优化后的配置逻辑入口 ====================
if [ "$SILENT_MODE" = true ]; then
    log_info "✅ 静默模式启动"
    # 静默模式下的参数合法性强校验
    if ! validate_domain "$CUSTOM_DOMAIN"; then
        log_error "静默模式错误: 域名格式不合法 ($CUSTOM_DOMAIN)"
        exit 1
    fi
    # ========== 核心修改：localhost 自动禁用 Cloudflare ==========
    if [ "$CUSTOM_DOMAIN" = "localhost" ]; then
        USE_CLOUDFLARE=false
        log_info "✅ 域名为 localhost，自动禁用 Cloudflare CDN"
    fi
    
    if ! [[ "$SPEED_PORT" =~ ^[0-9]+$ ]] || [ "$SPEED_PORT" -lt 1 ] || [ "$SPEED_PORT" -gt 65535 ]; then
        log_error "静默模式错误: 端口不合法 ($SPEED_PORT)"
        exit 1
    fi
    if check_port_in_use "$SPEED_PORT"; then
        log_error "静默模式错误: 端口 $SPEED_PORT 已被占用"
        exit 1
    fi
    # 处理国家代码
    if [ -n "$BLOCKED_COUNTRIES" ]; then
        INPUT_BLOCK="$BLOCKED_COUNTRIES"
        BLOCKED_COUNTRIES_CLEAN=""
        INPUT_BLOCK_CLEAN=$(echo "$INPUT_BLOCK" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
        IFS=',' read -ra COUNTRY_ARR <<< "$INPUT_BLOCK_CLEAN"
        for c in "${COUNTRY_ARR[@]}"; do
            if [ -n "$c" ] && validate_country_code "$c"; then
                BLOCKED_COUNTRIES_CLEAN+="$c,"
            fi
        done
        BLOCKED_COUNTRIES=${BLOCKED_COUNTRIES_CLEAN%,}
        if [ -z "$BLOCKED_COUNTRIES" ]; then BLOCKED_COUNTRIES="CN"; fi
    fi
    print_config_summary
else
    # ==================== 【优化版】步骤1: 交互配置 ====================
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}   LibreSpeed + GeoIP2 一体化部署     ${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""

    # 1. 自定义域名输入
    echo -e "${GREEN}【1/4】基础配置 - 域名${NC}"
    while true; do
        read -p "$(echo -e "${YELLOW}请输入要配置的域名 ${BLUE}[默认: localhost]${NC}\n域名：")" INPUT_DOMAIN
        if [ -z "$INPUT_DOMAIN" ]; then
            CUSTOM_DOMAIN="localhost"
            break
        fi
        if validate_domain "$INPUT_DOMAIN"; then
            CUSTOM_DOMAIN="$INPUT_DOMAIN"
            break
        else
            log_error "错误：域名格式不合法！(例如: speed.test.com)"
            echo ""
        fi
    done
    log_info "✅ 确认使用域名：$CUSTOM_DOMAIN"
    echo ""

    # 2. 测速端口配置（含占用检测）
    echo -e "${GREEN}【2/4】基础配置 - 端口${NC}"
    while true; do
        read -p "$(echo -e "${YELLOW}请输入 LibreSpeed 测速服务端口 ${BLUE}[默认: $DEFAULT_SPEED_PORT]${NC}\n端口号：")" CUSTOM_PORT
        if [ -z "$CUSTOM_PORT" ]; then
            # 检测默认端口
            if check_port_in_use "$DEFAULT_SPEED_PORT"; then
                log_warn "⚠️ 默认端口 $DEFAULT_SPEED_PORT 已被占用，请手动指定端口"
                continue
            fi
            SPEED_PORT=$DEFAULT_SPEED_PORT
            break
        fi
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 1 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
            if check_port_in_use "$CUSTOM_PORT"; then
                log_error "错误：端口 $CUSTOM_PORT 已被占用！"
                ss -tulpn | grep ":$CUSTOM_PORT " 2>/dev/null | awk '{print "  占用进程:", $NF}' || echo "  请使用 lsof -i :$CUSTOM_PORT 查看详情"
                echo ""
                continue
            fi
            SPEED_PORT=$CUSTOM_PORT
            break
        else
            log_error "错误：端口必须是1-65535之间的纯数字！"
            echo ""
        fi
    done
    log_info "✅ 确认 LibreSpeed 端口：$SPEED_PORT"
    echo ""

    # ========== 核心修改：localhost 自动禁用 CDN，跳过选择 ==========
    if [ "$CUSTOM_DOMAIN" = "localhost" ]; then
        USE_CLOUDFLARE=false
        log_info "✅ 域名为 localhost，自动禁用 Cloudflare CDN"
        echo ""
    else
        # 3. Cloudflare CDN 使用确认（仅非localhost域名显示）
        echo -e "${GREEN}【3/4】网络配置 - Cloudflare${NC}"
        while true; do
            read -p "$(echo -e "${YELLOW}是否使用了 Cloudflare CDN？ ${BLUE}[默认: y]${NC}\n选择 (y/n)：")" CF_USE
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
                log_error "错误：请输入 y 或 n"
                echo ""
            fi
        done
        if [ "$USE_CLOUDFLARE" = true ]; then
            log_info "✅ 已配置：使用 Cloudflare CDN"
        else
            log_info "✅ 已配置：不使用 Cloudflare CDN"
        fi
        echo ""
    fi

    # 4. 自定义拦截国家代码
    echo -e "${GREEN}【4/4】安全配置 - 访问控制${NC}"
    echo -e "${YELLOW}📌 常用代码：CN(中国) US(美国) JP(日本) SG(新加坡)${NC}"
    while true; do
        read -p "$(echo -e "${YELLOW}请输入要拦截的国家代码 ${BLUE}[逗号分隔，默认: CN]${NC}\n代码：")" INPUT_BLOCK
        echo ""
        
        BLOCKED_COUNTRIES_CLEAN=""
        if [ -n "$INPUT_BLOCK" ]; then
            INPUT_BLOCK_CLEAN=$(echo "$INPUT_BLOCK" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
            IFS=',' read -ra COUNTRY_ARR <<< "$INPUT_BLOCK_CLEAN"
            local has_error=0
            for c in "${COUNTRY_ARR[@]}"; do
                if [ -n "$c" ]; then
                    if validate_country_code "$c"; then
                        BLOCKED_COUNTRIES_CLEAN+="$c,"
                    else
                        log_warn "⚠️ 忽略无效代码: '$c' (需为2位字母)"
                        has_error=1
                    fi
                fi
            done
            BLOCKED_COUNTRIES=${BLOCKED_COUNTRIES_CLEAN%,}
            
            if [ -z "$BLOCKED_COUNTRIES" ]; then
                log_warn "⚠️ 未输入有效代码，将使用默认值 CN"
                BLOCKED_COUNTRIES="CN"
            fi
        else
            BLOCKED_COUNTRIES="CN"
        fi
        break
    done
    log_info "✅ 确认拦截国家/地区：$BLOCKED_COUNTRIES"

    # 5. 最终确认
    print_config_summary
    while true; do
        read -p "$(echo -e "${YELLOW}确认配置无误？开始部署？ ${BLUE}[默认: y]${NC}\n选择 (y/n)：")" CONFIRM
        if [ -z "$CONFIRM" ] || [ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
            break
        elif [ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" = "n" ]; then
            log_info "🔄 脚本退出，请重新运行以配置"
            exit 0
        else
            log_error "请输入 y 或 n"
        fi
    done
fi

# ==================== 【原脚本逻辑】步骤2: 安装 LibreSpeed (Docker) ====================
# (此处原脚本代码完全保留，仅在容器逻辑处插入了优化检查)
log_info "===== 开始部署 LibreSpeed 测速服务 ====="
# 安装 Docker
echo -e "${YELLOW}[1/3] 正在安装 Docker 环境...${NC}"
if command -v docker &> /dev/null; then
    log_info "Docker 已安装，跳过安装步骤"
else
    curl -fsSL --connect-timeout 10 --max-time 30 https://get.docker.com | bash
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

# 【优化插入】容器存在性与端口一致性检查
if docker ps -a --format "{{.Names}}" | grep -q "^librespeed$"; then
    log_info "✅ LibreSpeed 容器已存在"
    # 检查端口映射是否一致
    local current_port=""
    current_port=$(docker inspect librespeed --format='{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{if eq .HostPort "'$SPEED_PORT'"}}{{$.HostPort}}{{end}}{{end}}{{end}}' 2>/dev/null || true)
    
    if [ -z "$current_port" ]; then
        log_warn "⚠️ 容器端口配置不匹配，正在重建容器..."
        docker stop librespeed >/dev/null 2>&1 || true
        docker rm librespeed >/dev/null 2>&1 || true
        # 重建
        docker run -d \
          --restart always \
          --name librespeed \
          -p 0.0.0.0:$SPEED_PORT:80 \
          adolfintel/speedtest
        log_info "✅ 容器重建完成"
    else
        # 确保容器在运行
        if ! docker ps --format "{{.Names}}" | grep -q "^librespeed$"; then
            docker start librespeed
            log_info "✅ 已启动原有容器"
        fi
    fi
else
    # 容器不存在，全新创建
    docker run -d \
      --restart always \
      --name librespeed \
      -p 0.0.0.0:$SPEED_PORT:80 \
      adolfintel/speedtest
    if [ $? -ne 0 ]; then
        log_error "LibreSpeed 容器启动失败！"
        exit 1
    fi
    log_info "✅ LibreSpeed 容器新建完成"
fi
log_info "✅ LibreSpeed 部署成功，访问地址：http://服务器IP:$SPEED_PORT"
echo ""

# ==================== 【原脚本逻辑】步骤3: 部署 GeoIP2 + Cloudflare 真实IP ====================
# (以下原脚本核心逻辑完全保留，未做任何修改)
log_info "===== 开始部署 GeoIP2 + Cloudflare 真实IP ====="
# 3.1 检测/安装 Nginx
log_info "1. 检测Nginx版本..."
if ! command -v nginx &> /dev/null; then
    log_warn "未安装Nginx，正在自动安装..."
    apt-get update -o Acquire::Timeout=300 -y
    apt-get install -y nginx
fi
NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -z "$NGINX_VERSION" ]; then
    log_error "无法识别Nginx版本"
    exit 1
fi
# Nginx模块路径兼容源码编译版本
NGINX_MODULES=$(nginx -V 2>&1 | grep -oP '(?<=--modules-path=)[^ ]+' || echo "/usr/lib/nginx/modules")
if [ ! -d "$NGINX_MODULES" ]; then
    NGINX_MODULES="/usr/lib/nginx/modules"
    mkdir -p "$NGINX_MODULES" && chmod 755 "$NGINX_MODULES"
fi
log_info "✅ Nginx版本: $NGINX_VERSION, 模块路径: $NGINX_MODULES"
# 3.2 安装系统依赖
log_info "2. 安装系统依赖..."
apt-get update -o Acquire::Timeout=300 -y
apt-get install -y build-essential libpcre3-dev zlib1-dev libmaxminddb-dev git curl libssl-dev
log_info "✅ 依赖安装完成"
# 3.3 备份nginx.conf + SITE_CONF
# 定义备份函数 (原脚本内联逻辑提取，为了兼容，这里重新定义一遍，或者原脚本有定义，这里保持原样)
# 为了确保原脚本函数可用，这里把原脚本缺失的函数头补在这，但逻辑不变
backup_nginx_config() {
    mkdir -p "$(dirname "$NGINX_CONF_BACKUP")"
    if cp "$NGINX_CONF" "$NGINX_CONF_BACKUP"; then
        log_info "✅ nginx.conf 备份完成: $NGINX_CONF_BACKUP"
    else
        log_error "nginx.conf备份失败，脚本退出"
        exit 1
    fi
    mkdir -p "$(dirname "$SITE_CONF_BACKUP")"
    if [ -f "$SITE_CONF" ]; then
        cp "$SITE_CONF" "$SITE_CONF_BACKUP"
        log_info "✅ geoip2-block.conf 备份完成: $SITE_CONF_BACKUP"
    else
        log_info "✅ geoip2-block.conf 不存在，跳过备份"
    fi
}
restore_nginx_config() {
    if [ -f "$NGINX_CONF_BACKUP" ]; then
        log_warn "正在从备份恢复nginx.conf..."
        cp "$NGINX_CONF_BACKUP" "$NGINX_CONF"
        log_info "✅ 已恢复: $NGINX_CONF_BACKUP"
    fi
    if [ -f "$SITE_CONF_BACKUP" ]; then
        log_warn "正在从备份恢复geoip2-block.conf..."
        cp "$SITE_CONF_BACKUP" "$SITE_CONF"
        log_info "✅ 已恢复: $SITE_CONF_BACKUP"
    fi
}
test_nginx_config() {
    if ! nginx -t 2>&1; then
        log_error "❌ Nginx配置测试失败!"
        return 1
    fi
    return 0
}

backup_nginx_config
# 3.4 下载Nginx源码
log_info "3. 准备Nginx源码..."
cd /tmp
if [ ! -f "nginx-$NGINX_VERSION.tar.gz" ]; then
    curl -s -L --connect-timeout 10 --max-time 30 https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz \
    -o nginx-$NGINX_VERSION.tar.gz
fi
if [ ! -d "nginx-$NGINX_VERSION" ]; then
    tar zxf nginx-$NGINX_VERSION.tar.gz
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
log_info "测试Nginx配置（加载模块后）..."
if ! test_nginx_config; then
    restore_nginx_config
    exit 1
fi
# 3.9 获取Cloudflare IP
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "8. 获取 Cloudflare IP 段..."
    CF_IPV4=$(curl -s --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
    CF_IPV6=$(curl -s --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v6 2>/dev/null || true)
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
# 3.10 确保 SITE_CONF 文件及父目录存在
log_info "9. 初始化站点配置文件..."
mkdir -p /etc/nginx/conf.d
if [ ! -f "$SITE_CONF" ]; then
    touch "$SITE_CONF"
    log_info "✅ 已创建空配置文件: $SITE_CONF"
fi
# 3.11 配置Cloudflare真实IP
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "10. 配置Cloudflare真实IP还原..."
    if ! grep -q "# Cloudflare RealIP Configuration" "$SITE_CONF"; then
        cat > "$TEMP_CONF" << EOL
# Cloudflare RealIP Configuration
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
EOL
        while IFS= read -r ip; do
            [ -n "$ip" ] && echo "set_real_ip_from $ip;" >> "$TEMP_CONF"
        done <<< "$CF_IPS"
        echo "" >> "$TEMP_CONF"
        cat "$TEMP_CONF" "$SITE_CONF" > "${SITE_CONF}.new"
        mv "${SITE_CONF}.new" "$SITE_CONF"
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
if [ ! -f "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" ]; then
    log_info "正在自动下载GeoIP2数据库..."
    mkdir -p "$GEOIP_DB_PATH"
    curl -s -L --connect-timeout 10 --max-time 30 https://github.com/zhaolibinmax/install_geoip2/raw/refs/heads/main/GeoLite2-Country.mmdb \
    -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" || {
    log_warn "下载失败，尝试GitHub源1..."
    curl -s -L --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/P3TERX/GeoLite2-Database/master/GeoLite2-Country.mmdb \
        -o "$GEOIP_DB_PATH/GeoLite2-Country.mmdb" || {
            log_error "自动下载失败，请手动下载：https://www.maxmind.com/en/geolite2-free-geolocation-data 至/usr/share/GeoIP"
            restore_nginx_config
            exit 1
    }
}
fi
log_info "✅ GeoIP数据库检查完成"
# 3.13 生成GeoIP2拦截规则
log_info "12. 配置国家拦截规则..."
sed -i '/geoip2.*GeoLite2-Country.mmdb/,/}/d' "$SITE_CONF"
sed -i '/map.*geoip2_country_code/,/}/d' "$SITE_CONF"
cat > "$TEMP_CONF" << EOL
# GeoIP2 Country Configuration
geoip2 $GEOIP_DB_PATH/GeoLite2-Country.mmdb {
    auto_reload 5m;
    \$geoip2_country_code country iso_code;
}
map \$geoip2_country_code \$allowed_country {
    default yes;
EOL
IFS=',' read -ra COUNTRY_ARR <<< "$BLOCKED_COUNTRIES"
for c in "${COUNTRY_ARR[@]}"; do
    echo "    $c no;" >> "$TEMP_CONF"
done
echo "}" >> "$TEMP_CONF"
echo "" >> "$TEMP_CONF"
cat "$TEMP_CONF" "$SITE_CONF" > "${SITE_CONF}.new"
mv "${SITE_CONF}.new" "$SITE_CONF"
rm -f "$TEMP_CONF"
log_info "✅ GeoIP2国家拦截配置成功"
log_info "测试Nginx配置（GeoIP2拦截）..."
if ! test_nginx_config; then
    restore_nginx_config
    exit 1
fi
# 3.14 创建/完善 site 配置文件
log_info "13. 检查并完善站点Server配置..."
if ! grep -q "server {" "$SITE_CONF"; then
    SSL_CONFIG=""
    QUIC_CONFIG=""
    SSL_ENABLED=false
    if [ "$CUSTOM_DOMAIN" != "localhost" ]; then
        CERT_FILE="/etc/letsencrypt/live/$CUSTOM_DOMAIN/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/$CUSTOM_DOMAIN/privkey.pem"
        if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
            SSL_ENABLED=true
            SSL_CONFIG="    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
            if nginx -V 2>&1 | grep -q "http_v3_module"; then
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
            log_warn "⚠️ 未找到 SSL 证书文件，自动跳过 SSL/HTTPS 配置"
            SSL_CONFIG=""
            QUIC_CONFIG=""
            SSL_ENABLED=false
        fi
    else
        log_warn "⚠️ 域名为 localhost，跳过 SSL/QUIC 配置"
        SSL_CONFIG=""
        QUIC_CONFIG=""
        SSL_ENABLED=false
    fi
    if [ "$SSL_ENABLED" = true ]; then
        cat >> "$SITE_CONF" << SITEEOF
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
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
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
        log_info "✅ site配置文件创建完成（已启用SSL）"
    else
        cat >> "$SITE_CONF" << SITEEOF
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
        log_info "✅ site配置文件创建完成（未启用SSL）"
    fi
else
    log_info "${YELLOW}✅ site配置文件已存在，正在更新域名与端口...${NC}"
    sed -i "s/server_name _;/server_name $CUSTOM_DOMAIN;/g" "$SITE_CONF"
    sed -i "s/server_name localhost;/server_name $CUSTOM_DOMAIN;/g" "$SITE_CONF"
    sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:$SPEED_PORT;|g" "$SITE_CONF"
    log_info "✅ 配置更新完成，请手动检查确认"
fi
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
if systemctl is-active --quiet nginx || service nginx status | grep -q "running"; then
    log_info "✅ Nginx已成功重启"
else
    log_error "❌ Nginx未成功启动"
    restore_nginx_config
    exit 1
fi
# 3.17 清理临时文件
log_info "17. 清理临时文件..."
if [ -n "$NGINX_VERSION" ] && [ -d "/tmp/nginx-$NGINX_VERSION" ]; then
    rm -rf "/tmp/nginx-$NGINX_VERSION"
    rm -f "/tmp/nginx-$NGINX_VERSION.tar.gz"
fi
[ -d "/tmp/$MODULE_NAME" ] && rm -rf "/tmp/$MODULE_NAME"
[ -e "$TEMP_CONF" ] && rm -f "$TEMP_CONF"
[ -e "${SITE_CONF}.new" ] && rm -f "${SITE_CONF}.new"
log_info "✅ 清理完成"

# ==================== 完成 ====================
echo ""
echo "========================================"
log_info "✅ 一体化脚本执行完成！"
log_info "✅ 功能1：LibreSpeed 测速服务（端口：$SPEED_PORT）"
if [ "$USE_CLOUDFLARE" = true ]; then
    log_info "✅ 功能2：Cloudflare真实IP + GeoIP2 国家拦截（拦截：$BLOCKED_COUNTRIES）"
else
    log_info "✅ 功能2：GeoIP2 国家拦截（拦截：$BLOCKED_COUNTRIES）"
fi
log_info "✅ 功能3：自定义域名配置（域名：$CUSTOM_DOMAIN）"
log_info "✅ 备份位置：$NGINX_CONF_BACKUP | $SITE_CONF_BACKUP"
log_info "✅ 日志文件：$LOG_FILE"
echo "========================================"
echo ""
log_info "LibreSpeed 直连访问地址：http://服务器IP:$SPEED_PORT"
if [ "$SSL_ENABLED" = true ] && [ "$CUSTOM_DOMAIN" != "localhost" ]; then
    log_info "域名访问地址：https://$CUSTOM_DOMAIN"
elif [ "$CUSTOM_DOMAIN" != "localhost" ]; then
    log_info "域名访问地址：http://$CUSTOM_DOMAIN"
else
    log_info "⚠️ 域名为localhost，仅支持直连访问"
fi
