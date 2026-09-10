#!/usr/bin/env bash
# start.sh — cf-ssh-tunnel-kit 一键启动脚本
# 更新代码（直连不通自动换加速代理）→ 首次安装或拉起现有 Tunnel → 打印 SSH 连接信息
# 许可证：MIT
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly MAIN_SCRIPT="${ROOT_DIR}/scripts/cf-ssh-tunnel.sh"

if [[ ! -r "$MAIN_SCRIPT" ]]; then
  printf '[错误] 未找到 %s，请在完整的项目目录中运行本脚本。\n' "$MAIN_SCRIPT" >&2
  exit 1
fi

# 复用主脚本的常量、输出函数与托管方式判断；主脚本被 source 时不会执行安装流程。
# shellcheck source=scripts/cf-ssh-tunnel.sh
source "$MAIN_SCRIPT"
# 只借用函数与常量，不继承主脚本的 ERR/EXIT/信号陷阱（它们面向 install 流程）。
trap - ERR EXIT HUP INT TERM

usage() {
  cat <<'EOF'
用法：
  sudo bash start.sh [--mainland|--auto|--quic] [--no-update]

一条命令完成：更新项目代码 → 安装或拉起 Tunnel → 打印可直接复制的连接信息。
首次运行等价于 install（含浏览器授权）；已安装过时只加载现有配置，服务没在跑才拉起，
不会重复创建 Tunnel 或 DNS 记录。

结束时会打印登录所需的全部信息：域名、登录用户、认证方式（公钥指纹或密码），
以及客户端可直接复制的 ssh 命令与 ~/.ssh/config 片段。

  --mainland   固定使用 HTTP/2（TCP/7844），适合 UDP/QUIC 不稳定的网络（默认）。
  --auto       先尝试 QUIC，UDP 不可用时由 cloudflared 回退 HTTP/2。
  --quic       固定使用 QUIC（UDP/7844）。
  --no-update  跳过 git 拉取更新，直接用当前代码启动。

中国大陆直连 GitHub 超时时，脚本会自动测速并改用候选加速代理拉取代码；全部不可用时
跳过更新、用当前版本继续启动。容器等没有 systemd 的环境会自动改用后台看护进程托管：
Tunnel 异常退出后自动重启，重启后的首次登录 shell 会自动拉起。
EOF
}

update_repo() {
  local candidate result proxy latency best_proxy='' best_latency=-1
  if [[ ! -d "${ROOT_DIR}/.git" ]]; then
    warn '当前目录不是 Git 仓库（可能是解压安装），跳过自动更新。'
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    warn '未安装 Git，跳过自动更新；安装流程仍会继续。'
    return 0
  fi
  if ! git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
    warn '仓库未配置 origin，跳过自动更新。'
    return 0
  fi

  local -a timeout_cmd=()
  command -v timeout >/dev/null 2>&1 && timeout_cmd=(timeout 15)

  info '正在检查项目更新……'
  if "${timeout_cmd[@]}" git -C "$ROOT_DIR" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    if git -C "$ROOT_DIR" pull --ff-only --quiet; then
      info '代码已是最新版本。'
    else
      warn '代码更新失败（本地可能有改动），继续使用当前版本。'
    fi
    return 0
  fi

  warn '直连 GitHub 不可用，正在测试候选加速代理……'
  for candidate in "${GITHUB_PROXY_CANDIDATES[@]}"; do
    result="$(probe_github_proxy "$candidate" || true)"
    [[ -n "$result" ]] || continue
    IFS=$'\t' read -r proxy latency <<<"$result"
    printf '%-34s %-12s %s\n' "$proxy" "${latency} ms" '可用'
    if (( best_latency < 0 || latency < best_latency )); then
      best_proxy="$proxy"
      best_latency="$latency"
    fi
  done
  if [[ -z "$best_proxy" ]]; then
    warn '直连与候选加速代理都不可用，跳过更新，继续启动当前版本。'
    return 0
  fi
  # 临时改写 Git URL，不写入全局配置，也不改动 origin。
  if git -C "$ROOT_DIR" -c "url.${best_proxy}${GITHUB_PREFIX}.insteadOf=${GITHUB_PREFIX}" pull --ff-only --quiet; then
    info "已通过 ${best_proxy}（${best_latency} ms）更新到最新版本。"
  else
    warn '经代理更新失败（本地可能有改动），继续使用当前版本。'
  fi
}

load_or_install() {
  local protocol="$1"
  detect_service_mode
  if [[ ! -r "$META_FILE" ]]; then
    say
    info '未检测到本机配置，开始首次安装。'
    bash "$MAIN_SCRIPT" install "$protocol"
    return 0
  fi

  say
  say '本机已安装 cf-ssh-tunnel，直接加载现有配置：'
  read_metadata || die "无法读取 ${META_FILE}；请先执行 'sudo bash ${MAIN_SCRIPT} uninstall' 清理后重试。"
  say "Tunnel 名称：${TUNNEL_NAME:-未知}"
  say "Tunnel UUID：${TUNNEL_UUID}"
  say "SSH 域名：${PUBLIC_HOSTNAME}"
  say "传输协议：${PROTOCOL}"
  say "托管方式：$(service_mode_label)"
  say
  if service_is_active; then
    info 'Tunnel 服务正在运行，无需重启。'
  else
    warn 'Tunnel 服务未在运行，正在拉起……'
    bash "$MAIN_SCRIPT" restart
  fi
  say
  say '== SSH 登录体检 =='
  check_ssh_login "${INSTALL_USER:-root}"
  print_connection_info "${INSTALL_USER:-root}"
  say
  say "查看状态：sudo bash ${MAIN_SCRIPT} status；查看日志：sudo bash ${MAIN_SCRIPT} logs"
}

main() {
  local protocol='--mainland' do_update=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mainland|--auto|--quic) protocol="$1" ;;
      --no-update) do_update=0 ;;
      -h|--help) usage; return 0 ;;
      *) die "未知选项：$1（运行 'bash $0 --help' 查看用法）" ;;
    esac
    shift
  done

  [[ "${EUID}" -eq 0 ]] || die "请以 root 运行，例如：sudo bash $0"
  if (( do_update == 1 )); then
    update_repo
  fi
  load_or_install "$protocol"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
