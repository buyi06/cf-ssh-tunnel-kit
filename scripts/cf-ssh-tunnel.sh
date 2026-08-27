#!/usr/bin/env bash
# cf-ssh-tunnel.sh — 无显示器 Linux 的 Cloudflare SSH Tunnel 小白向部署工具
# 许可证：MIT
set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'

readonly SERVICE_NAME='cf-ssh-tunnel'
readonly SERVICE_USER='cf-ssh-tunnel'
readonly SERVICE_DIR='/etc/cf-ssh-tunnel'
readonly CONFIG_FILE="${SERVICE_DIR}/config.yml"
readonly META_FILE="${SERVICE_DIR}/tunnel.env"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly EDGE_HOST_1='region1.v2.argotunnel.com'
readonly EDGE_HOST_2='region2.v2.argotunnel.com'
readonly GITHUB_PREFIX='https://github.com/'
readonly PROJECT_GIT_INFO_URL='https://github.com/buyi06/cf-ssh-tunnel-kit.git/info/refs?service=git-upload-pack'
readonly CLOUDFLARED_RELEASE_PAGE='https://github.com/cloudflare/cloudflared/releases/latest'
readonly GITHUB_PROXY_STATE_FILE='/etc/cf-ssh-tunnel/github-proxy.env'
readonly -a GITHUB_PROXY_CANDIDATES=(
  'https://gh-proxy.org/'
  'https://v4.gh-proxy.org/'
  'https://v6.gh-proxy.org/'
  'https://cdn.gh-proxy.org/'
  'https://axisnow.gh-proxy.org/'
)

CF_BIN=''
PACKAGE_MANAGER=''
TUNNEL_UUID=''
TUNNEL_NAME=''
PUBLIC_HOSTNAME=''
PROTOCOL='auto'
LOGIN_HOME=''
CERT_FILE=''
TUNNEL_CREATED=0

say() { printf '%s\n' "$*"; }
info() { say "[信息] $*"; }
warn() { say "[警告] $*" >&2; }
error() { say "[错误] $*" >&2; }
die() { error "$*"; exit 1; }

on_error() {
  local code=$?
  if [[ -n "$TUNNEL_UUID" && "$TUNNEL_CREATED" -eq 1 ]]; then
    warn "本次已创建 Tunnel：${TUNNEL_UUID}。若流程未完成，请在 Cloudflare 控制台删除它及对应 DNS 路由。"
  fi
  error "操作未完成（退出码 ${code}）。可执行 '$0 diagnose' 检查本机网络与服务日志。"
  exit "$code"
}
trap on_error ERR

cleanup_login_certificate() {
  if [[ -n "$LOGIN_HOME" && -d "$LOGIN_HOME" ]]; then
    rm -rf "$LOGIN_HOME"
  fi
}
trap cleanup_login_certificate EXIT

usage() {
  cat <<'EOF'
用法：
  sudo bash cf-ssh-tunnel.sh install [--mainland|--auto|--quic]
  sudo bash cf-ssh-tunnel.sh status
  sudo bash cf-ssh-tunnel.sh diagnose
  sudo bash cf-ssh-tunnel.sh update
  sudo bash cf-ssh-tunnel.sh github-proxy [--show|--disable]
  bash cf-ssh-tunnel.sh client-config [ssh.example.com]
  sudo bash cf-ssh-tunnel.sh uninstall

最简单的安装方式：
  sudo bash cf-ssh-tunnel.sh install --mainland

命令说明：
  install        自动检测/安装 cloudflared，输出浏览器授权链接，随后询问域名并自动创建 Tunnel、DNS 路由、SSH 配置和系统服务。
  --mainland     固定使用 HTTP/2（TCP/7844），适合 UDP/QUIC 不稳定的网络。
  --auto         先尝试 QUIC，UDP 不可用时由 cloudflared 回退 HTTP/2（默认）。
  --quic         固定使用 QUIC（UDP/7844）。
  status         显示 Tunnel 名称、域名、服务状态和本机 SSH 状态。
  diagnose       检查 DNS、TCP/7844、本机 SSH 和最近服务日志；不会修改配置。
  update         使用系统包管理器更新 cloudflared。
  github-proxy   测试候选 GitHub 代理，自动选择低延迟可用项并全局加速 GitHub Git 克隆；--show 查看，--disable 关闭。
  client-config  输出 SSH 客户端配置；不带域名时自动读取本机配置。
  uninstall      仅删除本机服务和凭据；不会删除 Cloudflare 控制台中的 Tunnel 或 DNS 记录。

安全说明：
  本脚本不会开放服务器入站端口，不修改 sshd_config，也不创建裸 TCP/22 公网转发。
  脚本会自动创建 Tunnel、DNS 路由和 ssh://localhost:22 配置；Cloudflare Access 身份策略仍需由账号管理员确认配置。
  GitHub 代理仅写入 Git 的 github.com 规则，不设置 HTTP(S)_PROXY，不代理系统更新、Cloudflare 授权或其他网络流量。
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请以 root 运行，例如：sudo bash $0 install"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die '当前系统未检测到 systemctl；本脚本仅支持 systemd Linux。'
  [[ -d /run/systemd/system ]] || die '当前环境不是正在运行的 systemd 系统，无法可靠托管 Tunnel 服务。'
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
    die '未识别包管理器。支持 apt、dnf、yum、pacman 和 apk。'
  fi
}

curl_secure() {
  curl --fail --show-error --silent --location \
    --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 "$@"
}

install_prerequisites() {
  detect_package_manager
  case "$PACKAGE_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl
      ;;
    dnf) dnf -y install ca-certificates curl ;;
    yum) yum -y install ca-certificates curl ;;
    pacman)
      warn 'Arch Linux 将执行完整系统更新，以避免部分升级。'
      pacman -Syu --needed --noconfirm ca-certificates curl
      ;;
    apk)
      apk add --no-cache ca-certificates curl
      update-ca-certificates || true
      ;;
  esac
}

find_cloudflared() {
  CF_BIN="$(command -v cloudflared || true)"
  [[ -n "$CF_BIN" && -x "$CF_BIN" ]] || return 1
  return 0
}

show_cloudflared_version() {
  local output
  output="$($CF_BIN --version 2>&1 || true)"
  [[ -n "$output" ]] || die 'cloudflared 无法正常执行。'
  info "已检测到 cloudflared，跳过安装：${output}"
}

get_cloudflared_release_metadata() {
  local final_url tag digest tmp
  tmp="$(mktemp)"
  if ! final_url="$(curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 \
    --output "$tmp" --write-out '%{url_effective}' "$CLOUDFLARED_RELEASE_PAGE")"; then
    rm -f "$tmp"
    return 1
  fi
  tag="${final_url##*/}"
  digest="$(grep -Eio 'cloudflared-linux-amd64\.deb[^0-9a-f]{0,300}[0-9a-f]{64}' "$tmp" | head -n 1 | grep -Eio '[0-9a-f]{64}' | tr '[:upper:]' '[:lower:]' || true)"
  rm -f "$tmp"
  [[ "$tag" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'https://github.com/cloudflare/cloudflared/releases/download/%s/cloudflared-linux-amd64.deb\t%s' "$tag" "$digest"
}


probe_cloudflared_release_proxy() {
  local proxy="$1" asset_url="$2" output code seconds content_type milliseconds
  output="$(curl --request GET --silent --show-error --location --max-redirs 5 \
    --connect-timeout 5 --max-time 20 --range 0-1023 --output /dev/null \
    --write-out '%{http_code}\t%{time_total}\t%{content_type}' \
    "${proxy}${asset_url}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r code seconds content_type <<<"$output"
  [[ "$code" == '200' || "$code" == '206' ]] || return 1
  [[ "$content_type" == *'application/octet-stream'* ]] || return 1
  milliseconds="$(seconds_to_milliseconds "$seconds")"
  printf '%s\t%s' "$proxy" "$milliseconds"
}

install_cloudflared_deb_via_proxy() {
  local metadata asset_url expected_sha candidate result proxy latency best_proxy='' best_latency=-1
  local tmp actual_sha
  [[ "$PACKAGE_MANAGER" == 'apt' && "$(uname -m)" == 'x86_64' ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || { warn '未找到 sha256sum，拒绝通过第三方代理下载 cloudflared。'; return 1; }
  command -v dpkg-deb >/dev/null 2>&1 || { warn '未找到 dpkg-deb，拒绝通过第三方代理下载 cloudflared。'; return 1; }

  metadata="$(get_cloudflared_release_metadata || true)"
  if [[ -z "$metadata" ]]; then
    warn '无法从 GitHub 官方 Release 页面获取 cloudflared 的 SHA-256；改用 Cloudflare 官方签名软件源。'
    return 1
  fi
  IFS=$'\t' read -r asset_url expected_sha <<<"$metadata"

  info '正在测试 GitHub 代理对 Cloudflare 官方 cloudflared Debian 包的下载速度。'
  printf '%-34s %-12s %s\n' '代理地址' '延迟' '结果'
  for candidate in "${GITHUB_PROXY_CANDIDATES[@]}"; do
    result="$(probe_cloudflared_release_proxy "$candidate" "$asset_url" || true)"
    if [[ -z "$result" ]]; then
      printf '%-34s %-12s %s\n' "$candidate" '-' '不可用或二进制响应异常'
      continue
    fi
    IFS=$'\t' read -r proxy latency <<<"$result"
    printf '%-34s %-12s %s\n' "$proxy" "${latency} ms" '可用'
    if (( best_latency < 0 || latency < best_latency )); then
      best_proxy="$proxy"
      best_latency="$latency"
    fi
  done
  if [[ -z "$best_proxy" ]]; then
    warn '没有可用的 GitHub 代理可下载 cloudflared；改用 Cloudflare 官方签名软件源。'
    return 1
  fi

  tmp="$(mktemp --suffix=.deb)"
  if ! curl_secure -o "$tmp" "${best_proxy}${asset_url}"; then
    rm -f "$tmp"
    warn '代理下载 cloudflared 失败；改用 Cloudflare 官方签名软件源。'
    return 1
  fi
  actual_sha="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -f "$tmp"
    warn '代理下载文件的 SHA-256 与 GitHub 官方 Release 元数据不一致，已拒绝安装并回退。'
    return 1
  fi
  if ! dpkg-deb -I "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn '已下载文件不是有效 Debian 软件包，已拒绝安装并回退。'
    return 1
  fi
  chmod 0644 "$tmp"
  info "SHA-256 校验通过；使用 ${best_proxy}（${best_latency} ms）安装 cloudflared。"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp"; then
    rm -f "$tmp"
    warn '通过代理安装 cloudflared 失败；改用 Cloudflare 官方签名软件源。'
    return 1
  fi
  rm -f "$tmp"
  return 0
}

install_cloudflared() {
  install_prerequisites
  local tmp
  if [[ "$PROTOCOL" == 'http2' ]] && install_cloudflared_deb_via_proxy; then
    find_cloudflared || die 'cloudflared 代理安装完成后仍未找到可执行文件。'
    info "cloudflared 已安装：$($CF_BIN --version 2>&1)"
    return 0
  fi
  case "$PACKAGE_MANAGER" in
    apt)
      info '正在配置 Cloudflare 官方 APT 软件源并安装 cloudflared。'
      install -d -o root -g root -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
      tmp="$(mktemp)"
      curl_secure -o "$tmp" 'https://pkg.cloudflare.com/cloudflare-main.gpg'
      install -o root -g root -m 0644 "$tmp" /usr/share/keyrings/cloudflare-main.gpg
      rm -f "$tmp"
      printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' >"$tmp"
      install -o root -g root -m 0644 "$tmp" /etc/apt/sources.list.d/cloudflared.list
      rm -f "$tmp"
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
      ;;
    dnf|yum)
      info '正在配置 Cloudflare 官方 RPM 软件源并安装 cloudflared。'
      install -d -o root -g root -m 0755 /etc/yum.repos.d
      tmp="$(mktemp)"
      curl_secure -o "$tmp" 'https://pkg.cloudflare.com/cloudflared.repo'
      install -o root -g root -m 0644 "$tmp" /etc/yum.repos.d/cloudflared.repo
      rm -f "$tmp"
      if [[ "$PACKAGE_MANAGER" == 'dnf' ]]; then dnf -y install cloudflared; else yum -y install cloudflared; fi
      ;;
    pacman) pacman -Syu --needed --noconfirm cloudflared ;;
    apk) apk add --no-cache cloudflared ;;
  esac
  find_cloudflared || die 'cloudflared 安装完成后仍未找到可执行文件。'
  info "cloudflared 已安装：$($CF_BIN --version 2>&1)"
}

ensure_cloudflared() {
  if find_cloudflared; then
    show_cloudflared_version
  else
    info '未安装 cloudflared，开始自动安装。'
    install_cloudflared
  fi
}

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  info '未安装 Git，正在安装以启用 GitHub 加速。'
  detect_package_manager
  case "$PACKAGE_MANAGER" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y git ;;
    dnf) dnf -y install git ;;
    yum) yum -y install git ;;
    pacman) pacman -Syu --needed --noconfirm git ;;
    apk) apk add --no-cache git ;;
  esac
  command -v git >/dev/null 2>&1 || die 'Git 安装失败，无法配置 GitHub 代理。'
}

seconds_to_milliseconds() {
  local seconds="$1" whole fraction
  whole="${seconds%%.*}"
  fraction='0'
  [[ "$seconds" == *.* ]] && fraction="${seconds#*.}"
  fraction="${fraction}000"
  fraction="${fraction:0:3}"
  printf '%d' "$((10#${whole:-0} * 1000 + 10#${fraction:-0}))"
}

probe_github_proxy() {
  local proxy="$1" output code seconds content_type milliseconds
  output="$(curl --request GET --silent --show-error --location --max-redirs 3 \
    --connect-timeout 5 --max-time 12 --range 0-1023 --output /dev/null \
    --write-out '%{http_code}\t%{time_total}\t%{content_type}' \
    "${proxy}${PROJECT_GIT_INFO_URL}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r code seconds content_type <<<"$output"
  [[ "$code" == '200' && "$content_type" == *'application/x-git-upload-pack-advertisement'* ]] || return 1
  milliseconds="$(seconds_to_milliseconds "$seconds")"
  printf '%s\t%s' "$proxy" "$milliseconds"
}

remove_known_github_proxies() {
  local proxy key
  for proxy in "${GITHUB_PROXY_CANDIDATES[@]}"; do
    key="url.${proxy}${GITHUB_PREFIX}.insteadOf"
    git config --global --unset-all "$key" >/dev/null 2>&1 || true
  done
}

write_github_proxy_state() {
  local proxy="$1" latency="$2" tmp
  install -d -o root -g root -m 0750 "$SERVICE_DIR"
  tmp="$(mktemp "${SERVICE_DIR}/.github-proxy.env.XXXXXX")"
  cat >"$tmp" <<EOF
GITHUB_PROXY=${proxy}
LATENCY_MS=${latency}
CONFIGURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  install -o root -g root -m 0600 "$tmp" "$GITHUB_PROXY_STATE_FILE"
  rm -f "$tmp"
}

show_github_proxy() {
  if [[ -r "$GITHUB_PROXY_STATE_FILE" ]]; then
    say 'GitHub 加速状态：'
    sed 's/^/[信息] /' "$GITHUB_PROXY_STATE_FILE"
    say '仅 Git 的 https://github.com/ 地址会使用该代理；系统更新和 Cloudflare 流量不受影响。'
  else
    warn '未发现本脚本配置的 GitHub 代理。'
  fi
}

disable_github_proxy() {
  ensure_git
  remove_known_github_proxies
  rm -f "$GITHUB_PROXY_STATE_FILE"
  info '已移除本脚本添加的 GitHub 代理规则。'
}

configure_github_proxy() {
  ensure_git
  local candidate result proxy latency best_proxy='' best_latency=-1
  say
  info '正在测试 5 个 GitHub 加速代理，选择 Git 克隆延迟最低的可用项。'
  say '代理仅用于 Git 的 github.com 地址；不会设置 HTTP_PROXY、HTTPS_PROXY 或影响 Cloudflare Tunnel。'
  printf '%-34s %-12s %s\n' '代理地址' '延迟' '结果'
  for candidate in "${GITHUB_PROXY_CANDIDATES[@]}"; do
    result="$(probe_github_proxy "$candidate" || true)"
    if [[ -z "$result" ]]; then
      printf '%-34s %-12s %s\n' "$candidate" '-' '不可用或协议响应异常'
      continue
    fi
    IFS=$'\t' read -r proxy latency <<<"$result"
    printf '%-34s %-12s %s\n' "$proxy" "${latency} ms" '可用'
    if (( best_latency < 0 || latency < best_latency )); then
      best_proxy="$proxy"
      best_latency="$latency"
    fi
  done

  if [[ -z "$best_proxy" ]]; then
    warn '所有候选 GitHub 代理均不可用；保持 GitHub 直连，不影响 Tunnel 安装。'
    return 0
  fi

  remove_known_github_proxies
  git config --global "url.${best_proxy}${GITHUB_PREFIX}.insteadOf" "$GITHUB_PREFIX"
  write_github_proxy_state "$best_proxy" "$best_latency"
  info "已选择 ${best_proxy}（${best_latency} ms），并为当前管理员账户的 GitHub Git 操作启用加速。"
}

manage_github_proxy() {
  require_root
  case "${1:-}" in
    '') configure_github_proxy ;;
    --show) show_github_proxy ;;
    --disable) disable_github_proxy ;;
    *) die 'github-proxy 仅支持 --show 或 --disable。' ;;
  esac
}

ensure_service_user() {
  id "$SERVICE_USER" >/dev/null 2>&1 && return 0
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
  elif command -v adduser >/dev/null 2>&1; then
    adduser -S -H -s /sbin/nologin "$SERVICE_USER"
  else
    die '无法创建受限服务账户（未找到 useradd 或 adduser）。'
  fi
}

probe_dns() {
  local host="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$host" >/dev/null 2>&1
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" >/dev/null 2>&1
  else
    warn '未找到 getent 或 nslookup，跳过 DNS 预检。'
    return 0
  fi
}

probe_tcp_7844() {
  local host="$1"
  timeout 6 bash -c "exec 3<>/dev/tcp/${host}/7844" >/dev/null 2>&1
}

check_network() {
  local host dns_ok=0 tcp_ok=0
  for host in "$EDGE_HOST_1" "$EDGE_HOST_2"; do
    if probe_dns "$host"; then
      info "DNS 可解析：${host}"
      dns_ok=1
    else
      warn "DNS 解析失败：${host}"
    fi
  done
  (( dns_ok == 1 )) || die '无法解析 Cloudflare Tunnel 边缘域名，请先检查服务器 DNS。'

  for host in "$EDGE_HOST_1" "$EDGE_HOST_2"; do
    if probe_tcp_7844 "$host"; then
      info "TCP/7844 可连接：${host}"
      tcp_ok=1
    else
      warn "TCP/7844 不通：${host}"
    fi
  done
  (( tcp_ok == 1 )) || die '无法连接 Cloudflare TCP/7844；请检查防火墙、出口策略或所在网络限制。'
}

check_local_ssh() {
  local unit=''
  if systemctl is-active --quiet ssh; then unit='ssh'; fi
  if systemctl is-active --quiet sshd; then unit='sshd'; fi
  if [[ -z "$unit" ]]; then
    warn '未检测到运行中的 SSH 服务（ssh/sshd）。请先安装并启动 SSH。'
    return 1
  fi
  if command -v ss >/dev/null 2>&1 && ss -lntH '( sport = :22 )' 2>/dev/null | grep -q .; then
    info "本机 SSH 正在监听 22 端口（服务：${unit}）。"
  else
    warn 'SSH 服务已运行，但未能确认 22 端口监听；请确认 sshd 端口确为 22。'
  fi
  return 0
}

validate_hostname() {
  local host="$1"
  [[ ${#host} -le 253 && "$host" == *.* ]] || return 1
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

read_hostname() {
  local input
  while true; do
    read -r -p '请输入用于 SSH 的完整域名（例如 ssh.example.com）：' input
    input="${input,,}"
    if validate_hostname "$input"; then
      PUBLIC_HOSTNAME="$input"
      return 0
    fi
    warn '域名格式不正确。请填写完整域名，例如 ssh.example.com。'
  done
}

make_tunnel_name() {
  local hash
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$PUBLIC_HOSTNAME" | sha256sum | cut -c1-10)"
  else
    hash="$(printf '%s' "$PUBLIC_HOSTNAME" | cksum | awk '{print $1}')"
  fi
  TUNNEL_NAME="ssh-${hash}"
}

login_to_cloudflare() {
  LOGIN_HOME="$(mktemp -d /root/.cf-ssh-tunnel-login.XXXXXX)"
  chmod 0700 "$LOGIN_HOME"
  CERT_FILE="${LOGIN_HOME}/.cloudflared/cert.pem"

  say
  say '第 1 步：Cloudflare 浏览器授权'
  say '接下来 cloudflared 会在本终端输出一条 https:// 开头的授权链接。'
  say '请复制该链接，在任意可以使用浏览器的设备上打开，登录 Cloudflare，并选择包含目标域名的站点。'
  say '授权完成前请不要关闭本终端；完成后脚本会自动继续。'
  say

  if ! HOME="$LOGIN_HOME" "$CF_BIN" tunnel login; then
    die 'Cloudflare 授权未完成。请重新执行 install，并在浏览器中完成链接授权。'
  fi
  [[ -s "$CERT_FILE" ]] || die '未取得 Cloudflare 授权证书。请确认浏览器中已完成授权并选择了站点。'
  chmod 0600 "$CERT_FILE"
  info 'Cloudflare 授权成功。'
}

create_tunnel() {
  local output credential_source
  make_tunnel_name
  info "第 2 步：正在创建 Tunnel（名称：${TUNNEL_NAME}）。"
  if ! output="$(HOME="$LOGIN_HOME" "$CF_BIN" tunnel --origincert "$CERT_FILE" create "$TUNNEL_NAME" 2>&1)"; then
    error "$output"
    die '创建 Tunnel 失败。请确认授权账号对该 Cloudflare 账户具有 Tunnel 管理权限。'
  fi
  if [[ "$output" =~ ([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}) ]]; then
    TUNNEL_UUID="${BASH_REMATCH[1],,}"
  else
    error "$output"
    die 'Tunnel 已创建，但脚本无法识别其 UUID；为避免错误配置，已停止。请在 Cloudflare 控制台查看后删除该 Tunnel。'
  fi
  TUNNEL_CREATED=1
  credential_source="${LOGIN_HOME}/.cloudflared/${TUNNEL_UUID}.json"
  [[ -s "$credential_source" ]] || die "未找到 Tunnel 凭据文件：${credential_source}"

  install -d -o root -g "$SERVICE_USER" -m 0750 "$SERVICE_DIR"
  install -o root -g "$SERVICE_USER" -m 0640 "$credential_source" "${SERVICE_DIR}/${TUNNEL_UUID}.json"
  info "Tunnel 已创建（UUID：${TUNNEL_UUID}）。"
}

write_config() {
  local temp_config="${SERVICE_DIR}/.config.yml.XXXXXX"
  local tmp
  tmp="$(mktemp "$temp_config")"
  cat >"$tmp" <<EOF
# 由 cf-ssh-tunnel-kit 自动生成，请勿将凭据文件上传至 Git。
tunnel: ${TUNNEL_UUID}
credentials-file: ${SERVICE_DIR}/${TUNNEL_UUID}.json

ingress:
  - hostname: ${PUBLIC_HOSTNAME}
    service: ssh://localhost:22
  - service: http_status:404
EOF
  install -o root -g "$SERVICE_USER" -m 0640 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"

  if ! "$CF_BIN" tunnel --config "$CONFIG_FILE" ingress validate; then
    die '自动生成的 SSH 路由配置未通过 cloudflared 校验。'
  fi
}

create_dns_route() {
  info "第 3 步：正在自动创建 DNS 路由：${PUBLIC_HOSTNAME}。"
  if ! "$CF_BIN" tunnel --origincert "$CERT_FILE" route dns "$TUNNEL_UUID" "$PUBLIC_HOSTNAME"; then
    die '自动创建 DNS 路由失败。请确认该域名已托管至 Cloudflare，且授权时选择了正确站点。'
  fi
  info "DNS 路由已创建：${PUBLIC_HOSTNAME} -> ${TUNNEL_UUID}.cfargotunnel.com"
}

write_metadata() {
  local tmp
  tmp="$(mktemp "${SERVICE_DIR}/.tunnel.env.XXXXXX")"
  cat >"$tmp" <<EOF
TUNNEL_UUID=${TUNNEL_UUID}
TUNNEL_NAME=${TUNNEL_NAME}
PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME}
PROTOCOL=${PROTOCOL}
EOF
  install -o root -g root -m 0600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

read_metadata() {
  [[ -r "$META_FILE" ]] || return 1
  TUNNEL_UUID=''
  TUNNEL_NAME=''
  PUBLIC_HOSTNAME=''
  PROTOCOL='auto'
  while IFS='=' read -r key value; do
    case "$key" in
      TUNNEL_UUID) TUNNEL_UUID="$value" ;;
      TUNNEL_NAME) TUNNEL_NAME="$value" ;;
      PUBLIC_HOSTNAME) PUBLIC_HOSTNAME="$value" ;;
      PROTOCOL) PROTOCOL="$value" ;;
    esac
  done <"$META_FILE"
  [[ -n "$TUNNEL_UUID" && -n "$PUBLIC_HOSTNAME" ]]
}

write_unit() {
  local tmp
  case "$PROTOCOL" in auto|http2|quic) ;; *) die "无效协议：${PROTOCOL}" ;; esac
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
[Unit]
Description=Cloudflare Tunnel for local SSH (managed by cf-ssh-tunnel-kit)
Documentation=https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${SERVICE_DIR}
ExecStart=${CF_BIN} tunnel --no-autoupdate --config ${CONFIG_FILE} --protocol ${PROTOCOL} --edge-ip-version auto --retries 5 run ${TUNNEL_UUID}
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

wait_for_service() {
  local i
  for ((i = 0; i < 15; i++)); do
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      info 'Tunnel 服务已启动。'
      return 0
    fi
    sleep 1
  done
  error '服务未能在 15 秒内启动，以下为最近日志：'
  journalctl -u "$SERVICE_NAME" -n 60 --no-pager || true
  die 'Tunnel 服务启动失败。请执行 diagnose 查看网络和日志。'
}

show_access_notice() {
  say
  say '第 4 步：Tunnel 已自动配置完成。'
  say "SSH 域名：${PUBLIC_HOSTNAME}"
  say
  warn '为避免任何人访问 SSH，请在 Cloudflare Zero Trust → Access → Applications 中为该域名创建 Self-hosted 应用，并仅允许你的账号或指定用户组。'
  say '这是身份策略配置，脚本不会猜测你的登录方式，也不会默认开放 SSH。'
  say "完成后，在客户端运行：bash $0 client-config ${PUBLIC_HOSTNAME}"
  say
  info '为降低风险，授权期间使用的账户级证书已自动删除；运行服务只保留本 Tunnel 的专用凭据。'
}

show_mainland_notice() {
  say
  warn '中国大陆模式已启用：Tunnel 将固定使用 HTTP/2（TCP/7844），不依赖 UDP/QUIC。'
  warn '它无法保证任意网络均能连接；若 TCP/7844 或 DNS 不可达，Cloudflare Tunnel 无法建立。'
  say
}

install_tunnel() {
  PROTOCOL='auto'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mainland) PROTOCOL='http2' ;;
      --auto) PROTOCOL='auto' ;;
      --quic) PROTOCOL='quic' ;;
      -h|--help) usage; return 0 ;;
      *) die "未知 install 选项：$1" ;;
    esac
    shift
  done

  require_root
  require_systemd
  [[ ! -e "$UNIT_FILE" && ! -e "$META_FILE" ]] || die "已存在 ${SERVICE_NAME} 配置。请使用 status、diagnose、update 或先 uninstall。"
  ensure_cloudflared
  check_network
  check_local_ssh || die 'SSH 未就绪，拒绝创建没有本机 SSH 服务的 Tunnel。'
  ensure_service_user
  if [[ "$PROTOCOL" == 'http2' ]]; then
    show_mainland_notice
    configure_github_proxy
  fi

  login_to_cloudflare
  read_hostname
  create_tunnel
  write_config
  create_dns_route
  write_metadata
  write_unit
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  wait_for_service
  show_access_notice
}

status_tunnel() {
  require_root
  require_systemd
  if ! read_metadata; then
    warn "未发现 ${SERVICE_NAME} 的本地配置。"
    return 1
  fi
  ensure_cloudflared
  say "Tunnel 名称：${TUNNEL_NAME:-未知}"
  say "Tunnel UUID：${TUNNEL_UUID}"
  say "SSH 域名：${PUBLIC_HOSTNAME}"
  say "传输协议：${PROTOCOL}"
  say "凭据文件权限：$(stat -c '%a %U:%G %n' "${SERVICE_DIR}/${TUNNEL_UUID}.json" 2>/dev/null || echo '文件缺失')"
  say
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  say
  check_local_ssh || true
}

diagnose_tunnel() {
  require_root
  require_systemd
  say '== Cloudflare DNS 预检 =='
  if probe_dns "$EDGE_HOST_1"; then info "DNS 正常：${EDGE_HOST_1}"; else warn "DNS 异常：${EDGE_HOST_1}"; fi
  if probe_dns "$EDGE_HOST_2"; then info "DNS 正常：${EDGE_HOST_2}"; else warn "DNS 异常：${EDGE_HOST_2}"; fi
  say
  say '== Cloudflare TCP/7844 预检 =='
  if probe_tcp_7844 "$EDGE_HOST_1"; then info "TCP 正常：${EDGE_HOST_1}:7844"; else warn "TCP 失败：${EDGE_HOST_1}:7844"; fi
  if probe_tcp_7844 "$EDGE_HOST_2"; then info "TCP 正常：${EDGE_HOST_2}:7844"; else warn "TCP 失败：${EDGE_HOST_2}:7844"; fi
  say
  say '== 本机 SSH 检查 =='
  check_local_ssh || true
  say
  say '== Tunnel 本地配置 =='
  if read_metadata; then
    say "SSH 域名：${PUBLIC_HOSTNAME}"
    say "Tunnel UUID：${TUNNEL_UUID}"
  else
    warn '未发现本地 Tunnel 元数据。'
  fi
  say
  say '== 服务状态与日志 =='
  if [[ -e "$UNIT_FILE" ]]; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
  else
    warn "未安装 ${SERVICE_NAME} 服务。"
  fi
}

update_cloudflared() {
  require_root
  if ! find_cloudflared; then
    info '未安装 cloudflared，将直接执行自动安装。'
    install_cloudflared
    return 0
  fi
  install_prerequisites
  case "$PACKAGE_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade cloudflared
      ;;
    dnf) dnf -y upgrade cloudflared ;;
    yum) yum -y update cloudflared ;;
    pacman)
      warn 'Arch Linux 将执行完整系统更新，以避免部分升级。'
      pacman -Syu --needed --noconfirm cloudflared
      ;;
    apk) apk upgrade cloudflared ;;
  esac
  find_cloudflared || die 'cloudflared 更新后不可用。'
  info "更新完成：$($CF_BIN --version 2>&1)"
  info "如需立即加载新版本，请执行：systemctl restart ${SERVICE_NAME}"
}

client_config() {
  local hostname="${1:-}"
  if [[ -z "$hostname" ]] && [[ -r "$META_FILE" ]]; then
    read_metadata || true
    hostname="$PUBLIC_HOSTNAME"
  fi
  [[ -n "$hostname" ]] || die '请提供 SSH 域名，例如：client-config ssh.example.com'
  hostname="${hostname,,}"
  validate_hostname "$hostname" || die '域名格式无效，例如 ssh.example.com。'
  cat <<EOF
请将以下内容加入 SSH 客户端的 ~/.ssh/config（客户端也需安装 cloudflared）：

Host ${hostname}
    HostName ${hostname}
    User <你的 Linux 用户名>
    ProxyCommand cloudflared access ssh --hostname %h

连接命令：
  ssh <你的 Linux 用户名>@${hostname}

首次连接时，cloudflared 会打开浏览器完成 Cloudflare Access 身份验证。
请先在 Cloudflare Zero Trust 中为 ${hostname} 配置 Access Self-hosted 应用和最小化访问策略。
EOF
}

uninstall_tunnel() {
  require_root
  require_systemd
  [[ -e "$UNIT_FILE" || -e "$SERVICE_DIR" ]] || die '未发现本脚本创建的本地配置。'
  local old_uuid=''
  if read_metadata; then old_uuid="$TUNNEL_UUID"; fi
  say '该操作将停止并删除本机 systemd 服务、配置和 Tunnel 专用凭据。'
  say '为避免账户级误删，它不会删除 Cloudflare 控制台中的 Tunnel 或 DNS 记录。'
  [[ -n "$old_uuid" ]] && say "如不再使用，请在 Cloudflare 控制台删除 Tunnel：${old_uuid}"
  local answer
  read -r -p '若确认，请输入 DELETE：' answer
  [[ "$answer" == 'DELETE' ]] || die '已取消。'
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$UNIT_FILE"
  rm -rf "$SERVICE_DIR"
  systemctl daemon-reload
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    if command -v userdel >/dev/null 2>&1; then userdel "$SERVICE_USER" 2>/dev/null || true
    elif command -v deluser >/dev/null 2>&1; then deluser "$SERVICE_USER" 2>/dev/null || true
    fi
  fi
  info '本机 Tunnel 服务和专用凭据已删除。'
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    install) install_tunnel "$@" ;;
    status) [[ $# -eq 0 ]] || die 'status 不接受额外参数。'; status_tunnel ;;
    diagnose) [[ $# -eq 0 ]] || die 'diagnose 不接受额外参数。'; diagnose_tunnel ;;
    update) [[ $# -eq 0 ]] || die 'update 不接受额外参数。'; update_cloudflared ;;
    github-proxy) [[ $# -le 1 ]] || die 'github-proxy 最多接受一个选项。'; manage_github_proxy "${1:-}" ;;
    client-config) [[ $# -le 1 ]] || die 'client-config 最多接受一个域名参数。'; client_config "${1:-}" ;;
    uninstall) [[ $# -eq 0 ]] || die 'uninstall 不接受额外参数。'; uninstall_tunnel ;;
    help|-h|--help) usage ;;
    *) die "未知命令：${command}（运行 '$0 help' 查看用法）" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
