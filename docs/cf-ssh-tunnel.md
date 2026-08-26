# 无显示器 Linux 的 Cloudflare SSH Tunnel

> **目的**：让一台没有显示器、没有公网入站端口的 Linux 主机，通过 Cloudflare Tunnel 安全地接受 SSH 访问。脚本只连接本机的 `localhost:22`，不会开放 TCP/22，也不会修改 `sshd_config` 或防火墙规则。

此工具位于 [`scripts/cf-ssh-tunnel.sh`](../scripts/cf-ssh-tunnel.sh)，用于托管在 systemd 下的 `cloudflared` 服务。它采用 Cloudflare 官方的远程托管 Tunnel 及 `--token-file` 方式，令牌保存在服务器的 `/etc/cf-ssh-tunnel/token` 中，文件权限为 `0640 root:cf-ssh-tunnel`；令牌不会出现在 shell 历史、进程参数、systemd 单元或日志中。[1] [2]

| 能力 | 行为 |
|---|---|
| 发行版支持 | Debian/Ubuntu 与 RHEL/CentOS/Fedora 使用 Cloudflare 官方签名软件包仓库；Arch/Alpine 尝试发行版的 `cloudflared` 软件包，若仓库未提供则会明确失败而不会下载未知二进制。[3] |
| 身份验证 | 连接侧使用 Cloudflare Access，登录成功后仍需要 Linux 自己的 SSH 密钥或密码。Cloudflare Access **不是** SSH 认证的替代品。[1] |
| 网络预检 | 检查 SSH 服务、Cloudflare Tunnel 边缘域名 DNS 和至少一个 TCP/7844 出站连接。TCP/7844 不通时拒绝安装。[2] |
| 中国大陆模式 | `--mainland` 强制 HTTP/2（TCP/7844），避免依赖 UDP/QUIC；这是兼容性尝试，不承诺特定网络一定可用。[2] [4] |
| 进程韧性 | systemd 失败自动重启、5 秒重试间隔、失败突发限制、启动/停止超时、最小权限服务账户与基础沙箱限制。 |
| 运维 | 支持安全令牌轮换、状态查看、无侵入诊断、包管理器更新、客户端配置生成和明确确认的卸载。 |

## 上线前提

服务器必须能以 root 运行 systemd，且已有**正在运行的**本地 SSH 服务（`ssh` 或 `sshd`）。服务器不需要公网 IP、端口映射或显示器。Tunnel 仍必须能向 Cloudflare 边缘建立出站连接：HTTP/2 使用 TCP/7844，QUIC 使用 UDP/7844。[2]

你还需要一个 Cloudflare 账号，以及一个已添加到 Cloudflare 的活动域名。根据官方 SSH 指引，服务器端和客户端都需要 `cloudflared`，SSH 主机名应受 Cloudflare Access 自托管应用保护。[1]

## 一次性控制台配置

在任意能登录 Cloudflare 控制台的设备上，打开 **Networking → Tunnels → Create a tunnel**，创建一个名称便于识别的远程托管 Tunnel，例如 `home-ssh-01`。选择 Linux，先不要在控制台给出的安装命令中直接执行；只复制其中以 `eyJ` 开头的 **Tunnel Token**。该令牌可以运行这个 Tunnel，应当与密码同等对待。[5]

随后在 Tunnel 的 **Routes** 中添加 **Published application**。主机名可设为 `ssh.example.com`；服务类型选 `SSH`，地址填入 `localhost:22`。这是 Cloudflare 官方 SSH 路由方式。[1]

最后在 **Access → Applications** 创建一个 **Self-hosted** 应用，应用域名填 `ssh.example.com`。策略应采用**最小授权**，例如只允许你自己的身份提供商邮箱或指定身份组。没有 Access 策略的 SSH 路由不应投入使用。

## 在无显示器服务器上安装

先以可信方式将本仓库克隆或复制到服务器，然后运行脚本。不要把 Tunnel Token 直接写进命令行，也不要使用把远程脚本直接管道给 `bash` 的方式。

```bash
git clone https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash scripts/cf-ssh-tunnel.sh install --auto
```

安装期间，脚本会检查本机 SSH、DNS 与 TCP/7844；然后从 Cloudflare 官方源安装 `cloudflared`。令牌以两次隐藏输入方式粘贴。`--auto` 是默认模式：优先尝试 QUIC，若 UDP 不可用会由 `cloudflared` 回退 HTTP/2。[4]

完成后可以检查服务状态：

```bash
sudo bash scripts/cf-ssh-tunnel.sh status
```

如果你位于中国大陆网络，或明确知道 UDP/7844 不稳定，可以改用下述命令：

```bash
sudo bash scripts/cf-ssh-tunnel.sh install --mainland
```

> `--mainland` 仅把隧道传输固定为 HTTP/2（TCP/7844）。它**不是**规避网络限制的工具；若服务器的 DNS、TCP/7844 或客户端的 Access 登录不可达，Cloudflare Tunnel 就无法工作。脚本会停止并显示连通性错误，不会偷偷切换到未知中继或关闭 Access。

## 客户端连接

在你的 SSH 客户端安装 `cloudflared` 后，先让脚本生成配置模板：

```bash
sudo bash scripts/cf-ssh-tunnel.sh client-config ssh.example.com
```

将输出加入客户端的 `~/.ssh/config`，其中 `<你的 Linux 用户名>` 替换为服务器用户名：

```sshconfig
Host ssh.example.com
    HostName ssh.example.com
    User <你的 Linux 用户名>
    ProxyCommand cloudflared access ssh --hostname %h
```

然后用正常 SSH 方式连接：

```bash
ssh <你的 Linux 用户名>@ssh.example.com
```

首次连接时，`cloudflared` 会打开浏览器完成 Access 身份验证；随后 SSH 仍会验证服务器主机密钥和你的 SSH 凭据。[1]

## 日常运维

| 操作 | 命令 | 令牌暴露情况 |
|---|---|---|
| 查看状态 | `sudo bash scripts/cf-ssh-tunnel.sh status` | 不显示令牌。 |
| 网络与日志诊断 | `sudo bash scripts/cf-ssh-tunnel.sh diagnose` | 不修改配置，不显示令牌。 |
| 更新客户端 | `sudo bash scripts/cf-ssh-tunnel.sh update` | 使用系统包管理器；完成后不自动重启服务。 |
| 更新 Tunnel Token | `sudo bash scripts/cf-ssh-tunnel.sh rotate-token` | 两次隐藏输入、原子替换 token 文件、重启服务。 |
| 生成客户端模板 | `bash scripts/cf-ssh-tunnel.sh client-config ssh.example.com` | 无需 root。 |
| 删除本地服务 | `sudo bash scripts/cf-ssh-tunnel.sh uninstall` | 必须输入 `DELETE`；不会删除控制台的 Tunnel。 |

当令牌疑似泄露时，应先在 Cloudflare 控制台刷新/轮换令牌并删除未知连接，再立即执行 `rotate-token`；官方将 Tunnel Token 视作可运行 Tunnel 的凭据。[5]

## 故障排查

**安装时 TCP/7844 预检失败。** 这是服务器至 Cloudflare Tunnel 边缘的必要出站条件。确认网络出口、主机防火墙和上游安全设备允许到 `region1.v2.argotunnel.com`、`region2.v2.argotunnel.com` 的 TCP/7844；若用 QUIC，还需要 UDP/7844。[2] `--mainland` 可以避免对 UDP 的依赖，但不能替代 TCP/7844。

**服务启动失败。** 运行以下命令并核对 Tunnel 是否在控制台中显示为 Healthy。重点检查是否误粘贴了整条安装命令而非 `eyJ...` 令牌、令牌是否已经轮换失效、以及网络预检是否通过。

```bash
sudo bash scripts/cf-ssh-tunnel.sh diagnose
```

**能打开 Access 页面但 SSH 失败。** 检查发布路由的服务是否正好是 `ssh://localhost:22`，本机 SSH 是否在运行，以及客户端 `~/.ssh/config` 中是否有 `ProxyCommand cloudflared access ssh --hostname %h`。Cloudflare 并不把此配置变成公网 TCP/22 代理；客户端需通过 `cloudflared` 接入。[1]

**中国大陆网络不稳定。** 先使用 `--mainland`；如果 TCP/7844 仍然失败，脚本不会提供绕过网络控制的方案。应根据所在网络、服务商条款和适用法规，选择被明确允许且可维护的远程管理通道。

## 安全边界

本脚本的目标是减少暴露面而不是替代操作系统加固。你仍应禁用 SSH 弱密码，优先 SSH 密钥与最小权限用户，及时安装系统补丁，并保留可恢复的带外管理路径。Cloudflare Access 策略、Tunnel Token 和 Linux SSH 凭据都应独立保护。

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/ "Cloudflare: Tunnel with firewall"
[3]: https://pkg.cloudflare.com/ "Cloudflare Packages"
[4]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/ "Cloudflare: Tunnel run parameters"
[5]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/ "Cloudflare: Tunnel permissions"
