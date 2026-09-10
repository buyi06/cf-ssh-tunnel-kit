# 无显示器 Linux 的一键 Cloudflare SSH Tunnel

> 本工具服务于没有显示器、只有命令行的 Linux 主机。它会自动检测或安装 `cloudflared`，在终端显示 Cloudflare 浏览器授权链接；授权完成后，只需要输入 SSH 域名，脚本便会自动创建 Tunnel、DNS CNAME 路由、`ssh://localhost:22` ingress 配置和托管服务（优先 systemd，容器等无 systemd 环境自动改用后台进程）。

脚本位于 [`scripts/cf-ssh-tunnel.sh`](../scripts/cf-ssh-tunnel.sh)。它不会开放服务器的入站 `22` 端口，也不会将 Tunnel 凭据写进命令行、日志或 Git 仓库。唯一可能触及 `sshd` 配置的场景，是「sshd 禁止密码登录、而账户又没有公钥」时按你的确认放行密码登录（见下文「登录信息」），该改动有备份、有校验、可随时还原。

| 项目 | 自动完成的内容 |
|---|---|
| 客户端安装 | 已检测到可用 `cloudflared` 时跳过；否则通过官方软件源或发行版软件包自动安装。 |
| 无显示器授权 | `cloudflared tunnel login` 在终端给出授权链接；可在任意手机或电脑浏览器打开完成授权。 |
| Tunnel 与 DNS | 自动创建本地管理 Tunnel，并将用户输入的域名 CNAME 到 `<UUID>.cfargotunnel.com`。[1] |
| SSH 服务路由 | 自动生成 `ssh://localhost:22` ingress 和最后的 `http_status:404` 兜底规则。[2] |
| 开机运行 | 有 systemd 时创建受限 systemd 服务（失败自动重启，服务进程仅可读取该 Tunnel 专用 JSON 凭据）；没有 systemd 时以脱离终端会话的后台进程运行，由脚本管理 PID 与日志。 |
| SSH 认证 | 继续使用服务器原有的 SSH 密钥或密码认证。 |
| 中国大陆网络 | `--mainland` 强制 HTTP/2（TCP/7844），不依赖 UDP/QUIC；不能承诺任意网络均可用。 |

## 开始前只需确认两件事

第一，你拥有一个已经添加到 Cloudflare 且 DNS 已交由 Cloudflare 托管的域名。授权时应使用能管理该域名的 Cloudflare 账号；本地管理 Tunnel 的 DNS 路由命令需要该站点权限。[1] [3]

第二，服务器本机已经安装并运行 SSH 服务，且监听默认 `22` 端口。脚本会在修改系统前自动检查这一条件，以及 Cloudflare Tunnel 必需的出站 TCP/7844 连通性。[4]

## 小白安装步骤

在服务器上克隆项目，然后运行一键启动脚本：

```bash
git clone https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash start.sh
```

一键脚本按顺序完成：**更新代码 → 首次安装（含浏览器授权）→ 服务没在跑就拉起 → 打印可直接复制的 SSH 连接信息**。

| 执行时的状态 | `sudo bash start.sh` 的行为 |
|---|---|
| 首次运行 | 等价于 `install --mainland`：安装、授权、创建 Tunnel 与 DNS、启动托管服务 |
| 已安装且服务在运行 | 只更新代码并重新打印连接信息，不重启、不改动现有 Tunnel |
| 已安装但服务没跑（容器重启后等） | 自动拉起 Tunnel，再打印连接信息 |

参数：`--mainland`（默认）/ `--auto` / `--quic` 选择传输协议，`--no-update` 跳过代码更新。它每次运行都会先探测 GitHub 直连，连不通才自动测速并**临时**借用候选加速代理拉取代码——不写入全局 Git 配置，也不改动 `origin`，因此大陆网络下可以一直用同一条命令。

> 不想用一键脚本时，等价的手工命令是 `sudo bash scripts/cf-ssh-tunnel.sh install --mainland`；脚本会检测本机是否已配置过，不会重复安装。

脚本会全程显示中文提示。若系统尚未安装 `cloudflared`，会自动安装；若已安装则显示版本并跳过。随后终端会出现 Cloudflare 提供的 `https://...` 授权链接。复制它并在任意可联网设备的浏览器中打开，登录 Cloudflare，并选择目标域名所在站点。不要关闭服务器终端；浏览器授权完成后，脚本会自动继续。

接下来按提示输入一个完整域名，例如：

```text
ssh.example.com
```

脚本会自动执行以下动作：创建唯一 Tunnel、创建域名 DNS 记录、生成仅指向本机 `localhost:22` 的 SSH 路由、校验配置并启动托管服务。最后会显示实际使用的 SSH 域名和 Tunnel UUID。

> 授权期间产生的 `cert.pem` 具有账户级 Tunnel 管理能力。脚本仅在自动创建和 DNS 配置的短暂期间使用它，完成后立即清理；运行服务只保留此 Tunnel 的专用 JSON 凭据。[3]

## 登录信息（脚本会全部打印出来）

安装结束、重复执行 `install`、以及一键脚本 `start.sh` 结束时，都会先做一次「SSH 登录体检」，再把连得上所需的信息一次性打印：

```text
════════ 连接信息（照着做就能连上） ════════

服务器地址：ssh.example.com（Cloudflare Tunnel 域名）
登录用户：root
认证方式：密码
登录密码：Ab3xK9mQ2pL7wZ4
    （这是脚本刚设置的密码，只显示这一次，请立刻存下来）

① 一条命令直接连（不改任何配置）：
    ssh -o ProxyCommand='cloudflared access ssh --hostname %h' root@ssh.example.com

② 写进客户端 ~/.ssh/config（推荐，之后直接 ssh 就能连）：……
③ 想改用密钥登录（以后不用记密码）：ssh-copy-id -o ProxyCommand=…
```

体检按下面的顺序判断，并只在必要时改动本机账户：

| 服务器上的状况 | 脚本行为 |
|---|---|
| 该账户已有公钥（`~/.ssh/authorized_keys` 有有效条目） | 只列出公钥指纹，**不动密码**；指纹对不上时提示改用密码 |
| 既没有公钥、密码又是空的/被锁 | 生成 16 位随机密码，写入本机 `/etc/shadow`，**只打印一次**，不写入任何文件 |
| 既没有公钥、但账户已有密码 | 如实说明「Linux 不保存明文，脚本读不出来」，并提示用 `credentials --set-password` 重置 |
| sshd 不允许该账户用密码登录 | 交互运行时先询问；回答 Y 或带 `--allow-password` 才写 sshd 配置放行（写入前备份、`sshd -t` 校验失败立即回滚），否则只打印手工放行命令 |

任何时候都可以重新查看或重置，不用重装：

```bash
sudo bash scripts/cf-ssh-tunnel.sh credentials                # 域名、用户、认证方式、公钥指纹
sudo bash scripts/cf-ssh-tunnel.sh credentials --set-password # 生成并设置一个新密码后打印
```

> 安装时也可以直接指定：`install --set-password`（即使已有公钥也生成密码，两条路都能登）、`install --no-password`（只体检、绝不改密码）或 `install --allow-password`（sshd 禁止密码登录时免询问直接放行）。密码以哈希形式保存在本机 `/etc/shadow`，脚本自身不留任何明文副本。建议连上之后按上面 ③ 换成密钥登录。

### 放行密码登录时脚本改了什么

仅当 sshd 本身禁止该账户用密码登录、且需要密码登录时才发生，改动完全可还原：

| 系统情况 | 脚本动作 |
|---|---|
| `sshd_config` 里有 `Include .../sshd_config.d/*.conf`（Debian 12 / Ubuntu 22+ / RHEL9 等） | 写入独立文件 `sshd_config.d/99-cf-ssh-tunnel.conf`（`PasswordAuthentication yes`，root 另加 `PermitRootLogin yes`），主配置不动 |
| 老系统没有 Include | 把同样的三行插到 `sshd_config` 顶部（sshd 只认第一个出现的同名项），原文件备份为 `sshd_config.cf-ssh-tunnel.bak` |

写入后一定执行 `sshd -t` 语法校验并重载 sshd，再用 `sshd -T` 复核是否真正生效；**校验失败或未生效都会自动回滚**，不会把一个坏配置留在机器上。`credentials` 会打印当前改动与还原方式，`uninstall` 也会提醒该文件仍然存在。

## 连接与安全边界

Tunnel、DNS 和 SSH 路由在输入域名后即全部完成。客户端仍需要安装 `cloudflared` 作为 SSH 的 Tunnel 代理，随后以服务器现有的 Linux SSH 密钥或密码完成认证。[5]

> 该 SSH 域名会向 Internet 公开可达。[6] 这不等于免认证登录：`sshd` 仍会验证你的 Linux SSH 密钥或密码。请优先使用密钥认证，禁用不需要的 root 或密码登录，并保持系统更新。

## 中国大陆 GitHub 加速

当使用 `install --mainland` 时，脚本会自动对以下 GitHub 代理进行 Git 协议测速：`gh-proxy.org`、`v4.gh-proxy.org`、`v6.gh-proxy.org`、`cdn.gh-proxy.org` 与 `axisnow.gh-proxy.org`。只有返回正确 Git `upload-pack` 响应的代理才会参与比较，脚本将选择总耗时最低的可用项。

选中后，脚本通过 Git 全局 `url.<代理>https://github.com/.insteadOf` 规则加速当前管理员账户访问 `https://github.com/` 的 Git 克隆与拉取，并配套 `pushInsteadOf` 反向规则保证 `git push` 仍直连 GitHub。它**不会**设置 `HTTP_PROXY` 或 `HTTPS_PROXY`，因此不会代理 apt 更新、Cloudflare 授权、Tunnel 连接或系统其他网络流量。

对于未安装 `cloudflared` 的 Debian amd64 主机，`install --mainland` 也会从相同候选项中测试 Cloudflare 官方 GitHub Release `.deb` 文件的下载能力，并选择最快兼容项。下载前脚本通过 GitHub 官方 Release 页面取得版本与 SHA-256；该页面直连超时时（大陆常见）会自动改用候选代理取回并解析。下载后会验证 SHA-256 和 Debian 包结构，校验通过才交给 APT 安装。若元数据、代理下载、校验或安装失败，脚本自动回退到 Cloudflare 官方签名 APT 软件源。代理速度会随时间和线路变化，可随时重新测速：

```bash
sudo bash scripts/cf-ssh-tunnel.sh github-proxy
sudo bash scripts/cf-ssh-tunnel.sh github-proxy --show
sudo bash scripts/cf-ssh-tunnel.sh github-proxy --disable
```

> 这些是第三方 GitHub 加速服务。脚本只验证 Git 协议响应与延迟，不能把第三方代理变成代码来源信任锚。生产环境应固定经过审核的提交或发布版本，并审阅脚本后再以 root 执行。

> 上面的加速规则是在 `install --mainland` **运行之后**才写入全局 Git 配置的，供你自己的仓库操作使用。本项目的一键脚本 [`start.sh`](../start.sh) 不依赖它：它每次先探测直连，连不通才临时借用候选代理拉取代码，且不改动 `origin` 与全局配置。因此第一次克隆若直连超时，改用加速地址克隆一次即可，之后一直用同一条启动命令：
>
> ```bash
> git clone https://gh-proxy.org/https://github.com/buyi06/cf-ssh-tunnel-kit.git
> cd cf-ssh-tunnel-kit
> sudo bash start.sh
> ```

## 容器等没有 systemd 的环境

脚本不再要求必须存在 systemd。启动时它会检测 `systemctl` 与 `/run/systemd/system`：

| 项目 | systemd 模式 | 进程模式（Docker 容器、DSW/Colab、WSL 等） |
|---|---|---|
| 启动方式 | `systemctl enable --now cf-ssh-tunnel` | `setsid` 启动看护脚本 `run.sh`，脱离终端会话 |
| 运行账户 | 专用 `cf-ssh-tunnel` 系统账户 | 当前 root |
| 凭据与配置权限 | `0640 root:cf-ssh-tunnel` | `0600 root:root` |
| 崩溃自愈 | `Restart=on-failure` | 看护脚本重启 Tunnel，间隔 5 秒起、最长 60 秒 |
| 系统/容器重启后 | systemd 开机自启 | 首次登录 shell 自动拉起（`/etc/profile.d/cf-ssh-tunnel-autostart.sh`） |
| 运行状态 | `systemctl status cf-ssh-tunnel` | PID 文件 `/etc/cf-ssh-tunnel/tunnel.pid`（丢失时按看护脚本路径回退定位） |
| 日志 | `journalctl -u cf-ssh-tunnel` | `/etc/cf-ssh-tunnel/tunnel.log` |
| SSH 检查 | 服务名 + 22 端口 | 22 端口监听或 `sshd` 进程 |

因此容器里同样是一条命令装完即用：

```bash
sudo bash start.sh                             # 首次安装；容器重启后也可以直接再跑一次
sudo bash scripts/cf-ssh-tunnel.sh restart     # 只想拉起服务时
sudo bash scripts/cf-ssh-tunnel.sh logs        # 看护进程的重启记录与 cloudflared 输出都在这里
sudo bash scripts/cf-ssh-tunnel.sh autostart --show
```

保活分两层：**崩溃自愈**由看护脚本负责（Tunnel 异常退出后按 5 秒起步的退避间隔重启，最长 60 秒，避免崩溃循环刷日志）；**重启自启**由 profile.d 钩子负责——容器或机器重启后，任意一次登录 shell（例如打开终端）会检查并在必要时拉起 Tunnel，重复登录不会重复启动。不需要时执行 `autostart --disable` 关闭（或直接删除该文件），`uninstall` 也会一并清理。

> 进程模式的 Tunnel 独立于当前终端，关掉终端或断开 SSH 不会中断；但容器重建、实例回收后 `/etc` 下的配置与凭据都会丢失，需要重新执行 `install`（Cloudflare 上的 Tunnel 与 DNS 记录仍在，同名 Tunnel 需先在控制台删除，否则脚本会提示已存在同名 Tunnel）。容器内必须先有监听 `22` 端口的 `sshd`，否则脚本会拒绝创建指向空服务的 Tunnel，并提示安装方式。

## 客户端连接

安装完成或重复执行 `install` 时，脚本会直接打印完整的连接信息：可直接追加到 `~/.ssh/config` 的 Host 配置块，以及一条免配置直连命令，用户名默认为安装时的用户。

在你的电脑上安装 `cloudflared` 后，也可以随时按需生成：

```bash
bash scripts/cf-ssh-tunnel.sh client-config ssh.example.com [用户名]
```

将输出内容放进客户端的 `~/.ssh/config`，再执行：

```bash
ssh root@ssh.example.com
```

连接会通过 cloudflared 转入 Tunnel，随后仍会进行正常的 Linux SSH 主机密钥与用户凭据校验。[5]

## 常用维护命令

| 需求 | 命令 |
|---|---|
| 一键更新代码 + 安装或拉起 + 打印连接信息 | `sudo bash start.sh` |
| 查看托管方式、状态、Tunnel UUID、SSH 域名 | `sudo bash scripts/cf-ssh-tunnel.sh status` |
| 重启 Tunnel（容器/机器重启后也用它） | `sudo bash scripts/cf-ssh-tunnel.sh restart` |
| 查看最近 80 行日志 | `sudo bash scripts/cf-ssh-tunnel.sh logs` |
| 检查网络、SSH 和最近日志 | `sudo bash scripts/cf-ssh-tunnel.sh diagnose` |
| 查看登录信息 / 重置密码 / 放行密码登录 | `sudo bash scripts/cf-ssh-tunnel.sh credentials [--set-password] [--allow-password]` |
| 更新或安装 `cloudflared` | `sudo bash scripts/cf-ssh-tunnel.sh update` |
| 查看或开关登录自启（无 systemd 环境） | `sudo bash scripts/cf-ssh-tunnel.sh autostart [--show\|--enable\|--disable]` |
| 输出客户端配置 | `bash scripts/cf-ssh-tunnel.sh client-config` |
| 删除本机服务与专用凭据 | `sudo bash scripts/cf-ssh-tunnel.sh uninstall` |

卸载只会删除服务器上的服务、配置和 Tunnel 专用凭据。为避免使用账户级权限误删资源，它不会删除 Cloudflare 控制台中的 Tunnel 或 DNS 记录；脚本会打印 UUID，供你在控制台确认后手动删除。

## 常见问题

**终端没有出现授权链接，或者授权后一直不继续。** 请确认服务器能访问 Cloudflare，且不要关闭正在运行的 `install` 命令。若 `cloudflared tunnel login` 返回错误，重新运行安装命令即可；脚本不会保留失败授权期间的账户级证书。

**自动 DNS 失败。** 该域名必须已添加到 Cloudflare，DNS 必须由 Cloudflare 托管；授权时也必须选择了包含此域名的站点。[1]

**中国大陆服务器连不上。** 请使用 `--mainland`。该模式使用 TCP/7844 的 HTTP/2；若 TCP/7844、DNS 或客户端连接网络不可达，则 Cloudflare Tunnel 无法使用。脚本不会提供绕过网络控制的方案。[4]

**重复执行 install 会怎样？** 不会重复安装。脚本检测到已有配置时直接加载，显示现有 Tunnel 的域名、UUID、服务状态与连接命令；服务未运行会自动尝试拉起。想彻底重来，先执行 `uninstall`。

**SSH 仍然连接失败。** 先运行 `diagnose`，确认托管服务处于运行状态（systemd 模式看服务 `active`，进程模式看 PID 与日志尾部），再确认客户端 `~/.ssh/config` 中存在 `ProxyCommand cloudflared access ssh --hostname %h`，以及服务器的 SSH 用户、密钥或密码正确。[5] 如果卡在 `Permission denied (publickey,password)`，说明链路是通的、只是认证没对上：运行 `credentials` 看服务器上有哪些公钥；都不是你的就用 `credentials --set-password` 生成一个密码再连。

**登录密码是多少？脚本读不出服务器上原有的密码。** Linux 只保存哈希，任何工具都无法还原明文。三种处理：用你当初设置的那个密码；用自己手上的私钥（`credentials` 会列出服务器已授权的公钥指纹）；或者执行 `credentials --set-password` 重置为一个新密码——脚本会把新密码打印出来，且只打印这一次。若提示 sshd 不允许密码登录，执行 `credentials --set-password --allow-password` 让脚本自动放行并设置密码，或按输出里的命令手工放行。

**容器里提示「未检测到正在运行的 systemd」。** 这不是错误。脚本会自动改用后台看护进程继续安装：Tunnel 崩溃后会自动重启，容器/机器重启后首次登录 shell 会自动拉起。若提示未检测到 22 端口的 SSH 服务，请先在容器内启动 `sshd`，否则 Tunnel 没有可转发的目标。

**Tunnel 反复重启或需要确认保活是否生效。** 执行 `sudo bash scripts/cf-ssh-tunnel.sh logs`：看护进程每次重启都会写入一行 `[看护] Tunnel 进程退出（退出码 N，存活 N 秒），N 秒后重启`。持续出现说明 Tunnel 起不来（多为网络或凭据问题），而不是保活失效。日志文件过大时可自行截断：`sudo truncate -s 0 /etc/cf-ssh-tunnel/tunnel.log`（Tunnel 运行不受影响）。

**`git clone` 报 `Failed to connect to github.com port 443`。** 这是本机到 GitHub 的网络问题，与脚本无关。改用加速地址克隆（见上文「中国大陆 GitHub 加速」），或在能连通 GitHub 的机器上克隆后拷贝目录过去。安装完成后脚本配置的 Git 加速会让后续 `git pull` 自动走代理。

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/ "Cloudflare: Create a locally-managed tunnel"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/ "Cloudflare: Configuration file"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/ "Cloudflare: Tunnel permissions"
[4]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/ "Cloudflare: Tunnel with firewall"
[5]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[6]: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/ "Cloudflare: Publish a self-hosted application to the Internet"
