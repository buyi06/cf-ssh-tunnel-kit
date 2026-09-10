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
readonly PID_FILE="${SERVICE_DIR}/tunnel.pid"
readonly LOG_FILE="${SERVICE_DIR}/tunnel.log"
readonly RUNNER_SCRIPT="${SERVICE_DIR}/run.sh"
readonly AUTOSTART_FILE='/etc/profile.d/cf-ssh-tunnel-autostart.sh'
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

# 托管方式：优先 systemd；没有正在运行的 systemd（Docker 容器、DSW/Colab、WSL 等）时
# 退化为独立后台进程，由脚本自己用 PID 文件管理。SYSTEMD_RUNTIME_DIR 可在测试中覆盖。
SYSTEMD_RUNTIME_DIR='/run/systemd/system'
SERVICE_MODE=''
SERVICE_GROUP='root'
CREDENTIAL_MODE='0600'
RELEASE_PAGE_URL=''
SSHD_CONFIG_FILE=''
SSH_AUTH_METHOD=''
SSH_PASSWORD=''
FORCE_PASSWORD=0
NO_PASSWORD=0
CF_BIN=''
PACKAGE_MANAGER=''
TUNNEL_UUID=''
TUNNEL_NAME=''
PUBLIC_HOSTNAME=''
PROTOCOL='auto'
LOGIN_HOME=''
CERT_FILE=''
TUNNEL_CREATED=0
INSTALL_USER=''

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
trap 'cleanup_login_certificate; exit 129' HUP
trap 'cleanup_login_certificate; exit 130' INT
trap 'cleanup_login_certificate; exit 143' TERM

usage() {
  cat <<'EOF'
用法：
  sudo bash cf-ssh-tunnel.sh install [--mainland|--auto|--quic]
  sudo bash cf-ssh-tunnel.sh status
  sudo bash cf-ssh-tunnel.sh logs
  sudo bash cf-ssh-tunnel.sh restart
  sudo bash cf-ssh-tunnel.sh diagnose
  sudo bash cf-ssh-tunnel.sh credentials [--set-password]
  sudo bash cf-ssh-tunnel.sh update
  sudo bash cf-ssh-tunnel.sh autostart [--show|--enable|--disable]
  sudo bash cf-ssh-tunnel.sh github-proxy [--show|--disable]
  bash cf-ssh-tunnel.sh client-config [ssh.example.com] [用户名]
  sudo bash cf-ssh-tunnel.sh uninstall

最简单的安装方式：
  sudo bash cf-ssh-tunnel.sh install --mainland

在项目根目录一键启动（自动更新代码 + 安装或拉起现有 Tunnel + 打印连接信息）：
  sudo bash start.sh

命令说明：
  install        首次运行：自动安装 cloudflared、输出浏览器授权链接并创建 Tunnel、DNS 路由、SSH 配置和托管服务。本机已配置过时直接加载现有状态与连接方式，不会重复安装。
  --mainland     固定使用 HTTP/2（TCP/7844），适合 UDP/QUIC 不稳定的网络。
  --auto         先尝试 QUIC，UDP 不可用时由 cloudflared 回退 HTTP/2（默认）。
  --quic         固定使用 QUIC（UDP/7844）。
  --set-password 额外生成一个随机登录密码并打印（即使本机已有公钥）。
  --no-password  不设置密码，只检查并显示现有登录方式。
  status         显示 Tunnel 名称、域名、托管方式、进程状态和本机 SSH 状态。
  logs           查看最近 80 行 Tunnel 日志：systemd 用 journalctl，进程模式读日志文件。
  restart        重启 Tunnel 服务，systemd 与进程模式都可用；容器重启后也用它重新拉起。
  diagnose       检查 DNS、TCP/7844、本机 SSH 和最近服务日志；不会修改配置。
  credentials    显示登录所需的全部信息（域名、用户名、认证方式、已授权公钥指纹）；带上 --set-password 会生成并设置一个新密码后打印。
  update         使用系统包管理器更新 cloudflared。
  autostart      查看或开关「登录自启」：无 systemd 的环境下，登录 shell 时自动拉起 Tunnel。
  github-proxy   测试候选 GitHub 代理，自动选择低延迟可用项并全局加速 GitHub Git 克隆；--show 查看，--disable 关闭。
  client-config  输出可直接使用的 SSH 客户端配置（可选参数：域名、用户名）；不带参数时自动读取本机配置。
  uninstall      仅删除本机服务和凭据；不会删除 Cloudflare 控制台中的 Tunnel 或 DNS 记录。

托管方式：
  有正在运行的 systemd 时创建开机自启的受限 systemd 服务，Tunnel 异常退出后自动重启（Restart=on-failure）；
  容器、DSW/Colab、WSL 等没有 systemd 的环境自动改用后台看护进程，Tunnel 异常退出后自动重启
  （间隔 5 秒起、最长 60 秒）；PID 文件 /etc/cf-ssh-tunnel/tunnel.pid，
  日志 /etc/cf-ssh-tunnel/tunnel.log。
  进程模式还会写入 /etc/profile.d/cf-ssh-tunnel-autostart.sh，让容器/机器重启后的首次登录 shell
  自动拉起 Tunnel；用 autostart --disable 关闭，或 autostart --show 查看当前状态。

安全说明：
  本脚本不会开放服务器入站端口，不修改 sshd_config，也不创建裸 TCP/22 公网转发。
  若目标账户既没有公钥、也没有可用密码，脚本会生成一个随机密码写入本机 /etc/shadow 并只打印一次，
  保证 Tunnel 建好后立刻能登录（用 --no-password 关闭该行为，用 --set-password 强制重置密码）。
  脚本会自动创建 Tunnel、DNS 路由和 ssh://localhost:22 配置；连接继续使用 Linux 原有的 SSH 密钥或密码认证。
  GitHub 代理仅影响 Git 的 github.com 克隆与拉取（git push 仍直连 GitHub），不设置 HTTP(S)_PROXY，不代理系统更新、Cloudflare 授权或其他网络流量。
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请以 root 运行，例如：sudo bash $0 install"
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [[ -d "$SYSTEMD_RUNTIME_DIR" ]]
}

detect_service_mode() {
  if systemd_available; then
    SERVICE_MODE='systemd'
  else
    SERVICE_MODE='process'
  fi
}

service_mode_label() {
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    printf '%s' 'systemd 服务'
  else
    printf '%s' '后台进程（未检测到 systemd）'
  fi
}

require_service_environment() {
  detect_service_mode
  if [[ "$SERVICE_MODE" == 'process' ]]; then
    warn '未检测到正在运行的 systemd，将以「后台看护进程」托管 Tunnel（Docker 容器、DSW/Colab、WSL 等环境属于此类）。'
    info "看护进程会在 Tunnel 异常退出后自动重启；PID 文件：${PID_FILE}，日志：${LOG_FILE}"
  fi
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

fetch_release_page() {
  # 先直连 GitHub；连不通（大陆网络常见超时）时依次尝试候选代理。成功时输出页面临时文件路径。
  local prefix tmp final_url
  RELEASE_PAGE_URL=''
  for prefix in '' "${GITHUB_PROXY_CANDIDATES[@]}"; do
    tmp="$(mktemp)"
    if final_url="$(curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
      --retry 2 --retry-delay 2 --connect-timeout 5 --max-time 30 \
      --output "$tmp" --write-out '%{url_effective}' "${prefix}${CLOUDFLARED_RELEASE_PAGE}" 2>/dev/null)"; then
      RELEASE_PAGE_URL="$final_url"
      printf '%s' "$tmp"
      return 0
    fi
    rm -f "$tmp"
  done
  return 1
}

get_cloudflared_release_metadata() {
  local tmp tag digest
  tmp="$(fetch_release_page || true)"
  [[ -n "$tmp" ]] || return 1
  tag="${RELEASE_PAGE_URL##*/}"
  # 经代理取回时最终 URL 属于代理，改从页面 HTML 解析版本号。
  if [[ ! "$tag" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]]; then
    tag="$(grep -Eo 'releases/tag/[0-9]{4}\.[0-9]+\.[0-9]+' "$tmp" | head -n 1 | sed 's#releases/tag/##' || true)"
  fi
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
  # 首 1KB 探测只反映握手延迟，不反映吞吐；deb 约 30MB，放宽下载时限避免慢代理被误判失败。
  if ! curl_secure --max-time 600 -o "$tmp" "${best_proxy}${asset_url}"; then
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
  local proxy key value
  for proxy in "${GITHUB_PROXY_CANDIDATES[@]}"; do
    key="url.${proxy}${GITHUB_PREFIX}.insteadOf"
    git config --global --unset-all "$key" >/dev/null 2>&1 || true
  done
  # pushInsteadOf 的键名固定；仅当当前值确属本脚本写入的已知代理时才删除，避免误删用户自定义规则。
  value="$(git config --global --get "url.${GITHUB_PREFIX}.pushInsteadOf" 2>/dev/null || true)"
  for proxy in "${GITHUB_PROXY_CANDIDATES[@]}"; do
    if [[ "$value" == "${proxy}${GITHUB_PREFIX}" ]]; then
      git config --global --unset-all "url.${GITHUB_PREFIX}.pushInsteadOf" >/dev/null 2>&1 || true
      break
    fi
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
  # insteadOf 会同时劫持 push，而加速代理只支持下载；pushInsteadOf 把推送改回直连 GitHub。
  git config --global "url.${GITHUB_PREFIX}.pushInsteadOf" "${best_proxy}${GITHUB_PREFIX}"
  write_github_proxy_state "$best_proxy" "$best_latency"
  info "已选择 ${best_proxy}（${best_latency} ms）：克隆与拉取经代理加速，git push 仍直连 GitHub。"
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

resolve_service_identity() {
  # systemd 模式用受限账户运行并让该组只读凭据；进程模式（容器里通常是 root）保持 root 独占 0600。
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    ensure_service_user
    SERVICE_GROUP="$SERVICE_USER"
    CREDENTIAL_MODE='0640'
  else
    SERVICE_GROUP='root'
    CREDENTIAL_MODE='0600'
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
  if (( tcp_ok == 1 )); then
    return 0
  fi
  if [[ "$PROTOCOL" == 'http2' ]]; then
    die '无法连接 Cloudflare TCP/7844；--mainland 模式依赖 TCP 出站，请检查防火墙、出口策略或所在网络限制。'
  fi
  # QUIC 模式走 UDP/7844，TCP 不通不应直接判死；交给 cloudflared 自行尝试。
  warn 'TCP/7844 不通，将改用 QUIC（UDP/7844）尝试连接；若 UDP 同样受限，Tunnel 将无法建立。'
}

check_local_ssh() {
  local unit='' listening=0
  # systemd 只在可用时用于确认服务名；容器里 sshd 常由镜像直接拉起，故以端口/进程为准。
  if command -v systemctl >/dev/null 2>&1 && [[ -d "$SYSTEMD_RUNTIME_DIR" ]]; then
    if systemctl is-active --quiet ssh; then unit='ssh'; fi
    if systemctl is-active --quiet sshd; then unit='sshd'; fi
  fi
  if command -v ss >/dev/null 2>&1 && ss -lntH '( sport = :22 )' 2>/dev/null | grep -q .; then
    listening=1
  elif command -v pgrep >/dev/null 2>&1 && pgrep -x sshd >/dev/null 2>&1; then
    listening=1
  fi
  if (( listening == 1 )); then
    if [[ -n "$unit" ]]; then
      info "本机 SSH 正在监听 22 端口（服务：${unit}）。"
    else
      info '本机 SSH 正在监听 22 端口。'
    fi
    return 0
  fi
  if [[ -n "$unit" ]]; then
    warn 'SSH 服务已运行，但未能确认 22 端口监听；请确认 sshd 端口确为 22。'
    return 0
  fi
  warn '未检测到监听 22 端口的 SSH 服务（sshd）。请先安装并启动 SSH，例如容器内执行：apt-get install -y openssh-server && /usr/sbin/sshd'
  return 1
}

login_user_home() {
  local user="$1" home=''
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  printf '%s' "${home:-/root}"
}

authorized_key_lines() {
  [[ -r "$1" ]] || return 0
  grep -E '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-(ssh-ed25519|ecdsa-sha2))' "$1" 2>/dev/null || true
}

user_has_password() {
  local user="$1" field=''
  # 直接读 /etc/shadow：以 ! 或 * 开头表示已锁定/无可用密码，此时密码登录必然失败。
  [[ -r /etc/shadow ]] || return 1
  field="$(awk -F: -v u="$user" '$1 == u { print $2 }' /etc/shadow 2>/dev/null || true)"
  [[ -n "$field" && "$field" != '!'* && "$field" != '*'* ]]
}

password_login_allowed() {
  local user="$1" effective=''
  # SSHD_CONFIG_FILE 仅用于测试与特殊部署：留空时读取系统 sshd 有效配置。
  if [[ -n "$SSHD_CONFIG_FILE" ]]; then
    effective="$(sshd -T -f "$SSHD_CONFIG_FILE" 2>/dev/null || true)"
  else
    effective="$(sshd -T 2>/dev/null || true)"
  fi
  # 无法读取有效配置时不阻塞流程，交由用户按提示判断。
  [[ -n "$effective" ]] || return 0
  grep -qi '^passwordauthentication yes' <<<"$effective" || return 1
  if [[ "$user" == 'root' ]]; then
    grep -qi '^permitrootlogin yes' <<<"$effective" || return 1
  fi
  return 0
}

generate_password() {
  local password=''
  if command -v openssl >/dev/null 2>&1; then
    password="$(openssl rand -base64 24 2>/dev/null | tr -d '\n/+=' | cut -c1-16 || true)"
  fi
  if [[ -z "$password" ]]; then
    password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
  fi
  [[ -n "$password" ]] || die '无法生成随机密码（缺少 openssl 且 /dev/urandom 不可读）。'
  printf '%s' "$password"
}

check_ssh_login() {
  local user="$1" home authorized='' key_count=0
  home="$(login_user_home "$user")"
  authorized="${home}/.ssh/authorized_keys"
  key_count="$(authorized_key_lines "$authorized" | grep -c . || true)"

  if (( key_count > 0 )); then
    SSH_AUTH_METHOD='key'
    info "服务器账户 ${user} 已配置 ${key_count} 个公钥，可用对应私钥直接登录。"
    if (( FORCE_PASSWORD == 0 )); then
      return 0
    fi
    warn '已指定 --set-password，将额外设置一个密码，两种方式都能登录。'
  fi

  if (( NO_PASSWORD == 1 )); then
    warn '已指定 --no-password，脚本不会设置密码；请自行准备 SSH 密钥或密码。'
    return 0
  fi

  if (( FORCE_PASSWORD == 0 )) && (( key_count == 0 )) && user_has_password "$user"; then
    SSH_AUTH_METHOD='password'
    warn "服务器账户 ${user} 已有密码；Linux 不保存明文，脚本无法读出，请用你设置过的那个密码登录。"
    info "忘记或不知道密码时执行：sudo bash $0 credentials --set-password（重置为新密码并立即打印）"
    return 0
  fi

  if ! password_login_allowed "$user"; then
    warn "服务器 sshd 当前不允许账户 ${user} 使用密码登录，脚本不会代改 sshd_config。"
    say '如需改用密码登录，请在服务器上执行（Debian/Ubuntu/RHEL9 等支持 sshd_config.d 的系统）：'
    say "    printf 'PasswordAuthentication yes\\nPermitRootLogin yes\\n' > /etc/ssh/sshd_config.d/99-cf-ssh-tunnel.conf"
    say '    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || kill -HUP "$(pgrep -x sshd | head -n 1)"'
    say '    （老系统需手工修改 /etc/ssh/sshd_config 中对应的行，sshd 只认第一个出现的同名项）'
    say "然后执行：sudo bash $0 credentials --set-password"
    return 0
  fi

  SSH_PASSWORD="$(generate_password)"
  printf '%s:%s\n' "$user" "$SSH_PASSWORD" | chpasswd || die "设置账户 ${user} 的密码失败。"
  SSH_AUTH_METHOD='password'
  say
  info "已为服务器账户 ${user} 设置登录密码（只保存在本机 /etc/shadow，脚本不写入任何文件）："
  say "    用户名：${user}"
  say "    密码：${SSH_PASSWORD}"
  say '    请立刻保存上面的密码，脚本不会再次显示它。'
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
    if [[ "$output" =~ already[[:space:]]exists ]]; then
      die "已存在同名 Tunnel：${TUNNEL_NAME}（通常是上次未完成的安装残留，或容器重建后本机配置丢失）。请执行 '$0 uninstall'，并到 Cloudflare Zero Trust 控制台（Networks → Tunnels）删除旧 Tunnel 后重试。"
    fi
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

  install -d -o root -g "$SERVICE_GROUP" -m 0750 "$SERVICE_DIR"
  install -o root -g "$SERVICE_GROUP" -m "$CREDENTIAL_MODE" "$credential_source" "${SERVICE_DIR}/${TUNNEL_UUID}.json"
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
  install -o root -g "$SERVICE_GROUP" -m "$CREDENTIAL_MODE" "$tmp" "$CONFIG_FILE"
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
INSTALL_USER=${INSTALL_USER}
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
  INSTALL_USER=''
  while IFS='=' read -r key value; do
    case "$key" in
      TUNNEL_UUID) TUNNEL_UUID="$value" ;;
      TUNNEL_NAME) TUNNEL_NAME="$value" ;;
      PUBLIC_HOSTNAME) PUBLIC_HOSTNAME="$value" ;;
      PROTOCOL) PROTOCOL="$value" ;;
      INSTALL_USER) INSTALL_USER="$value" ;;
    esac
  done <"$META_FILE"
  [[ -n "$TUNNEL_UUID" && -n "$PUBLIC_HOSTNAME" ]]
}

write_unit() {
  local tmp edge_ip_version='auto'
  case "$PROTOCOL" in auto|http2|quic) ;; *) die "无效协议：${PROTOCOL}" ;; esac
  # 大陆网络的 IPv6 出口常见半残（解析得到 v6 却连不通），HTTP/2 模式固定走 IPv4 边缘更稳。
  if [[ "$PROTOCOL" == 'http2' ]]; then
    edge_ip_version='4'
  fi
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
ExecStart=${CF_BIN} tunnel --no-autoupdate --config ${CONFIG_FILE} --protocol ${PROTOCOL} --edge-ip-version ${edge_ip_version} --retries 5 run ${TUNNEL_UUID}
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

process_is_tunnel_service() {
  local pid="$1" cmdline=''
  [[ -r "/proc/${pid}/cmdline" ]] || return 0
  cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  # 进程模式下 PID 文件记录的是看护脚本；升级前启动的旧进程则直接是 cloudflared。
  [[ "$cmdline" == *'cloudflared'* || "$cmdline" == *"$RUNNER_SCRIPT"* ]]
}

process_service_pid() {
  local pid=''
  if [[ -r "$PID_FILE" ]]; then
    read -r pid <"$PID_FILE" || true
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && process_is_tunnel_service "$pid"; then
      printf '%s' "$pid"
      return 0
    fi
  fi
  # PID 文件缺失或进程已被回收：按命令行锚定到本项目的看护脚本，避免误伤只是提到配置路径的进程。
  if command -v pgrep >/dev/null 2>&1; then
    pid="$(pgrep -f -- "^[^ ]*(bash|sh) ${RUNNER_SCRIPT}\$" 2>/dev/null | head -n 1 || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      printf '%s' "$pid"
      return 0
    fi
  fi
  return 1
}

write_process_runner() {
  local tmp edge_ip_version='auto'
  if [[ "$PROTOCOL" == 'http2' ]]; then
    edge_ip_version='4'
  fi
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
#!/usr/bin/env bash
# 由 cf-ssh-tunnel-kit 自动生成（重新 install 会覆盖，请勿手工编辑）。
# 作用：看护 Tunnel 进程，异常退出后自动重启；停止本进程即可结束 Tunnel。
set -uo pipefail
LOG='${LOG_FILE}'
delay=5
child=''
stop() {
  if [[ -n "\$child" ]]; then
    kill "\$child" 2>/dev/null || true
    wait "\$child" 2>/dev/null || true
  fi
  exit 0
}
trap stop TERM INT
while true; do
  start="\$(date +%s)"
  '${CF_BIN}' tunnel --no-autoupdate --config '${CONFIG_FILE}' --protocol '${PROTOCOL}' --edge-ip-version '${edge_ip_version}' --retries 5 run '${TUNNEL_UUID}' >>"\$LOG" 2>&1 &
  child=\$!
  wait "\$child"
  code=\$?
  elapsed=\$(( \$(date +%s) - start ))
  printf '[看护] Tunnel 进程退出（退出码 %s，存活 %s 秒），%s 秒后重启\n' "\$code" "\$elapsed" "\$delay" >>"\$LOG"
  sleep "\$delay"
  if (( elapsed < 10 )); then
    delay=\$(( delay * 2 ))
    if (( delay > 60 )); then delay=60; fi
  else
    delay=5
  fi
done
EOF
  install -o root -g root -m 0755 "$tmp" "$RUNNER_SCRIPT"
  rm -f "$tmp"
}

start_process_service() {
  local -a launcher=()
  [[ -n "$CF_BIN" && -x "$CF_BIN" ]] || die '未找到 cloudflared 可执行文件，无法启动 Tunnel；请先执行 update。'
  if process_service_pid >/dev/null; then
    info 'Tunnel 进程已在运行，无需重复启动。'
    return 0
  fi
  install -d -o root -g root -m 0750 "$SERVICE_DIR"
  [[ -r "$RUNNER_SCRIPT" ]] || write_process_runner
  # 与 systemd 单元保持同一组运行参数；setsid 让看护进程脱离当前终端会话，关掉终端不会带走 Tunnel。
  command -v setsid >/dev/null 2>&1 && launcher=(setsid)
  launcher+=(nohup bash "$RUNNER_SCRIPT")
  "${launcher[@]}" </dev/null >>"$LOG_FILE" 2>&1 &
  printf '%s\n' "$!" >"$PID_FILE"
  info "Tunnel 看护进程已启动（PID $!），日志：${LOG_FILE}"
}

stop_process_service() {
  local pid='' i
  if ! pid="$(process_service_pid)"; then
    rm -f "$PID_FILE"
    return 0
  fi
  # 看护脚本收到 TERM 会先结束 cloudflared 子进程再退出，因此这里只需终止看护进程。
  kill "$pid" 2>/dev/null || true
  for ((i = 0; i < 10; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "Tunnel 进程未在 10 秒内退出，将强制结束（PID ${pid}）。"
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  info 'Tunnel 进程已停止。'
}

install_autostart() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# 由 cf-ssh-tunnel-kit 写入：容器等无 systemd 环境下，登录 shell 时自动拉起 Tunnel。
# 关闭方式：sudo bash <项目目录>/scripts/cf-ssh-tunnel.sh autostart --disable，或直接删除本文件。
if [ -r ${RUNNER_SCRIPT} ] && [ -w ${SERVICE_DIR} ]; then
  _cfkit_pid="\$(cat ${PID_FILE} 2>/dev/null || true)"
  if [ -z "\$_cfkit_pid" ] || ! kill -0 "\$_cfkit_pid" 2>/dev/null; then
    setsid nohup /bin/bash ${RUNNER_SCRIPT} >>${LOG_FILE} 2>&1 &
    echo \$! >${PID_FILE} 2>/dev/null || true
  fi
  unset _cfkit_pid
fi
EOF
  install -o root -g root -m 0644 "$tmp" "$AUTOSTART_FILE"
  rm -f "$tmp"
}

show_autostart() {
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    say '当前托管方式：systemd 服务（开机自启由 systemd 负责，不使用登录钩子）。'
  else
    say '当前托管方式：后台看护进程（未检测到 systemd），崩溃后自动重启。'
  fi
  if [[ -r "$AUTOSTART_FILE" ]]; then
    say "登录自启：已启用（${AUTOSTART_FILE}）"
    say '容器或机器重启后，任意一次登录 shell（例如打开终端）都会自动拉起 Tunnel。'
  else
    say '登录自启：未启用'
    say "启用方式：sudo bash $0 autostart --enable（重启后需手动 restart）"
  fi
}

enable_autostart() {
  if [[ "$SERVICE_MODE" != 'process' ]]; then
    info 'systemd 模式已由 systemd 负责开机自启，无需登录钩子。'
    return 0
  fi
  [[ -r "$RUNNER_SCRIPT" ]] || die '未找到看护脚本，请先重新执行 install。'
  install_autostart
  info "已启用登录自启：${AUTOSTART_FILE}（重启后首次登录 shell 自动拉起 Tunnel）。"
}

disable_autostart() {
  rm -f "$AUTOSTART_FILE"
  info '已关闭登录自启；当前正在运行的 Tunnel 不受影响。'
}

manage_autostart() {
  require_root
  detect_service_mode
  case "${1:-}" in
    ''|--show) show_autostart ;;
    --enable) enable_autostart ;;
    --disable) disable_autostart ;;
    *) die 'autostart 仅支持 --show、--enable 或 --disable。' ;;
  esac
}

wait_for_systemd_service() {
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

wait_for_process_service() {
  local i pid
  for ((i = 0; i < 15; i++)); do
    if pid="$(process_service_pid)"; then
      info "Tunnel 进程运行中（PID ${pid}）。"
      return 0
    fi
    sleep 1
  done
  error 'Tunnel 进程未能在 15 秒内启动，以下为最近日志：'
  tail -n 60 "$LOG_FILE" 2>/dev/null || true
  die 'Tunnel 服务启动失败。请执行 diagnose 查看网络和日志。'
}

wait_for_service() {
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    wait_for_systemd_service
  else
    wait_for_process_service
  fi
}

service_is_active() {
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    systemctl is-active --quiet "$SERVICE_NAME"
  else
    process_service_pid >/dev/null
  fi
}

start_tunnel_service() {
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  else
    start_process_service
  fi
}

stop_tunnel_service() {
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  else
    stop_process_service
  fi
}

install_service() {
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    write_unit
    systemctl daemon-reload
  else
    write_process_runner
    install_autostart
  fi
}

show_process_mode_notice() {
  say
  info '当前环境没有 systemd，Tunnel 由后台看护进程托管：异常退出后自动重启（间隔 5 秒起，最长 60 秒）。'
  say "看护脚本：${RUNNER_SCRIPT}；运行日志：${LOG_FILE}"
  if [[ -r "$AUTOSTART_FILE" ]]; then
    say '已启用登录自启：容器或机器重启后，任意一次登录 shell（例如打开终端）都会自动拉起 Tunnel。'
    say "如需关闭：sudo bash $0 autostart --disable"
  else
    warn '未启用登录自启：重启后需手动执行 restart 拉起 Tunnel。'
  fi
  say "查看运行日志：sudo bash $0 logs"
}

restart_tunnel() {
  require_root
  detect_service_mode
  read_metadata || die "未发现本机 Tunnel 配置（${META_FILE}）。请先执行 install。"
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    [[ -e "$UNIT_FILE" ]] || die "检测到本机配置但缺少 systemd 服务文件（可能是上次未完成的安装，或配置来自容器环境）。请执行 'sudo bash $0 uninstall' 清理后重新 install。"
    systemctl restart "$SERVICE_NAME"
  else
    find_cloudflared || die '未找到 cloudflared，无法重启 Tunnel；请先执行 update。'
    stop_process_service
    start_process_service
  fi
  wait_for_service
  info 'Tunnel 服务已重启。'
}

show_tunnel_logs() {
  require_root
  detect_service_mode
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
  else
    [[ -r "$LOG_FILE" ]] || die "未找到日志文件 ${LOG_FILE}；进程模式尚未启动过 Tunnel。"
    tail -n 80 "$LOG_FILE"
  fi
}

print_connection_info() {
  local user="${1:-root}" home='' authorized=''
  say '════════ 连接信息（照着做就能连上） ════════'
  say
  if [[ -n "$PUBLIC_HOSTNAME" ]]; then
    say "服务器地址：${PUBLIC_HOSTNAME}（Cloudflare Tunnel 域名）"
  else
    say '服务器地址：尚未创建 Tunnel（执行 install 后这里会显示域名）'
  fi
  say "登录用户：${user}"
  case "$SSH_AUTH_METHOD" in
    key)
      say '认证方式：公钥（用你手上对应的私钥登录，不需要密码）'
      home="$(login_user_home "$user")"
      authorized="${home}/.ssh/authorized_keys"
      if [[ -r "$authorized" ]]; then
        say "服务器已授权的公钥（${authorized}）："
        ssh-keygen -lf "$authorized" 2>/dev/null | sed 's/^/    /' || true
        say '    指纹对不上？说明这些都不是你的密钥，可执行 credentials --set-password 改用密码登录。'
      fi
      ;;
    password)
      say '认证方式：密码'
      if [[ -n "$SSH_PASSWORD" ]]; then
        say "登录密码：${SSH_PASSWORD}"
        say '    （这是脚本刚设置的密码，只显示这一次，请立刻存下来）'
      else
        say '登录密码：服务器上原有的密码（脚本读不到明文，用你设置过的那个）'
      fi
      ;;
    *)
      say '认证方式：沿用服务器上原有的 SSH 密钥或密码'
      say '    想看服务器上到底有哪些公钥、或重置密码：sudo bash '"$0"' credentials'
      ;;
  esac
  say
  if [[ -z "$PUBLIC_HOSTNAME" ]]; then
    return 0
  fi
  say '客户端（Windows / macOS / Linux，需先自行安装 cloudflared）任选一种：'
  say
  say '① 一条命令直接连（不改任何配置）：'
  say "    ssh -o ProxyCommand='cloudflared access ssh --hostname %h' ${user}@${PUBLIC_HOSTNAME}"
  say
  say '② 写进客户端 ~/.ssh/config（推荐，之后直接 ssh 就能连）：'
  say "    Host ${PUBLIC_HOSTNAME}"
  say "        HostName ${PUBLIC_HOSTNAME}"
  say "        User ${user}"
  say '        ProxyCommand cloudflared access ssh --hostname %h'
  say "    然后执行：ssh ${user}@${PUBLIC_HOSTNAME}"
  say
  say '③ 想改用密钥登录（以后不用记密码）：'
  say "    ssh-copy-id -o ProxyCommand='cloudflared access ssh --hostname %h' ${user}@${PUBLIC_HOSTNAME}"
  say
  say "认证沿用服务器上 ${user} 原有的 SSH 密钥或密码；要换登录用户，改掉 User 和命令里的 ${user} 即可。"
}

show_connection_notice() {
  say
  say '第 4 步：Tunnel 已自动配置完成。'
  print_connection_info "${INSTALL_USER:-root}"
  say
  warn '该 SSH 域名现在可从 Internet 访问：请使用强密码或密钥登录，并保持系统更新。'
  if [[ -n "$SSH_PASSWORD" ]]; then
    say '    本次生成的是 16 位随机密码；想更省事可按上面 ③ 改用密钥登录。'
  fi
  info '为降低风险，授权期间使用的账户级证书已自动删除；运行服务只保留本 Tunnel 的专用凭据。'
}

show_mainland_notice() {
  say
  warn '中国大陆模式已启用：Tunnel 将固定使用 HTTP/2（TCP/7844），不依赖 UDP/QUIC。'
  warn '它无法保证任意网络均能连接；若 TCP/7844 或 DNS 不可达，Cloudflare Tunnel 无法建立。'
  say
}

load_existing_install() {
  if [[ "$SERVICE_MODE" == 'systemd' && ! -e "$UNIT_FILE" ]]; then
    die "检测到残留配置但缺少 systemd 服务文件（可能是上次未完成的安装）。请执行 'sudo bash $0 uninstall' 清理后重新 install。"
  fi
  if ! read_metadata; then
    die "检测到已有配置但无法读取 ${META_FILE}。请执行 'sudo bash $0 uninstall' 清理后重新 install。"
  fi
  say
  say '本机已配置过 cf-ssh-tunnel，直接加载现有安装：'
  say "Tunnel 名称：${TUNNEL_NAME:-未知}"
  say "Tunnel UUID：${TUNNEL_UUID}"
  say "SSH 域名：${PUBLIC_HOSTNAME}"
  say "传输协议：${PROTOCOL}"
  say
  if service_is_active; then
    info 'Tunnel 服务正在运行，无需重新安装。'
  else
    warn 'Tunnel 服务未在运行，正在尝试启动……'
    if [[ "$SERVICE_MODE" == 'process' ]]; then
      find_cloudflared || die "未找到 cloudflared，无法以进程模式启动 Tunnel。请执行 'sudo bash $0 update' 重新安装。"
    fi
    start_tunnel_service
    if service_is_active; then
      info '服务已重新启动，运行正常。'
    else
      die "服务启动失败。请执行 '$0 diagnose' 排查网络与服务日志。"
    fi
  fi
  say
  say '== SSH 登录体检 =='
  check_ssh_login "${INSTALL_USER:-root}"
  print_connection_info "${INSTALL_USER:-root}"
  say
  say "查看详细状态：sudo bash $0 status；按需生成客户端配置：bash $0 client-config ${PUBLIC_HOSTNAME} [用户名]"
  say '如需彻底重来：sudo bash '"$0"' uninstall 后再 install。'
}

install_tunnel() {
  PROTOCOL='auto'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mainland) PROTOCOL='http2' ;;
      --auto) PROTOCOL='auto' ;;
      --quic) PROTOCOL='quic' ;;
      --set-password) FORCE_PASSWORD=1 ;;
      --no-password) NO_PASSWORD=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "未知 install 选项：$1" ;;
    esac
    shift
  done

  require_root
  require_service_environment
  if [[ -e "$UNIT_FILE" || -e "$META_FILE" || -e "$SERVICE_DIR" ]]; then
    load_existing_install
    return 0
  fi
  ensure_cloudflared
  check_network
  check_local_ssh || die 'SSH 未就绪，拒绝创建没有本机 SSH 服务的 Tunnel。'
  resolve_service_identity
  INSTALL_USER="${SUDO_USER:-$(id -un)}"
  say
  say '== SSH 登录体检 =='
  check_ssh_login "$INSTALL_USER"
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
  install_service
  start_tunnel_service
  wait_for_service
  show_connection_notice
  if [[ "$SERVICE_MODE" == 'process' ]]; then
    show_process_mode_notice
  fi
}

status_tunnel() {
  local pid=''
  require_root
  detect_service_mode
  if ! read_metadata; then
    warn "未发现 ${SERVICE_NAME} 的本地配置。"
    return 1
  fi
  if find_cloudflared; then
    show_cloudflared_version
  else
    warn '未检测到 cloudflared；status 仅查看状态，不会自动安装（需要安装请运行 update）。'
  fi
  say "Tunnel 名称：${TUNNEL_NAME:-未知}"
  say "Tunnel UUID：${TUNNEL_UUID}"
  say "SSH 域名：${PUBLIC_HOSTNAME}"
  say "传输协议：${PROTOCOL}"
  say "登录用户：${INSTALL_USER:-root}（认证方式与密码：sudo bash $0 credentials）"
  say "托管方式：$(service_mode_label)"
  say "凭据文件权限：$(stat -c '%a %U:%G %n' "${SERVICE_DIR}/${TUNNEL_UUID}.json" 2>/dev/null || echo '文件缺失')"
  say
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
  else
    if pid="$(process_service_pid)"; then
      info "Tunnel 进程运行中（PID ${pid}），日志：${LOG_FILE}"
      tail -n 20 "$LOG_FILE" 2>/dev/null || true
    else
      warn 'Tunnel 进程未在运行。可执行 restart 重新拉起。'
    fi
  fi
  say
  check_local_ssh || true
}

diagnose_tunnel() {
  require_root
  detect_service_mode
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
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    if [[ -e "$UNIT_FILE" ]]; then
      systemctl --no-pager --full status "$SERVICE_NAME" || true
      journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
    else
      warn "未安装 ${SERVICE_NAME} 服务。"
    fi
  else
    local pid=''
    if pid="$(process_service_pid)"; then
      info "Tunnel 进程运行中（PID ${pid}）。"
    else
      warn 'Tunnel 进程未在运行。可执行 restart 重新拉起。'
    fi
    if [[ -r "$LOG_FILE" ]]; then
      tail -n 80 "$LOG_FILE"
    else
      warn "未找到日志文件 ${LOG_FILE}。"
    fi
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
  # restart 会按当前托管方式（systemd 或后台进程）自动选择重启方式。
  info "如需立即加载新版本，请执行：sudo bash $0 restart"
}

client_config() {
  local hostname="${1:-}" user="${2:-}"
  if [[ -z "$hostname" ]] && [[ -r "$META_FILE" ]]; then
    read_metadata || true
    hostname="$PUBLIC_HOSTNAME"
    [[ -n "$user" ]] || user="${INSTALL_USER:-}"
  fi
  [[ -n "$hostname" ]] || die '请提供 SSH 域名，例如：client-config ssh.example.com'
  hostname="${hostname,,}"
  validate_hostname "$hostname" || die '域名格式无效，例如 ssh.example.com。'
  [[ -n "$user" ]] || user='root'
  cat <<EOF
请将以下内容加入 SSH 客户端的 ~/.ssh/config（客户端也需安装 cloudflared）：

Host ${hostname}
    HostName ${hostname}
    User ${user}
    ProxyCommand cloudflared access ssh --hostname %h

连接命令：
  ssh ${user}@${hostname}

首次连接会通过 cloudflared 将流量转入 Tunnel，再使用 Linux 原有的 SSH 密钥或密码认证。
EOF
}

manage_credentials() {
  local user=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --set-password) FORCE_PASSWORD=1 ;;
      --show) : ;;
      *) die 'credentials 仅支持 --show 或 --set-password。' ;;
    esac
    shift
  done
  require_root
  read_metadata || true
  user="${INSTALL_USER:-root}"
  say '== SSH 登录体检 =='
  check_ssh_login "$user"
  say
  print_connection_info "$user"
}

uninstall_tunnel() {
  require_root
  detect_service_mode
  [[ -e "$UNIT_FILE" || -e "$SERVICE_DIR" ]] || die '未发现本脚本创建的本地配置。'
  local old_uuid=''
  if read_metadata; then old_uuid="$TUNNEL_UUID"; fi
  say '该操作将停止并删除本机托管服务、配置和 Tunnel 专用凭据。'
  say '为避免账户级误删，它不会删除 Cloudflare 控制台中的 Tunnel 或 DNS 记录。'
  if [[ -n "$old_uuid" ]]; then say "如不再使用，请在 Cloudflare 控制台删除 Tunnel：${old_uuid}"; fi
  local answer=''
  if ! read -r -p '若确认，请输入 DELETE：' answer; then
    die '未读取到确认输入，已取消。'
  fi
  [[ "$answer" == 'DELETE' ]] || die '已取消。'
  stop_tunnel_service
  if [[ "$SERVICE_MODE" == 'systemd' ]]; then
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
  else
    rm -f "$AUTOSTART_FILE"
  fi
  rm -rf "$SERVICE_DIR"
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
    logs) [[ $# -eq 0 ]] || die 'logs 不接受额外参数。'; show_tunnel_logs ;;
    restart) [[ $# -eq 0 ]] || die 'restart 不接受额外参数。'; restart_tunnel ;;
    diagnose) [[ $# -eq 0 ]] || die 'diagnose 不接受额外参数。'; diagnose_tunnel ;;
    credentials) [[ $# -le 1 ]] || die 'credentials 最多接受一个选项。'; manage_credentials "$@" ;;
    update) [[ $# -eq 0 ]] || die 'update 不接受额外参数。'; update_cloudflared ;;
    autostart) [[ $# -le 1 ]] || die 'autostart 最多接受一个选项。'; manage_autostart "${1:-}" ;;
    github-proxy) [[ $# -le 1 ]] || die 'github-proxy 最多接受一个选项。'; manage_github_proxy "${1:-}" ;;
    client-config) [[ $# -le 2 ]] || die 'client-config 最多接受域名和用户名两个参数。'; client_config "${1:-}" "${2:-}" ;;
    uninstall) [[ $# -eq 0 ]] || die 'uninstall 不接受额外参数。'; uninstall_tunnel ;;
    help|-h|--help) usage ;;
    *) die "未知命令：${command}（运行 '$0 help' 查看用法）" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
