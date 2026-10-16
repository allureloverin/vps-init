# GitHub 发布与维护

仓库：[allureloverin/vps-init](https://github.com/allureloverin/vps-init)，默认分支 `main`。

在目标 VPS 的 root Bash 终端运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/allureloverin/vps-init/main/vps-init.sh)
```

新机须已有 curl 和 CA 证书。也可以下载 `vps-init.sh` 后用 `sudo bash vps-init.sh` 执行。

当前版本依次执行指定的 apt 命令、北京时间与 NTP/RTC 设置，全部成功后只询问是否运行 tcpfit。选否或回车直接退出。

在开发电脑上更新：

```bash
git clone https://github.com/allureloverin/vps-init.git
cd vps-init
# 已克隆时，在自己的工作目录确认本地修改后使用 git pull。
bash -n vps-init.sh
python3 -m unittest discover -s tests -v
git add vps-init.sh README.md HANDOFF.md PUBLISH.md tests/test_vps_init.py
git commit -m "Describe the change"
git push origin main
```

当前版本已通过本地 Bash 语法检查和 18 项模拟测试，覆盖 apt 失败、四项时间状态、NTP 服务补装、已有 NTP 服务报错时不自动替换、是/否分支，以及调优下载失败、内容不完整、语法错误和超时设置。测试不在开发电脑上修改系统设置。

仓库的 GitHub Actions 配置在 Ubuntu 22.04、24.04 上执行测试，运行状态以 [Actions 页面](https://github.com/allureloverin/vps-init/actions) 为准。实际 VPS 的软件安装、NTP 联网同步和 tcpfit 调优效果尚需部署验证。
