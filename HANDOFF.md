# 项目交接

## 当前完成情况

项目是面向新 VPS 的单文件 Bash 初始化工具，入口为 `vps-init.sh`。

必须按顺序完成：

1. 更新系统、安装常用工具。
2. 设置北京时间 `Asia/Shanghai`，启用 chrony，并检查 NTP 启用、服务运行和系统实际同步状态。任何一步失败均停止，不进入菜单。

随后进入交互菜单：

- `1`：配置 Cloudflare DDNS。直接在终端输入主域名、完整解析域名、记录类型、橙云状态和 API Token，不使用 ddns-go 网页。成功后安装 systemd 定时任务，每 5 分钟检查。
- `2`：下载并运行用户指定的 `https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh`，进入其交互菜单。
- `0`：退出。

支持使用 systemd 的 Debian/Ubuntu 和常见 RHEL 系发行版。DDNS 工作脚本嵌在初始化脚本中，在线运行不需要下载其他项目文件。

## 文件说明

- `vps-init.sh`：完整可运行脚本。
- `README.md`：运行方法、Cloudflare Token 权限、服务管理和故障处理。
- `tests/test_vps_init.py`：23 项测试，通过模拟网络与系统命令验证关键行为。
- `.github/workflows/test.yml`：Ubuntu 22.04、24.04 自动测试配置。

## 已验证与未验证

迁移前的交接记录报告：已通过 Bash 语法检查、原有 19 项模拟测试，以及使用 Bash 进程替换执行帮助入口的检查。

2026-10-15 在当前 Windows 电脑继续开发：修复 DDNS 安装中途失败后无法重试的问题。已有配置时，菜单 `1` 会沿用配置，验证成功后重新安装程序、服务和定时任务；仅残留服务文件时允许重新输入配置。新增 4 项回归测试，覆盖恢复、失败重试和验证失败不覆盖原安装。

当前电脑使用 Git 自带的 Bash（`sh.exe`）通过语法检查、原有 8 项初始化测试和新增 4 项恢复测试，共 12 项。测试入口通过临时适配脚本将 `bash` 命令映射到该 shell；未修改正式 Linux 测试入口。本机未安装 WSL，缺少 jq 等完整 Linux 依赖，原有 11 项 DDNS worker 测试本次未重跑。新添加的 GitHub Actions 配置尚未在远端执行；推送后需确认两套 Ubuntu 环境中的全部 23 项测试结果。

尚未在真实新 VPS 上执行系统升级和校时，也未使用真实 Cloudflare Token 更新真实 DNS。项目不包含真实 Token 或账号凭证。

在 Linux/Bash 环境中运行验证：

```bash
bash -n vps-init.sh
python3 -m unittest discover -s tests -v
```

测试依赖 Bash、Python 3、jq、curl、flock 等标准工具。Windows 上建议在 WSL 中开发和验证。脚本文件需保留 UTF-8 与 LF 换行。

## GitHub 发布状态

2026-10-15 已通过当前 GitHub 连接确认账号为 `allureloverin`；读取 `allureloverin/vps-init` 返回 404，当前连接未找到目标仓库。未创建或上传远程仓库。拟创建公开仓库 `allureloverin/vps-init`。前文出现的 `ibsgss/TcpQuality` 仅为运行命令形式的示例，不是本项目的目标仓库。

当前电脑已把 `outputs/vps-init` 初始化为独立 Git 仓库，分支为 `main`，远程 `origin` 指向上述地址。发布准备包含源码 ZIP、Git bundle 和 [PUBLISH.md](PUBLISH.md) 操作说明；提交身份使用 GitHub 的 noreply 邮箱。

本会话的 GitHub 连接可以操作用户已有仓库，但没有提供创建仓库接口。本机没有安装 GitHub CLI。可先通过 GitHub 网页创建空仓库，再在已有本地仓库中推送：

```bash
git push -u origin main
```

若目标仓库已经存在，先确认访问权限和已有内容。发布后再核对实际仓库地址和 `main` 分支中的脚本内容，等待 GitHub Actions 的两套 Ubuntu 测试通过。预期的一键运行命令如下，目前该地址尚未验证可用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/allureloverin/vps-init/main/vps-init.sh)
```

该命令应在目标 VPS 的 root Bash 终端运行。运行前确保 curl 和 CA 证书已安装。
