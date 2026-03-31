#!/bin/bash
# Docker + LibreSpeed 一键安装脚本 | 支持自定义端口
# 适配 CentOS / Ubuntu / Debian

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查 root 权限
if [ $EUID -ne 0 ]; then
    echo -e "${RED}请使用 root 权限运行！${NC}"
    exit 1
fi

clear
echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}   LibreSpeed 测速服务 一键部署      ${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""

# ====================== 交互选择端口 ======================
echo -e "${YELLOW}请输入你要使用的端口 [默认: 56789]${NC}"
read -p "端口号：" CUSTOM_PORT

# 如果用户没输入，使用默认端口
if [ -z "$CUSTOM_PORT" ]; then
    CUSTOM_PORT=56789
fi

# 简单验证端口是否为数字
if ! [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}错误：端口必须是纯数字！${NC}"
    exit 1
fi

echo -e "${GREEN}你选择的端口：$CUSTOM_PORT${NC}"
echo ""

# ====================== 安装 Docker ======================
echo -e "${YELLOW}[1/3] 正在安装 Docker 环境...${NC}"
curl -fsSL https://get.docker.com | bash >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}Docker 安装失败，请检查网络！${NC}"
    exit 1
fi

# ====================== 启动 Docker ======================
echo -e "${YELLOW}[2/3] 启动 Docker 并设置开机自启...${NC}"
systemctl enable docker >/dev/null 2>&1
systemctl start docker >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}Docker 启动失败！${NC}"
    exit 1
fi

# ====================== 部署 LibreSpeed ======================
echo -e "${YELLOW}[3/3] 部署 LibreSpeed 容器...${NC}"

# 删除旧容器（防止重复运行报错）
docker rm -f librespeed >/dev/null 2>&1

# 启动容器
docker run -d \
  --restart always \
  --name librespeed \
  -p 0.0.0.0:$CUSTOM_PORT:80 \
  adolfintel/speedtest >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}          部署成功！🎉${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo -e "访问地址：${BLUE}http://服务器IP:$CUSTOM_PORT${NC}"
    echo ""
    echo -e "管理命令："
    echo -e "  查看状态：${GREEN}docker ps | grep librespeed${NC}"
    echo -e "  停止服务：${GREEN}docker stop librespeed${NC}"
    echo -e "  启动服务：${GREEN}docker start librespeed${NC}"
    echo -e "  删除服务：${GREEN}docker rm -f librespeed${NC}"
    echo ""
else
    echo -e "${RED}容器启动失败！${NC}"
    exit 1
fi