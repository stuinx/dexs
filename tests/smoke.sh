#!/usr/bin/env bash
set -euo pipefail
test_xray=${XRAY_BIN:?Set XRAY_BIN to the Linux Xray binary}
# shellcheck disable=SC1091
source "$(dirname "$0")/../install.sh"
XRAY_BIN=$test_xray
taskdir=$(mktemp -d /tmp/dex-lite-smoke.XXXXXX)
BASE="$taskdir/base"
server_home=$BASE
export CONFIG_GROUP=root
client_pid=''
echo_pid=''
pure_pid=''
cleanup() {
    [[ ! -f $server_home/pid ]] || kill "$(cat "$server_home/pid")" 2>/dev/null || true
    [[ -z $client_pid ]] || kill "$client_pid" 2>/dev/null || true
    [[ -z $echo_pid ]] || kill "$echo_pid" 2>/dev/null || true
    [[ -z $pure_pid ]] || kill "$pure_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$taskdir"
}
trap cleanup EXIT
for port in 29344 29345 29346 29347 29348 29349 29350 29351; do
    [[ -z $(ss -H -ltn "sport = :$port") && -z $(ss -H -lun "sport = :$port") ]]
done
mkdir -p "$BASE/tls"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com \
    -keyout "$BASE/tls/key.pem" -out "$BASE/tls/fullchain.pem" -days 1 >/dev/null 2>&1
cat > "$BASE/state.json" <<'JSON'
{"version":1,"domain":"node.example.com","nodes":[{"name":"main","port":29344,"uuid":"00000000-0000-4000-8000-000000123456"}],"relays":[]}
JSON
validate_state "$BASE/state.json"
render_state "$BASE/state.json" > "$BASE/config.json"
jq -e '.inbounds[0].streamSettings.wsSettings.path == "/123456" and .inbounds[0].streamSettings.security == "tls"' "$BASE/config.json" >/dev/null
"$XRAY_BIN" run -test -config "$BASE/config.json" > "$taskdir/check.log" 2>&1
node_info main > "$taskdir/info.txt"
grep -q '^DoH:       Disabled$' "$taskdir/info.txt"
grep -q '^Path:      /123456$' "$taskdir/info.txt"
grep -q 'security=tls&type=ws&host=node.example.com&sni=node.example.com&path=%2F123456' "$taskdir/info.txt"
[[ $(wc -l < "$taskdir/info.txt") -gt 20 ]]
echo 'Node fields, encoded URI and terminal QR: passed'
ACME_HOME="$taskdir/acme"
mkdir "$ACME_HOME"
printf "SAVED_CF_Token='test-only'\nSAVED_CF_Key='test-only'\nOTHER_SETTING='keep'\n" > "$ACME_HOME/account.conf"
scrub_dns
if grep -q '^SAVED_CF_' "$ACME_HOME/account.conf"; then exit 1; fi
grep -q '^OTHER_SETTING=' "$ACME_HOME/account.conf"
echo 'One-time DNS credential cleanup: passed'

# Only the service controller is replaced; every restart uses the real Xray binary.
systemctl() {
    case "$1" in
        restart)
            if [[ -f $BASE/pid ]]; then
                kill "$(cat "$BASE/pid")" 2>/dev/null || true
                sleep 0.2
            fi
            if [[ -f $BASE/fail-next-restart ]]; then rm "$BASE/fail-next-restart"; return 1; fi
            "$XRAY_BIN" run -config "$BASE/config.json" > "$taskdir/server.log" 2>&1 9>&- &
            printf '%s\n' "$!" > "$BASE/pid"
            ;;
        is-active) kill -0 "$(cat "$BASE/pid")" 2>/dev/null ;;
        --no-pager) printf 'active (running)\n' ;;
        *) return 1 ;;
    esac
}
systemctl restart vless-lite.service
(manager_main node add extra 29346 00000000-0000-4000-8000-000000654321) > "$taskdir/add.txt"
(manager_main relay add transit 29347 127.0.0.1 29344 tcp)
(manager_main relay add udp-test 29348 127.0.0.1 29349 tcp,udp)
(manager_main node list) | grep -q extra
(manager_main relay list) | grep -q transit
(manager_main node info extra) > "$taskdir/extra-info.txt"
grep -q '/654321' "$taskdir/extra-info.txt"
(manager_main relay info transit) | jq -e '.port == 29347 and .target_port == 29344' >/dev/null
[[ $(jq '.inbounds | length' "$BASE/config.json") == 4 ]]
echo 'Node and relay add/list/info, shared core configuration: passed'

cat > "$taskdir/client.json" <<'JSON'
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":29345,"protocol":"socks","settings":{"auth":"noauth"}}],"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":29347,"users":[{"id":"00000000-0000-4000-8000-000000123456","encryption":"none"}]}]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":"node.example.com"},"wsSettings":{"path":"/123456"}}}]}
JSON
jq --arg cert "$BASE/tls/fullchain.pem" '.outbounds[0].streamSettings.tlsSettings.certificates=[{usage:"verify",certificateFile:$cert}]' "$taskdir/client.json" > "$taskdir/client-trusted.json"
"$XRAY_BIN" run -config "$taskdir/client-trusted.json" > "$taskdir/client.log" 2>&1 &
client_pid=$!
sleep 1
if ! status=$(curl -sS --proxy socks5h://127.0.0.1:29345 --noproxy '' --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' https://example.com/); then
    cat "$taskdir/server.log" "$taskdir/client.log" >&2
    exit 1
fi
[[ $status == 200 ]]
printf 'TCP relay -> VLESS WS TLS node -> HTTPS: HTTP %s\n' "$status"
pure_base="$taskdir/pure-relay"
mkdir "$pure_base"
cat > "$pure_base/state.json" <<'JSON'
{"version":1,"domain":"","nodes":[],"relays":[{"name":"main","port":29350,"host":"127.0.0.1","target_port":29344,"network":"tcp"}]}
JSON
validate_state "$pure_base/state.json"
(BASE="$pure_base"; render_state "$BASE/state.json") > "$pure_base/config.json"
jq -e '.inbounds|all(.protocol=="dokodemo-door" and .streamSettings==null)' "$pure_base/config.json" >/dev/null
(BASE="$pure_base"; manager_main info) > "$taskdir/pure-info.json"
jq -e '.target_port==29344' "$taskdir/pure-info.json" >/dev/null
if (BASE="$pure_base"; manager_main node add blocked 29351) >/dev/null 2>&1; then exit 1; fi
"$XRAY_BIN" run -config "$pure_base/config.json" > "$taskdir/pure.log" 2>&1 &
pure_pid=$!
kill "$client_pid"
wait "$client_pid" 2>/dev/null || true
jq '.outbounds[0].settings.vnext[0].port=29350' "$taskdir/client-trusted.json" > "$taskdir/pure-client.json"
"$XRAY_BIN" run -config "$taskdir/pure-client.json" > "$taskdir/pure-client.log" 2>&1 &
client_pid=$!
sleep 1
status=$(curl -sS --proxy socks5h://127.0.0.1:29345 --noproxy '' --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' https://example.com/)
[[ $status == 200 && ! -e $pure_base/tls ]]
printf 'Relay-only configuration without domain/certificate -> external node: HTTP %s\n' "$status"
kill "$pure_pid"
wait "$pure_pid" 2>/dev/null || true
pure_pid=''
BASE=$server_home
python3 -u - <<'PY' &
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('127.0.0.1', 29349))
while True:
    data, peer = sock.recvfrom(2048)
    sock.sendto(data, peer)
PY
echo_pid=$!
sleep 0.2
python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.settimeout(5)
    sock.sendto(b'dex-lite-udp-test', ('127.0.0.1', 29348))
    assert sock.recv(2048) == b'dex-lite-udp-test'
print('Native UDP relay echo: passed')
PY

before=$(sha256sum "$BASE/config.json" "$BASE/state.json")
if (manager_main relay add invalid 29350 'bad/target' 443) >/dev/null 2>&1; then exit 1; fi
if (manager_main node add duplicate 29344) >/dev/null 2>&1; then exit 1; fi
[[ $(sha256sum "$BASE/config.json" "$BASE/state.json") == "$before" ]]
touch "$BASE/fail-next-restart"
if (manager_main relay add rollback 29350 127.0.0.1 29344) > "$taskdir/rollback.txt" 2>&1; then exit 1; fi
[[ $(sha256sum "$BASE/config.json" "$BASE/state.json") == "$before" ]]
systemctl is-active --quiet vless-lite.service
grep -q 'previous configuration restored' "$taskdir/rollback.txt"
echo 'Invalid input rejection and failed-restart rollback: passed'
(manager_main node del extra)
(manager_main relay del transit)
(manager_main relay del udp-test)
[[ $(jq '.nodes|length' "$BASE/state.json") == 1 && $(jq '.relays|length' "$BASE/state.json") == 0 ]]
[[ $(jq -r '.nodes[0].uuid' "$BASE/state.json") == 00000000-0000-4000-8000-000000123456 ]]
echo 'Node/relay deletion with original main identity preserved: passed'
cp "$BASE/config.json" "$taskdir/config.saved.json"
jq '.log.loglevel="error"' "$BASE/config.json" > "$taskdir/edited.json"
cp "$taskdir/edited.json" "$BASE/config.json"
if (manager_main relay add drift 29350 127.0.0.1 29344) > "$taskdir/drift.txt" 2>&1; then exit 1; fi
cmp -s "$taskdir/edited.json" "$BASE/config.json"
grep -q 'edited outside dex-lite' "$taskdir/drift.txt"
cp "$taskdir/config.saved.json" "$BASE/config.json"
echo 'External configuration edit protection: passed'

export MENU_FD=7
printf '9\n\n1\n2\n\n0\n2\n2\n\n0\n0\n' > "$taskdir/menu-input"
(exec 7< "$taskdir/menu-input"; manager_main) > "$taskdir/menu-output" 2>&1
for label in '1. 安装' '2. 中转' '9. 查看' '0. 退出'; do grep -Fq "$label" "$taskdir/menu-output"; done
grep -q 'QR code:' "$taskdir/menu-output"
printf '2\n1\nmenu-rule\n29350\n127.0.0.1\n29344\ntcp\n\n4\nmenu-rule\nn\n\n0\n0\n' > "$taskdir/menu-input"
(exec 7< "$taskdir/menu-input"; manager_main) > "$taskdir/menu-add" 2>&1
jq -e '.relays[]|select(.name=="menu-rule")' "$BASE/state.json" >/dev/null
grep -q '已取消' "$taskdir/menu-add"
printf '2\n4\nmenu-rule\ny\n\n0\n0\n' > "$taskdir/menu-input"
(exec 7< "$taskdir/menu-input"; manager_main) > "$taskdir/menu-delete" 2>&1
jq -e '.relays|all(.name!="menu-rule")' "$BASE/state.json" >/dev/null
printf '1\n1\nbad-port\ninvalid\n\n\n2\n\n0\n0\n' > "$taskdir/menu-input"
(exec 7< "$taskdir/menu-input"; manager_main) > "$taskdir/menu-error" 2>&1
grep -q '操作未完成' "$taskdir/menu-error"
jq -e '.nodes|all(.name!="bad-port")' "$BASE/state.json" >/dev/null
printf '33346\nnode.example.com\n443\ntcp\n' > "$taskdir/wizard-input"
(
    # shellcheck disable=SC2317
    main() { printf '%s\n' "$@" > "$taskdir/wizard-args"; }
    exec 7< "$taskdir/wizard-input"; install_wizard relay
) > "$taskdir/wizard-output" 2>&1
printf '%s\n' --mode relay --port 33346 --target-host node.example.com --target-port 443 --network tcp > "$taskdir/expected-args"
cmp -s "$taskdir/wizard-args" "$taskdir/expected-args"
printf 'node.example.com\n33344\n\n1\nn\n' > "$taskdir/wizard-input"
(
    # shellcheck disable=SC2317
    main() { printf '%s\n' "$@" > "$taskdir/wizard-args"; }
    exec 7< "$taskdir/wizard-input"; install_wizard server
) > "$taskdir/wizard-output" 2>&1
printf '%s\n' --mode server --domain node.example.com --port 33344 > "$taskdir/expected-args"
cmp -s "$taskdir/wizard-args" "$taskdir/expected-args"
echo '1/2/9/0 menus, add/delete/cancel, error recovery and installation prompts: passed'

BASE="$taskdir/legacy"
MANAGER_DIR="$taskdir/bin"
mkdir -p "$BASE" "$MANAGER_DIR"
jq '.domain as $domain | .nodes[0] | {domain:$domain,port,uuid,path:("/"+.uuid[-6:])}' "$server_home/state.json" > "$BASE/node.json"
jq '{version:1,domain,nodes:[{name:"main",port,uuid}],relays:[]}' "$BASE/node.json" > "$taskdir/legacy-state.json"
render_state "$taskdir/legacy-state.json" | jq 'del(.inbounds[].tag,.outbounds[].tag)' > "$BASE/config.json"
before=$(sha256sum "$BASE/config.json")
(upgrade_manager)
validate_state "$BASE/state.json"
[[ $(jq -r '.nodes[0].uuid' "$BASE/state.json") == 00000000-0000-4000-8000-000000123456 ]]
[[ $(sha256sum "$BASE/config.json") == "$before" ]]
bash "$MANAGER_DIR/dex-lite" help > "$taskdir/manager-help.txt"
grep -q 'relay add' "$taskdir/manager-help.txt"
printf '0\n' > "$taskdir/menu-input"
(exec 7< "$taskdir/menu-input"; bash "$MANAGER_DIR/dex-lite") > "$taskdir/installed-menu" 2>&1
grep -Fq '9. 查看' "$taskdir/installed-menu"
python3 - "$MANAGER_DIR/dex-lite" <<'PY'
import os
import pty
import select
import signal
import sys
import time

pid, fd = pty.fork()
if pid == 0:
    os.environ.pop('MENU_FD', None)
    os.environ.pop('NO_COLOR', None)
    os.execv('/bin/bash', ['bash', sys.argv[1]])
output = b''
sent = False
finished = False
deadline = time.monotonic() + 6
try:
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                chunk = os.read(fd, 8192)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if b'Select:' in output and not sent:
                os.write(fd, b'0\n')
                sent = True
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            finished = True
            assert os.waitstatus_to_exitcode(status) == 0
            break
    while not finished and time.monotonic() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            finished = True
            assert os.waitstatus_to_exitcode(status) == 0
        else:
            time.sleep(0.01)
    assert finished and sent, 'interactive menu did not exit'
    assert b'\x1b[32m' in output, 'terminal colors missing'
    for label in ('1. 安装', '2. 中转', '9. 查看', '0. 退出'):
        assert label.encode() in output
finally:
    os.close(fd)
    if not finished:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
print('Generated menu in a real pseudo-terminal, colors and exit: passed')
PY
echo 'Legacy metadata migration and generated management command: passed'
