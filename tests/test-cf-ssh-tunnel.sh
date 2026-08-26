#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/cf-ssh-tunnel.sh"

pass_count=0
fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}
pass() {
  printf '[PASS] %s\n' "$*"
  pass_count=$((pass_count + 1))
}
assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label：未找到 '$needle'"
  pass "$label"
}
assert_status() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" -eq "$expected" ]] || fail "$label：期望退出码 $expected，实际 $actual"
  pass "$label"
}

bash -n "$SCRIPT"
pass 'Bash 语法检查'

help_output="$(bash "$SCRIPT" help)"
assert_contains "$help_output" 'install [--mainland|--auto|--quic]' '帮助文本包含安装模式'
assert_contains "$help_output" '本脚本不开放服务器入站端口' '帮助文本声明安全边界'

client_output="$(bash "$SCRIPT" client-config ssh.example.com)"
assert_contains "$client_output" 'ProxyCommand cloudflared access ssh --hostname %h' '客户端配置包含 Access ProxyCommand'
assert_contains "$client_output" 'ssh <你的 Linux 用户名>@ssh.example.com' '客户端配置包含连接命令'

set +e
bash "$SCRIPT" unexpected-command >/tmp/cf-ssh-tunnel-test.stderr 2>&1
unknown_status=$?
set -e
assert_status 1 "$unknown_status" '未知命令被拒绝'
unknown_output="$(cat /tmp/cf-ssh-tunnel-test.stderr)"
assert_contains "$unknown_output" '未知命令' '未知命令的错误信息'
rm -f /tmp/cf-ssh-tunnel-test.stderr

# Sourcing is deliberately side-effect free; it permits deterministic unit checks.
# shellcheck source=/dev/null
source "$SCRIPT"
version_ge '2025.4.0' '2025.4.0'
pass '最低支持版本被接受'
version_ge '2026.8.2' '2025.4.0'
pass '较新版本被接受'
if version_ge '2025.3.9' '2025.4.0'; then
  fail '较旧版本不应被接受'
fi
pass '较旧版本被拒绝'

script_text="$(cat "$SCRIPT")"
assert_contains "$script_text" 'run --token-file ${TOKEN_FILE}' 'systemd 使用 token-file 而非命令行令牌'
assert_contains "$script_text" 'User=${SERVICE_USER}' 'systemd 使用受限服务用户'
assert_contains "$script_text" 'NoNewPrivileges=true' 'systemd 禁止新增权限'
assert_contains "$script_text" 'ProtectSystem=full' 'systemd 启用系统文件保护'
assert_contains "$script_text" 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' 'systemd 限制地址族'
assert_contains "$script_text" "protocol='http2'" '中国大陆模式固定 HTTP/2'

printf '所有 %d 项无网络回归测试通过。\n' "$pass_count"
