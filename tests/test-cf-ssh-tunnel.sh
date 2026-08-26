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
assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$label：不应包含 '$needle'"
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
assert_contains "$help_output" '输出浏览器授权链接' '帮助文本说明浏览器授权'
assert_contains "$help_output" '自动创建 Tunnel、DNS 路由、SSH 配置和系统服务' '帮助文本说明自动配置范围'
assert_contains "$help_output" '本脚本不会开放服务器入站端口' '帮助文本声明安全边界'

client_output="$(bash "$SCRIPT" client-config ssh.example.com)"
assert_contains "$client_output" 'ProxyCommand cloudflared access ssh --hostname %h' '客户端配置包含 Access ProxyCommand'
assert_contains "$client_output" 'ssh <你的 Linux 用户名>@ssh.example.com' '客户端配置包含连接命令'
assert_contains "$client_output" '配置 Access Self-hosted 应用' '客户端配置提醒 Access 策略'

set +e
bash "$SCRIPT" unexpected-command >/tmp/cf-ssh-tunnel-test.stderr 2>&1
unknown_status=$?
set -e
assert_status 1 "$unknown_status" '未知命令被拒绝'
unknown_output="$(cat /tmp/cf-ssh-tunnel-test.stderr)"
assert_contains "$unknown_output" '未知命令' '未知命令的错误信息'
rm -f /tmp/cf-ssh-tunnel-test.stderr

# Sourcing is deliberately side-effect free; it permits deterministic function tests.
# shellcheck source=/dev/null
source "$SCRIPT"
validate_hostname 'ssh.example.com'
pass '合法 SSH 域名被接受'
if validate_hostname 'ssh_example.com'; then
  fail '非法 SSH 域名不应被接受'
fi
pass '非法 SSH 域名被拒绝'
if validate_hostname 'SSH.EXAMPLE.COM'; then
  fail '未规范化的大写域名不应被直接接受'
fi
pass '未规范化的大写域名被拒绝'

script_text="$(cat "$SCRIPT")"
assert_contains "$script_text" 'ensure_cloudflared()' '包含 cloudflared 自动检测函数'
assert_contains "$script_text" "info '未安装 cloudflared，开始自动安装。'" '未安装时触发自动安装'
assert_contains "$script_text" 'tunnel login' '包含 Cloudflare 浏览器授权命令'
assert_contains "$script_text" 'https:// 开头的授权链接' '以中文说明授权链接'
assert_contains "$script_text" "tunnel --origincert \"\$CERT_FILE\" create \"\$TUNNEL_NAME\"" '使用授权证书自动创建 Tunnel'
assert_contains "$script_text" "route dns \"\$TUNNEL_UUID\" \"\$PUBLIC_HOSTNAME\"" '自动创建域名 DNS 路由'
assert_contains "$script_text" 'service: ssh://localhost:22' '生成本机 SSH ingress'
assert_contains "$script_text" 'service: http_status:404' '生成 ingress 兜底规则'
assert_contains "$script_text" "credentials-file: \${SERVICE_DIR}/\${TUNNEL_UUID}.json" '服务仅使用单 Tunnel 凭据'
assert_contains "$script_text" "ExecStart=\${CF_BIN} tunnel --no-autoupdate --config \${CONFIG_FILE}" 'systemd 从受限配置文件启动'
assert_not_contains "$script_text" '--token-file' '新流程不依赖远程托管 Token'
assert_contains "$script_text" "User=\${SERVICE_USER}" 'systemd 使用受限服务用户'
assert_contains "$script_text" 'NoNewPrivileges=true' 'systemd 禁止新增权限'
assert_contains "$script_text" 'ProtectSystem=full' 'systemd 启用系统文件保护'
assert_contains "$script_text" 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' 'systemd 限制地址族'
assert_contains "$script_text" "--mainland) PROTOCOL='http2'" '中国大陆模式固定 HTTP/2'
assert_contains "$script_text" "rm -rf \"\$LOGIN_HOME\"" '授权后的账户级证书会被清理'

printf '所有 %d 项无网络回归测试通过。\n' "$pass_count"
