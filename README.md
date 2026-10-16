# 新 VPS 初始化（2026-10-16 简化版）

在 Debian/Ubuntu 新 VPS 的 root SSH 终端运行：

```bash
bash vps-init.sh
```

普通用户可使用 `sudo bash vps-init.sh`。需要 apt、运行中的 systemd 和交互终端。

脚本按以下顺序执行：

1. 执行用户指定的命令：

   ```bash
   apt update -y && apt install curl wget -y
   ```

2. 设置 `Asia/Shanghai`、将 RTC 设置为 UTC、启用 NTP。优先使用已有的时间同步服务；缺少时自动补装 `systemd-timesyncd`，缺少时区数据时补装 `tzdata`。最多等待 120 秒，检查四项实际状态，全部通过后显示真实的 `timedatectl status`：

   ```text
   Time zone: Asia/Shanghai (CST, +0800)
   System clock synchronized: yes
   NTP service: active
   RTC in local TZ: no
   ```

3. 询问 `是否运行 TCP 调优脚本？[y/N]`。输入 `n`、`否` 或直接回车，立即结束；输入 `y` 或 `是`，运行以下地址的脚本：

   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh)
   ```

   实现中先检查下载成功且内容非空，再用 Bash 进程替换执行同一份脚本。进入 tcpfit 的交互界面后，按其提示操作；退出 tcpfit 后本脚本结束。

apt 或校时失败时立即停止，不询问调优。当前版本仅更新软件包索引并安装所需组件，不执行 `apt upgrade`，没有 DDNS 菜单。

## 在线运行

脚本是独立文件，发布到公开地址后可在 root Bash 终端运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/allureloverin/vps-init/main/vps-init.sh)
```

仓库为 [allureloverin/vps-init](https://github.com/allureloverin/vps-init)，默认分支为 `main`。新机使用在线入口前须已有 curl 和 CA 证书；也可上传文件后直接运行。

## 开发验证

```bash
bash -n vps-init.sh
python3 -m unittest discover -s tests -v
```

测试使用模拟系统命令和模拟下载，不会修改宿主系统或执行真实调优。真实 VPS 的软件安装和联网校时尚需部署验证。
