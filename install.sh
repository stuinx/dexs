#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

BASE=/etc/vless-lite
ACME_HOME=/root/.vless-lite-acme
XRAY_BIN=/usr/local/bin/vless-lite-xray
CONFIG_GROUP=vless-lite
MANAGER_DIR=/usr/local/bin

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

show_info() {
    local node=$1 domain port uuid path link
    IFS=$'\t' read -r domain port uuid path < <(jq -er '[.domain,.port,.uuid,.path] | @tsv' "$node")
    link="vless://$uuid@$domain:$port?encryption=none&security=tls&type=ws&host=$domain&sni=$domain&path=%2F${path#/}#$domain:$port"
    printf '\nNode Information\n\nDoH:       Disabled\nAddress:   %s:%s\nUUID:      %s\nPath:      %s\n\nQR code:\nProtocol: vless\n' "$domain" "$port" "$uuid" "$path"
    qrencode -t UTF8 -m 2 "$link"
    printf '\nLink:      %s\n' "$link"
}

parse_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] || die 'Invalid port.'
    local value=$((10#$1)) minimum=${2:-1024}
    ((value >= minimum && value <= 65535)) || die "Port must be $minimum-65535."
    printf '%s\n' "$value"
}

valid_name() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; }
valid_uuid() { [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }

valid_host() {
    local host=$1 label
    local -a labels
    if [[ $host == *:* ]]; then
        [[ $host =~ ^[0-9a-fA-F:]+$ && $host == *::* || $host =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ ]]
        return
    fi
    [[ ${#host} -le 253 && $host != *..* && $host =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
    IFS=. read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

validate_state() {
    local state=$1 host
    jq -e '
      .version == 1 and (.domain | type == "string") and
      (.nodes | type == "array") and (.relays | type == "array") and
      all(.nodes[]; (.name | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
        (.uuid | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
        (.port | type == "number" and floor == . and . >= 1024 and . <= 65535)) and
      all(.relays[]; (.name | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
        (.host | type == "string") and
        (.port | type == "number" and floor == . and . >= 1024 and . <= 65535) and
        (.target_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        (.network == "tcp" or .network == "udp" or .network == "tcp,udp")) and
      ([.nodes[].port,.relays[].port] | length == (unique | length)) and
      ([.nodes[].name] | length == (unique | length)) and
      ([.relays[].name] | length == (unique | length))
    ' "$state" >/dev/null || return 1
    host=$(jq -r .domain "$state")
    if [[ -n $host ]]; then valid_host "$host" || return 1; else
        [[ $(jq '.nodes|length' "$state") == 0 ]] || return 1
    fi
    while IFS= read -r host; do valid_host "$host" || return 1; done < <(jq -r '.relays[].host' "$state")
}

render_state() {
    jq --arg cert "$BASE/tls/fullchain.pem" --arg key "$BASE/tls/key.pem" '
      {log:{loglevel:"warning"},inbounds:(
        [.nodes[] | {tag:("node-"+.name),listen:"0.0.0.0",port:.port,protocol:"vless",
          settings:{clients:[{id:.uuid}],decryption:"none"},
          streamSettings:{network:"ws",security:"tls",
            tlsSettings:{alpn:["http/1.1"],certificates:[{certificateFile:$cert,keyFile:$key}]},
            wsSettings:{path:("/"+.uuid[-6:])}}}] +
        [.relays[] | {tag:("relay-"+.name),listen:"0.0.0.0",port:.port,protocol:"dokodemo-door",
          settings:{address:.host,port:.target_port,network:.network}}]),
        outbounds:[{tag:"direct",protocol:"freedom"}]}
    ' "$1"
}

port_available() {
    local port=$1 network=$2
    if [[ $network == *tcp* && -n $(ss -H -ltn "sport = :$port") ]]; then return 1; fi
    if [[ $network == *udp* && -n $(ss -H -lun "sport = :$port") ]]; then return 1; fi
}

managed_config_matches() {
    cmp -s <(render_state "$1" | jq -S 'del(.inbounds[].tag,.outbounds[].tag)') \
        <(jq -S 'del(.inbounds[].tag,.outbounds[].tag)' "$BASE/config.json")
}

apply_state() {
    local next=$1 transaction
    managed_config_matches "$BASE/state.json" || { printf 'Configuration was edited outside dex-lite; refusing to overwrite it.\n' >&2; return 1; }
    validate_state "$next" || { printf 'Invalid configuration: check names, ports and targets.\n' >&2; return 1; }
    transaction=$(mktemp -d "$BASE/.transaction.XXXXXX")
    if ! { cp "$next" "$transaction/state.json" &&
        render_state "$next" > "$transaction/config.json" &&
        "$XRAY_BIN" run -test -config "$transaction/config.json" > "$transaction/check.log" 2>&1 &&
        cp -p "$BASE/state.json" "$transaction/state.before.json" &&
        cp -p "$BASE/config.json" "$transaction/config.before.json" &&
        chown "root:$CONFIG_GROUP" "$transaction/config.json" &&
        chmod 0640 "$transaction/config.json" && chmod 0600 "$transaction/state.json"; }; then
        [[ ! -f $transaction/check.log ]] || cat "$transaction/check.log" >&2
        rm -rf "$transaction"
        return 1
    fi
    if mv "$transaction/config.json" "$BASE/config.json" &&
        mv "$transaction/state.json" "$BASE/state.json" &&
        systemctl restart vless-lite.service && sleep 1 && systemctl is-active --quiet vless-lite.service; then
        rm -rf "$transaction"
        return 0
    fi
    cp -p "$transaction/config.before.json" "$BASE/config.json"
    cp -p "$transaction/state.before.json" "$BASE/state.json"
    if systemctl restart vless-lite.service; then
        printf 'Change failed; previous configuration restored.\n' >&2
        rm -rf "$transaction"
    else
        printf 'Previous files restored, but service restart failed. Recovery files: %s\n' "$transaction" >&2
    fi
    return 1
}

node_info() {
    local name=$1
    jq -e --arg name "$name" '.nodes[] | select(.name==$name)' "$BASE/state.json" >/dev/null || die "Unknown node: $name"
    show_info <(jq --arg name "$name" '.domain as $domain | .nodes[] | select(.name==$name) | {domain:$domain,port,uuid,path:("/"+.uuid[-6:])}' "$BASE/state.json")
}

relay_info() {
    jq -e --arg name "$1" '.relays[] | select(.name==$name)' "$BASE/state.json" || die "Unknown relay: $1"
}

manager_main() {
    [[ $EUID == 0 ]] || die 'Run as root.'
    if [[ ${1:-help} == help || ${1:-} == --help ]]; then
        cat <<'HELP'
Dex Lite — one Xray process for VLESS WS TLS nodes and port relays
  dex-lite info [NAME]                       Node + QR or relay details (default main)
  dex-lite node list
  dex-lite node add NAME PORT [UUID]         Reuse installed hostname/certificate
  dex-lite node info NAME
  dex-lite node del NAME
  dex-lite relay list
  dex-lite relay add NAME PORT HOST TARGET_PORT [tcp|udp|tcp,udp]
  dex-lite relay info NAME
  dex-lite relay del NAME
  dex-lite status
Changes restart Xray and briefly disconnect existing sessions.
Relays forward raw traffic; TLS/SNI, UUID and WS Path belong to the final server.
HELP
        return
    fi
    [[ -f $BASE/state.json ]] || die 'Management metadata missing; run the installer with --upgrade.'
    exec 9> "$BASE/.lock"
    flock -x 9
    local action=${1:-info} kind command name port uuid host target network next
    case "$action" in
        status) systemctl --no-pager status vless-lite.service; return ;;
        info)
            name=${2:-main}
            if jq -e --arg name "$name" '.nodes[] | select(.name==$name)' "$BASE/state.json" >/dev/null; then
                node_info "$name"
            else relay_info "$name"; fi
            return ;;
        node|relay) kind=$action; command=${2:-list} ;;
        *) die 'Unknown command; use dex-lite help.' ;;
    esac
    case "$command" in
        list)
            if [[ $kind == node ]]; then
                printf 'Name\tAddress\tUUID\tPath\n'
                jq -r '.domain as $domain | .nodes[] | [.name,($domain+":"+(.port|tostring)),.uuid,("/"+.uuid[-6:])] | @tsv' "$BASE/state.json"
            else
                printf 'Name\tListen\tTarget\tNetwork\n'
                jq -r '.relays[] | [.name,("0.0.0.0:"+(.port|tostring)),(.host+":"+(.target_port|tostring)),.network] | @tsv' "$BASE/state.json"
            fi
            return ;;
        info)
            (($# == 3)) || die "Usage: dex-lite $kind info NAME"
            if [[ $kind == node ]]; then node_info "$3"; else
                relay_info "$3"
            fi
            return ;;
        add|del) (($# >= 3)) || die 'A name is required.'; name=$3 ;;
        *) die 'Use add, list, info or del.' ;;
    esac
    valid_name "$name" || die 'Name: 1-32 letters, digits, underscore or hyphen.'
    if [[ $command == add ]]; then
        if [[ $kind == node ]]; then
            [[ -n $(jq -r .domain "$BASE/state.json") && -r $BASE/tls/fullchain.pem && -r $BASE/tls/key.pem ]] || die 'This relay-only installation has no TLS setup; node creation is unavailable.'
            (($# == 4 || $# == 5)) || die 'Usage: dex-lite node add NAME PORT [UUID]'
            port=$(parse_port "$4")
            uuid=${5:-$(cat /proc/sys/kernel/random/uuid)}
            uuid=${uuid,,}
            valid_uuid "$uuid" || die 'Invalid UUID.'
            network=tcp
        else
            (($# == 6 || $# == 7)) || die 'Usage: dex-lite relay add NAME PORT HOST TARGET_PORT [NETWORK]'
            port=$(parse_port "$4")
            host=$5
            valid_host "$host" || die 'Invalid target hostname/IP; do not include a scheme, port or IPv6 brackets.'
            target=$(parse_port "$6" 1)
            network=${7:-tcp}
            [[ $network == tcp || $network == udp || $network == tcp,udp ]] || die 'Network must be tcp, udp or tcp,udp.'
            [[ $port != "$target" || ( $host != 127.0.0.1 && $host != ::1 && $host != localhost ) ]] || die 'Relay cannot point to its own listening port.'
        fi
        port_available "$port" "$network" || die "Listening port $port is already in use."
        jq -e --arg kind "${kind}s" --arg name "$name" '.[$kind] | all(.name != $name)' "$BASE/state.json" >/dev/null || die "Name already exists: $name"
    else
        (($# == 3)) || die "Usage: dex-lite $kind del NAME"
        jq -e --arg kind "${kind}s" --arg name "$name" '.[$kind][] | select(.name==$name)' "$BASE/state.json" >/dev/null || die "Unknown $kind: $name"
    fi
    next=$(mktemp "$BASE/.next.XXXXXX")
    if [[ $command == del ]]; then
        jq --arg kind "${kind}s" --arg name "$name" '.[$kind] |= map(select(.name!=$name))' "$BASE/state.json" > "$next"
    elif [[ $kind == node ]]; then
        jq --arg name "$name" --arg uuid "$uuid" --argjson port "$port" '.nodes += [{name:$name,uuid:$uuid,port:$port}]' "$BASE/state.json" > "$next"
    else
        jq --arg name "$name" --arg host "$host" --arg network "$network" --argjson port "$port" --argjson target "$target" '.relays += [{name:$name,port:$port,host:$host,target_port:$target,network:$network}]' "$BASE/state.json" > "$next"
    fi
    if apply_state "$next"; then
        rm -f "$next"
        printf '%s %s: %s\n' "$kind" "$command" "$name"
        if [[ $kind == node && $command == add ]]; then node_info "$name"; fi
    else
        rm -f "$next"
        return 1
    fi
}

write_manager() {
    local temporary
    temporary=$(mktemp "$MANAGER_DIR/.vless-lite.XXXXXX")
    {
        cat <<'MANAGER'
#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
BASE=/etc/vless-lite
XRAY_BIN=/usr/local/bin/vless-lite-xray
CONFIG_GROUP=vless-lite
MANAGER
        declare -f die show_info parse_port valid_name valid_uuid valid_host validate_state render_state port_available managed_config_matches apply_state node_info relay_info manager_main
        # shellcheck disable=SC2016
        printf '\nmanager_main "$@"\n'
    } > "$temporary"
    chmod 0755 "$temporary"
    mv "$temporary" "$MANAGER_DIR/vless-lite"
    ln -sfn "$MANAGER_DIR/vless-lite" "$MANAGER_DIR/dex-lite"
}

upgrade_manager() {
    local candidate
    [[ $EUID == 0 ]] || die 'Run as root.'
    [[ -x $XRAY_BIN && -f $BASE/config.json ]] || die 'An existing vless-lite installation is required.'
    [[ ! -e $MANAGER_DIR/dex-lite || -L $MANAGER_DIR/dex-lite ]] || die 'dex-lite command already exists and is not a symlink.'
    [[ ! -L $MANAGER_DIR/dex-lite || $(readlink "$MANAGER_DIR/dex-lite") == "$MANAGER_DIR/vless-lite" ]] || die 'dex-lite points to another program.'
    exec 9> "$BASE/.lock"
    flock -x 9
    if [[ ! -f $BASE/state.json ]]; then
        [[ -f $BASE/node.json ]] || die 'Legacy node metadata missing.'
        jq -e --arg base "$BASE" --slurpfile old "$BASE/node.json" '
          (.inbounds|length)==1 and (.outbounds|length)==1 and .outbounds[0].protocol=="freedom" and
          .inbounds[0].protocol=="vless" and .inbounds[0].port==$old[0].port and
          (.inbounds[0].settings.clients|length)==1 and
          .inbounds[0].settings.clients[0].id==$old[0].uuid and
          .inbounds[0].streamSettings.network=="ws" and .inbounds[0].streamSettings.security=="tls" and
          .inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile==($base+"/tls/fullchain.pem") and
          .inbounds[0].streamSettings.tlsSettings.certificates[0].keyFile==($base+"/tls/key.pem") and
          (.routing==null and .dns==null) and
          .inbounds[0].streamSettings.wsSettings.path==("/"+$old[0].uuid[-6:])
        ' "$BASE/config.json" >/dev/null || die 'Existing configuration is customized; automatic migration refused.'
        candidate=$(mktemp "$BASE/.upgrade.XXXXXX")
        jq '{version:1,domain,nodes:[{name:"main",port,uuid}],relays:[]}' "$BASE/node.json" > "$candidate"
        if validate_state "$candidate" && managed_config_matches "$candidate"; then
            chmod 0600 "$candidate"
            mv "$candidate" "$BASE/state.json"
        else
            rm -f "$candidate"
            die 'Legacy configuration differs from its metadata; migration refused.'
        fi
    fi
    validate_state "$BASE/state.json" || die 'Invalid management metadata.'
    write_manager
    printf 'Dex Lite management upgraded; use dex-lite help.\n'
}

scrub_dns() {
    if [[ -f $ACME_HOME/account.conf ]]; then
        sed -i '/^SAVED_CF_/d; /^CF_/d' "$ACME_HOME/account.conf"
    fi
    unset CF_Token CF_Key CF_Email CF_Account_ID CF_Zone_ID
}

main() {
    case ${1:-} in
        info|node|relay|status) manager_main "$@"; return ;;
        --upgrade) (($# == 1)) || die '--upgrade does not accept installation options.'; upgrade_manager; return ;;
    esac
    local domain='' port=2096 uuid='' cert='' key='' renew=0 version='' work=''
    local mode=server target_host='' target_port='' network=tcp
    local arch asset expected expiry method email hook label
    local -a labels
    while (($#)); do
        case "$1" in
            --domain|--port|--uuid|--cert-file|--key-file|--version|--mode|--target-host|--target-port|--network)
                (($# >= 2)) || die "$1 requires a value"
                case "$1" in
                    --domain) domain=$2 ;; --port) port=$2 ;; --uuid) uuid=$2 ;;
                    --cert-file) cert=$2 ;; --key-file) key=$2 ;; --version) version=$2 ;;
                    --mode) mode=$2 ;; --target-host) target_host=$2 ;; --target-port) target_port=$2 ;;
                    --network) network=$2 ;;
                esac
                shift 2 ;;
            --renew) renew=1; shift ;;
            -h|--help)
                cat <<'HELP'
Usage: bash install.sh [options]
  --mode server|relay Create a dex-compatible node or a plain relay (default server)
  --domain HOST       TLS hostname; prompted when omitted
  --port PORT         Container listening port, 1024-65535 (default 2096)
  --uuid UUID         Existing UUID; generated when omitted
  --cert-file FILE    Existing full-chain PEM certificate
  --key-file FILE     Matching unencrypted PEM private key
  --version TAG       Official Xray release tag (default latest stable)
  --renew             Keep DNS credentials and enable certificate renewal
  --target-host HOST  Relay mode: destination hostname/IP (no scheme or port)
  --target-port PORT  Relay mode: destination port, 1-65535
  --network NETWORK   Relay mode: tcp, udp, or tcp,udp (default tcp)
  --upgrade           Upgrade installed command and migrate legacy metadata
  info                Show main node + QR, or main relay details

Server mode without certificate files uses Cloudflare DNS validation. Credentials are
read from CF_Token or CF_Key/CF_Email, or prompted without echoing the secret.
By default DNS credentials are removed after issuance; renewal is manual.
HELP
                return ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ $EUID == 0 ]] || die 'Run as root.'
    [[ ! -e $BASE && ! -e /usr/local/bin/vless-lite && ! -e /etc/systemd/system/vless-lite.service ]] || die 'Installation exists; use vless-lite info. Existing files will not be overwritten.'
    [[ ! -e /usr/local/bin/dex-lite && ! -L /usr/local/bin/dex-lite ]] || die '/usr/local/bin/dex-lite already exists.'
    [[ -d /run/systemd/system ]] || die 'Requires systemd inside the container.'
    . /etc/os-release
    [[ $ID == debian && ( $VERSION_ID == 12 || $VERSION_ID == 13 ) ]] || die 'Supported systems: Debian 12/13.'
    [[ $mode == server || $mode == relay ]] || die 'Mode must be server or relay.'
    port=$(parse_port "$port")
    if [[ $mode == server ]]; then
        [[ -z $target_host && -z $target_port && $network == tcp ]] || die 'Target/network options are for relay mode.'
        if [[ -z $domain ]]; then read -r -p 'Domain: ' domain </dev/tty; fi
        domain=${domain,,}
        [[ ${#domain} -le 253 && $domain == *.* && $domain != *..* && $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die 'Invalid hostname; enter the hostname without scheme, port or path.'
        IFS=. read -r -a labels <<< "$domain"
        for label in "${labels[@]}"; do
            [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die 'Invalid hostname label.'
        done
        [[ -n $uuid ]] || uuid=$(cat /proc/sys/kernel/random/uuid)
        uuid=${uuid,,}
        [[ $uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 'Invalid UUID.'
        [[ -z $cert && -z $key || -n $cert && -n $key ]] || die 'Provide both --cert-file and --key-file.'
        [[ -z $cert || $renew == 0 ]] || die '--renew is only available for certificates issued by this installer.'
    else
        [[ -z $domain && -z $uuid && -z $cert && -z $key && $renew == 0 ]] || die 'Relay mode does not use a domain, UUID, certificate or renewal.'
        if [[ -z $target_host ]]; then read -r -p 'Target hostname/IP: ' target_host </dev/tty; fi
        if [[ -z $target_port ]]; then read -r -p 'Target port: ' target_port </dev/tty; fi
        valid_host "$target_host" || die 'Invalid target hostname/IP.'
        target_port=$(parse_port "$target_port" 1)
        [[ $network == tcp || $network == udp || $network == tcp,udp ]] || die 'Network must be tcp, udp or tcp,udp.'
        [[ $port != "$target_port" || ( $target_host != 127.0.0.1 && $target_host != ::1 && $target_host != localhost ) ]] || die 'Relay cannot point to its own listening port.'
    fi
    case $(uname -m) in x86_64) arch=64 ;; aarch64|arm64) arch=arm64-v8a ;; *) die 'Supported CPU architectures: amd64/arm64.' ;; esac
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl jq unzip iproute2 util-linux
    if [[ $mode == server ]]; then apt-get install -y --no-install-recommends openssl qrencode; fi
    port_available "$port" "$network" || die "Listening port $port is already in use."
    work=$(mktemp -d /tmp/vless-lite.XXXXXX)
    cleanup_work=$work
    keep_dns=$renew
    dns_used=0
    trap 'if [[ $dns_used == 1 && $keep_dns != 1 ]]; then scrub_dns; fi; rm -rf "$cleanup_work"' EXIT
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
    install -d -o root -g vless-lite -m 0750 "$BASE"
    install -m 0755 "$work/xray" /usr/local/bin/vless-lite-xray
    if [[ $mode == server ]]; then
        install -d -o root -g vless-lite -m 0750 "$BASE/tls"
        if [[ -n $cert ]]; then
            [[ -r $cert && -r $key ]] || die 'Certificate/key not readable.'
            install -o root -g vless-lite -m 0640 "$cert" "$BASE/tls/fullchain.pem"
            install -o root -g vless-lite -m 0640 "$key" "$BASE/tls/key.pem"
        else
            dns_used=1
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
        jq -n --arg domain "$domain" --argjson port "$port" --arg uuid "$uuid" '{version:1,domain:$domain,nodes:[{name:"main",port:$port,uuid:$uuid}],relays:[]}' > "$BASE/state.json"
    else
        jq -n --arg host "$target_host" --argjson port "$port" --argjson target "$target_port" --arg network "$network" '{version:1,domain:"",nodes:[],relays:[{name:"main",port:$port,host:$host,target_port:$target,network:$network}]}' > "$BASE/state.json"
    fi
    render_state "$BASE/state.json" > "$BASE/config.json"
    chown root:vless-lite "$BASE/config.json"
    chmod 0640 "$BASE/config.json"
    /usr/local/bin/vless-lite-xray run -test -config "$BASE/config.json"
    cat > /etc/systemd/system/vless-lite.service <<'UNIT'
[Unit]
Description=Dex Lite nodes and port relays
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
    write_manager
    systemctl daemon-reload
    systemctl enable --now vless-lite.service
    sleep 2
    systemctl is-active --quiet vless-lite.service || die 'Service failed; check journalctl -u vless-lite.'
    if ((renew)); then systemctl enable --now vless-lite-renew.timer; fi
    if [[ $mode == server ]]; then
        expiry=$(openssl x509 -in "$BASE/tls/fullchain.pem" -noout -enddate)
        printf '\nTLS %s\n' "$expiry"
        if ((renew)); then printf 'Certificate renewal: enabled; DNS credentials retained with root-only access.\n'; else printf 'Certificate renewal: manual; DNS credentials not retained.\n'; fi
        node_info main
    else
        printf '\nRelay Information\n'
        relay_info main
        printf '\nClient: change Address to the relay address/port; retain final-server SNI, Host, UUID and Path.\n'
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
