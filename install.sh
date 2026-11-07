#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

BASE=/etc/vless-lite
ACME_HOME=/root/.vless-lite-acme

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

show_info() {
    local node=$1 domain port uuid path link
    domain=$(jq -r .domain "$node")
    port=$(jq -r .port "$node")
    uuid=$(jq -r .uuid "$node")
    path=$(jq -r .path "$node")
    link="vless://$uuid@$domain:$port?encryption=none&security=tls&type=ws&host=$domain&sni=$domain&path=%2F${path#/}#$domain:$port"
    printf '\nNode Information\n\nDoH:       Disabled\nAddress:   %s:%s\nUUID:      %s\nPath:      %s\n\nQR code:\nProtocol: vless\n' "$domain" "$port" "$uuid" "$path"
    qrencode -t UTF8 -m 2 "$link"
    printf '\nLink:      %s\n' "$link"
}

write_config() {
    local uuid=$1 port=$2 cert=$3 key=$4
    jq -n --arg uuid "$uuid" --argjson port "$port" --arg cert "$cert" --arg key "$key" '
      {log:{loglevel:"warning"},inbounds:[{
        listen:"0.0.0.0",port:$port,protocol:"vless",
        settings:{clients:[{id:$uuid}],decryption:"none"},
        streamSettings:{network:"ws",security:"tls",
          tlsSettings:{alpn:["http/1.1"],certificates:[{certificateFile:$cert,keyFile:$key}]},
          wsSettings:{path:("/" + $uuid[-6:])}}
      }],outbounds:[{protocol:"freedom"}]}'
}

scrub_dns() {
    if [[ -f $ACME_HOME/account.conf ]]; then
        sed -i '/^SAVED_CF_/d; /^CF_/d' "$ACME_HOME/account.conf"
    fi
    unset CF_Token CF_Key CF_Email CF_Account_ID CF_Zone_ID
}

main() {
    local domain='' port=2096 uuid='' cert='' key='' renew=0 version='' work=''
    local arch asset expected expiry method email hook label
    local -a labels
    while (($#)); do
        case "$1" in
            info) [[ $EUID == 0 ]] || die 'Run as root.'; show_info "$BASE/node.json"; return ;;
            --domain|--port|--uuid|--cert-file|--key-file|--version)
                (($# >= 2)) || die "$1 requires a value"
                case "$1" in
                    --domain) domain=$2 ;; --port) port=$2 ;; --uuid) uuid=$2 ;;
                    --cert-file) cert=$2 ;; --key-file) key=$2 ;; --version) version=$2 ;;
                esac
                shift 2 ;;
            --renew) renew=1; shift ;;
            -h|--help)
                cat <<'HELP'
Usage: bash install.sh [options]
  --domain HOST       TLS hostname; prompted when omitted
  --port PORT         Container listening port, 1024-65535 (default 2096)
  --uuid UUID         Existing UUID; generated when omitted
  --cert-file FILE    Existing full-chain PEM certificate
  --key-file FILE     Matching unencrypted PEM private key
  --version TAG       Official Xray release tag (default latest stable)
  --renew             Keep DNS credentials and enable certificate renewal
  info                Show installed node information and QR code

Without certificate files, uses Cloudflare DNS validation. Credentials are
read from CF_Token or CF_Key/CF_Email, or prompted without echoing the secret.
By default DNS credentials are removed after issuance; renewal is manual.
HELP
                return ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ $EUID == 0 ]] || die 'Run as root.'
    [[ ! -e $BASE && ! -e /usr/local/bin/vless-lite && ! -e /etc/systemd/system/vless-lite.service ]] || die 'Installation exists; use vless-lite info. Existing files will not be overwritten.'
    [[ -d /run/systemd/system ]] || die 'Requires systemd inside the container.'
    . /etc/os-release
    [[ $ID == debian && ( $VERSION_ID == 12 || $VERSION_ID == 13 ) ]] || die 'Supported systems: Debian 12/13.'
    if [[ -z $domain ]]; then read -r -p 'Domain: ' domain </dev/tty; fi
    domain=${domain,,}
    [[ ${#domain} -le 253 && $domain == *.* && $domain != *..* && $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die 'Invalid hostname; enter the hostname without scheme, port or path.'
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die 'Invalid hostname label.'
    done
    [[ $port =~ ^[0-9]{1,5}$ ]] || die 'Invalid port.'
    port=$((10#$port))
    ((port >= 1024 && port <= 65535)) || die 'Port must be 1024-65535.'
    [[ -n $uuid ]] || uuid=$(cat /proc/sys/kernel/random/uuid)
    uuid=${uuid,,}
    [[ $uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 'Invalid UUID.'
    [[ -z $cert && -z $key || -n $cert && -n $key ]] || die 'Provide both --cert-file and --key-file.'
    [[ -z $cert || $renew == 0 ]] || die '--renew is only available for certificates issued by this installer.'
    case $(uname -m) in x86_64) arch=64 ;; aarch64|arm64) arch=arm64-v8a ;; *) die 'Supported CPU architectures: amd64/arm64.' ;; esac
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl jq unzip openssl qrencode iproute2
    [[ -z $(ss -H -ltn "sport = :$port") ]] || die "TCP port $port is already in use."
    work=$(mktemp -d /tmp/vless-lite.XXXXXX)
    cleanup_work=$work
    keep_dns=$renew
    trap '[[ $keep_dns == 1 ]] || scrub_dns; rm -rf "$cleanup_work"' EXIT
    if [[ -z $version ]]; then
        version=$(curl --connect-timeout 10 --max-time 60 -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -er .tag_name)
    fi
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid release tag.'
    asset="Xray-linux-$arch.zip"
    curl --connect-timeout 10 --max-time 180 --retry 2 -fsSL "https://github.com/XTLS/Xray-core/releases/download/$version/$asset" -o "$work/$asset"
    curl --connect-timeout 10 --max-time 60 -fsSL "https://github.com/XTLS/Xray-core/releases/download/$version/$asset.dgst" -o "$work/digest"
    expected=$(awk '$1 == "SHA2-256=" {print $2}' "$work/digest")
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || die 'Missing official SHA256 digest.'
    printf '%s  %s\n' "$expected" "$work/$asset" | sha256sum -c -
    unzip -q "$work/$asset" xray -d "$work"
    getent group vless-lite >/dev/null || groupadd --system vless-lite
    id vless-lite >/dev/null 2>&1 || useradd --system --gid vless-lite --home-dir /nonexistent --shell /usr/sbin/nologin vless-lite
    install -d -o root -g vless-lite -m 0750 "$BASE" "$BASE/tls"
    install -m 0755 "$work/xray" /usr/local/bin/vless-lite-xray
    if [[ -n $cert ]]; then
        [[ -r $cert && -r $key ]] || die 'Certificate/key not readable.'
        install -o root -g vless-lite -m 0640 "$cert" "$BASE/tls/fullchain.pem"
        install -o root -g vless-lite -m 0640 "$key" "$BASE/tls/key.pem"
    else
        if [[ -z ${CF_Token:-} && -z ${CF_Key:-} ]]; then
            read -r -p 'Cloudflare credential type [token/key] (token): ' method </dev/tty
            case ${method:-token} in
                token) read -r -s -p 'Cloudflare API Token: ' CF_Token </dev/tty; export CF_Token ;;
                key) read -r -s -p 'Cloudflare Global API Key: ' CF_Key </dev/tty; export CF_Key ;;
                *) die 'Choose token or key.' ;;
            esac
            printf '\n'
        fi
        if [[ -n ${CF_Key:-} && -z ${CF_Email:-} ]]; then
            read -r -p 'Cloudflare account email: ' CF_Email </dev/tty
            export CF_Email
        fi
        read -r -p 'ACME account email: ' email </dev/tty
        [[ $email == *@*.* ]] || die 'Email is required.'
        install -d -m 0700 "$ACME_HOME/dnsapi"
        curl --connect-timeout 10 --max-time 60 -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -o "$ACME_HOME/acme.sh"
        curl --connect-timeout 10 --max-time 60 -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/dns_cf.sh -o "$ACME_HOME/dnsapi/dns_cf.sh"
        chmod 0700 "$ACME_HOME/acme.sh"
        "$ACME_HOME/acme.sh" --home "$ACME_HOME" --register-account --server letsencrypt -m "$email"
        "$ACME_HOME/acme.sh" --home "$ACME_HOME" --issue --server letsencrypt --dns dns_cf -d "$domain" --keylength ec-256
        hook="chown root:vless-lite '$BASE/tls/fullchain.pem' '$BASE/tls/key.pem' && chmod 640 '$BASE/tls/fullchain.pem' '$BASE/tls/key.pem' && if systemctl cat vless-lite.service >/dev/null 2>&1; then systemctl try-restart vless-lite.service; fi"
        "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" --ecc --fullchain-file "$BASE/tls/fullchain.pem" --key-file "$BASE/tls/key.pem" --reloadcmd "$hook"
        if ((renew == 0)); then scrub_dns; fi
    fi
    openssl x509 -in "$BASE/tls/fullchain.pem" -noout -checkend 0 || die 'Expired certificate.'
    openssl x509 -in "$BASE/tls/fullchain.pem" -noout -checkhost "$domain" | grep -Fq 'does match certificate' || die 'Certificate hostname mismatch.'
    [[ $(openssl x509 -in "$BASE/tls/fullchain.pem" -pubkey -noout | openssl sha256) == $(openssl pkey -in "$BASE/tls/key.pem" -pubout -passin pass: | openssl sha256) ]] || die 'Certificate/private key mismatch.'
    chown root:vless-lite "$BASE/tls/"*.pem
    chmod 0640 "$BASE/tls/"*.pem
    write_config "$uuid" "$port" "$BASE/tls/fullchain.pem" "$BASE/tls/key.pem" > "$BASE/config.json"
    chown root:vless-lite "$BASE/config.json"
    chmod 0640 "$BASE/config.json"
    /usr/local/bin/vless-lite-xray run -test -config "$BASE/config.json"
    cat > /etc/systemd/system/vless-lite.service <<'UNIT'
[Unit]
Description=VLESS WebSocket TLS low-memory server
After=network-online.target
Wants=network-online.target
[Service]
User=vless-lite
Group=vless-lite
ExecStart=/usr/local/bin/vless-lite-xray run -config /etc/vless-lite/config.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
    if ((renew)); then
        cat > /etc/systemd/system/vless-lite-renew.service <<UNIT
[Unit]
Description=Renew VLESS TLS certificate
[Service]
Type=oneshot
ExecStart=$ACME_HOME/acme.sh --cron --home $ACME_HOME
UNIT
        cat > /etc/systemd/system/vless-lite-renew.timer <<'UNIT'
[Unit]
Description=Check VLESS TLS certificate daily
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
    fi
    {
        cat <<'MANAGER'
#!/usr/bin/env bash
set -euo pipefail
BASE=/etc/vless-lite
MANAGER
        declare -f show_info
        cat <<'MANAGER'
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
show_info "$BASE/node.json"
MANAGER
    } > /usr/local/bin/vless-lite
    chmod 0755 /usr/local/bin/vless-lite
    jq -n --arg domain "$domain" --argjson port "$port" --arg uuid "$uuid" '{domain:$domain,port:$port,uuid:$uuid,path:("/"+$uuid[-6:])}' > "$BASE/node.json"
    systemctl daemon-reload
    systemctl enable --now vless-lite.service
    sleep 2
    systemctl is-active --quiet vless-lite.service || die 'Service failed; check journalctl -u vless-lite.'
    if ((renew)); then systemctl enable --now vless-lite-renew.timer; fi
    expiry=$(openssl x509 -in "$BASE/tls/fullchain.pem" -noout -enddate)
    printf '\nTLS %s\n' "$expiry"
    if ((renew)); then printf 'Certificate renewal: enabled; DNS credentials retained with root-only access.\n'; else printf 'Certificate renewal: manual; DNS credentials not retained.\n'; fi
    show_info "$BASE/node.json"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
