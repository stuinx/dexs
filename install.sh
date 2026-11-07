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

detect_init() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
        printf 'systemd\n'
    elif command -v rc-service >/dev/null && command -v rc-update >/dev/null; then
        printf 'openrc\n'
    else die '需要运行中的 systemd 或 OpenRC。'; fi
}

listeners_ready() {
    local port network entries
    entries=$(jq -r '.inbounds[] | [.port,(if .protocol=="dokodemo-door" then .settings.network else "tcp" end)] | @tsv' "$BASE/config.json") || return 1
    while IFS=$'\t' read -r port network; do
        [[ -n $port ]] || continue
        if [[ $network == *tcp* && -z $(ss -H -ltn "sport = :$port") ]]; then return 1; fi
        if [[ $network == *udp* && -z $(ss -H -lun "sport = :$port") ]]; then return 1; fi
    done <<< "$entries"
}

service_action() {
    local init
    init=$(detect_init) || return 1
    if [[ $init == openrc ]]; then
        # OpenRC launches the supervisor as a child of this command.
        unset CF_Token CF_Key CF_Email CF_Account_ID CF_Zone_ID
    fi
    case "$init:$1" in
        systemd:restart) systemctl restart vless-lite.service ;;
        systemd:active) systemctl is-active --quiet vless-lite.service && listeners_ready ;;
        systemd:status) systemctl --no-pager status vless-lite.service ;;
        systemd:start) systemctl daemon-reload && systemctl enable --now vless-lite.service ;;
        # The supervisor must not inherit the configuration lock or menu terminal.
        openrc:restart) rc-service vless-lite restart 8>&- 9>&- ;;
        openrc:active) rc-service -q vless-lite status 8>&- 9>&- && listeners_ready ;;
        openrc:status) rc-service vless-lite status 8>&- 9>&- ;;
        openrc:start) rc-update add vless-lite default 8>&- 9>&- && rc-service vless-lite start 8>&- 9>&- ;;
        *) die "Unknown service action: $1" ;;
    esac
}

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
    local value=$((10#$1)) minimum=${2:-1}
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
        (.port | type == "number" and floor == . and . >= 1 and . <= 65535)) and
      all(.relays[]; (.name | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
        (.host | type == "string") and
        (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
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
    managed_config_matches "$BASE/state.json" || { printf 'Configuration was edited outside dexs; refusing to overwrite it.\n' >&2; return 1; }
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
        service_action restart && sleep 1 && service_action active; then
        rm -rf "$transaction"
        return 0
    fi
    cp -p "$transaction/config.before.json" "$BASE/config.json"
    cp -p "$transaction/state.before.json" "$BASE/state.json"
    if service_action restart; then
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

menu_open() {
    if [[ -z ${MENU_FD:-} ]]; then
        [[ -r /dev/tty ]] || die '菜单需要终端；非交互安装请使用命令行参数。'
        exec 8<> /dev/tty
        MENU_FD=8
    fi
}

menu_read() {
    local destination=$1 prompt=$2
    printf '%s' "$prompt" >&2
    IFS= read -r -u "$MENU_FD" "${destination?}"
}

menu_pause() {
    read -r -u "$MENU_FD" -p '按 Enter 返回菜单...' || true
}

menu_header() {
    local blue='' green='' cyan='' yellow='' red='' reset='' nodes=0 relays=0
    if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
        blue='\033[34m'; green='\033[32m'; cyan='\033[36m'
        yellow='\033[33m'; red='\033[31m'; reset='\033[0m'
    fi
    if [[ -f $BASE/state.json ]]; then
        nodes=$(jq '.nodes|length' "$BASE/state.json")
        relays=$(jq '.relays|length' "$BASE/state.json")
    fi
    printf '\n%b----------------------------------------------------------------%b\n' "$blue" "$reset"
    printf '%bKernel: %s%b\n' "$blue" "$(uname -r)" "$reset"
    printf '%b============ DEXS · SERVER =================================%b\n' "$green" "$reset"
    printf '%b  VLESS + WS + TLS                 TCP / UDP 中转%b\n' "$green" "$reset"
    printf '%b  Server 节点: %s                 中转规则: %s%b\n' "$cyan" "$nodes" "$relays" "$reset"
    printf '%b================================================================%b\n\n' "$green" "$reset"
    printf '%b1. 安装%b\n' "$green" "$reset"
    printf '%b2. 中转%b\n' "$cyan" "$reset"
    printf '%b9. 查看%b\n' "$yellow" "$reset"
    printf '%b0. 退出%b\n\n' "$red" "$reset"
}

menu_run() {
    local result
    set +e
    ( set -e; manager_main "$@" )
    result=$?
    set -e
    if ((result != 0)); then printf '操作未完成，请根据上方提示检查。\n' >&2; fi
}

menu_manage() {
    local kind=$1 title choice name port uuid host target network answer
    if [[ $kind == node ]]; then title='Server 节点管理'; else title='中转管理'; fi
    while true; do
        printf '\n============ %s ============\n' "$title"
        printf '1. 新增\n2. 列表\n3. 详情'
        [[ $kind != node ]] || printf ' / 二维码'
        printf '\n4. 删除\n0. 返回\n\n'
        menu_read choice 'Select: ' || return 0
        case "$choice" in
            1)
                printf '应用配置会重启 Xray，现有连接将短暂断开。\n'
                menu_read name '名称: ' || return 0
                menu_read port '监听端口: ' || return 0
                if [[ $kind == node ]]; then
                    menu_read uuid 'UUID（回车自动生成）: ' || return 0
                    if [[ -n $uuid ]]; then menu_run node add "$name" "$port" "$uuid"; else menu_run node add "$name" "$port"; fi
                else
                    menu_read host '目标 IP / 域名: ' || return 0
                    menu_read target '目标端口: ' || return 0
                    menu_read network '协议 tcp / udp / tcp,udp（默认 tcp）: ' || return 0
                    menu_run relay add "$name" "$port" "$host" "$target" "${network:-tcp}"
                fi ;;
            2) menu_run "$kind" list ;;
            3)
                menu_run "$kind" list
                menu_read name '查看名称（默认 main）: ' || return 0
                menu_run "$kind" info "${name:-main}" ;;
            4)
                menu_run "$kind" list
                menu_read name '删除名称: ' || return 0
                menu_read answer "确认删除 $name 并重启服务？[y/N]: " || return 0
                if [[ $answer == y || $answer == Y ]]; then menu_run "$kind" del "$name"; else printf '已取消。\n'; fi ;;
            0) return ;;
            *) printf '请输入菜单编号。\n' ;;
        esac
        menu_pause
    done
}

install_wizard() {
    local mode=$1 domain port uuid cert key renewal host target network method
    local -a args=(--mode "$mode")
    if [[ $mode == server ]]; then
        printf '\n============ 安装 Server 节点 ============\n'
        menu_read domain '节点域名（不含端口）: ' || return 0
        domain=${domain,,}
        if [[ $domain != *.* || $domain == *:* ]] || ! valid_host "$domain"; then
            printf '域名无效，请只填写域名，端口在下一项填写。\n' >&2
            return 0
        fi
        menu_read port '监听端口（默认 2096）: ' || return 0
        port=$(parse_port "${port:-2096}") || return 0
        menu_read uuid 'UUID（回车自动生成）: ' || return 0
        args+=(--domain "$domain" --port "${port:-2096}")
        [[ -z $uuid ]] || args+=(--uuid "$uuid")
        printf '1. Cloudflare DNS 签发证书\n2. 使用已有证书\n'
        menu_read method '证书方式（默认 1）: ' || return 0
        case ${method:-1} in
            1)
                menu_read renewal '保留 DNS 凭据以启用自动续期？[y/N]: ' || return 0
                [[ $renewal != y && $renewal != Y ]] || args+=(--renew) ;;
            2)
                menu_read cert '全链证书路径: ' || return 0
                menu_read key '私钥路径: ' || return 0
                args+=(--cert-file "$cert" --key-file "$key") ;;
            *) printf '证书方式无效。\n' >&2; return 0 ;;
        esac
    else
        printf '\n============ 安装纯中转 ============\n'
        menu_read port '监听端口（默认 2096）: ' || return 0
        port=$(parse_port "${port:-2096}") || return 0
        menu_read host '目标 IP / 域名: ' || return 0
        menu_read target '目标端口: ' || return 0
        menu_read network '协议 tcp / udp / tcp,udp（默认 tcp）: ' || return 0
        args+=(--port "${port:-2096}" --target-host "$host" --target-port "$target" --network "${network:-tcp}")
    fi
    # Installation exits on failure; a subshell keeps the menu available afterwards.
    local result
    set +e
    ( set -e; main "${args[@]}" )
    result=$?
    set -e
    if ((result != 0)); then printf '安装未完成，请检查上方提示。\n' >&2; fi
}

prepare_install_directory() {
    local backup
    [[ -e $BASE || -L $BASE ]] || return 0
    [[ -d $BASE && ! -L $BASE && ! -L $BASE/tls ]] || die "Existing installation path is not a regular directory: $BASE"
    if [[ -n $(find "$BASE" -mindepth 1 ! -path "$BASE/tls" -print -quit) ]] ||
        [[ -e $BASE/tls && ! -d $BASE/tls ]]; then
        die "Existing configuration or files found in $BASE; refusing to overwrite. Use --upgrade only for a completed installation."
    fi
    backup=$(mktemp -d "${BASE}.incomplete.XXXXXX")
    mv "$BASE" "$backup/install"
    printf 'Preserved empty incomplete installation at %s/install; retrying installation.\n' "$backup"
}

menu_main() {
    [[ $EUID == 0 ]] || die 'Run as root.'
    menu_open
    local choice first
    while true; do
        menu_header
        menu_read choice 'Select: ' || return 0
        case "$choice" in
            1|2)
                if [[ -f $BASE/state.json ]]; then
                    if [[ $choice == 1 ]]; then menu_manage node; else menu_manage relay; fi
                elif declare -F install_wizard >/dev/null; then
                    if [[ $choice == 1 ]]; then install_wizard server; else install_wizard relay; fi
                    menu_pause
                else printf '安装状态缺失，请重新运行安装脚本检查。\n'; menu_pause; fi ;;
            9)
                if [[ -f $BASE/state.json ]]; then
                    menu_run node list
                    menu_run relay list
                    first=$(jq -r '.nodes[0].name // .relays[0].name // ""' "$BASE/state.json")
                    [[ -z $first ]] || menu_run info "$first"
                    menu_run status
                else printf '尚未安装 dexs。\n'; fi
                menu_pause ;;
            0) return ;;
            *) printf '请输入 1、2、9 或 0。\n'; menu_pause ;;
        esac
    done
}

manager_main() {
    [[ $EUID == 0 ]] || die 'Run as root.'
    if (($# == 0)) || [[ ${1:-} == menu ]]; then menu_main; return; fi
    if [[ ${1:-help} == help || ${1:-} == --help ]]; then
        cat <<'HELP'
dexs — one Xray process for VLESS WS TLS nodes and port relays
  dexs                                  Interactive menu (1/2/9/0)
  dexs info [NAME]                       Node + QR or relay details (default main)
  dexs node list
  dexs node add NAME PORT [UUID]         Reuse installed hostname/certificate
  dexs node info NAME
  dexs node del NAME
  dexs relay list
  dexs relay add NAME PORT HOST TARGET_PORT [tcp|udp|tcp,udp]
  dexs relay info NAME
  dexs relay del NAME
  dexs status
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
        status) service_action status; return ;;
        cert-reload)
            "$XRAY_BIN" run -test -config "$BASE/config.json" >/dev/null
            if service_action active; then service_action restart; fi
            return ;;
        info)
            name=${2:-main}
            if jq -e --arg name "$name" '.nodes[] | select(.name==$name)' "$BASE/state.json" >/dev/null; then
                node_info "$name"
            else relay_info "$name"; fi
            return ;;
        node|relay) kind=$action; command=${2:-list} ;;
        *) die 'Unknown command; use dexs help.' ;;
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
            (($# == 3)) || die "Usage: dexs $kind info NAME"
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
            (($# == 4 || $# == 5)) || die 'Usage: dexs node add NAME PORT [UUID]'
            port=$(parse_port "$4")
            uuid=${5:-$(cat /proc/sys/kernel/random/uuid)}
            uuid=${uuid,,}
            valid_uuid "$uuid" || die 'Invalid UUID.'
            network=tcp
        else
            (($# == 6 || $# == 7)) || die 'Usage: dexs relay add NAME PORT HOST TARGET_PORT [NETWORK]'
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
        (($# == 3)) || die "Usage: dexs $kind del NAME"
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
    temporary=$(mktemp "$MANAGER_DIR/.dexs.XXXXXX")
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
        declare -f die detect_init listeners_ready service_action show_info parse_port valid_name valid_uuid valid_host validate_state render_state port_available managed_config_matches apply_state node_info relay_info menu_open menu_read menu_pause menu_header menu_run menu_manage menu_main manager_main
        # shellcheck disable=SC2016
        printf '\nmanager_main "$@"\n'
    } > "$temporary"
    chmod 0755 "$temporary"
    mv "$temporary" "$MANAGER_DIR/dexs"
    ln -sfn "$MANAGER_DIR/dexs" "$MANAGER_DIR/vless-lite"
    ln -sfn "$MANAGER_DIR/dexs" "$MANAGER_DIR/dex-lite"
}

upgrade_manager() {
    local candidate alias target
    [[ $EUID == 0 ]] || die 'Run as root.'
    [[ -x $XRAY_BIN && -f $BASE/config.json ]] || die 'An existing dexs/vless-lite installation is required.'
    if [[ -e $MANAGER_DIR/dexs || -L $MANAGER_DIR/dexs ]]; then
        [[ -f $MANAGER_DIR/dexs && ! -L $MANAGER_DIR/dexs && -L $MANAGER_DIR/vless-lite && $(readlink "$MANAGER_DIR/vless-lite") == "$MANAGER_DIR/dexs" ]] || die 'dexs already exists and is not managed by this installation.'
    fi
    for alias in vless-lite dex-lite; do
        if [[ -L $MANAGER_DIR/$alias ]]; then
            target=$(readlink "$MANAGER_DIR/$alias")
            [[ $target == "$MANAGER_DIR/dexs" || ( $alias == dex-lite && $target == "$MANAGER_DIR/vless-lite" ) ]] || die "$alias points to another program."
        elif [[ -e $MANAGER_DIR/$alias ]]; then
            [[ $alias == vless-lite && -f $MANAGER_DIR/$alias ]] || die "$alias already exists and is not managed by this installation."
        fi
    done
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
    printf 'dexs management upgraded; use dexs help.\n'
}

scrub_dns() {
    if [[ -f $ACME_HOME/account.conf ]]; then
        sed -i '/^SAVED_CF_/d; /^CF_/d' "$ACME_HOME/account.conf"
    fi
    unset CF_Token CF_Key CF_Email CF_Account_ID CF_Zone_ID
}

main() {
    if (($# == 0)) || [[ ${1:-} == menu ]]; then menu_main; return; fi
    case ${1:-} in
        info|node|relay|status|cert-reload) manager_main "$@"; return ;;
        --upgrade) (($# == 1)) || die '--upgrade does not accept installation options.'; upgrade_manager; return ;;
    esac
    local domain='' port=2096 uuid='' cert='' key='' renew=0 version='' work=''
    local mode=server target_host='' target_port='' network=tcp
    local arch asset expected expiry method email hook label init
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
  (no options)        Open the interactive 1/2/9/0 menu
  --mode server|relay Create a dex-compatible node or a plain relay (default server)
  --domain HOST       TLS hostname; prompted when omitted
  --port PORT         Container listening port, 1-65535 (default 2096)
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
    [[ ! -e /usr/local/bin/vless-lite && ! -e /etc/systemd/system/vless-lite.service && ! -e /etc/init.d/vless-lite ]] || die 'Installation exists; run --upgrade. Existing files will not be overwritten.'
    [[ ! -e /usr/local/bin/dexs && ! -L /usr/local/bin/dexs ]] || die '/usr/local/bin/dexs already exists.'
    [[ ! -e /usr/local/bin/dex-lite && ! -L /usr/local/bin/dex-lite ]] || die '/usr/local/bin/dex-lite already exists.'
    . /etc/os-release
    [[ $ID == alpine && $VERSION_ID == 3.* || $ID == debian && ( $VERSION_ID == 12 || $VERSION_ID == 13 ) ]] || die 'Supported systems: Debian 12/13 or Alpine 3.x.'
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
    prepare_install_directory
    if [[ $ID == alpine ]]; then
        apk add --no-cache bash ca-certificates curl jq unzip iproute2-ss flock openrc
        if [[ $mode == server ]]; then apk add --no-cache openssl libqrencode-tools; fi
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl jq unzip iproute2 util-linux
        if [[ $mode == server ]]; then apt-get install -y --no-install-recommends openssl qrencode; fi
    fi
    init=$(detect_init)
    [[ $ID != debian || $init == systemd ]] || die 'Debian 安装需要 systemd。'
    [[ $ID != alpine || $init == openrc ]] || die 'Alpine 安装需要 OpenRC。'
    [[ $init != openrc || -f /run/openrc/softlevel ]] || die 'OpenRC 尚未启动；请在正常启动的 Alpine LXC 中安装。'
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
    if [[ $ID == alpine ]]; then
        grep -q '^vless-lite:' /etc/group || addgroup -S vless-lite
        id vless-lite >/dev/null 2>&1 || adduser -S -D -H -h /nonexistent -s /sbin/nologin -G vless-lite vless-lite
    else
        getent group vless-lite >/dev/null || groupadd --system vless-lite
        id vless-lite >/dev/null 2>&1 || useradd --system --gid vless-lite --home-dir /nonexistent --shell /usr/sbin/nologin vless-lite
    fi
    install -d -o root -g vless-lite -m 0750 "$BASE"
    [[ -d /usr/local/bin ]] || install -d -m 0755 /usr/local/bin
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
            hook="chown root:vless-lite '$BASE/tls/fullchain.pem' '$BASE/tls/key.pem' && chmod 640 '$BASE/tls/fullchain.pem' '$BASE/tls/key.pem' && if [ -x /usr/local/bin/dexs ]; then /usr/local/bin/dexs cert-reload; fi"
            "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" --ecc --fullchain-file "$BASE/tls/fullchain.pem" --key-file "$BASE/tls/key.pem" --reloadcmd "$hook"
            if ((renew == 0)); then scrub_dns; fi
        fi
        unset CF_Token CF_Key CF_Email CF_Account_ID CF_Zone_ID
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
    if [[ $init == systemd ]]; then
    cat > /etc/systemd/system/vless-lite.service <<'UNIT'
[Unit]
Description=dexs nodes and port relays
After=network-online.target
Wants=network-online.target
[Service]
User=vless-lite
Group=vless-lite
ExecStart=/usr/local/bin/vless-lite-xray run -config /etc/vless-lite/config.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
    else
        cat > /etc/init.d/vless-lite <<'UNIT'
#!/sbin/openrc-run
description="dexs nodes and port relays"
command="/usr/local/bin/vless-lite-xray"
command_args="run -config /etc/vless-lite/config.json"
command_user="vless-lite:vless-lite"
capabilities="^cap_net_bind_service"
supervisor="supervise-daemon"
pidfile="/run/vless-lite/supervisor.pid"
output_log="/var/log/vless-lite.log"
error_log="/var/log/vless-lite.log"
respawn_delay=5
umask="0077"
depend() { after net; }
start_pre() {
    checkpath -d -m 0755 -o vless-lite:vless-lite /run/vless-lite
    checkpath -f -m 0640 -o vless-lite:vless-lite /var/log/vless-lite.log
    "$command" run -test -config /etc/vless-lite/config.json >/dev/null 2>&1
}
UNIT
        chmod 0755 /etc/init.d/vless-lite
    fi
    if ((renew)); then
    if [[ $init == systemd ]]; then
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
    else
        apk add --no-cache busybox-openrc
        install -d -m 0755 /etc/periodic/daily
        printf '#!/bin/sh\nexec %s/acme.sh --cron --home %s\n' "$ACME_HOME" "$ACME_HOME" > /etc/periodic/daily/vless-lite-renew
        chmod 0700 /etc/periodic/daily/vless-lite-renew
        rc-update add crond default
        if ! rc-service -q crond status; then rc-service crond start 8>&- 9>&-; fi
    fi
    fi
    write_manager
    service_action start
    sleep 2
    service_action active || die 'Service failed; check system logs or /var/log/vless-lite.log.'
    if ((renew)) && [[ $init == systemd ]]; then systemctl enable --now vless-lite-renew.timer; fi
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
