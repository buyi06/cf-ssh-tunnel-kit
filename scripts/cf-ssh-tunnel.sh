#!/usr/bin/env bash
# cf-ssh-tunnel.sh — 安全管理 Cloudflare Tunnel 到本机 SSH（仅 systemd Linux）
# 许可证：MIT（与本仓库一致）
set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'

readonly SERVICE_NAME='cf-ssh-tunnel'
readonly SERVICE_USER='cf-ssh-tunnel'
readonly SERVICE_DIR='/etc/cf-ssh-tunnel'
readonly TOKEN_FILE="${SERVICE_DIR}/token"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly MIN_VERSION='2025.4.0'
readonly EDGE_HOST_1='region1.v2.argotunnel.com'
readonly EDGE_HOST_2='region2.v2.argotunnel.com'

CF_BIN=''
PACKAGE_MANAGER=''

say() { printf '%s\n' "$*"; }
info() { say "[信息] $*"; }
warn() { say "[警告] $*" >&2; }
error() { say "[错误] $*" >&2; }
die() { error "$*"; exit 1; }

on_error() {
  local exit_code=$?
  error "操作未完成（退出码 ${exit_code}）。未打印或记录隧道令牌。请运行 '$0 diagnose' 查看本机诊断信息。"
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<'EOF'
用法：
  sudo bash cf-ssh-tunnel.sh install [--mainland|--auto|--quic]
  sudo bash cf-ssh-tunnel.sh rotate-token
  sudo bash cf-ssh-tunnel.sh status
  sudo bash cf-ssh-tunnel.sh diagnose
  sudo bash cf-ssh-tunnel.sh update
  sudo bash cf-ssh-tunnel.sh client-config <ssh.example.com>
  sudo bash cf-ssh-tunnel.sh uninstall

命令说明：
  install        安装官方 cloudflared、保存令牌到受限文件并启用 systemd 服务。
  --mainland     固定使用 HTTP/2（TCP/7844），适合 UDP/QUIC 不稳定的网络；不保证中国大陆网络可达。
  --auto         让 cloudflared 先尝试 QUIC，失败时回退 HTTP/2（默认）。
  --quic         固定使用 QUIC（UDP/7844）。
  rotate-token   通过隐藏输入更新令牌并原子重启服务。
  status         显示服务、版本、令牌文件权限与 SSH 监听状态；不显示令牌。
  diagnose       检查 DNS、TCP/7844、SSH 和最近日志；不改变配置。
  update         使用系统包管理器更新 cloudflared；不重启服务、不更改令牌。
  client-config  输出客户端 ~/.ssh/config 示例。客户端也必须安装 cloudflared。
  uninstall      仅删除本脚本创建的服务和本地令牌，不删除 Cloudflare 控制台中的 Tunnel。

安全模型：
  本脚本不开放服务器入站端口，不修改 sshd 配置，不创建公开 SSH 入口。
  请在 Cloudflare 控制台将 Published application 的服务设置为 ssh://localhost:22，
  并创建 Cloudflare Access 自托管应用和最小化身份策略后再连接。
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请以 root 运行，例如：sudo bash $0 <命令>"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "该脚本需要 systemd；当前系统未检测到 systemctl。"
  [[ -d /run/systemd/system ]] || die "当前环境不是已运行的 systemd 系统，无法可靠托管隧道服务。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PACKAGE_MANAGER='apt'
  elif command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER='dnf'
  elif command -v yum >/dev/null 2>&1; then
    PACKAGE_MANAGER='yum'
  elif command -v pacman >/dev/null 2>&1; then
    PACKAGE_MANAGER='pacman'
  elif command -v apk >/dev/null 2>&1; then
    PACKAGE_MANAGER='apk'
  else
    die "不支持的包管理器。支持 apt、dnf、yum、pacman 和 apk。"
  fi
}

install_prerequisites() {
  detect_package_manager
  case "$PACKAGE_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl
      ;;
    dnf)
      dnf -y install ca-certificates curl
      ;;
    yum)
      yum -y install ca-certificates curl
      ;;
    pacman)
      pacman -Syu --needed --noconfirm ca-certificates curl
      ;;
    apk)
      apk add --no-cache ca-certificates curl
      update-ca-certificates || true
      ;;
  esac
}

curl_secure() {
  # 仅请求 HTTPS，限制重试与超时；调用方负责指定 -o <临时文件>。
  curl --fail --show-error --silent --location \
    --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 "$@"
}

find_cloudflared() {
  CF_BIN="$(command -v cloudflared || true)"
  [[ -n "$CF_BIN" ]] || die "未找到 cloudflared 可执行文件。"
  [[ -x "$CF_BIN" ]] || die "cloudflared 不可执行：$CF_BIN"
}

version_ge() {
  # 比较 yyyy.m.p 格式版本：version_ge <actual> <minimum>
  local actual="$1" minimum="$2"
  local -a a b
  local i
  IFS='.' read -r -a a <<<"$actual"
  IFS='.' read -r -a b <<<"$minimum"
  for i in 0 1 2; do
    [[ "${a[$i]:-0}" =~ ^[0-9]+$ && "${b[$i]:-0}" =~ ^[0-9]+$ ]] || return 1
    if (( 10#${a[$i]:-0} > 10#${b[$i]:-0} )); then return 0; fi
    if (( 10#${a[$i]:-0} < 10#${b[$i]:-0} )); then return 1; fi
  done
  return 0
}

require_supported_cloudflared() {
  find_cloudflared
  local output version
  output="$($CF_BIN --version 2>&1)"
  if [[ "$output" =~ ([0-9]{4}\.[0-9]+\.[0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
  else
    die "无法解析 cloudflared 版本：$output"
  fi
  version_ge "$version" "$MIN_VERSION" || die "cloudflared ${version} 过旧；需要 ${MIN_VERSION} 或更新版本以安全使用 --token-file。"
  info "cloudflared 版本：${version}（满足令牌文件要求）"
}

install_cloudflared() {
  install_prerequisites
  local tmp
  case "$PACKAGE_MANAGER" in
    apt)
      info "配置 Cloudflare 官方 APT 软件包仓库。"
      install -d -o root -g root -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
      tmp="$(mktemp)"
      curl_secure -o "$tmp" 'https://pkg.cloudflare.com/cloudflare-main.gpg'
      install -o root -g root -m 0644 "$tmp" /usr/share/keyrings/cloudflare-main.gpg
      rm -f "$tmp"
      tmp="$(mktemp)"
      printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' >"$tmp"
      install -o root -g root -m 0644 "$tmp" /etc/apt/sources.list.d/cloudflared.list
      rm -f "$tmp"
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
      ;;
    dnf|yum)
      info "配置 Cloudflare 官方 RPM 软件包仓库。"
      install -d -o root -g root -m 0755 /etc/yum.repos.d
      tmp="$(mktemp)"
      curl_secure -o "$tmp" 'https://pkg.cloudflare.com/cloudflared.repo'
      install -o root -g root -m 0644 "$tmp" /etc/yum.repos.d/cloudflared.repo
      rm -f "$tmp"
      if [[ "$PACKAGE_MANAGER" == 'dnf' ]]; then
        dnf -y install cloudflared
      else
        yum -y install cloudflared
      fi
      ;;
    pacman)
      warn "Arch 将执行完整系统更新，以避免部分升级。"
      pacman -Syu --needed --noconfirm cloudflared
      ;;
    apk)
      apk add --no-cache cloudflared
      ;;
  esac
  require_supported_cloudflared
}

ensure_service_user() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    return 0
  fi
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
  elif command -v adduser >/dev/null 2>&1; then
    adduser -S -H -s /sbin/nologin "$SERVICE_USER"
  else
    die "无法创建受限服务账户（未找到 useradd/adduser）。"
  fi
}

probe_dns() {
  local host="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$host" >/dev/null 2>&1
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" >/dev/null 2>&1
  else
    warn "未找到 getent 或 nslookup，跳过 DNS 预检。"
    return 0
  fi
}

probe_tcp_7844() {
  local host="$1"
  # /dev/tcp 是 Bash 内建能力；只进行 TCP 三次握手，不发送业务数据。
  timeout 6 bash -c "exec 3<>/dev/tcp/${host}/7844" >/dev/null 2>&1
}

check_network() {
  local host
  local dns_ok=0 tcp_ok=0
  for host in "$EDGE_HOST_1" "$EDGE_HOST_2"; do
    if probe_dns "$host"; then
      info "DNS 可解析：${host}"
      dns_ok=1
    else
      warn "DNS 解析失败：${host}"
    fi
  done
  (( dns_ok == 1 )) || die "无法解析 Cloudflare Tunnel 边缘域名。请先检查服务器 DNS。"

  for host in "$EDGE_HOST_1" "$EDGE_HOST_2"; do
    if probe_tcp_7844 "$host"; then
      info "TCP/7844 连通：${host}"
      tcp_ok=1
    else
      warn "TCP/7844 不通：${host}"
    fi
  done
  (( tcp_ok == 1 )) || die "无法连接 Cloudflare 的 TCP/7844。隧道无法建立；请检查上游防火墙、出口策略或所在网络限制。"
}

check_local_ssh() {
  local ssh_service=''
  if systemctl is-active --quiet ssh; then ssh_service='ssh'; fi
  if systemctl is-active --quiet sshd; then ssh_service='sshd'; fi
  if [[ -z "$ssh_service" ]]; then
    warn '未检测到运行中的 SSH 服务（ssh/sshd）。请先安装并启动 SSH。'
    return 1
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -lntH '( sport = :22 )' 2>/dev/null | grep -q .; then
      info "本机 SSH 正在监听 22 端口（服务：${ssh_service}）。"
      return 0
    fi
  fi
  warn 'SSH 服务处于运行状态，但未能确认 22 端口监听。请确认 Cloudflare 控制台服务地址与实际 sshd 端口一致。'
  return 0
}

read_token() {
  local prompt="$1"
  local token confirm
  say >&2
  say '请从 Cloudflare 控制台的 Tunnel 安装命令中仅复制 eyJ... 令牌字符串。' >&2
  say '令牌不会显示、不会写入日志、不会置于 systemd 命令行或环境变量。' >&2
  read -r -s -p "$prompt" token
  say >&2
  [[ -n "$token" ]] || die '令牌不能为空。'
  [[ "$token" == eyJ* && "$token" =~ ^[A-Za-z0-9._~+=-]+$ && ${#token} -ge 80 ]] || die '令牌格式无效。请只粘贴安装命令中的 eyJ... 令牌，不要粘贴整条命令。'
  read -r -s -p '再次输入以确认：' confirm
  say >&2
  [[ "$token" == "$confirm" ]] || die '两次输入的令牌不一致。'
  printf '%s' "$token"
}

write_token_atomically() {
  local token="$1" tmp
  install -d -o root -g "$SERVICE_USER" -m 0750 "$SERVICE_DIR"
  tmp="$(mktemp "${SERVICE_DIR}/.token.XXXXXX")"
  umask 0077
  if ! { printf '%s' "$token" >"$tmp" && chown root:"$SERVICE_USER" "$tmp" && chmod 0640 "$tmp" && mv -f "$tmp" "$TOKEN_FILE"; }; then
    rm -f "$tmp"
    die '无法安全保存 Tunnel 令牌。'
  fi
}

write_unit() {
  local protocol="$1" tmp
  case "$protocol" in auto|http2|quic) ;; *) die "无效协议：$protocol" ;; esac
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
[Unit]
Description=Cloudflare Tunnel for local SSH (managed by cf-ssh-tunnel)
Documentation=https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${CF_BIN} tunnel --no-autoupdate --protocol ${protocol} --edge-ip-version auto --retries 5 run --token-file ${TOKEN_FILE}
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s
TimeoutStopSec=45s
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelLogs=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
  install -o root -g root -m 0644 "$tmp" "$UNIT_FILE"
  rm -f "$tmp"
}

show_mainland_notice() {
  say
  warn '中国大陆兼容模式只会强制使用 HTTP/2（TCP/7844），以避免依赖 UDP/QUIC。'
  warn '它不能保证 Cloudflare Tunnel、DNS 或 Access 登录在任何网络中可达，也不会自动改用第三方中继。'
  say
}

wait_for_service() {
  local i
  for i in {1..12}; do
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      info "服务已启动。"
      return 0
    fi
    sleep 1
  done
  error "服务未能在 12 秒内启动。以下为最近日志："
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
  die "请核对 Tunnel 令牌、Cloudflare 控制台状态与 TCP/7844 出站连通性。"
}

install_tunnel() {
  local protocol='auto'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mainland) protocol='http2' ;;
      --auto) protocol='auto' ;;
      --quic) protocol='quic' ;;
      -h|--help) usage; return 0 ;;
      *) die "未知 install 选项：$1" ;;
    esac
    shift
  done

  require_root
  require_systemd
  [[ ! -e "$UNIT_FILE" ]] || die "已存在 ${SERVICE_NAME} 服务。请使用 rotate-token、status、update 或先 uninstall。"
  check_network
  check_local_ssh || die 'SSH 未就绪，拒绝创建一个没有本机 SSH 服务的 Tunnel。'
  install_cloudflared
  ensure_service_user
  if [[ "$protocol" == 'http2' ]]; then show_mainland_notice; fi

  local token
  token="$(read_token '粘贴 Tunnel 令牌（输入隐藏）：')"
  write_token_atomically "$token"
  unset token
  write_unit "$protocol"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  wait_for_service

  say
  info '安装完成：本机未开放任何新的入站端口。'
  say '下一步请在 Cloudflare 控制台配置 Published application：'
  say '  主机名：ssh.你的域名'
  say '  服务：ssh://localhost:22'
  say '并为该主机名创建 Cloudflare Access 自托管应用与最小化身份策略。'
  say "随后在客户端运行：sudo bash $0 client-config ssh.你的域名"
}

status_tunnel() {
  require_root
  require_systemd
  if [[ ! -e "$UNIT_FILE" ]]; then
    warn "未发现 ${SERVICE_NAME} 服务。"
    return 1
  fi
  find_cloudflared
  say "服务：${SERVICE_NAME}"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  say
  say "cloudflared：$($CF_BIN --version 2>&1 || true)"
  if [[ -e "$TOKEN_FILE" ]]; then
    say "令牌文件权限：$(stat -c '%a %U:%G %n' "$TOKEN_FILE")"
  else
    warn "令牌文件缺失：${TOKEN_FILE}"
  fi
  check_local_ssh || true
}

diagnose_tunnel() {
  require_root
  require_systemd
  say '== Cloudflare Tunnel DNS 预检 =='
  probe_dns "$EDGE_HOST_1" && info "DNS 正常：$EDGE_HOST_1" || warn "DNS 异常：$EDGE_HOST_1"
  probe_dns "$EDGE_HOST_2" && info "DNS 正常：$EDGE_HOST_2" || warn "DNS 异常：$EDGE_HOST_2"
  say
  say '== Cloudflare Tunnel TCP/7844 预检 =='
  probe_tcp_7844 "$EDGE_HOST_1" && info "TCP 正常：$EDGE_HOST_1:7844" || warn "TCP 失败：$EDGE_HOST_1:7844"
  probe_tcp_7844 "$EDGE_HOST_2" && info "TCP 正常：$EDGE_HOST_2:7844" || warn "TCP 失败：$EDGE_HOST_2:7844"
  say
  say '== 本机 SSH 检查 =='
  check_local_ssh || true
  say
  say '== 服务状态 =='
  if [[ -e "$UNIT_FILE" ]]; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    say
    say '== 最近 80 行服务日志 =='
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
  else
    warn "未安装 ${SERVICE_NAME} 服务。"
  fi
}

rotate_token() {
  require_root
  require_systemd
  [[ -e "$UNIT_FILE" ]] || die "未发现 ${SERVICE_NAME} 服务。"
  [[ -e "$TOKEN_FILE" ]] || die "令牌文件缺失；为避免误操作，请先 uninstall 后重新 install。"
  local token
  token="$(read_token '粘贴新的 Tunnel 令牌（输入隐藏）：')"
  write_token_atomically "$token"
  unset token
  systemctl restart "$SERVICE_NAME"
  wait_for_service
  info '令牌已更新。请在 Cloudflare 控制台确认旧令牌已按你的轮换策略失效。'
}

update_cloudflared() {
  require_root
  install_prerequisites
  case "$PACKAGE_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade cloudflared
      ;;
    dnf)
      dnf -y upgrade cloudflared
      ;;
    yum)
      yum -y update cloudflared
      ;;
    pacman)
      warn "Arch 将执行完整系统更新，以避免部分升级。"
      pacman -Syu --needed --noconfirm cloudflared
      ;;
    apk)
      apk upgrade cloudflared
      ;;
  esac
  require_supported_cloudflared
  info '更新完成。服务未自动重启；请在维护窗口执行：systemctl restart cf-ssh-tunnel'
}

client_config() {
  local hostname="${1:-}"
  [[ -n "$hostname" ]] || die '请提供 SSH 主机名，例如：client-config ssh.example.com'
  [[ "$hostname" =~ ^[A-Za-z0-9.-]+$ && "$hostname" == *.* ]] || die '主机名格式无效。'
  cat <<EOF
将以下内容加入客户端的 ~/.ssh/config（客户端需已安装 cloudflared）：

Host ${hostname}
    HostName ${hostname}
    User <你的 Linux 用户名>
    ProxyCommand cloudflared access ssh --hostname %h

随后运行：
  ssh <你的 Linux 用户名>@${hostname}

首次连接时，cloudflared 会打开浏览器完成 Cloudflare Access 身份验证。
EOF
}

uninstall_tunnel() {
  require_root
  require_systemd
  [[ -e "$UNIT_FILE" || -e "$SERVICE_DIR" ]] || die "未发现本脚本创建的本地配置。"
  say '此操作只会停止并删除本脚本创建的 systemd 服务与本地令牌。'
  say '它不会删除 Cloudflare 控制台中的 Tunnel、路由或 Access 策略，也不会卸载 cloudflared。'
  local answer
  read -r -p '若确认，请输入 DELETE：' answer
  [[ "$answer" == 'DELETE' ]] || die '已取消。'
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$UNIT_FILE"
  rm -rf "$SERVICE_DIR"
  systemctl daemon-reload
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    if command -v userdel >/dev/null 2>&1; then
      userdel "$SERVICE_USER" 2>/dev/null || true
    elif command -v deluser >/dev/null 2>&1; then
      deluser "$SERVICE_USER" 2>/dev/null || true
    fi
  fi
  info '本地服务与令牌已删除。请在 Cloudflare 控制台删除或停用不再需要的 Tunnel。'
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    install) install_tunnel "$@" ;;
    rotate-token) [[ $# -eq 0 ]] || die 'rotate-token 不接受额外参数。'; rotate_token ;;
    status) [[ $# -eq 0 ]] || die 'status 不接受额外参数。'; status_tunnel ;;
    diagnose) [[ $# -eq 0 ]] || die 'diagnose 不接受额外参数。'; diagnose_tunnel ;;
    update) [[ $# -eq 0 ]] || die 'update 不接受额外参数。'; update_cloudflared ;;
    client-config) [[ $# -eq 1 ]] || die 'client-config 需要一个主机名参数。'; client_config "$1" ;;
    uninstall) [[ $# -eq 0 ]] || die 'uninstall 不接受额外参数。'; uninstall_tunnel ;;
    help|-h|--help) usage ;;
    *) die "未知命令：$command（运行 '$0 help' 查看用法）" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
