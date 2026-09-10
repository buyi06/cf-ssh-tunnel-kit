# cf-ssh-tunnel-kit

> **无显示器 Linux 的全中文 Cloudflare SSH Tunnel 一键部署工具。** 执行一条命令，自动安装 `cloudflared`（已安装则跳过）、终端显示浏览器授权链接、填写域名后自动创建 Tunnel、DNS 路由、SSH 配置和托管服务：有正在运行的 systemd 时创建 systemd 服务，Docker 容器、DSW/Colab、WSL 等没有 systemd 的环境自动改用独立后台进程。

它适合家用 Linux、小主机、NAS、树莓派、没有公网入站 IP 的云服务器，以及 ModelScope DSW 这类只有容器的开发环境。脚本只把 Cloudflare Tunnel 接到本机 `ssh://localhost:22`，不会开放服务器入站 `22` 端口，也不创建裸 TCP SSH 公网转发。

为了装完就能登，脚本会做一次 SSH 登录体检：账户没有公钥也没有可用密码时生成一个随机密码；sshd 禁止密码登录时会**先问一句**（或加 `--allow-password` 免问），同意后才写入 `sshd_config.d` 下的独立文件放行，写入前备份、`sshd -t` 校验不通过立即回滚，`credentials` 里可随时看到还原方式。

## 一条命令开始

```bash
git clone https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash start.sh
```

[`start.sh`](start.sh) 是一键启动脚本：**更新代码 → 首次安装（含浏览器授权）→ 服务没在跑就拉起 → 打印可直接复制的 SSH 连接信息**，可以反复执行。

| 执行时的状态 | `sudo bash start.sh` 会做什么 |
|---|---|
| 首次运行 | 安装 cloudflared、给出授权链接、创建 Tunnel 与 DNS 路由、启动托管服务 |
| 已安装且服务在运行 | 只更新代码并重新打印连接信息，不动现有 Tunnel |
| 已安装但服务没跑（容器重启后等） | 自动拉起 Tunnel，再打印连接信息 |

可选参数：`--auto` / `--quic` 切换传输协议（默认 `--mainland`），`--no-update` 跳过代码更新。

> 不想用一键脚本时，等价的手工命令是 `sudo bash scripts/cf-ssh-tunnel.sh install --mainland`；已安装过时该命令会直接加载现有配置，不会重复安装。

中国大陆直连 `github.com` 超时（出现 `Failed to connect to github.com port 443`）时，第一次克隆改用加速地址即可，**不需要**再手工切换 `origin`：

```bash
git clone https://gh-proxy.org/https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash start.sh
```

> `start.sh` 每次运行都会先探测直连，连不通才自动测速并**临时**借用加速代理拉取代码（不写入全局 Git 配置、不改动 `origin`），因此之后的更新也不用再手工处理。

执行后，脚本会按中文提示完成以下流程：

| 步骤 | 你需要做什么 | 脚本自动完成什么 |
|---|---|---|
| 1. 检查环境 | 无需操作。 | 检查本机 SSH、DNS、Cloudflare TCP/7844；检测 `cloudflared`，未安装时自动安装。 |
| 2. Cloudflare 授权 | 复制终端显示的 `https://...` 链接，在任意浏览器打开并选择站点。 | 等待授权成功，不需要服务器显示器。 |
| 3. 填写域名 | 输入完整域名，例如 `ssh.example.com`。 | 创建 Tunnel、自动写 DNS CNAME、生成 `ssh://localhost:22` ingress、校验配置、启动托管服务。 |
| 4. 直接连接 | 照抄终端打印的信息即可。 | 打印域名、登录用户、认证方式（已授权公钥指纹，或新生成的密码）和三种可直接复制的连接方式。 |

> **登录信息全在最后一段输出里**：服务器地址、用户名、认证方式（公钥指纹 / 密码），以及「一条命令直连」「写进 `~/.ssh/config`」「改用密钥」三种做法。如果该账户既没有公钥也没有可用密码，脚本会生成一个 16 位随机密码、写入本机 `/etc/shadow` 并**只打印这一次**（不会落到任何文件）；已经有公钥时不会碰密码。随时可以重新查看或重置：
>
> ```bash
> sudo bash scripts/cf-ssh-tunnel.sh credentials                # 域名、用户、认证方式、已授权公钥指纹
> sudo bash scripts/cf-ssh-tunnel.sh credentials --set-password # 生成新密码并打印
> sudo bash scripts/cf-ssh-tunnel.sh credentials --set-password --allow-password  # sshd 禁止密码登录时一并放行
> ```

> `--mainland` 使用 HTTP/2/TCP 7844，适合 UDP/QUIC 不稳定的网络。它不保证任何网络一定可连，也不会绕过网络限制。默认 `--auto` 会优先 QUIC，失败时回退 HTTP/2。[1]

在 `--mainland` 模式下，脚本还会自动测速 `gh-proxy.org`、`v4.gh-proxy.org`、`v6.gh-proxy.org`、`cdn.gh-proxy.org` 和 `axisnow.gh-proxy.org`，选择可用且延迟最低者，并为当前管理员账户写入 Git 的 GitHub URL 重写规则。它只影响 Git 的 `https://github.com/` 克隆和拉取（`git push` 不受影响，仍直连 GitHub），不设置 `HTTP_PROXY` / `HTTPS_PROXY`，不会代理 apt、Cloudflare 授权、Tunnel 或系统其他流量。

如果 Debian amd64 主机尚未安装 `cloudflared`，同一次测速还会挑选能够透传 Cloudflare 官方 GitHub Release `.deb` 包的最快代理。脚本先从 GitHub 官方 Release 页面取得版本和 SHA-256，再下载代理文件、校验 SHA-256、校验 Debian 包结构，**全部通过才安装**；任一步失败都会改用 Cloudflare 官方签名 APT 软件源。可随时重新测速或关闭 Git 加速：

```bash
sudo bash scripts/cf-ssh-tunnel.sh github-proxy
sudo bash scripts/cf-ssh-tunnel.sh github-proxy --disable
```

## 没有 systemd 的环境（容器 / DSW / Colab / WSL）

脚本不需要 systemd。检测不到正在运行的 systemd 时，它会自动改用**后台进程模式**托管 Tunnel：

| 项目 | systemd 模式 | 进程模式（容器等） |
|---|---|---|
| 启动方式 | 受限 systemd 服务，开机自启 | `setsid` 启动的看护进程 `run.sh`，脱离终端会话 |
| 运行账户 | 专用 `cf-ssh-tunnel` 系统账户 | 当前 root |
| 凭据权限 | `0640 root:cf-ssh-tunnel` | `0600 root:root` |
| 崩溃自愈 | `Restart=on-failure` | 看护进程自动重启 Tunnel（5 秒起、最长 60 秒） |
| 重启后 | 开机自启 | 首次登录 shell 自动拉起，也可手动 `restart` |
| 运行状态 | `systemctl status` | 看护进程 PID 文件 `/etc/cf-ssh-tunnel/tunnel.pid` |
| 日志 | `journalctl -u cf-ssh-tunnel` | `/etc/cf-ssh-tunnel/tunnel.log` |

```bash
sudo bash start.sh                                  # 一键：更新代码 + 拉起 Tunnel + 打印连接信息
sudo bash scripts/cf-ssh-tunnel.sh restart          # 只重启 Tunnel 服务
sudo bash scripts/cf-ssh-tunnel.sh logs             # 查看最近 80 行日志
sudo bash scripts/cf-ssh-tunnel.sh status           # 显示托管方式、PID 与进程状态
sudo bash scripts/cf-ssh-tunnel.sh autostart --show # 查看登录自启状态
```

> **保活**：进程模式下 Tunnel 由看护脚本 `/etc/cf-ssh-tunnel/run.sh` 托管，异常退出会自动重启（间隔 5 秒起、最长 60 秒）；容器或机器重启后，任意一次登录 shell（例如打开终端）会把它自动拉起，也可以用 `restart` 手动拉起。不需要登录自启时执行 `autostart --disable`。
>
> 容器内还需先有监听 `22` 端口的 `sshd`，否则脚本会提示先安装启动 SSH。

## 必要前提

你的域名必须已添加到 Cloudflare，且 DNS 已交由 Cloudflare 托管。服务器上必须已有正在运行的 SSH 服务，通常监听 `22` 端口。Cloudflare 官方的本地管理 Tunnel 支持在授权后使用 CLI 自动创建 Tunnel 和 DNS 路由。[2]

## 连接与安全边界

Tunnel 和 DNS 完成后即可直接连接。客户端使用 `cloudflared` 作为 SSH 的 Tunnel 代理，随后继续由服务器上的 `sshd` 验证 Linux 用户、SSH 密钥或密码。[3]

> 该 SSH 域名会向 Internet 公开可达。[4] 这不等于任何人都能登录：每次连接仍需通过服务器 `sshd` 的密钥或密码验证。请优先使用 SSH 密钥认证，并关闭不需要的 root 或密码登录。

## 客户端连接

安装完成或重复执行 `install` 时，脚本会直接打印可复制的完整连接信息：`~/.ssh/config` 的 Host 配置块和一条免配置直连命令，用户名默认为安装时的用户。

客户端电脑安装 `cloudflared` 后，也可以随时按需生成：

```bash
bash scripts/cf-ssh-tunnel.sh client-config ssh.example.com [用户名]
```

把输出内容复制到 `~/.ssh/config`，然后连接：

```bash
ssh root@ssh.example.com
```

## 维护命令

| 用途 | 命令 |
|---|---|
| 一键更新 + 安装/拉起 + 打印连接信息 | `sudo bash start.sh` |
| 查看托管方式、服务状态、Tunnel UUID 与域名 | `sudo bash scripts/cf-ssh-tunnel.sh status` |
| 重启 Tunnel（容器重启后也用它） | `sudo bash scripts/cf-ssh-tunnel.sh restart` |
| 查看最近 80 行日志 | `sudo bash scripts/cf-ssh-tunnel.sh logs` |
| 检查网络、SSH 和日志 | `sudo bash scripts/cf-ssh-tunnel.sh diagnose` |
| 更新或安装 cloudflared | `sudo bash scripts/cf-ssh-tunnel.sh update` |
| 查看/开关登录自启（无 systemd 环境） | `sudo bash scripts/cf-ssh-tunnel.sh autostart [--show\|--enable\|--disable]` |
| 查看登录信息 / 重置密码 / 放行密码登录 | `sudo bash scripts/cf-ssh-tunnel.sh credentials [--set-password] [--allow-password]` |
| 输出客户端 SSH 配置 | `bash scripts/cf-ssh-tunnel.sh client-config` |
| 删除本机服务与专用凭据 | `sudo bash scripts/cf-ssh-tunnel.sh uninstall` |

完整的步骤、故障排查、发行版说明和安全边界，请阅读[中文部署指南](docs/cf-ssh-tunnel.md)。技术实现和官方依据详见[研究记录](docs/cf-ssh-tunnel-research.md)。

## 测试

```bash
./tests/test-cf-ssh-tunnel.sh
```

## 许可

本项目采用 [MIT License](LICENSE)。

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/ "Cloudflare: Tunnel run parameters"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/ "Cloudflare: Create a locally-managed tunnel"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[4]: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/ "Cloudflare: Publish a self-hosted application to the Internet"
