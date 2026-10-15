# GitHub 发布准备

目标仓库：`allureloverin/vps-init`，计划使用 `main` 分支。

截至 2026-10-15，当前 GitHub 连接已确认账号为 `allureloverin`，读取目标仓库时返回 404。仓库可能尚未创建，也可能未向连接授权；当前没有执行远端创建或上传。

## 当前验证

- Bash 语法检查通过。
- 当前 Windows 环境通过 12 项隔离测试（8 项初始化测试、4 项 DDNS 安装恢复测试）。
- 原有 11 项 DDNS worker 测试本次未重跑。交接记录报告迁移前通过。
- GitHub Actions 配置会在 Ubuntu 22.04、24.04 上运行全部 23 项测试；尚未在远端执行。
- 未在真实 VPS 上升级系统、校时或修改真实 Cloudflare DNS。

## 创建仓库

在 GitHub 登录 `allureloverin`，打开：

[创建 vps-init 仓库](https://github.com/new?name=vps-init&description=VPS%20initialization%20and%20Cloudflare%20DDNS)

选择 Public，保持空仓库，不自动添加 README、.gitignore 或许可证，然后创建。如果目标仓库已经存在，先确认访问权限及现有内容，不要覆盖或强制推送。

## 从本机上传

本机项目目录已经初始化 Git，并设置 `origin` 为 `https://github.com/allureloverin/vps-init.git`。在该项目目录打开 PowerShell：

```powershell
git status --short
git remote -v
git push -u origin main
```

推送需要 Git 自己的 GitHub 登录授权；聊天内的 GitHub 连接不会自动向本地 Git 提供凭证。不要将 Token 写进远程 URL、代码或聊天。

如使用其他电脑，可先恢复旁边提供的 Git bundle：

```powershell
git clone -b main ./vps-init-ready-20261015.bundle vps-init
cd vps-init
git remote set-url origin https://github.com/allureloverin/vps-init.git
git push -u origin main
```

如果使用源码 ZIP，解压后需自行 `git init -b main`、添加文件并提交，再添加上述远程地址。

## 发布核对

推送后打开仓库的 Actions，等待两套 Ubuntu 测试全部通过。再确认 `main` 中的 `vps-init.sh` 可从 raw 地址下载，并在测试 VPS 中验证。下面的地址是发布后的预期地址，当前未验证可用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/allureloverin/vps-init/main/vps-init.sh)
```

该命令在目标 VPS 的 root Bash 终端执行，会更新系统软件包及修改时间设置。先审阅脚本，再运行。

项目尚未指定开源许可证；公开仓库不等于已授予开源许可证，后续可由项目所有者选择。
