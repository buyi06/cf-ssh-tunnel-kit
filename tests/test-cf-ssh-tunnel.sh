#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/cf-ssh-tunnel.sh"
START_SCRIPT="${ROOT_DIR}/start.sh"

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
bash -n "$START_SCRIPT"
pass 'start.sh 语法检查'

help_output="$(bash "$SCRIPT" help)"
assert_contains "$help_output" 'install [--mainland|--auto|--quic]' '帮助文本包含安装模式'
assert_contains "$help_output" '输出浏览器授权链接' '帮助文本说明浏览器授权'
assert_contains "$help_output" '不会重复安装' '帮助文本说明重复安装行为'
assert_contains "$help_output" '本脚本不会开放服务器入站端口' '帮助文本声明安全边界'
assert_contains "$help_output" 'github-proxy [--show|--disable]' '帮助文本包含 GitHub 代理管理命令'
assert_contains "$help_output" 'GitHub 代理仅影响 Git 的 github.com 克隆与拉取' '帮助文本限制代理影响范围'
assert_contains "$help_output" 'restart        重启 Tunnel 服务' '帮助文本包含 restart 命令'
assert_contains "$help_output" 'logs           查看最近 80 行 Tunnel 日志' '帮助文本包含 logs 命令'
assert_contains "$help_output" '改用后台看护进程' '帮助文本说明非 systemd 托管方式'
assert_contains "$help_output" '容器、DSW/Colab、WSL 等没有 systemd 的' '帮助文本点名无 systemd 的典型环境'
assert_contains "$help_output" '/etc/cf-ssh-tunnel/tunnel.log' '帮助文本给出进程模式日志路径'
assert_contains "$help_output" 'sudo bash start.sh' '帮助文本指向一键启动脚本'
assert_contains "$help_output" 'autostart [--show|--enable|--disable]' '帮助文本包含登录自启命令'
assert_contains "$help_output" 'credentials [--set-password]' '帮助文本包含登录信息命令'
assert_contains "$help_output" '--no-password' '帮助文本包含关闭设密选项'
assert_contains "$help_output" '生成一个随机密码写入本机 /etc/shadow' '安全说明交代密码设置行为'
assert_contains "$help_output" '异常退出后自动重启' '帮助文本说明看护进程会自愈'

start_help="$(bash "$START_SCRIPT" --help)"
assert_contains "$start_help" 'sudo bash start.sh [--mainland|--auto|--quic] [--no-update]' '一键脚本帮助包含完整用法'
assert_contains "$start_help" '首次运行等价于 install' '一键脚本说明首次运行行为'
assert_contains "$start_help" '不会重复创建 Tunnel 或 DNS 记录' '一键脚本说明重复执行行为'
assert_contains "$start_help" '改用候选加速代理拉取代码' '一键脚本说明代理回退'

set +e
bash "$START_SCRIPT" --unexpected-option >/tmp/cf-ssh-tunnel-start.stderr 2>&1
start_unknown_status=$?
set -e
assert_status 1 "$start_unknown_status" '一键脚本拒绝未知选项'
assert_contains "$(cat /tmp/cf-ssh-tunnel-start.stderr)" '未知选项' '一键脚本未知选项错误信息'
rm -f /tmp/cf-ssh-tunnel-start.stderr

client_output="$(bash "$SCRIPT" client-config ssh.example.com)"
assert_contains "$client_output" 'ProxyCommand cloudflared access ssh --hostname %h' '客户端配置包含 Tunnel ProxyCommand'
assert_contains "$client_output" 'User root' '客户端配置默认填充用户名'
assert_contains "$client_output" 'ssh root@ssh.example.com' '客户端配置包含可直接执行的连接命令'
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

# 行为测试：托管方式检测——没有正在运行的 systemd 时退化为后台进程模式
mode_stub_dir="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' >"${mode_stub_dir}/systemctl"
chmod +x "${mode_stub_dir}/systemctl"
mkdir -p "${mode_stub_dir}/run-systemd"
mode_old_path="$PATH"
mode_old_runtime="$SYSTEMD_RUNTIME_DIR"
# 探测期间只暴露桩目录，避免命中宿主机上真实的 systemctl。
PATH="${mode_stub_dir}"
SYSTEMD_RUNTIME_DIR="${mode_stub_dir}/no-systemd"
detect_service_mode
[[ "$SERVICE_MODE" == 'process' ]] || fail '没有 systemd 运行目录时应选择后台进程模式'
pass '没有 systemd 运行目录时选择后台进程模式'
SYSTEMD_RUNTIME_DIR="${mode_stub_dir}/run-systemd"
detect_service_mode
[[ "$SERVICE_MODE" == 'systemd' ]] || fail 'systemctl 与运行目录都在时应选择 systemd'
pass 'systemd 可用时优先选择 systemd 服务'
PATH="$mode_old_path"
rm -f "${mode_stub_dir}/systemctl"
PATH="${mode_stub_dir}"
detect_service_mode
[[ "$SERVICE_MODE" == 'process' ]] || fail '缺少 systemctl 命令时应选择后台进程模式'
pass '缺少 systemctl 命令时选择后台进程模式'
PATH="$mode_old_path"
SYSTEMD_RUNTIME_DIR="$mode_old_runtime"
rm -rf "$mode_stub_dir"

# 行为测试：随机登录密码
login_password="$(generate_password)"
[[ "${#login_password}" -eq 16 ]] || fail "随机密码长度应为 16，实际 ${#login_password}"
pass '随机登录密码长度为 16'
[[ "$login_password" =~ ^[A-Za-z0-9]+$ ]] || fail '随机密码应只含字母数字，便于手输'
pass '随机登录密码只含字母数字'
[[ "$(generate_password)" != "$login_password" ]] || fail '两次生成的密码不应相同'
pass '随机登录密码每次不同'

# 行为测试：authorized_keys 解析（忽略注释、空行与非法行）
keys_file="$(mktemp)"
printf '# 注释行\n\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@host\nnot-a-key\nssh-rsa AAAAB3NzaC1yc2EAAAATESTONLY rsa@host\n' >"$keys_file"
parsed_keys="$(authorized_key_lines "$keys_file" | grep -c . || true)"
[[ "$parsed_keys" -eq 2 ]] || fail "应解析出 2 个公钥，实际 ${parsed_keys}"
pass 'authorized_keys 解析忽略注释与非法行'
[[ -z "$(authorized_key_lines "${keys_file}.missing")" ]] || fail '缺失的 authorized_keys 应返回空'
pass '缺失的 authorized_keys 返回空'
rm -f "$keys_file"

if user_has_password 'cf-ssh-tunnel-no-such-user'; then
  fail '不存在的账户不应判定为有可用密码'
fi
pass '不存在的账户判定为无可用密码'

[[ -n "$(login_user_home root)" ]] || fail '应能解析 root 的家目录'
pass '解析登录用户家目录'

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

# 去掉 CR：Windows 上 core.autocrlf=true 的工作区是 CRLF，跨行断言不应因此失效。
script_text="$(tr -d '\r' <"$SCRIPT")"
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
assert_contains "$script_text" 'print_connection_info' '安装完成与加载时直接输出连接信息'
assert_contains "$script_text" 'INSTALL_USER' '记录安装用户供连接信息使用'
assert_contains "$script_text" "ssh -o ProxyCommand='cloudflared access ssh --hostname %h'" '提供免配置一条命令直连'
assert_contains "$script_text" "trap 'cleanup_login_certificate; exit 130' INT" 'Ctrl-C 中断也清理授权证书'
assert_contains "$script_text" "\"\$PROTOCOL\" == 'http2'" '仅中国大陆模式尝试代理下载'
assert_contains "$script_text" "rm -rf \"\$LOGIN_HOME\"" '授权后的账户级证书会被清理'
assert_not_contains "$script_text" 'require_systemd' '不再硬性拒绝非 systemd 环境'
assert_not_contains "$script_text" '本脚本仅支持 systemd Linux' '不再声明仅支持 systemd'
assert_contains "$script_text" 'detect_service_mode' '自动检测托管方式'
assert_contains "$script_text" "readonly PID_FILE=\"\${SERVICE_DIR}/tunnel.pid\"" '进程模式使用独立 PID 文件'
assert_contains "$script_text" "readonly LOG_FILE=\"\${SERVICE_DIR}/tunnel.log\"" '进程模式写独立日志文件'
assert_contains "$script_text" 'start_process_service' '包含进程模式启动函数'
assert_contains "$script_text" 'stop_process_service' '包含进程模式停止函数'
assert_contains "$script_text" 'wait_for_process_service' '进程模式有启动等待'
assert_contains "$script_text" 'setsid' '进程模式脱离终端会话'
assert_contains "$script_text" 'nohup' '进程模式忽略挂断信号'
assert_contains "$script_text" 'process_is_tunnel_service' '启动前校验 PID 确属本项目进程'
assert_contains "$script_text" 'pgrep -f -- "^[^ ]*(bash|sh) ${RUNNER_SCRIPT}\$"' 'PID 文件丢失时按看护脚本路径回退定位'
assert_contains "$script_text" "readonly RUNNER_SCRIPT=\"\${SERVICE_DIR}/run.sh\"" '进程模式使用独立看护脚本'
assert_contains "$script_text" "AUTOSTART_FILE='/etc/profile.d/cf-ssh-tunnel-autostart.sh'" '定义登录自启钩子路径'
assert_contains "$script_text" 'write_process_runner' '生成看护脚本'
assert_contains "$script_text" '[看护] Tunnel 进程退出' '看护脚本记录每次异常退出'
assert_contains "$script_text" 'trap stop TERM INT' '看护脚本退出时一并结束 cloudflared'
assert_contains "$script_text" 'launcher+=(nohup bash "$RUNNER_SCRIPT")' '进程模式启动看护脚本而非裸进程'
assert_contains "$script_text" 'delay > 60' '重启间隔有上限，避免崩溃循环刷日志'
assert_contains "$script_text" 'install_autostart' '安装时写入登录自启钩子'
assert_contains "$script_text" 'manage_autostart' '提供 autostart 子命令'
assert_contains "$script_text" 'rm -f "$AUTOSTART_FILE"' '卸载时移除登录自启钩子'
assert_contains "$script_text" '登录 shell' '说明登录自启的触发时机'
assert_contains "$script_text" 'resolve_service_identity' '按托管方式决定服务账户与凭据权限'
assert_contains "$script_text" "SERVICE_GROUP=\"\$SERVICE_USER\"" 'systemd 模式凭据归受限服务组'
assert_contains "$script_text" 'CREDENTIAL_MODE' '进程模式以 0600 独占凭据'
assert_contains "$script_text" 'show_process_mode_notice' '进程模式提示不会随重启自动拉起'
assert_contains "$script_text" "  if [[ \"\$SERVICE_MODE\" == 'process' ]]; then
    show_process_mode_notice" '安装结束提示仅在进程模式出现'
assert_contains "$script_text" 'apt-get install -y openssh-server' '容器内缺少 sshd 时给出启动提示'
assert_contains "$script_text" 'fetch_release_page' 'Release 元数据支持经代理回退'
assert_contains "$script_text" 'releases/tag/[0-9]{4}' '经代理取回时从页面解析版本号'
assert_contains "$script_text" 'restart_tunnel' '提供 restart 子命令'
assert_contains "$script_text" 'show_tunnel_logs' '提供 logs 子命令'
assert_contains "$script_text" 'service_mode_label' '托管方式名称供状态与一键脚本复用'
assert_contains "$script_text" 'check_ssh_login' '安装前做 SSH 登录体检'
assert_contains "$script_text" 'manage_credentials' '提供 credentials 子命令'
assert_contains "$script_text" 'generate_password' '内置随机密码生成'
assert_contains "$script_text" 'password_login_allowed' '检查 sshd 是否允许密码登录'
assert_contains "$script_text" 'user_has_password' '检查账户是否已有可用密码'
assert_contains "$script_text" 'authorized_key_lines' '解析已授权公钥'
assert_contains "$script_text" 'ssh-keygen -lf' '打印已授权公钥指纹'
assert_contains "$script_text" 'sshd -T' '以 sshd 有效配置判断认证方式'
assert_contains "$script_text" 'chpasswd' '通过 chpasswd 设置密码'
assert_contains "$script_text" '不修改 sshd_config' '仍不改动 sshd 配置'
assert_contains "$script_text" "if [[ -n \"\$SSH_PASSWORD\" ]]; then" '仅在本次生成密码时打印密码'
assert_not_contains "$script_text" 'SSH_PASSWORD >' '密码不写入任何文件'
assert_not_contains "$script_text" 'FORCE_PASSWORD" >' '强制设密标记不落盘'

start_text="$(tr -d '\r' <"$START_SCRIPT")"
assert_contains "$start_text" 'source "$MAIN_SCRIPT"' '一键脚本复用主脚本函数与常量'
assert_contains "$start_text" 'trap - ERR EXIT HUP INT TERM' '一键脚本不继承主脚本陷阱'
assert_contains "$start_text" 'GITHUB_PROXY_CANDIDATES' '一键脚本复用候选代理列表'
assert_contains "$start_text" 'ls-remote --exit-code origin HEAD' '先探测直连再决定是否走代理'
assert_contains "$start_text" 'pull --ff-only' '一键脚本快进拉取更新'
assert_contains "$start_text" 'insteadOf=${GITHUB_PREFIX}' '经代理拉取使用临时 URL 改写'
assert_not_contains "$start_text" 'remote set-url' '一键脚本不要求手工切换 origin 地址'
assert_not_contains "$start_text" 'curl' '一键脚本不通过 curl 管道执行远程脚本'
assert_contains "$start_text" 'install "$protocol"' '未安装时进入安装流程'
assert_contains "$start_text" 'service_is_active' '已在运行时不重复重启'
assert_contains "$start_text" 'bash "$MAIN_SCRIPT" restart' '未运行时拉起现有 Tunnel'
assert_contains "$start_text" 'print_connection_info' '一键脚本结束时打印连接信息'

printf '所有 %d 项无网络回归测试通过。\n' "$pass_count"
