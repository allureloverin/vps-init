# GitHub 发布与维护

项目已发布到公开仓库：[allureloverin/vps-init](https://github.com/allureloverin/vps-init)，默认分支为 `main`。

2026-10-15 已确认仓库及脚本可通过 GitHub 连接读取，raw 脚本地址返回的内容与仓库中的脚本一致。

## 在线运行

在目标 VPS 的 **root Bash 终端**执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/allureloverin/vps-init/main/vps-init.sh)
```

VPS 需要已安装 curl 和 CA 证书。脚本会更新系统软件包并配置北京时间及 NTP，成功后显示 DDNS 和 TCP 调优菜单。

## 下载与维护

在开发电脑上克隆仓库：

```bash
git clone https://github.com/allureloverin/vps-init.git
cd vps-init
```

在 Linux/Bash 环境中修改后，执行检查：

```bash
bash -n vps-init.sh
python3 -m unittest discover -s tests -v
```

检查通过后提交并上传：

```bash
git add .
git commit -m "Describe the change"
git push origin main
```

本地 Git 推送需要 GitHub 登录授权。当前聊天的 GitHub 连接可读取仓库，但写入接口返回 403；可通过 GitHub 网页编辑或上传文件。

## 验证范围

- 当前 Windows 环境已通过 Bash 语法检查和 12 项隔离测试（8 项初始化测试、4 项 DDNS 安装恢复测试）。
- 原有 11 项 DDNS worker 测试本次未在 Windows 重跑；迁移前的交接记录报告通过。
- 完整项目包含 `tests/test_vps_init.py` 和 `.github/workflows/test.yml`，请连同目录上传。配置在 Ubuntu 22.04、24.04 上执行全部 23 项测试。
- 最新远端执行结果以 [GitHub Actions](https://github.com/allureloverin/vps-init/actions) 为准。
- 尚未在真实 VPS 上验证系统升级、校时及使用真实 Cloudflare Token 更新 DNS。脚本下载地址可用不代表已完成实机验证。
