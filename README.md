# cf-ssh-tunnel-kit

> **无显示器 Linux 的全中文 Cloudflare SSH Tunnel 一键部署工具。** 一条命令装完：自动安装 `cloudflared`、终端给出浏览器授权链接、自动创建 Tunnel 与 DNS 路由、拉起托管服务，最后把「怎么连」——域名、用户名、密码或公钥指纹——全部打印出来。

适合家用 Linux、小主机、NAS、树莓派、没有公网入站 IP 的云服务器，以及 ModelScope DSW 这类只有容器的环境。

- **不用公网 IP、不用开放入站端口**：Tunnel 由服务器主动连出，脚本只把它接到本机 `ssh://localhost:22`，不创建裸 TCP SSH 公网转发。[2]
- **有 systemd 用 systemd，没有就用看护进程**：容器/Docker/DSW/Colab/WSL 里照样能跑，崩溃自愈、重启后登录自启。
- **装完就能登**：账户没有公钥也没有可用密码时自动生成密码并打印；sshd 禁止密码登录时会先问一句再放行。
- **中国大陆网络**：`--mainland` 固定 TCP/7844，并自动测速 GitHub 加速代理。

---

## 快速开始

在服务器上执行（root 或 sudo）：

```bash
git clone https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash start.sh
```

[`start.sh`](start.sh) 是幂等的一键入口，可以反复执行：

| 执行时的状态 | `sudo bash start.sh` 会做什么 |
|---|---|
| 首次运行 | 更新代码 → 装 `cloudflared` → 浏览器授权 → 创建 Tunnel 与 DNS → 启动托管服务 → 打印连接信息 |
| 已安装且服务在运行 | 只更新代码并重新打印连接信息，不动现有 Tunnel |
| 已安装但服务没跑（容器重启后等） | 自动拉起 Tunnel，再打印连接信息 |

参数：`--mainland`（默认）/ `--auto` / `--quic` 选传输协议，`--allow-password` 免询问放行 sshd 密码登录，`--no-update` 跳过代码更新。

> 不想用一键脚本时，等价的手工命令是 `sudo bash scripts/cf-ssh-tunnel.sh install --mainland`。

### 中国大陆直连 GitHub 超时

出现 `Failed to connect to github.com port 443` 时，第一次克隆改用加速地址即可，**不需要**手工切换 `origin`：

```bash
git clone https://gh-proxy.org/https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash start.sh
```

> `start.sh` 每次运行都先探测直连，连不通才自动测速并**临时**借用加速代理拉取代码（不写入全局 Git 配置、不改动 `origin`），之后的更新也不用再手工处理。

### 首次安装你只需要做两件事

| 步骤 | 你需要做什么 | 脚本自动完成什么 |
|---|---|---|
| 1. 检查环境 | 无需操作 | 检查本机 SSH、DNS、Cloudflare TCP/7844；检测 `cloudflared`，未安装时自动装 |
| 2. Cloudflare 授权 | 复制终端显示的 `https://...` 链接，在任意设备的浏览器打开并选择站点 | 等待授权成功，不需要服务器显示器 |
| 3. 填写域名 | 输入完整域名，例如 `ssh.example.com` | 创建 Tunnel、写 DNS CNAME、生成 `ssh://localhost:22` ingress、校验配置、启动托管服务 |
| 4. 连接 | 照抄终端最后打印的连接信息 | 打印域名、登录用户、认证方式（密码或公钥指纹）和三种可直接复制的连接方式 |

> `--mainland` 使用 HTTP/2/TCP 7844，适合 UDP/QUIC 不稳定的网络；它不保证任何网络一定可连，也不会绕过网络限制。默认 `--auto` 优先 QUIC，失败时回退 HTTP/2。[1]

---

## 连接信息：该给的全部会打印出来

安装结束、重复执行 `install`、以及 `start.sh` 结束时，都会先做一次 SSH 登录体检，再打印完整信息：

```text
════════ 连接信息（照着做就能连上） ════════

服务器地址：ssh.example.com（Cloudflare Tunnel 域名）
登录用户：root
认证方式：密码
登录密码：Ab3xK9mQ2pL7wZ4
    （这是脚本刚设置的密码，只显示这一次，请立刻存下来）

① 一条命令直接连（不改任何配置）：
    ssh -o ProxyCommand='cloudflared access ssh --hostname %h' root@ssh.example.com

② 写进客户端 ~/.ssh/config（推荐，之后直接 ssh 就能连）：
    Host ssh.example.com
        HostName ssh.example.com
        User root
        ProxyCommand cloudflared access ssh --hostname %h

③ 想改用密钥登录（以后不用记密码）：
    ssh-copy-id -o ProxyCommand='cloudflared access ssh --hostname %h' root@ssh.example.com
```

体检逻辑与对账户的改动：

| 服务器上的状况 | 脚本行为 |
|---|---|
| 该账户已有公钥 | 列出已授权公钥指纹，**不碰密码**；指纹对不上会提示改用密码 |
| 没有公钥、密码为空或被锁 | 生成 16 位随机密码写入本机 `/etc/shadow`，**只打印这一次**、不落到任何文件 |
| 没有公钥、但账户已有密码 | 如实说明「Linux 不保存明文、读不出来」，提示用 `credentials --set-password` 重置 |
| sshd 禁止该账户用密码登录 | 交互运行时先问一句；回答 Y 或带 `--allow-password` 才放行：优先写 `sshd_config.d/` 独立文件（主配置不动），老系统插在 `sshd_config` 顶部并留 `.cf-ssh-tunnel.bak` 备份；写入后 `sshd -t` 校验 → 重载 → 复核生效，任一步不通过**立即回滚** |

随时可以重新查看或重置，不用重装：

```bash
sudo bash scripts/cf-ssh-tunnel.sh credentials                                  # 域名、用户、认证方式、公钥指纹
sudo bash scripts/cf-ssh-tunnel.sh credentials --set-password                   # 生成并设置新密码后打印
sudo bash scripts/cf-ssh-tunnel.sh credentials --set-password --allow-password  # sshd 挡着也一并放行
```

> 安装时也能直接指定：`install --set-password`（即使已有公钥也生成密码，两条路都能登）、`install --no-password`（只体检、绝不改密码）、`install --allow-password`（sshd 挡着也免询问放行）。

客户端（Windows / macOS / Linux）需要自行安装 `cloudflared`[5]，然后按上面 ① 或 ② 连接；认证沿用服务器 `sshd` 的密钥或密码。[3]

---

## 适用环境：systemd 与容器都能跑

脚本不要求 systemd。检测不到正在运行的 systemd 时，自动改用**后台看护进程**托管：

| 项目 | systemd 模式 | 进程模式（容器 / DSW / Colab / WSL） |
|---|---|---|
| 启动方式 | 受限 systemd 服务，开机自启 | `setsid` 启动的看护脚本 `run.sh`，脱离终端会话 |
| 运行账户 | 专用 `cf-ssh-tunnel` 系统账户 | 当前 root |
| 凭据权限 | `0640 root:cf-ssh-tunnel` | `0600 root:root` |
| 崩溃自愈 | `Restart=on-failure` | 看护进程自动重启 Tunnel（5 秒起、最长 60 秒） |
| 重启后 | 开机自启 | 首次登录 shell 自动拉起，也可手动 `restart` |
| 运行状态 | `systemctl status cf-ssh-tunnel` | PID 文件 `/etc/cf-ssh-tunnel/tunnel.pid` |
| 日志 | `journalctl -u cf-ssh-tunnel` | `/etc/cf-ssh-tunnel/tunnel.log` |

```bash
sudo bash start.sh                                   # 一键：更新代码 + 拉起 Tunnel + 打印连接信息
sudo bash scripts/cf-ssh-tunnel.sh restart           # 只重启 Tunnel
sudo bash scripts/cf-ssh-tunnel.sh logs              # 最近 80 行日志（含看护进程的重启记录）
sudo bash scripts/cf-ssh-tunnel.sh status            # 托管方式、PID、Tunnel UUID 与域名
sudo bash scripts/cf-ssh-tunnel.sh autostart --show  # 查看登录自启状态（--disable 关闭）
```

> 容器里还需要先有监听 `22` 端口的 `sshd`，否则脚本会拒绝创建指向空服务的 Tunnel，并提示安装方式。容器**重建**（不是重启）会清空 `/etc`，配置与凭据需重新 `install`；Cloudflare 上的 Tunnel 与 DNS 记录仍在，同名 Tunnel 要先在控制台删除。

---

## 中国大陆 GitHub 加速

`install --mainland` 会测速 `gh-proxy.org`、`v4.gh-proxy.org`、`v6.gh-proxy.org`、`cdn.gh-proxy.org`、`axisnow.gh-proxy.org`，选可用且延迟最低者，为当前管理员账户写入 Git 的 GitHub URL 重写规则。它只影响 Git 的 `https://github.com/` 克隆与拉取（`git push` 仍直连），不设置 `HTTP_PROXY`/`HTTPS_PROXY`，不代理 apt、Cloudflare 授权或 Tunnel 流量。

Debian amd64 主机若尚未安装 `cloudflared`，同一次测速还会挑能透传官方 Release `.deb` 的最快代理：先从 GitHub 官方 Release 页取版本与 SHA-256（直连超时自动改用候选代理取回），下载后校验 SHA-256 与 Debian 包结构，**全部通过才安装**，任一步失败即回退到 Cloudflare 官方签名 APT 源。

```bash
sudo bash scripts/cf-ssh-tunnel.sh github-proxy            # 重新测速
sudo bash scripts/cf-ssh-tunnel.sh github-proxy --show     # 查看当前加速状态
sudo bash scripts/cf-ssh-tunnel.sh github-proxy --disable  # 关闭
```

> 这些是第三方加速服务，脚本只验证 Git 协议响应与延迟，不能把代理当成代码来源的信任锚。生产环境请固定经过审核的提交或发布版本。

---

## 必要前提

- 一个已添加到 Cloudflare、且 DNS 交由 Cloudflare 托管的域名；授权时选择包含该域名的站点。[2]
- 服务器上有正在运行的 SSH 服务，通常监听 `22` 端口。
- 中国大陆网络或 UDP 不稳定时用 `--mainland`。

---

## 维护命令

| 用途 | 命令 |
|---|---|
| 一键更新 + 安装/拉起 + 打印连接信息 | `sudo bash start.sh` |
| 查看托管方式、服务状态、Tunnel UUID 与域名 | `sudo bash scripts/cf-ssh-tunnel.sh status` |
| 重启 Tunnel | `sudo bash scripts/cf-ssh-tunnel.sh restart` |
| 查看最近 80 行日志 | `sudo bash scripts/cf-ssh-tunnel.sh logs` |
| 检查网络、SSH 与日志 | `sudo bash scripts/cf-ssh-tunnel.sh diagnose` |
| 查看登录信息 / 重置密码 / 放行密码登录 | `sudo bash scripts/cf-ssh-tunnel.sh credentials [--set-password] [--allow-password]` |
| 查看、开关登录自启（无 systemd 环境） | `sudo bash scripts/cf-ssh-tunnel.sh autostart [--show\|--enable\|--disable]` |
| 更新或安装 cloudflared | `sudo bash scripts/cf-ssh-tunnel.sh update` |
| 生成客户端 SSH 配置 | `bash scripts/cf-ssh-tunnel.sh client-config [域名] [用户名]` |
| 删除本机服务与专用凭据 | `sudo bash scripts/cf-ssh-tunnel.sh uninstall` |

完整的步骤、故障排查与发行版说明见[中文部署指南](docs/cf-ssh-tunnel.md)；技术实现与官方依据见[研究记录](docs/cf-ssh-tunnel-research.md)。

---

## 常见问题

**`git clone` 报 `Failed to connect to github.com port 443`。** 本机到 GitHub 的网络问题，与脚本无关：改用上面的加速地址克隆一次即可。

**SSH 卡在 `Permission denied (publickey,password)`。** 说明隧道和 SSH 握手都通了，只是认证没对上：`credentials` 看服务器上有哪些公钥；都不是你的就用 `credentials --set-password` 生成一个密码。

**密码是多少？** 脚本读不出服务器上原有的密码（Linux 只保存哈希）。要么用你当初设的那个，要么 `credentials --set-password` 重置为新密码并打印。

**容器里提示「没有 systemd」。** 不是错误，是预期行为：脚本自动改用看护进程托管，崩溃自愈、登录自启。

**Tunnel 反复重启。** `logs` 里每次重启都会写一行 `[看护] Tunnel 进程退出（退出码 N，存活 N 秒）`；持续出现说明 Tunnel 建不起来（多为网络或凭据问题），而不是保活失效。

---

## 安全边界

- 脚本不开放服务器入站端口，不改动 `sshd_config`（除你在「sshd 禁止密码登录」时明确同意放行），不把凭据写进命令行、日志或 Git 仓库。
- 该 SSH 域名会向 Internet 公开可达。[4] 这不等于任何人都能登录：每次连接仍要过服务器 `sshd` 的密钥或密码验证。建议连上后按连接信息里的 ③ 换成密钥登录。
- 授权期间产生的账户级 `cert.pem` 只在创建流程中短暂存在，完成后立即删除；运行服务只保留该 Tunnel 的专用凭据。

---

## 开发与测试

```bash
./tests/test-cf-ssh-tunnel.sh   # 168 项无网络回归测试
```

CI 会对脚本做 `bash -n` 语法检查、`shellcheck -S warning` 静态检查并跑上面的测试。

## 许可

本项目采用 [MIT License](LICENSE)。

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/ "Cloudflare: Tunnel run parameters"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/ "Cloudflare: Create a locally-managed tunnel"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[4]: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/ "Cloudflare: Publish a self-hosted application to the Internet"
[5]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/ "Cloudflare: Downloads"
