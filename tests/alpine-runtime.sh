#!/usr/bin/env bash
set -euo pipefail
[[ -f /work/.dexs-test-container && -f /etc/alpine-release ]] || {
    echo 'Run only in the disposable Alpine test container.' >&2
    exit 1
}
taskdir=$(mktemp -d /tmp/dexs-openrc.XXXXXX)
client_pid=''
cleanup() {
    [[ -z $client_pid ]] || kill "$client_pid" 2>/dev/null || true
    rm -rf "$taskdir"
}
trap cleanup EXIT
rc-service -q vless-lite status
[[ -L /etc/runlevels/default/vless-lite ]]
dexs node add extra 29348 00000000-0000-4000-8000-000000654321 > "$taskdir/extra.txt"
dexs relay add web 29346 example.com 443 tcp
dexs relay add node 29347 127.0.0.1 29344 tcp
CF_Token=test-only CF_Key=test-only dexs relay add dns 29349 1.1.1.1 53 tcp,udp
supervisor_found=0
for status in /proc/[0-9]*/status; do
    procdir=${status%/status}
    [[ -r $procdir/cmdline ]] || continue
    args=$(tr '\0' ' ' < "$procdir/cmdline" 2>/dev/null) || continue
    case "$args" in
        'supervise-daemon vless-lite '*|'/sbin/supervise-daemon vless-lite '*)
            tr '\0' '\n' < "$procdir/environ" > "$taskdir/environment.txt"
            if grep -q '^CF_' "$taskdir/environment.txt"; then exit 1; fi
            [[ $(readlink "$procdir/fd/9" || true) != /etc/vless-lite/.lock ]]
            supervisor_found=1 ;;
    esac
done
[[ $supervisor_found == 1 ]]
echo 'Supervisor does not inherit DNS credentials or configuration lock: passed'
dexs node list
dexs relay list
[[ $(jq '.inbounds|length' /etc/vless-lite/config.json) == 5 ]]
jq -n --arg cert /work/fullchain.pem '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:29345,protocol:"socks",settings:{auth:"noauth"}}],outbounds:[{protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:29347,users:[{id:"00000000-0000-4000-8000-000000123456",encryption:"none"}]}]},streamSettings:{network:"ws",security:"tls",tlsSettings:{serverName:"node.example.com",certificates:[{usage:"verify",certificateFile:$cert}]},wsSettings:{path:"/123456"}}}]}' > "$taskdir/client.json"
/usr/local/bin/vless-lite-xray run -config "$taskdir/client.json" > "$taskdir/client.log" 2>&1 &
client_pid=$!
sleep 1
node_status=$(curl -sS --proxy socks5h://127.0.0.1:29345 --noproxy '' --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' https://example.com/)
web_status=$(curl -sS --connect-to example.com:443:127.0.0.1:29346 --noproxy '*' --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' https://example.com/)
[[ $node_status == 200 && $web_status == 200 ]]
printf 'Alpine OpenRC: VLESS WS TLS via relay=%s; HTTPS relay=%s\n' "$node_status" "$web_status"
timeout 8 bash -c 'exec 3<>/dev/udp/127.0.0.1/29349; printf "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01" >&3; dd bs=4096 count=1 <&3 2>/dev/null' > "$taskdir/dns.bin"
prefix=$(od -An -tx1 -N4 "$taskdir/dns.bin" | tr -d ' \n')
[[ $prefix == 12348180 ]]
echo 'Alpine native UDP DNS relay: passed'
found=0
for status in /proc/[0-9]*/status; do
    procdir=${status%/status}
    [[ -r $procdir/cmdline ]] || continue
    args=$(tr '\0' ' ' < "$procdir/cmdline" 2>/dev/null) || continue
    if [[ $args == '/usr/local/bin/vless-lite-xray run -config /etc/vless-lite/config.json '* ]]; then
        [[ $(awk '/^Uid:/{print $2}' "$status") == "$(id -u vless-lite)" ]]
        [[ $(awk '/^Umask:/{print $2}' "$status") == 0077 ]]
        awk '/^VmRSS:/{print "OpenRC core " $0}' "$status"
        found=1
        break
    fi
done
[[ $found == 1 ]]
echo 'Dedicated non-root service user: passed'
dexs cert-reload
rc-service -q vless-lite status
dexs node del extra
dexs relay del web
dexs relay del node
dexs relay del dns
[[ $(jq '.inbounds|length' /etc/vless-lite/config.json) == 1 ]]
before=$(sha256sum /etc/vless-lite/state.json /etc/vless-lite/config.json)
bash /work/install.sh --upgrade
[[ $(sha256sum /etc/vless-lite/state.json /etc/vless-lite/config.json) == "$before" ]]
rc-service -q vless-lite status
echo 'OpenRC restart, certificate reload, deletion and manager upgrade: passed'
printf 'container memory limit='; cat /sys/fs/cgroup/memory.max
printf 'container memory current='; cat /sys/fs/cgroup/memory.current
cat /sys/fs/cgroup/memory.events
