#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║        SNI + HOST Port Multiplexer  v2.2.12 — by acrnm          ║
# ║  Port 443 → SNI-based routing  (REALITY/WS-TLS/XHTTP/gRPC)     ║
# ║  Port 80  → Host-based routing (WS/XHTTP/gRPC plaintext)       ║
# ║  Enable/Disable each port independently at any time             ║
# ║  Compatible: 3x-ui · s-ui · MTProxyMax · DSNS TM                ║
# ╚══════════════════════════════════════════════════════════════════╝
# INSTALL:  bash <(curl -fsSL https://raw.githubusercontent.com/alaaabd90/sni/main/sni-router.sh) --install
# UPDATE:   sni update
# MENU:     sni
# ──────────────────────────────────────────────────────────────────

# ── Colors ────────────────────────────────────────────────────────
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────
CONF_DIR="/etc/sni-router"
ROUTES_443="$CONF_DIR/routes_443.conf"
ROUTES_80="$CONF_DIR/routes_80.conf"
STATE_FILE="$CONF_DIR/state.conf"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
CMD_LINK="/usr/local/bin/sni"
SCRIPT_DEST="/usr/local/sbin/sni-router.sh"
LOG_FILE="/var/log/sni-router.log"
IP_CACHE="$CONF_DIR/.server_ip"
VERSION="2.2.12"
REPO_RAW="https://raw.githubusercontent.com/alaaabd90/sni/main/sni-router.sh"
REPO_API="https://api.github.com/repos/alaaabd90/sni/contents/sni-router.sh"

# ─────────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────────
info()    { echo -e "${G}[OK]${NC} $*"; }
warn()    { echo -e "${Y}[!]${NC} $*"; }
err()     { echo -e "${R}[ERR]${NC} $*"; }
title()   { echo -e "\n${BOLD}${C}$*${NC}"; }
divider() { echo -e "${DIM}────────────────────────────────────────────────────${NC}"; }
pause()   { echo -e "\n${DIM}  Press Enter to continue...${NC}"; read -r; }

root_check() {
    [[ $EUID -ne 0 ]] && { err "Run as root."; exit 1; }
}

# ─────────────────────────────────────────────────────────────────
#  STATE — simple key=value file
# ─────────────────────────────────────────────────────────────────
state_get() {
    local key="$1" default="${2-1}"
    if [[ -f "$STATE_FILE" ]]; then
        local val
        val=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        [[ -n "$val" ]] && echo "$val" && return
    fi
    echo "$default"
}

state_set() {
    local key="$1" val="$2"
    mkdir -p "$CONF_DIR"
    touch "$STATE_FILE"
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$STATE_FILE"
    else
        echo "${key}=${val}" >> "$STATE_FILE"
    fi
}

port443_enabled() { [[ "$(state_get enabled_443 1)" == "1" ]]; }
port80_enabled()  { [[ "$(state_get enabled_80  1)" == "1" ]]; }

# ─────────────────────────────────────────────────────────────────
#  ROUTES  (format: name|domain|local_port|description)
# ─────────────────────────────────────────────────────────────────
load_routes() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    grep -v '^#' "$file" 2>/dev/null | grep -v '^$' || true
}

route_count() {
    local file="$1"
    [[ -f "$file" ]] || { echo 0; return; }
    local n
    n=$(grep -v '^#' "$file" 2>/dev/null | grep -c '|') || n=0
    echo "$n"
}

route_exists() {
    grep -q "^${2}|" "$1" 2>/dev/null
}

port_listening() {
    ss -tlnp 2>/dev/null | grep -q ":$1 "
}

# ─────────────────────────────────────────────────────────────────
#  HAPROXY CONFIG GENERATOR
# ─────────────────────────────────────────────────────────────────
generate_haproxy_config() {
    local en443; en443=$(state_get enabled_443 1)
    local en80;  en80=$(state_get enabled_80 1)
    local def443; def443=$(state_get default_443 "")
    local def80;  def80=$(state_get default_80 "")

    # Write to temp file first — move atomically when done.
    local tmpfile
    tmpfile=$(mktemp /tmp/haproxy.XXXXXX.cfg)
    trap "rm -f '$tmpfile'" RETURN

    cat > "$tmpfile" <<'GLOBAL'
#──────────────────────────────────────────────────────────────────
# HAProxy — SNI+HOST Router (managed by sni-router, do not edit)
#──────────────────────────────────────────────────────────────────

global
    daemon
    maxconn 100000
    log /dev/log local0 info
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    tune.bufsize 65536

defaults
    log global
    option dontlognull
    option splice-auto
    option tcpka
    timeout connect     3s
    timeout client      10m
    timeout server      10m
    timeout tunnel      1h
    timeout client-fin  10s
    timeout server-fin  10s

frontend ft_stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE

GLOBAL

    # ── PORT 443 block ────────────────────────────────────────────
    if [[ "$en443" == "1" ]]; then
        local r443; r443=$(load_routes "$ROUTES_443")
        {
            echo "#── PORT 443 — SNI passthrough (Layer 4 TCP, no decryption) ──────"
            echo "frontend ft_443"
            echo "    bind *:443"
            echo "    mode tcp"
            echo "    option tcplog"
            echo "    tcp-request inspect-delay 1s"
            echo "    tcp-request content accept if { req_ssl_hello_type 1 }"
            # Reject non-TLS before use_backend (correct HAProxy ordering — no warning)
            if [[ -z "$def443" ]]; then
                echo "    tcp-request content reject"
            fi
            echo ""
        } >> "$tmpfile"

        if [[ -n "$r443" ]]; then
            while IFS='|' read -r name sni port desc; do
                [[ -z "$name" ]] && continue
                echo "    use_backend bk443_${name} if { req_ssl_sni -i ${sni} }" >> "$tmpfile"
            done <<< "$r443"
        fi

        if [[ -n "$def443" ]]; then
            echo "    default_backend bk443_default" >> "$tmpfile"
        fi
        echo "" >> "$tmpfile"

        if [[ -n "$r443" ]]; then
            echo "#── Port 443 backends ────────────────────────────────────────────" >> "$tmpfile"
            while IFS='|' read -r name sni port desc; do
                [[ -z "$name" ]] && continue
                printf "\nbackend bk443_%s\n    # %s => sni:%s\n    mode tcp\n    server srv 127.0.0.1:%s check inter 30s rise 2 fall 3\n" \
                    "$name" "$desc" "$sni" "$port" >> "$tmpfile"
            done <<< "$r443"
            echo "" >> "$tmpfile"
        fi

        if [[ -n "$def443" ]]; then
            printf "\nbackend bk443_default\n    # Default 443 fallback\n    mode tcp\n    server srv 127.0.0.1:%s\n\n" \
                "$def443" >> "$tmpfile"
        fi
    fi

    # ── PORT 80 block ─────────────────────────────────────────────
    if [[ "$en80" == "1" ]]; then
        local r80; r80=$(load_routes "$ROUTES_80")
        {
            echo "#── PORT 80 — Host header routing (Layer 7 HTTP) ────────────────"
            echo "frontend ft_80"
            echo "    bind *:80"
            echo "    mode http"
            echo "    option httplog"
            echo "    option forwardfor"
            echo "    option http-server-close"
            echo ""
        } >> "$tmpfile"

        if [[ -n "$r80" ]]; then
            while IFS='|' read -r name host port desc; do
                [[ -z "$name" ]] && continue
                echo "    acl host_${name} hdr(host) -i ${host}" >> "$tmpfile"
            done <<< "$r80"
            echo "" >> "$tmpfile"
            while IFS='|' read -r name host port desc; do
                [[ -z "$name" ]] && continue
                echo "    use_backend bk80_${name} if host_${name}" >> "$tmpfile"
            done <<< "$r80"
        fi

        if [[ -n "$def80" ]]; then
            echo "    default_backend bk80_default" >> "$tmpfile"
        fi
        echo "" >> "$tmpfile"

        if [[ -n "$r80" ]]; then
            echo "#── Port 80 backends ─────────────────────────────────────────────" >> "$tmpfile"
            while IFS='|' read -r name host port desc; do
                [[ -z "$name" ]] && continue
                printf "\nbackend bk80_%s\n    # %s => host:%s\n    mode http\n    option http-server-close\n    timeout tunnel 1h\n    server srv 127.0.0.1:%s check inter 30s rise 2 fall 3\n" \
                    "$name" "$desc" "$host" "$port" >> "$tmpfile"
            done <<< "$r80"
            echo "" >> "$tmpfile"
        fi

        if [[ -n "$def80" ]]; then
            printf "\nbackend bk80_default\n    # Default 80 fallback\n    mode http\n    option http-server-close\n    timeout tunnel 1h\n    server srv 127.0.0.1:%s\n\n" \
                "$def80" >> "$tmpfile"
        fi
    fi

    mv "$tmpfile" "$HAPROXY_CFG"
    trap - RETURN
}

# ─────────────────────────────────────────────────────────────────
#  APPLY
# ─────────────────────────────────────────────────────────────────
apply_config() {
    [[ -d /run/haproxy ]] || { mkdir -p /run/haproxy; chown haproxy:haproxy /run/haproxy 2>/dev/null || true; }
    generate_haproxy_config
    tune_sysctl
    if haproxy -c -f "$HAPROXY_CFG" &>/dev/null; then
        systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') Config reloaded OK" >> "$LOG_FILE"
        return 0
    else
        err "Config validation error:"
        haproxy -c -f "$HAPROXY_CFG"
        echo "$(date '+%Y-%m-%d %H:%M:%S') Config ERROR" >> "$LOG_FILE"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────
#  VALIDATION
# ─────────────────────────────────────────────────────────────────
validate_sni() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] || { err "Invalid domain: $1"; return 1; }
    return 0
}

validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || { err "Invalid port: $p"; return 1; }
    [[ "$p" -eq 443 || "$p" -eq 80 ]] && { err "Local port cannot be 80 or 443"; return 1; }
    return 0
}

validate_name_unique() {
    local file="$1" name="$2"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Name: letters/numbers/_ or - only"; return 1; }
    route_exists "$file" "$name" && { err "Name '$name' already exists"; return 1; }
    return 0
}

# ─────────────────────────────────────────────────────────────────
#  DISPLAY
# ─────────────────────────────────────────────────────────────────
print_header() {
    clear 2>/dev/null || printf '\033c' 2>/dev/null || true
    echo -e "${BOLD}${C}"
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║     SNI + HOST Port Multiplexer  v${VERSION}           ║"
    echo "  ║     Port 443 (SNI)  ·  Port 80 (Host Header)          ║"
    echo "  ╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

status_badge() {
    local enabled="$1" port="$2"
    if [[ "$enabled" == "1" ]]; then
        port_listening "$port" && echo -e "${G}${BOLD}ON  [active]${NC}" || echo -e "${Y}${BOLD}ON  [haproxy?]${NC}"
    else
        echo -e "${R}${BOLD}OFF [disabled]${NC}"
    fi
}

print_status_bar() {
    local en443; en443=$(state_get enabled_443 1)
    local en80;  en80=$(state_get enabled_80 1)
    local b443; b443=$(status_badge "$en443" "443")
    local b80;  b80=$(status_badge "$en80" "80")
    local hap
    systemctl is-active --quiet haproxy 2>/dev/null && hap="${G}running${NC}" || hap="${R}stopped${NC}"
    local cnt443; cnt443=$(route_count "$ROUTES_443")
    local cnt80;  cnt80=$(route_count "$ROUTES_80")
    local ip; ip=$(cat "$IP_CACHE" 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "?")

    echo -e "  ${DIM}HAProxy:${NC} $hap   ${DIM}IP:${NC} ${BOLD}$ip${NC}"
    echo -e "  ${DIM}Port 443:${NC} $b443  ${DIM}(${cnt443} routes)${NC}     ${DIM}Port 80:${NC} $b80  ${DIM}(${cnt80} routes)${NC}"
    divider
}

list_routes_table() {
    local file="$1" port_label="$2"
    local routes; routes=$(load_routes "$file")
    local cnt; cnt=$(route_count "$file")
    if [[ "$cnt" -eq 0 || -z "$routes" ]]; then
        echo -e "  ${Y}No routes for port ${port_label} yet.${NC}"
        return
    fi
    printf "  ${BOLD}%-4s %-16s %-30s %-8s %s${NC}\n" "No." "Name" "SNI / Host" "Port" "Description"
    divider
    local i=1
    while IFS='|' read -r name domain port desc; do
        [[ -z "$name" ]] && continue
        local badge
        port_listening "$port" && badge="${G}[UP]${NC}" || badge="${Y}[--]${NC}"
        printf "  ${BOLD}%-4s${NC} ${G}%-16s${NC} ${C}%-30s${NC} ${Y}%-8s${NC} %b  ${DIM}%s${NC}\n" \
            "$i." "$name" "$domain" "$port" "$badge" "$desc"
        ((i++)) || true
    done <<< "$routes"
    divider
    echo -e "  ${DIM}[UP]=inbound listening  [--]=not detected${NC}"
}

# ─────────────────────────────────────────────────────────────────
#  ADD ROUTE
# ─────────────────────────────────────────────────────────────────
action_add_route() {
    local pt="$1"
    local rfile; [[ "$pt" == "443" ]] && rfile="$ROUTES_443" || rfile="$ROUTES_80"
    local dlabel; [[ "$pt" == "443" ]] && dlabel="SNI domain (e.g. cdn.cloudflare.com)" || dlabel="Host header (e.g. sub.example.com)"

    title "  ADD ROUTE — Port ${pt}"
    divider
    echo -e "  ${DIM}Clients connect to port ${pt}. HAProxy routes by $([ "$pt" == "443" ] && echo SNI || echo 'Host header') to your local inbound.${NC}\n"

    local name
    while true; do
        read -rp "  Route name (letters/numbers/_-): " name
        name=$(echo "$name" | tr -d ' ')
        validate_name_unique "$rfile" "$name" && break
    done

    local domain
    while true; do
        read -rp "  ${dlabel}: " domain
        domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        validate_sni "$domain" && break
    done

    local lport
    while true; do
        read -rp "  Local inbound port (e.g. 10443): " lport
        validate_port "$lport" || continue
        port_listening "$lport" && info "Port $lport is listening — inbound found" || \
            warn "Nothing on $lport yet — set your inbound to this port first"
        break
    done

    local desc
    read -rp "  Description (optional): " desc
    [[ -z "$desc" ]] && desc="port${pt} route"

    echo ""
    echo -e "  ${BOLD}Route summary:${NC}"
    echo -e "  Client  →  ${BOLD}YOUR_IP:${pt}${NC}  $([ "$pt" == "443" ] && echo "SNI" || echo "Host")=${C}$domain${NC}"
    echo -e "  HAProxy →  ${Y}127.0.0.1:$lport${NC}  (your inbound)"
    echo ""
    read -rp "  Confirm? [y/N]: " ok
    [[ "$ok" != "y" && "$ok" != "Y" ]] && { warn "Cancelled."; pause; return; }

    echo "${name}|${domain}|${lport}|${desc}" >> "$rfile"
    apply_config && info "Route added and HAProxy reloaded!" || err "Reload failed"

    echo ""
    echo -e "  ${BOLD}${Y}Set your inbound in 3x-ui / s-ui:${NC}"
    echo -e "  ${DIM}Listen IP${NC}  →  ${G}127.0.0.1${NC}  (NOT 0.0.0.0)"
    echo -e "  ${DIM}Port${NC}       →  ${Y}$lport${NC}"
    if [[ "$pt" == "443" ]]; then
        echo -e "  ${DIM}TLS ON${NC}, SNI/serverName = ${C}$domain${NC}"
    else
        echo -e "  ${DIM}TLS OFF${NC}, no cert needed, protocol = ws/xhttp/grpc"
    fi
    pause
}

# ─────────────────────────────────────────────────────────────────
#  DELETE ROUTE
# ─────────────────────────────────────────────────────────────────
action_delete_route() {
    local pt="$1"
    local rfile; [[ "$pt" == "443" ]] && rfile="$ROUTES_443" || rfile="$ROUTES_80"

    title "  DELETE ROUTE — Port ${pt}"
    divider
    list_routes_table "$rfile" "$pt"
    [[ "$(route_count "$rfile")" -eq 0 ]] && { pause; return; }

    echo ""
    read -rp "  Route name to delete (0=cancel): " del
    [[ "$del" == "0" || -z "$del" ]] && return
    route_exists "$rfile" "$del" || { err "Not found: $del"; pause; return; }

    read -rp "  Delete '$del'? [y/N]: " ok
    [[ "$ok" != "y" && "$ok" != "Y" ]] && { warn "Cancelled."; pause; return; }

    sed -i "/^${del}|/d" "$rfile"
    apply_config && info "Deleted '$del'" || err "Reload failed"
    pause
}

# ─────────────────────────────────────────────────────────────────
#  EDIT ROUTE
# ─────────────────────────────────────────────────────────────────
action_edit_route() {
    local pt="$1"
    local rfile; [[ "$pt" == "443" ]] && rfile="$ROUTES_443" || rfile="$ROUTES_80"

    title "  EDIT ROUTE — Port ${pt}"
    divider
    list_routes_table "$rfile" "$pt"
    [[ "$(route_count "$rfile")" -eq 0 ]] && { pause; return; }

    echo ""
    read -rp "  Route name to edit (0=cancel): " ename
    [[ "$ename" == "0" || -z "$ename" ]] && return

    local line; line=$(grep "^${ename}|" "$rfile" 2>/dev/null || true)
    [[ -z "$line" ]] && { err "Not found: $ename"; pause; return; }

    IFS='|' read -r oname odomain oport odesc <<< "$line"
    echo -e "\n  ${DIM}Press Enter to keep current value [ ]${NC}\n"

    read -rp "  Domain/SNI [$odomain]: " nd; [[ -z "$nd" ]] && nd="$odomain"
    nd=$(echo "$nd" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    read -rp "  Local port [$oport]: " np; [[ -z "$np" ]] && np="$oport"
    read -rp "  Description [$odesc]: " nde; [[ -z "$nde" ]] && nde="$odesc"

    validate_sni "$nd" || { pause; return; }
    validate_port "$np" || { pause; return; }

    # Atomic rewrite using awk — avoids sed delimiter conflicts with '|' in route format
    local tmpfile; tmpfile=$(mktemp)
    awk -v old="$ename" -v new="${oname}|${nd}|${np}|${nde}" \
        'BEGIN{FS=OFS="|"} $1==old{print new; next} {print}' \
        "$rfile" > "$tmpfile" && mv "$tmpfile" "$rfile" || {
        rm -f "$tmpfile"
        err "Failed to write route file"
        pause
        return
    }

    apply_config && info "Route updated!" || err "Reload failed"
    pause
}

# ─────────────────────────────────────────────────────────────────
#  DEFAULT BACKEND
# ─────────────────────────────────────────────────────────────────
action_set_default() {
    local pt="$1"
    local key="default_${pt}"
    local cur; cur=$(state_get "$key" "")

    title "  DEFAULT BACKEND — Port ${pt}"
    divider
    echo -e "  ${DIM}Catches all traffic with no matching $([ "$pt" == "443" ] && echo SNI || echo Host).${NC}\n"
    [[ -n "$cur" ]] && echo -e "  Current default port: ${Y}$cur${NC}" || echo -e "  Current: ${DIM}none (unmatched rejected cleanly)${NC}"
    echo ""
    read -rp "  Default local port (Enter=clear/none): " dp
    if [[ -z "$dp" ]]; then
        state_set "$key" ""; warn "Default cleared — unmatched connections will be rejected"
    else
        validate_port "$dp" || { pause; return; }
        state_set "$key" "$dp"; info "Default → 127.0.0.1:$dp"
    fi
    apply_config && info "Config reloaded." || err "Reload failed"
    pause
}

# ─────────────────────────────────────────────────────────────────
#  ENABLE / DISABLE PORT
# ─────────────────────────────────────────────────────────────────
action_toggle_port() {
    local pt="$1"
    local key="enabled_${pt}"
    local cur; cur=$(state_get "$key" 1)

    title "  PORT ${pt} — ENABLE / DISABLE"
    divider

    if [[ "$cur" == "1" ]]; then
        echo -e "  Port ${pt} is: ${G}${BOLD}ENABLED${NC} (HAProxy is routing it)\n"
        echo -e "  ${Y}Disabling will free port ${pt} so your panel can bind to it directly.${NC}"
        echo -e "  ${Y}All routes for port ${pt} are preserved — re-enable anytime.${NC}\n"
        echo -e "  ${BOLD}Steps after disabling:${NC}"
        echo -e "  1. In 3x-ui/s-ui: change inbound listen IP from ${G}127.0.0.1${NC} → ${Y}0.0.0.0${NC}"
        echo -e "  2. Change inbound port to ${BOLD}${pt}${NC}"
        echo -e "  3. Restart the panel\n"
        read -rp "  Disable port ${pt}? [y/N]: " ok
        if [[ "$ok" == "y" || "$ok" == "Y" ]]; then
            state_set "$key" "0"
            apply_config && info "Port ${pt} disabled — HAProxy no longer listens on it." || { err "Reload failed"; state_set "$key" "1"; }
        else
            warn "Cancelled."
        fi
    else
        echo -e "  Port ${pt} is: ${R}${BOLD}DISABLED${NC} (HAProxy ignores it)\n"
        echo -e "  ${Y}Enabling lets HAProxy take over port ${pt} and route by $([ "$pt" == "443" ] && echo SNI || echo 'Host header').${NC}\n"
        echo -e "  ${BOLD}Steps before enabling:${NC}"
        echo -e "  1. In 3x-ui/s-ui: change inbound listen IP → ${G}127.0.0.1${NC}"
        echo -e "  2. Change inbound port to your local port (NOT ${pt})"
        echo -e "  3. Restart the panel\n"

        if port_listening "$pt"; then
            warn "Something is already on port ${pt}:"
            ss -tlnp | grep ":${pt} " | sed 's/^/    /'
            echo ""
            read -rp "  Enable anyway? [y/N]: " ok
        else
            read -rp "  Enable port ${pt}? [y/N]: " ok
        fi

        if [[ "$ok" == "y" || "$ok" == "Y" ]]; then
            state_set "$key" "1"
            if apply_config; then
                info "Port ${pt} enabled — HAProxy is routing it!"
            else
                err "Failed to start — rolling back"
                state_set "$key" "0"
                apply_config || true
            fi
        else
            warn "Cancelled."
        fi
    fi
    pause
}

action_toggle_both() {
    title "  BOTH PORTS — ENABLE / DISABLE"
    divider
    local en443; en443=$(state_get enabled_443 1)
    local en80;  en80=$(state_get enabled_80 1)

    echo -e "  Port 443: $([ "$en443" == "1" ] && echo -e "${G}ENABLED${NC}" || echo -e "${R}DISABLED${NC}")"
    echo -e "  Port 80:  $([ "$en80"  == "1" ] && echo -e "${G}ENABLED${NC}" || echo -e "${R}DISABLED${NC}")"
    echo ""
    echo -e "  ${G}[1]${NC} Enable  both  (HAProxy routes 443 + 80)"
    echo -e "  ${R}[2]${NC} Disable both  (free 443 + 80 for direct panel use)"
    echo -e "  ${DIM}[0]${NC} Cancel"
    echo ""
    read -rp "  Select: " opt
    case "$opt" in
        1)
            state_set "enabled_443" "1"; state_set "enabled_80" "1"
            apply_config && info "Both ports enabled!" || err "Reload failed"
            ;;
        2)
            state_set "enabled_443" "0"; state_set "enabled_80" "0"
            apply_config && info "Both ports disabled." || err "Reload failed"
            echo -e "\n  ${Y}You can now bind 0.0.0.0:443 and 0.0.0.0:80 directly in your panel.${NC}"
            echo -e "  ${Y}Re-enable anytime from this menu — all routes are preserved.${NC}"
            ;;
        *) warn "Cancelled." ;;
    esac
    pause
}

# ─────────────────────────────────────────────────────────────────
#  STATUS / TOOLS
# ─────────────────────────────────────────────────────────────────
action_status() {
    title "  FULL STATUS"
    divider

    echo -e "\n  ${BOLD}HAProxy:${NC}"
    systemctl status haproxy --no-pager -l 2>&1 | head -12 | sed 's/^/  /'

    echo -e "\n  ${BOLD}Port 443 Routes:${NC}"
    list_routes_table "$ROUTES_443" "443"

    echo -e "\n  ${BOLD}Port 80 Routes:${NC}"
    list_routes_table "$ROUTES_80" "80"

    echo -e "\n  ${BOLD}Active Listeners:${NC}"
    ss -tlnp 2>/dev/null | sed 's/^/  /' | head -30 || true

    echo -e "\n  ${BOLD}Log (last 15):${NC}"
    tail -15 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo -e "  ${DIM}Empty${NC}"

    echo -e "\n  ${DIM}HAProxy stats: curl http://127.0.0.1:8404/stats${NC}"
    pause
}

action_reload() {
    title "  RELOAD HAPROXY"
    divider
    apply_config && info "Reloaded OK!" || err "Failed — check: systemctl status haproxy"
    pause
}

action_live_log() {
    title "  LIVE LOG  (Ctrl+C to stop)"
    divider
    echo ""
    journalctl -u haproxy -f --no-pager 2>/dev/null || \
        tail -f /var/log/haproxy.log 2>/dev/null || \
        { err "No log found"; pause; }
}

action_show_config() {
    title "  HAPROXY CONFIG"
    divider
    echo ""
    cat "$HAPROXY_CFG" 2>/dev/null | sed 's/^/  /' || err "Config not found"
    pause
}

action_refresh_ip() {
    info "Fetching server IP..."
    local ip
    ip=$(curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
         curl -s4 --connect-timeout 5 https://api4.my-ip.io/ip 2>/dev/null || \
         hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    mkdir -p "$CONF_DIR"
    echo "$ip" > "$IP_CACHE"
    info "Server IP: $ip"
    pause
}

# ─────────────────────────────────────────────────────────────────
#  UPDATE
# ─────────────────────────────────────────────────────────────────
action_update() {
    title "  UPDATE"
    divider
    info "Fetching latest version from GitHub..."

    local tmp
    tmp=$(mktemp)
    trap "rm -f '$tmp'" RETURN

    if ! curl -fsSL --connect-timeout 15 --max-time 60 "${REPO_RAW}?nocache=$(date +%s)" -o "$tmp" 2>/dev/null; then
        warn "CDN unavailable — trying GitHub API..."
        : > "$tmp"
        curl -fsSL --connect-timeout 15 --max-time 60 \
            -H "Accept: application/vnd.github.raw+json" \
            -o "$tmp" "$REPO_API" 2>/dev/null || true
    fi

    if [[ ! -s "$tmp" ]]; then
        err "Download failed — check internet connection"
        pause
        return
    fi

    local new_ver
    new_ver=$(grep '^VERSION=' "$tmp" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [[ -z "$new_ver" ]]; then
        err "Downloaded file looks invalid — cannot read version"
        rm -f "$tmp"
        pause
        return
    fi

    echo ""
    echo -e "  Installed: ${Y}v${VERSION}${NC}"
    echo -e "  Available: ${G}v${new_ver}${NC}"

    if [[ "$new_ver" == "$VERSION" ]]; then
        info "Already up to date."
        rm -f "$tmp"
        pause
        return
    fi

    # Prevent downgrade: if available < installed, skip
    local newest
    newest=$(printf '%s\n' "$VERSION" "$new_ver" | sort -V | tail -1)
    if [[ "$newest" != "$new_ver" ]]; then
        info "Installed v${VERSION} is already newer than available v${new_ver} — skipping."
        rm -f "$tmp"
        pause
        return
    fi

    echo ""
    local ok
    if [[ -t 0 ]]; then
        read -rp "  Update to v${new_ver}? [y/N]: " ok
    else
        ok="y"
        info "Non-interactive — auto-confirming update"
    fi
    if [[ "$ok" != "y" && "$ok" != "Y" ]]; then
        warn "Cancelled."
        rm -f "$tmp"
        pause
        return
    fi

    chmod +x "$tmp"
    cp "$tmp" "$SCRIPT_DEST"
    chmod +x "$SCRIPT_DEST"
    ln -sf "$SCRIPT_DEST" "$CMD_LINK"
    rm -f "$tmp"
    info "Updated to v${new_ver}!"
    if [[ -t 0 ]]; then
        echo -e "  ${DIM}Restarting with new version...${NC}"
        sleep 1
        exec "$CMD_LINK"
    fi
}

# ─────────────────────────────────────────────────────────────────
#  HELP
# ─────────────────────────────────────────────────────────────────
action_help() {
    print_header
    cat << 'HELP'

  ┌──────────────────────────────────────────────────────────────┐
  │               INBOUND SETUP GUIDE                            │
  └──────────────────────────────────────────────────────────────┘

  PORT 443 — SNI ROUTING (TLS passthrough, Layer 4)
  ──────────────────────────────────────────────────
  HAProxy reads only the SNI field from the TLS ClientHello.
  It NEVER decrypts. Raw bytes forwarded as-is. Zero overhead.

  Inbound settings (3x-ui / s-ui):
    Listen IP  →  127.0.0.1  (NOT 0.0.0.0  — critical!)
    Port       →  your local port  (e.g. 10443)
    TLS        →  ON  (panel manages TLS)
    SNI        →  the domain you set in the route

  Client settings:
    Address    →  YOUR_SERVER_IP
    Port       →  443
    SNI        →  the domain for this route

  Works with: REALITY · VLESS+TLS · VMess+TLS · WS+TLS
              XHTTP+TLS · SplitHTTP+TLS · gRPC+TLS · Trojan

  PORT 80 — HOST HEADER ROUTING (HTTP Layer 7)
  ──────────────────────────────────────────────
  HAProxy reads the HTTP Host header. WebSocket upgrades
  are passed through transparently. Minimal overhead.

  Inbound settings (3x-ui / s-ui):
    Listen IP  →  127.0.0.1  (NOT 0.0.0.0)
    Port       →  your local port  (e.g. 20080)
    TLS        →  OFF  (port 80 = plaintext)
    Network    →  ws / xhttp / splithttp / grpc

  Client settings:
    Address    →  YOUR_SERVER_IP
    Port       →  80
    Host       →  the domain for this route
    TLS        →  OFF

  Works with: WS · XHTTP · SplitHTTP · gRPC plaintext
  Does NOT:   REALITY (needs TLS) · raw TCP (no Host header)

  DISABLE / RE-ENABLE A PORT
  ──────────────────────────────────────────────
  To use a port directly with your panel:
    1. Menu → option [3] or [4] → Disable port 443 or 80
    2. Panel: set inbound to 0.0.0.0:443 (or :80)
    3. When done: re-enable from menu
    4. Panel: set inbound back to 127.0.0.1:LOCAL_PORT

  All routes are preserved when disabled — nothing is deleted.

  RULES:
    Each route needs a unique SNI/Host domain
    Each route needs a different local port
    Never bind inbounds to 0.0.0.0 while HAProxy is ON
    Local ports cannot be 80 or 443

HELP
    pause
}

# ─────────────────────────────────────────────────────────────────
#  UNINSTALL
# ─────────────────────────────────────────────────────────────────
action_uninstall() {
    title "  UNINSTALL"
    divider
    echo -e "  ${R}${BOLD}Will remove:${NC}  HAProxy · all routes · 'sni' command"
    echo ""
    read -rp "  Type UNINSTALL to confirm: " ok
    [[ "$ok" != "UNINSTALL" ]] && { warn "Cancelled."; pause; return; }
    do_clean_old silent
    info "Uninstalled. Remember to update your panel inbounds to 0.0.0.0:PORT"
    exit 0
}

# ─────────────────────────────────────────────────────────────────
#  CLEAN OLD INSTALLATION
# ─────────────────────────────────────────────────────────────────
do_clean_old() {
    local silent="${1:-}"
    [[ -z "$silent" ]] && info "Cleaning old installation..."
    systemctl stop haproxy    2>/dev/null || true
    systemctl disable haproxy 2>/dev/null || true
    apt-get remove -y haproxy 2>/dev/null || true
    apt-get autoremove -y     2>/dev/null || true
    rm -f "$CMD_LINK"
    rm -f "$SCRIPT_DEST"
    rm -f /etc/haproxy/haproxy.cfg
    rmdir /etc/haproxy 2>/dev/null || true
    rm -f "$LOG_FILE"
    [[ -z "$silent" ]] && info "Old installation removed."
}

tune_sysctl() {
    # Tune TCP keepalive: start probing after 60s idle (default is 7200s — 2 hours).
    # This keeps carrier NAT mappings alive so idle VPN connections resume instantly.
    local conf="/etc/sysctl.d/99-sni-router.conf"
    cat > "$conf" <<'EOF'
# SNI Router — TCP keepalive tuning
# Keeps carrier NAT mappings alive on idle VPN connections
net.ipv4.tcp_keepalive_time  = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
EOF
    sysctl -p "$conf" &>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────
#  INSTALL
# ─────────────────────────────────────────────────────────────────
do_install() {
    root_check
    print_header
    title "  Installing SNI+HOST Router v${VERSION}..."
    divider

    # ── Step 1: Clean any old installation ────────────────────────
    echo ""
    if [[ -f "$CMD_LINK" || -f "$SCRIPT_DEST" || -d /etc/haproxy ]]; then
        warn "Existing installation detected — cleaning first..."
        do_clean_old silent
        info "Old installation removed."
    else
        info "No previous installation found."
    fi

    # ── Step 2: Port check warning ────────────────────────────────
    echo ""
    for p in 443 80; do
        if port_listening "$p"; then
            local holder; holder=$(ss -tlnp | grep ":${p} " | awk '{print $NF}' | head -1)
            warn "Port $p currently in use by: $holder"
        fi
    done

    echo ""
    echo -e "  ${Y}HAProxy will take over ports 443 and 80.${NC}"
    echo -e "  ${Y}Move any existing panel inbounds to local ports FIRST.${NC}"
    echo -e "  ${DIM}(You can also disable each port individually after install)${NC}"
    echo ""
    read -rp "  Continue with install? [y/N]: " cont
    [[ "$cont" != "y" && "$cont" != "Y" ]] && { warn "Aborted."; exit 1; }

    # ── Step 3: Install required packages ────────────────────────
    echo ""
    info "Updating package list..."
    apt-get update -qq 2>/dev/null
    info "Installing required tools (haproxy curl iproute2)..."
    apt-get install -y haproxy curl iproute2 2>/dev/null
    command -v haproxy &>/dev/null || { err "HAProxy install failed"; exit 1; }
    command -v curl    &>/dev/null || { err "curl install failed"; exit 1; }
    command -v ss      &>/dev/null || { err "iproute2 (ss) install failed"; exit 1; }
    info "$(haproxy -v 2>&1 | head -1)"

    # ── Step 4: Create config directory and files ─────────────────
    mkdir -p "$CONF_DIR" /etc/haproxy /run/haproxy
    chown haproxy:haproxy /run/haproxy 2>/dev/null || true

    # Ensure /run/haproxy survives reboots via systemd RuntimeDirectory
    mkdir -p /etc/systemd/system/haproxy.service.d/
    cat > /etc/systemd/system/haproxy.service.d/runtime-dir.conf << 'SVCEOF'
[Service]
RuntimeDirectory=haproxy
RuntimeDirectoryMode=0755
SVCEOF
    systemctl daemon-reload 2>/dev/null || true
    echo 'd /run/haproxy 0755 haproxy haproxy -' > /etc/tmpfiles.d/haproxy.conf

    [[ -f "$ROUTES_443" ]] || touch "$ROUTES_443"
    [[ -f "$ROUTES_80"  ]] || touch "$ROUTES_80"
    [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"
    touch "$LOG_FILE"
    chmod 600 "$ROUTES_443" "$ROUTES_80" "$STATE_FILE"

    state_set "enabled_443" "1"
    state_set "enabled_80"  "1"
    [[ -z "$(state_get default_443 "")" ]] && state_set "default_443" ""
    [[ -z "$(state_get default_80  "")" ]] && state_set "default_80"  ""

    # ── Step 5: Generate and validate HAProxy config ──────────────
    generate_haproxy_config
    if ! haproxy -c -f "$HAPROXY_CFG" &>/dev/null; then
        err "Generated config has errors:"
        haproxy -c -f "$HAPROXY_CFG"
        exit 1
    fi
    info "HAProxy config generated and validated OK"

    # ── Step 6: Start HAProxy ─────────────────────────────────────
    systemctl enable haproxy 2>/dev/null
    systemctl restart haproxy 2>/dev/null
    sleep 1
    if systemctl is-active --quiet haproxy 2>/dev/null; then
        info "HAProxy started successfully"
    else
        err "HAProxy failed to start:"
        systemctl status haproxy --no-pager | head -20
        exit 1
    fi

    # ── Step 6b: Tune TCP keepalive ──────────────────────────────
    tune_sysctl
    info "TCP keepalive tuned (idle probe starts after 60s)"

    # ── Step 7: Install sni command ───────────────────────────────
    # Handle both file-based and piped installs (bash <(curl ...))
    if [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/self/fd/* ]]; then
        cp "$0" "$SCRIPT_DEST"
        info "Script installed from local file."
    else
        info "Downloading script from GitHub..."
        if ! curl -fsSL --connect-timeout 15 "${REPO_RAW}?nocache=$(date +%s)" -o "$SCRIPT_DEST" 2>/dev/null; then
            err "Download failed — install script manually from: $REPO_RAW"
            exit 1
        fi
    fi
    chmod +x "$SCRIPT_DEST"
    ln -sf "$SCRIPT_DEST" "$CMD_LINK"
    chmod +x "$CMD_LINK"
    info "Command 'sni' installed → $CMD_LINK"

    # ── Step 8: Get server IP ─────────────────────────────────────
    local ip
    ip=$(curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
         curl -s4 --connect-timeout 5 https://api4.my-ip.io/ip 2>/dev/null || \
         hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
    echo "$ip" > "$IP_CACHE"

    # ── Done ──────────────────────────────────────────────────────
    divider
    echo -e "\n  ${G}${BOLD}Installation complete!${NC}\n"
    echo -e "  Server IP:  ${BOLD}$ip${NC}"
    echo -e "  Command:    ${C}sni${NC}  (opens this menu anytime)"
    echo -e "  Update:     ${C}sni update${NC}"
    echo ""
    echo -e "  ${BOLD}Quick start:${NC}"
    echo -e "  1. Run ${C}sni${NC} → option 1 → Add port 443 routes"
    echo -e "  2. Run ${C}sni${NC} → option 2 → Add port 80 routes"
    echo -e "  3. Set each inbound: Listen IP=${G}127.0.0.1${NC}  Port=local port"
    echo -e "  4. Use option 3/4 anytime to disable a port for direct panel use"
    echo ""
    divider
    echo ""
    read -rp "  Open menu now? [Y/n]: " go
    [[ "$go" == "n" || "$go" == "N" ]] && exit 0
}

# ─────────────────────────────────────────────────────────────────
#  SUBMENUS
# ─────────────────────────────────────────────────────────────────
menu_port443() {
    while true; do
        print_header
        local en; en=$(state_get enabled_443 1)
        local cnt; cnt=$(route_count "$ROUTES_443")
        local badge; badge=$(status_badge "$en" "443")
        echo -e "  ${BOLD}${C}PORT 443 — SNI Routing${NC}   $badge   Routes: ${BOLD}$cnt${NC}"
        divider
        echo ""
        echo -e "  ${G}[1]${NC} List routes"
        echo -e "  ${G}[2]${NC} Add route"
        echo -e "  ${G}[3]${NC} Edit route"
        echo -e "  ${G}[4]${NC} Delete route"
        echo -e "  ${G}[5]${NC} Set default backend"
        echo ""
        if [[ "$en" == "1" ]]; then
            echo -e "  ${R}[6]${NC} ${BOLD}Disable port 443${NC}  ${DIM}← free it for direct panel use${NC}"
        else
            echo -e "  ${G}[6]${NC} ${BOLD}Enable port 443${NC}   ${DIM}← HAProxy takes over${NC}"
        fi
        echo ""
        echo -e "  ${DIM}[0]${NC} Back"
        divider
        read -rp "  Select: " opt
        case "$opt" in
            1) print_header; list_routes_table "$ROUTES_443" "443"; pause ;;
            2) action_add_route "443" ;;
            3) action_edit_route "443" ;;
            4) action_delete_route "443" ;;
            5) action_set_default "443" ;;
            6) action_toggle_port "443" ;;
            0|q) return ;;
            *) warn "Invalid" ;;
        esac
    done
}

menu_port80() {
    while true; do
        print_header
        local en; en=$(state_get enabled_80 1)
        local cnt; cnt=$(route_count "$ROUTES_80")
        local badge; badge=$(status_badge "$en" "80")
        echo -e "  ${BOLD}${C}PORT 80 — Host Header Routing${NC}   $badge   Routes: ${BOLD}$cnt${NC}"
        divider
        echo ""
        echo -e "  ${G}[1]${NC} List routes"
        echo -e "  ${G}[2]${NC} Add route"
        echo -e "  ${G}[3]${NC} Edit route"
        echo -e "  ${G}[4]${NC} Delete route"
        echo -e "  ${G}[5]${NC} Set default backend"
        echo ""
        if [[ "$en" == "1" ]]; then
            echo -e "  ${R}[6]${NC} ${BOLD}Disable port 80${NC}   ${DIM}← free it for direct panel use${NC}"
        else
            echo -e "  ${G}[6]${NC} ${BOLD}Enable port 80${NC}    ${DIM}← HAProxy takes over${NC}"
        fi
        echo ""
        echo -e "  ${DIM}[0]${NC} Back"
        divider
        read -rp "  Select: " opt
        case "$opt" in
            1) print_header; list_routes_table "$ROUTES_80" "80"; pause ;;
            2) action_add_route "80" ;;
            3) action_edit_route "80" ;;
            4) action_delete_route "80" ;;
            5) action_set_default "80" ;;
            6) action_toggle_port "80" ;;
            0|q) return ;;
            *) warn "Invalid" ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────────────────────────
main_menu() {
    root_check
    [[ -t 0 ]] || { err "Interactive terminal required. Run: sni"; exit 1; }
    while true; do
        print_header
        print_status_bar
        echo -e "  ${BOLD}Routing${NC}"
        echo -e "  ${G}[1]${NC} Manage Port ${BOLD}443${NC}  ${DIM}(SNI · REALITY · WS+TLS · XHTTP · gRPC)${NC}"
        echo -e "  ${G}[2]${NC} Manage Port ${BOLD}80${NC}   ${DIM}(Host · WS · XHTTP · gRPC plaintext)${NC}"
        echo ""
        echo -e "  ${BOLD}Power Switch${NC}"
        echo -e "  ${C}[3]${NC} Enable / Disable  port ${BOLD}443${NC} only"
        echo -e "  ${C}[4]${NC} Enable / Disable  port ${BOLD}80${NC}  only"
        echo -e "  ${C}[5]${NC} Enable / Disable  ${BOLD}both ports${NC}"
        echo ""
        echo -e "  ${BOLD}System${NC}"
        echo -e "  ${Y}[6]${NC} Full status & diagnostics"
        echo -e "  ${Y}[7]${NC} Reload HAProxy"
        echo -e "  ${Y}[8]${NC} Live log"
        echo -e "  ${Y}[9]${NC} Show HAProxy config"
        echo -e "  ${Y}[r]${NC} Refresh server IP"
        echo ""
        echo -e "  ${Y}[h]${NC} Setup guide"
        echo -e "  ${G}[U]${NC} Update sni"
        echo -e "  ${R}[u]${NC} Uninstall"
        echo -e "  ${DIM}[0]${NC} Exit"
        divider
        read -rp "  Select: " opt
        case "$opt" in
            1) menu_port443 ;;
            2) menu_port80 ;;
            3) action_toggle_port "443" ;;
            4) action_toggle_port "80" ;;
            5) action_toggle_both ;;
            6) action_status ;;
            7) action_reload ;;
            8) action_live_log ;;
            9) action_show_config ;;
            r|R) action_refresh_ip ;;
            h|H) action_help ;;
            U) action_update ;;
            u) action_uninstall ;;
            0|q|Q) echo -e "\n  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
            *) warn "Invalid option" ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────
#  ENTRYPOINT
# ─────────────────────────────────────────────────────────────────
case "${1:-}" in
    --install|-i|install)
        do_install
        main_menu
        ;;
    update|--update)
        root_check
        action_update
        ;;
    version|--version|-v)
        echo "SNI+HOST Router v${VERSION}"
        exit 0
        ;;
    --help|-h|help)
        echo -e "\n  ${BOLD}SNI+HOST Router v${VERSION}${NC}"
        echo -e "  Install:  bash <(curl -fsSL ${REPO_RAW}) --install"
        echo -e "  Update:   sni update"
        echo -e "  Menu:     sni\n"
        ;;
    "")
        [[ ! -f "$ROUTES_443" ]] && { err "Not installed. Run:"; echo "  bash <(curl -fsSL ${REPO_RAW}) --install"; exit 1; }
        root_check
        main_menu
        ;;
    *)
        err "Unknown: $1"
        echo -e "  Usage: sni [--install | update | version | --help]"
        exit 1
        ;;
esac
