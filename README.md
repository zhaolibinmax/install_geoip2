⚡ 快速部署
一键运行（推荐）
服务器终端直接复制执行以下命令，全程按交互提示操作即可：
bash
运行
curl -sSL https://raw.githubusercontent.com/zhaolibinmax/install_geoip2/refs/heads/main/install_librespeed.sh | sudo bash
备用运行方法（若一键命令报错）
适用于部分服务器网络限制或 curl 异常场景：
bash
运行
# 下载脚本到服务器本地
wget -O install_librespeed.sh https://raw.githubusercontent.com/zhaolibinmax/install_geoip2/refs/heads/main/install_librespeed.sh
# 给脚本添加执行权限
chmod +x install_librespeed.sh
# root 权限运行脚本
sudo ./install_librespeed.sh
