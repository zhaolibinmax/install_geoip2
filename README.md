# LibreSpeed + GeoIP2 一键部署脚本
一键部署 LibreSpeed 测速服务 + Nginx GeoIP2 地域访问限制，支持 Cloudflare 真实 IP 还原。

## 📝 说明

仅支持 Debian / Ubuntu

必须以 root 权限运行

GeoIP2 数据库自动下载，失败可手动从 MaxMind 获取

使用 Cloudflare 需将域名解析接入 CF

## ⚡ 快速部署
一键运行

服务器终端直接复制执行以下命令，全程按交互提示操作即可：

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/zhaolibinmax/install_geoip2/refs/heads/main/librespeed_geoip2.sh)"
```

测试

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/zhaolibinmax/install_geoip2/refs/heads/main/test.sh)"
```

# 🧑‍💻 作者
GitHub：zhaolibinmax

# 📜 许可证
本项目无许可证限制，可自由使用、修改、分发，用于个人 / 商业场景均可。
