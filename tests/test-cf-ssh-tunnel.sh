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
assert_contains "$help_output" '不会重复安装' '帮助文本说明重复安装行为'
assert_contains "$help_output" '本脚本不会开放服务器入站端口' '帮助文本声明安全边界'
assert_contains "$help_output" 'github-proxy [--show|--disable]' '帮助文本包含 GitHub 代理管理命令'
assert_contains "$help_output" 'GitHub 代理仅影响 Git 的 github.com 克隆与拉取' '帮助文本限制代理影响范围'

client_output="$(bash "$SCRIPT" client-config ssh.example.com)"
assert_contains "$client_output" 'ProxyCommand cloudflared access ssh --hostname %h' '客户端配置包含 Tunnel ProxyCommand'
assert_contains "$client_output" 'ssh <你的 Linux 用户名>@ssh.example.com' '客户端配置包含连接命令'
assert_contains "$client_output" 'Linux 原有的 SSH 密钥或密码认证' '客户端配置说明标准 SSH 认证'
assert_not_contains "$client_output" 'Access' '客户端配置不涉及 Access'

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

# 行为测试：毫秒换算边界
[[ "$(seconds_to_milliseconds '0.521')" == '521' ]] || fail '毫秒换算错误：0.521 应为 521'
pass '毫秒换算行为正确（0.521 -> 521）'
[[ "$(seconds_to_milliseconds '.5')" == '500' ]] || fail '毫秒换算错误：.5 应为 500'
pass '毫秒换算行为正确（.5 -> 500）'
[[ "$(seconds_to_milliseconds '12')" == '12000' ]] || fail '毫秒换算错误：12 应为 12000'
pass '毫秒换算行为正确（12 -> 12000）'

# 行为测试：同一域名生成确定的 Tunnel 名称
# shellcheck disable=SC2034  # 由 source 进来的 make_tunnel_name 读取
PUBLIC_HOSTNAME='ssh.example.com'
make_tunnel_name
tunnel_name_first="$TUNNEL_NAME"
make_tunnel_name
[[ "$TUNNEL_NAME" == "$tunnel_name_first" ]] || fail '同一域名应生成相同的 Tunnel 名称'
pass 'Tunnel 名称按域名确定性生成'

# 行为测试：代理清理同时移除 insteadOf 与 pushInsteadOf（隔离 HOME，不污染真实 gitconfig）
if command -v git >/dev/null 2>&1; then
  proxy_test_home="$(mktemp -d)"
  proxy_old_home="$HOME"
  HOME="$proxy_test_home"
  git config --global 'url.https://gh-proxy.org/https://github.com/.insteadOf' 'https://github.com/'
  git config --global 'url.https://github.com/.pushInsteadOf' 'https://gh-proxy.org/https://github.com/'
  remove_known_github_proxies
  if git config --global --get 'url.https://gh-proxy.org/https://github.com/.insteadOf' >/dev/null 2>&1 \
    || git config --global --get 'url.https://github.com/.pushInsteadOf' >/dev/null 2>&1; then
    HOME="$proxy_old_home"
    rm -rf "$proxy_test_home"
    fail '代理清理应同时删除 insteadOf 与 pushInsteadOf'
  fi
  HOME="$proxy_old_home"
  rm -rf "$proxy_test_home"
  pass '代理清理同时移除 insteadOf 与 pushInsteadOf 规则'
fi

script_text="$(cat "$SCRIPT")"
assert_contains "$script_text" 'ensure_cloudflared()' '包含 cloudflared 自动检测函数'
assert_contains "$script_text" "info '未安装 cloudflared，开始自动安装。'" '未安装时触发自动安装'
assert_contains "$script_text" "\"\$CF_BIN\" tunnel login" '包含 Cloudflare 浏览器授权命令'
assert_contains "$script_text" 'show_connection_notice' '完成流程直接输出连接提示'
assert_not_contains "$script_text" 'Access' '脚本全文不涉及 Access 流程'
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
assert_contains "$script_text" 'configure_github_proxy' '中国大陆模式调用 GitHub 代理测速'
assert_contains "$script_text" "readonly -a GITHUB_PROXY_CANDIDATES=(" '定义候选 GitHub 代理列表'
assert_contains "$script_text" "'https://gh-proxy.org/'" '包含 gh-proxy 候选项'
assert_contains "$script_text" "'https://v4.gh-proxy.org/'" '包含 v4 候选项'
assert_contains "$script_text" "'https://v6.gh-proxy.org/'" '包含 v6 候选项'
assert_contains "$script_text" "'https://cdn.gh-proxy.org/'" '包含 cdn 候选项'
assert_contains "$script_text" "'https://axisnow.gh-proxy.org/'" '包含 axisnow 候选项'
assert_contains "$script_text" 'application/x-git-upload-pack-advertisement' '验证 Git 协议响应类型'
assert_contains "$script_text" 'latency < best_latency' '按低延迟选择代理'
assert_contains "$script_text" "git config --global \"url.\${best_proxy}\${GITHUB_PREFIX}.insteadOf\"" '通过 Git URL 重写全局加速 GitHub'
assert_contains "$script_text" 'remove_known_github_proxies' '切换代理前清理旧规则'
assert_contains "$script_text" 'GITHUB_PROXY_STATE_FILE' '记录代理状态'
assert_not_contains "$script_text" 'export HTTP_PROXY=' '不设置系统 HTTP_PROXY'
assert_not_contains "$script_text" 'export HTTPS_PROXY=' '不设置系统 HTTPS_PROXY'
assert_contains "$script_text" "CLOUDFLARED_RELEASE_PAGE='https://github.com/cloudflare/cloudflared/releases/latest'" '使用官方 Release 页面作为校验来源'
assert_contains "$script_text" 'get_cloudflared_release_metadata()' '包含官方 Release 元数据解析函数'
assert_contains "$script_text" 'cloudflared-linux-amd64.deb' '限定代理下载的 Debian amd64 资产名称'
assert_contains "$script_text" "sha256sum \"\$tmp\"" '校验代理下载文件的 SHA-256'
assert_contains "$script_text" "dpkg-deb -I \"\$tmp\"" '校验下载文件为有效 Debian 包'
assert_contains "$script_text" "chmod 0644 \"\$tmp\"" '允许 APT 沙箱读取已校验的临时 Debian 包'
assert_contains "$script_text" "actual_sha\" != \"\$expected_sha" '哈希不一致时拒绝安装'
assert_contains "$script_text" 'Cloudflare 官方签名软件源' '代理下载失败时回退官方签名软件源'
assert_contains "$script_text" 'pushInsteadOf' '推送经反向规则保持直连 GitHub'
assert_contains "$script_text" 'curl_secure --max-time 600' '按吞吐放宽代理 deb 下载时限'
assert_contains "$script_text" '--edge-ip-version ${edge_ip_version}' '按协议选择边缘 IP 版本'
assert_contains "$script_text" 'already[[:space:]]exists' '同名 Tunnel 冲突有针对性提示'
assert_contains "$script_text" 'load_existing_install' '重复 install 自动加载现有配置'
assert_contains "$script_text" '-e "$META_FILE" || -e "$SERVICE_DIR" ]]' '完整检测三类已有配置'
assert_contains "$script_text" "trap 'cleanup_login_certificate; exit 130' INT" 'Ctrl-C 中断也清理授权证书'
assert_contains "$script_text" "\"\$PROTOCOL\" == 'http2'" '仅中国大陆模式尝试代理下载'
assert_contains "$script_text" "rm -rf \"\$LOGIN_HOME\"" '授权后的账户级证书会被清理'

printf '所有 %d 项无网络回归测试通过。\n' "$pass_count"
