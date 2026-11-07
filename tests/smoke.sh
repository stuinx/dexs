#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/../install.sh"
: "${XRAY_BIN:?Set XRAY_BIN to the Linux Xray binary}"
taskdir=$(mktemp -d /tmp/vless-lite-smoke.XXXXXX)
server_pid=''
client_pid=''
cleanup() {
    [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
    [[ -z $client_pid ]] || kill "$client_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$taskdir"
}
trap cleanup EXIT
[[ -z $(ss -H -ltn 'sport = :29344') && -z $(ss -H -ltn 'sport = :29345') ]]
uuid=00000000-0000-4000-8000-000000123456
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com \
    -keyout "$taskdir/key.pem" -out "$taskdir/cert.pem" -days 1 >/dev/null 2>&1
write_config "$uuid" 29344 "$taskdir/cert.pem" "$taskdir/key.pem" > "$taskdir/server.json"
jq -e '.inbounds[0].streamSettings.wsSettings.path == "/123456" and .inbounds[0].streamSettings.security == "tls"' "$taskdir/server.json" >/dev/null
"$XRAY_BIN" run -test -config "$taskdir/server.json" > "$taskdir/check.log" 2>&1
jq -n --arg uuid "$uuid" '{domain:"node.example.com",port:29344,uuid:$uuid,path:"/123456"}' > "$taskdir/node.json"
show_info "$taskdir/node.json" > "$taskdir/info.txt"
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
"$XRAY_BIN" run -config "$taskdir/server.json" > "$taskdir/server.log" 2>&1 &
server_pid=$!
cat > "$taskdir/client.json" <<'JSON'
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":29345,"protocol":"socks","settings":{"auth":"noauth"}}],"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":29344,"users":[{"id":"00000000-0000-4000-8000-000000123456","encryption":"none"}]}]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":"node.example.com"},"wsSettings":{"path":"/123456"}}}]}
JSON
jq --arg cert "$taskdir/cert.pem" '.outbounds[0].streamSettings.tlsSettings.certificates=[{usage:"verify",certificateFile:$cert}]' "$taskdir/client.json" > "$taskdir/client-trusted.json"
mv "$taskdir/client-trusted.json" "$taskdir/client.json"
"$XRAY_BIN" run -config "$taskdir/client.json" > "$taskdir/client.log" 2>&1 &
client_pid=$!
sleep 1
if ! status=$(curl -sS --proxy socks5h://127.0.0.1:29345 --noproxy '' --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' https://example.com/); then
    cat "$taskdir/server.log" "$taskdir/client.log" >&2
    exit 1
fi
[[ $status == 200 ]]
printf 'Generated server config + VLESS WS TLS HTTPS traffic: HTTP %s\n' "$status"
