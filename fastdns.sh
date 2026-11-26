#!/usr/bin/env bash
# FastDNS manager — versión bash (port de fastdns.cpp)
# Relay UDP-sobre-DNS + stack OpenVPN para VPS.
#
# Uso:  sudo bash fastdns.sh [comando] [opciones]
#

G_ARGV=("$@")

# ────────────────────────── estado / config ──────────────────────────
NAME="fastdns"
BIN_DST="/usr/local/bin/fastdns-server"
CMD_DST="/usr/local/bin/fastdns"
CONF_DIR="/etc/fastdns"
CONF_FILE="/etc/fastdns/fastdns.conf"
UNIT_FILE="/etc/systemd/system/fastdns.service"
PID_FILE="/run/fastdns.pid"
LOG_FILE="/var/log/fastdns.log"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/fastdns.conf"

# relay
LISTEN=":53"
UPSTREAM="127.0.0.1:1194"
IDLE="2m0s"
QUEUE="2048"
POLL_ONLY="0"
VERBOSE="0"
ARGS=""

# binario / arquitectura
ARCH=""
BIN_NAME="fastdns-server-linux-amd64"
BIN_SRC=""
BIN_URL_BASE="https://raw.githubusercontent.com/JotchuaST/FastDNS-HexCustom/refs/heads/main"
BIN_URL=""
BIN_SHA256=""
DL_TMP=""
SCRIPT_DIR="."

# OpenVPN
OVPN_INSTANCE="fastdns"
OVPN_SERVER_CONF="/etc/openvpn/server/fastdns.conf"
OVPN_UNIT="openvpn-server@fastdns"
PKI_DIR="/etc/openvpn/fastdns-pki"
EASYRSA_DIR="/etc/openvpn/easy-rsa-fastdns"
CLIENT_OVPN="/root/fastdns-client.ovpn"
OVPN_PORT="1194"
OVPN_NET="10.9.0.0 255.255.255.0"
WITH_OPENVPN="1"
REGEN_PKI="0"
PUBLIC_IP=""

# ────────────────────────── colores ──────────────────────────
init_colors() {
  if [ -t 1 ] || [ -n "${FASTDNS_FORCE_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_BLD=$'\033[1m'; BC=$'\033[38;5;99m'; C_ACC=$'\033[38;5;51m'
    C_OK=$'\033[38;5;84m'; C_ERR=$'\033[38;5;203m'; C_WARN=$'\033[38;5;221m'
    C_MUT=$'\033[38;5;245m'; C_TXT=$'\033[38;5;255m'
    BG_OK=$'\033[48;5;29m\033[38;5;231m'; BG_ERR=$'\033[48;5;160m\033[38;5;231m'
    BG_WARN=$'\033[48;5;178m\033[38;5;16m'; BG_NUM=$'\033[48;5;99m\033[38;5;231m'
  else
    C_RST=""; C_BLD=""; BC=""; C_ACC=""; C_OK=""; C_ERR=""; C_WARN=""; C_MUT=""; C_TXT=""
    BG_OK=""; BG_ERR=""; BG_WARN=""; BG_NUM=""
  fi
}
ok()   { printf '  %s✔%s %s\n' "$C_OK" "$C_RST" "$1"; }
bad()  { printf '  %s✘%s %s\n' "$C_ERR" "$C_RST" "$1"; }
warn() { printf '  %s▲%s %s\n' "$C_WARN" "$C_RST" "$1"; }
note() { printf '  %s❯%s %s\n' "$C_ACC" "$C_RST" "$1"; }

# ────────────────────────── helpers de sistema ──────────────────────────
ok_run()     { "$@" >/dev/null 2>&1; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
is_exec()    { [ -e "$1" ] && [ -x "$1" ]; }
is_root()    { [ "$(id -u)" -eq 0 ]; }
has_systemd(){ [ -e /run/systemd/system ] && cmd_exists systemctl; }

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

self_path() { readlink -f "$0" 2>/dev/null || printf '%s' "$0"; }

need_root() {
  is_root && return 0
  if cmd_exists sudo; then
    exec sudo bash "$(self_path)" "${G_ARGV[@]}"
  fi
  bad "Necesitas root. Ejecuta con sudo o como root."
  exit 1
}

# ────────────────────────── arquitectura ──────────────────────────
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) printf '' ;;
  esac
}
uname_m() { uname -m 2>/dev/null || printf '?'; }

find_local_bin() {
  local a=${ARCH:-amd64} p
  for p in "$SCRIPT_DIR/$BIN_NAME" "$SCRIPT_DIR/bin/$BIN_NAME" \
           "$SCRIPT_DIR/fastdns-server-linux-$a" "$SCRIPT_DIR/bin/fastdns-server-linux-$a"; do
    if [ -e "$p" ]; then printf '%s' "$p"; return; fi
  done
  printf '%s' "$SCRIPT_DIR/$BIN_NAME"
}

# e_machine de un ELF LE (offset 18): 62=x86-64, 183=AArch64
# imprime: -1 no legible, -2 no es ELF, o el número
elf_machine() {
  local f=$1 hdr b
  [ -r "$f" ] || { echo -1; return; }
  hdr=$(od -An -v -tu1 -N20 "$f" 2>/dev/null)
  b=($hdr)
  [ "${#b[@]}" -lt 20 ] && { echo -1; return; }
  if [ "${b[0]}" = 127 ] && [ "${b[1]}" = 69 ] && [ "${b[2]}" = 76 ] && [ "${b[3]}" = 70 ]; then
    echo $(( b[18] | (b[19] << 8) ))
  else
    echo -2
  fi
}
elf_arch_ok() {
  local m; m=$(elf_machine "$1")
  if [ "$ARCH" = amd64 ]; then [ "$m" = 62 ]; return; fi
  if [ "$ARCH" = arm64 ]; then [ "$m" = 183 ]; return; fi
  return 0
}

# ────────────────────────── config ──────────────────────────
port_of()   { printf '%s' "${LISTEN##*:}"; }
port_busy() { [ -n "$(ss -H -lun "sport = :$1" 2>/dev/null)" ]; }
build_args() {
  ARGS="-listen $LISTEN -upstream $UPSTREAM -idle $IDLE -queue $QUEUE"
  [ "$POLL_ONLY" = 1 ] && ARGS+=" -poll-only"
  [ "$VERBOSE" = 1 ]   && ARGS+=" -verbose"
}
save_conf() {
  build_args
  mkdir -p "$CONF_DIR"
  {
    printf 'LISTEN="%s"\n'    "$LISTEN"
    printf 'UPSTREAM="%s"\n'  "$UPSTREAM"
    printf 'IDLE="%s"\n'      "$IDLE"
    printf 'QUEUE="%s"\n'     "$QUEUE"
    printf 'POLL_ONLY="%s"\n' "$POLL_ONLY"
    printf 'VERBOSE="%s"\n'   "$VERBOSE"
    printf 'ARGS="%s"\n'      "$ARGS"
    printf 'BIN_URL="%s"\n'   "$BIN_URL"
  } > "$CONF_FILE"
  chmod 644 "$CONF_FILE"
}
conf_val() { # $1 = clave
  local key=$1 line v
  while IFS= read -r line; do
    if [[ $line == "$key="* ]]; then
      v=${line#"$key="}
      if [ "${#v}" -ge 2 ] && [ "${v:0:1}" = '"' ] && [ "${v: -1}" = '"' ]; then
        v=${v:1:${#v}-2}
      fi
      printf '%s' "$v"
      return
    fi
  done < "$CONF_FILE"
}
load_conf() {
  [ -e "$CONF_FILE" ] || return 0
  local k v
  for k in LISTEN UPSTREAM IDLE QUEUE POLL_ONLY VERBOSE ARGS BIN_URL; do
    v=$(conf_val "$k")
    [ -n "$v" ] && printf -v "$k" '%s' "$v"
  done
}

is_installed() { is_exec "$BIN_DST"; }
is_running() {
  if has_systemd && [ -e "$UNIT_FILE" ]; then ok_run systemctl is-active --quiet "$NAME"; return; fi
  if [ -e "$PID_FILE" ]; then ok_run kill -0 "$(cat "$PID_FILE")"; return; fi
  return 1
}

# ────────────────────────── puerto 53 / firewall ──────────────────────────
free_port_53() {
  [ "$(port_of)" = 53 ] || return 0
  port_busy 53 || return 0
  if has_systemd && ok_run systemctl is-active --quiet systemd-resolved; then
    note "Puerto 53 ocupado por systemd-resolved, desactivando su stub listener..."
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > "$RESOLVED_DROPIN"
    systemctl restart systemd-resolved
    if [ -L /etc/resolv.conf ] && [ "$(readlink -f /etc/resolv.conf)" = "/run/systemd/resolve/stub-resolv.conf" ]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
    sleep 1
  fi
  if port_busy 53; then
    bad "El puerto 53/udp sigue ocupado:"
    ss -lunp "sport = :53" >&2 || true
    exit 1
  fi
}
fw_kind() {
  if cmd_exists ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then printf 'ufw'; return; fi
  if cmd_exists firewall-cmd && ok_run firewall-cmd --state; then printf 'firewalld'; return; fi
  if cmd_exists iptables; then printf 'iptables'; return; fi
  printf 'ninguno'
}
fw_has_rule() {
  local port=$1 k; k=$(fw_kind)
  case $k in
    ufw)       ufw status 2>/dev/null | grep -Eq "^${port}/udp[[:space:]]+ALLOW" ;;
    firewalld) firewall-cmd --list-ports 2>/dev/null | grep -qw "${port}/udp" ;;
    iptables)  ok_run iptables -C INPUT -p udp --dport "$port" -j ACCEPT ;;
    *)         return 1 ;;
  esac
}
open_firewall() {
  local port k; port=$(port_of); k=$(fw_kind)
  if [ "$k" = ufw ]; then ufw allow "$port/udp" >/dev/null; ok "ufw: $port/udp abierto"
  elif [ "$k" = firewalld ]; then
    firewall-cmd --permanent --add-port="$port/udp" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld: $port/udp abierto"
  elif [ "$k" = iptables ]; then
    if ! ok_run iptables -C INPUT -p udp --dport "$port" -j ACCEPT; then
      ok_run iptables -I INPUT -p udp --dport "$port" -j ACCEPT
      ok "iptables: $port/udp abierto (no persistente)"
    fi
  fi
}
close_firewall() {
  local port k; port=$(port_of); k=$(fw_kind)
  if [ "$k" = ufw ]; then ok_run ufw delete allow "$port/udp"
  elif [ "$k" = firewalld ]; then
    ok_run firewall-cmd --permanent --remove-port="$port/udp"
    ok_run firewall-cmd --reload
  elif [ "$k" = iptables ]; then ok_run iptables -D INPUT -p udp --dport "$port" -j ACCEPT
  fi
}

# ────────────────────────── systemd unit / servicio ──────────────────────────
write_unit() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=FastDNS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$CONF_FILE
ExecStart=$BIN_DST \$ARGS
Restart=always
RestartSec=2
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
svc_stop() {
  if has_systemd && [ -e "$UNIT_FILE" ]; then ok_run systemctl stop "$NAME"; return; fi
  if [ -e "$PID_FILE" ]; then ok_run kill "$(cat "$PID_FILE")"; rm -f "$PID_FILE"; fi
}
svc_start() {
  load_conf
  if has_systemd && [ -e "$UNIT_FILE" ]; then
    ok_run systemctl enable "$NAME"
    systemctl restart "$NAME"
    return
  fi
  svc_stop; build_args
  nohup setsid "$BIN_DST" $ARGS >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
}
svc_status() {
  if has_systemd && [ -e "$UNIT_FILE" ]; then systemctl --no-pager -n 12 status "$NAME" || true; return; fi
  if is_running; then ok "Corriendo (PID $(trim "$(cat "$PID_FILE" 2>/dev/null)"))"
  else bad "Detenido"; fi
}
svc_logs() {
  if has_systemd && [ -e "$UNIT_FILE" ]; then journalctl -u "$NAME" -f --no-pager -n 50
  else tail -n 50 -f "$LOG_FILE"; fi
}
svc_logs_last() {
  if has_systemd && [ -e "$UNIT_FILE" ]; then journalctl -u "$NAME" --no-pager -n 80
  elif [ -e "$LOG_FILE" ]; then tail -n 80 "$LOG_FILE"
  else warn "Sin logs todavía"; fi
}

# ────────────────────────── descarga del binario ──────────────────────────
fetch_bin() {
  local tmp got=0
  tmp=$(mktemp /tmp/fastdns-bin.XXXXXX)
  if [ -z "$tmp" ]; then bad "No pude crear archivo temporal"; return 1; fi
  note "Descargando binario..."; note "$BIN_URL"
  if cmd_exists curl; then
    ok_run curl -fSL --progress-bar --retry 3 --connect-timeout 15 -o "$tmp" "$BIN_URL" && got=1
  elif cmd_exists wget; then
    ok_run wget -q -O "$tmp" "$BIN_URL" && got=1
  else
    rm -f "$tmp"; bad "Necesitas curl o wget para descargar"; return 1
  fi
  if [ "$got" != 1 ]; then rm -f "$tmp"; bad "No se pudo descargar el binario"; return 1; fi
  local m; m=$(elf_machine "$tmp")
  if [ "$m" = -2 ] || [ "$m" = -1 ]; then rm -f "$tmp"; bad "Lo descargado no es un binario ELF, ¿el link es raw?"; return 1; fi
  if ! elf_arch_ok "$tmp"; then rm -f "$tmp"; bad "El binario descargado no es $ARCH, revisa la URL (--url)"; return 1; fi
  if [ -n "$BIN_SHA256" ]; then
    if ! printf '%s  %s\n' "$BIN_SHA256" "$tmp" | sha256sum -c --quiet >/dev/null 2>&1; then
      rm -f "$tmp"; bad "El SHA256 no coincide, descarga descartada"; return 1
    fi
    ok "SHA256 verificado"
  fi
  chmod 755 "$tmp"
  DL_TMP=$tmp; BIN_SRC=$tmp; ok "Binario descargado"
  return 0
}

install_cmd() {
  if [ "$(readlink -f "$(self_path)")" != "$(readlink -f "$CMD_DST")" ]; then
    install -m 755 "$(self_path)" "$CMD_DST"
  fi
  ok "Comando instalado: abre el menú con  sudo fastdns"
}

# ────────────────────────── OpenVPN ──────────────────────────
pkg_mgr() {
  local m
  for m in apt-get dnf yum pacman zypper; do
    if cmd_exists "$m"; then printf '%s' "$m"; return; fi
  done
}
easyrsa_bin() {
  local p g
  if cmd_exists easyrsa; then command -v easyrsa; return; fi
  for p in /usr/share/easy-rsa/easyrsa /usr/share/easy-rsa/3/easyrsa; do
    if is_exec "$p"; then printf '%s' "$p"; return; fi
  done
  g=$(ls -1 /usr/share/easy-rsa/3.*/easyrsa 2>/dev/null | head -1)
  if [ -n "$g" ] && is_exec "$g"; then printf '%s' "$g"; return; fi
}
pkg_install_openvpn() {
  if cmd_exists openvpn && [ -n "$(easyrsa_bin)" ]; then ok "openvpn y easy-rsa ya están instalados"; return 0; fi
  local m; m=$(pkg_mgr); note "Instalando openvpn y easy-rsa ($m)..."
  if [ "$m" = apt-get ]; then
    ok_run env DEBIAN_FRONTEND=noninteractive apt-get update -y
    ok_run env DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn easy-rsa iptables
  elif [ "$m" = dnf ]; then
    ok_run dnf install -y epel-release; ok_run dnf install -y openvpn easy-rsa iptables
  elif [ "$m" = yum ]; then
    ok_run yum install -y epel-release; ok_run yum install -y openvpn easy-rsa iptables
  elif [ "$m" = pacman ]; then
    ok_run pacman -Sy --noconfirm openvpn easy-rsa iptables
  elif [ "$m" = zypper ]; then
    ok_run zypper --non-interactive install openvpn easy-rsa iptables
  else
    bad "No reconozco el gestor de paquetes; instala openvpn y easy-rsa a mano"; return 1
  fi
  if ! cmd_exists openvpn; then bad "No se pudo instalar openvpn"; return 1; fi
  if [ -z "$(easyrsa_bin)" ]; then bad "No se pudo instalar easy-rsa"; return 1; fi
  ok "openvpn y easy-rsa instalados"; return 0
}
gen_ta_key() {
  ok_run openvpn --genkey secret "$PKI_DIR/ta.key" \
  || ok_run openvpn --genkey --secret "$PKI_DIR/ta.key" \
  || ok_run openvpn --genkey tls-crypt "$PKI_DIR/ta.key"
}
gen_pki() {
  if [ -e "$PKI_DIR/ca.crt" ] && [ "$REGEN_PKI" != 1 ]; then
    note "PKI ya existe en $PKI_DIR (usa --regen-pki para rehacerlo)"; return 0
  fi
  local era; era=$(easyrsa_bin)
  if [ -z "$era" ]; then bad "No encuentro easyrsa"; return 1; fi
  note "Generando PKI con easy-rsa..."
  rm -rf "$EASYRSA_DIR"; mkdir -p "$EASYRSA_DIR"
  cp -a "$(dirname "$era")"/. "$EASYRSA_DIR"/ 2>/dev/null || true
  if ! is_exec "$EASYRSA_DIR/easyrsa"; then install -m 755 "$era" "$EASYRSA_DIR/easyrsa"; fi
  if ! ( cd "$EASYRSA_DIR" && export EASYRSA_BATCH=1 EASYRSA_REQ_CN=FastDNS-CA && \
         ./easyrsa init-pki && ./easyrsa build-ca nopass && \
         ./easyrsa build-server-full server nopass && ./easyrsa build-client-full client nopass ) >/dev/null 2>&1; then
    bad "Falló easy-rsa al generar certificados"; return 1
  fi
  mkdir -p "$PKI_DIR"
  install -m 644 "$EASYRSA_DIR/pki/ca.crt" "$PKI_DIR/ca.crt"
  install -m 644 "$EASYRSA_DIR/pki/issued/server.crt" "$PKI_DIR/server.crt"
  install -m 600 "$EASYRSA_DIR/pki/private/server.key" "$PKI_DIR/server.key"
  install -m 644 "$EASYRSA_DIR/pki/issued/client.crt" "$PKI_DIR/client.crt"
  install -m 600 "$EASYRSA_DIR/pki/private/client.key" "$PKI_DIR/client.key"
  if ! gen_ta_key; then bad "No se pudo generar ta.key"; return 1; fi
  chmod 600 "$PKI_DIR/ta.key"
  ok "PKI generado en $PKI_DIR"; return 0
}
write_ovpn_server_conf() {
  mkdir -p /etc/openvpn/server
  cat > "$OVPN_SERVER_CONF" <<EOF
local 127.0.0.1
port $OVPN_PORT
proto udp
dev tun
topology subnet
server $OVPN_NET

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
tun-mtu 1300
mssfix 1000
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA512
compress lz4-v2
push "compress lz4-v2"
keepalive 10 120
explicit-exit-notify 1
dh none

ca $PKI_DIR/ca.crt
cert $PKI_DIR/server.crt
key $PKI_DIR/server.key
tls-crypt $PKI_DIR/ta.key

persist-key
persist-tun
status /var/log/ovpn-status-$OVPN_INSTANCE.log
verb 3
EOF
  chmod 640 "$OVPN_SERVER_CONF"
  ok "Config OpenVPN escrita en $OVPN_SERVER_CONF"
}
enable_ip_forward() {
  ok_run sysctl -w net.ipv4.ip_forward=1
  if [ -e /etc/sysctl.d ]; then printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-fastdns.conf; fi
}
ovpn_nat_rule() { # $1 = add | del
  local net wan
  net="${OVPN_NET%% *}/24"
  wan=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
  if [ -z "$wan" ] || ! cmd_exists iptables; then return 0; fi
  if [ "$1" = add ]; then
    if ! ok_run iptables -t nat -C POSTROUTING -s "$net" -o "$wan" -j MASQUERADE; then
      ok_run iptables -t nat -A POSTROUTING -s "$net" -o "$wan" -j MASQUERADE
    fi
  else
    ok_run iptables -t nat -D POSTROUTING -s "$net" -o "$wan" -j MASQUERADE
  fi
}
public_ip() {
  if [ -n "$PUBLIC_IP" ]; then printf '%s' "$PUBLIC_IP"; return; fi
  local u ip
  if cmd_exists curl; then
    for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
      ip=$(trim "$(curl -fsS --max-time 8 "$u" 2>/dev/null)")
      if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf '%s' "$ip"; return; fi
    done
  fi
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [ -n "$ip" ]; then printf '%s' "$ip"; return; fi
  ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}'
}
pem_only() { awk '/-----BEGIN/{p=1} p{print} /-----END/{p=0}' "$1" 2>/dev/null; }
gen_client_ovpn() {
  local pub f
  pub=$(public_ip)
  if [ -z "$pub" ]; then warn "No pude detectar la IP pública; usa --public-ip IP o edita el .ovpn"; pub="TU_IP_PUBLICA_VPS"; fi
  for f in ca.crt client.crt client.key ta.key; do
    if [ ! -e "$PKI_DIR/$f" ]; then bad "Falta $PKI_DIR/$f, genera el PKI primero"; return 1; fi
  done
  {
    cat <<EOF
client
dev tun
proto udp
remote 127.0.0.1 8080
nobind
persist-key
persist-tun
remote-cert-tls server
tun-mtu 1300
mssfix 1000
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA512
compress lz4-v2
route $pub 255.255.255.255 net_gateway
verb 3

EOF
    printf '<ca>\n';        pem_only "$PKI_DIR/ca.crt";     printf '</ca>\n\n'
    printf '<cert>\n';      pem_only "$PKI_DIR/client.crt"; printf '</cert>\n\n'
    printf '<key>\n';       pem_only "$PKI_DIR/client.key"; printf '</key>\n\n'
    printf '<tls-crypt>\n'; pem_only "$PKI_DIR/ta.key";     printf '</tls-crypt>\n'
  } > "$CLIENT_OVPN"
  chmod 600 "$CLIENT_OVPN"
  ok "Cliente en $CLIENT_OVPN (remote 127.0.0.1:8080 = proxy FastDNS local; route $pub saca el DNS-tunnel del túnel)"
  return 0
}
ovpn_start() {
  if has_systemd; then ok_run systemctl enable "$OVPN_UNIT"; systemctl restart "$OVPN_UNIT"
  else warn "Sin systemd: arranca OpenVPN con  openvpn --config $OVPN_SERVER_CONF"; fi
}
ovpn_stop() {
  if has_systemd; then ok_run systemctl stop "$OVPN_UNIT"
  else ok_run pkill -f "[o]penvpn.*$OVPN_INSTANCE"; fi  # [o] evita automatcheo
}
ovpn_running() {
  if has_systemd; then ok_run systemctl is-active --quiet "$OVPN_UNIT"; return; fi
  ok_run pgrep -f "[o]penvpn.*$OVPN_INSTANCE"  # [o] evita automatcheo
}
setup_openvpn() {
  note "Preparando upstream OpenVPN..."
  pkg_install_openvpn || return 1
  mkdir -p "$PKI_DIR"
  gen_pki || return 1
  write_ovpn_server_conf; enable_ip_forward; ovpn_nat_rule add; ovpn_start; sleep 1
  if ovpn_running; then ok "OpenVPN ($OVPN_UNIT) activo en 127.0.0.1:$OVPN_PORT"
  else bad "OpenVPN no arrancó. Revisa:  journalctl -u $OVPN_UNIT -n 50"; return 1; fi
  gen_client_ovpn
  return 0
}
remove_openvpn() {
  ovpn_stop
  if has_systemd; then ok_run systemctl disable "$OVPN_UNIT"; fi
  ovpn_nat_rule del
  rm -f "$OVPN_SERVER_CONF" /etc/sysctl.d/99-fastdns.conf
  rm -f "/var/log/ovpn-status-$OVPN_INSTANCE.log"
  rm -rf "$PKI_DIR" "$EASYRSA_DIR"
  rm -f "$CLIENT_OVPN"
  ok "OpenVPN eliminado"
}

# ────────────────────────── install / uninstall ──────────────────────────
do_install() {
  need_root
  if [ "$(uname -s)" != Linux ]; then bad "Solo Linux"; exit 1; fi
  if [ -z "$ARCH" ]; then bad "Arquitectura $(uname_m) no soportada (solo amd64 o arm64)"; exit 1; fi
  note "Arquitectura: $ARCH"

  if [ -n "$BIN_URL" ]; then
    if ! fetch_bin; then
      if [ -e "$BIN_SRC" ]; then warn "Falló la descarga, uso el binario local"
      elif [ -e "$BIN_DST" ]; then warn "Falló la descarga, uso el binario ya instalado"; BIN_SRC=$BIN_DST
      else bad "Falló la descarga y no hay binario local"; exit 1; fi
    fi
  elif [ ! -e "$BIN_SRC" ] && [ -e "$BIN_DST" ]; then BIN_SRC=$BIN_DST; fi

  if [ ! -e "$BIN_SRC" ]; then bad "No encuentro el binario en $BIN_SRC (usa --bin RUTA)"; exit 1; fi
  if ! elf_arch_ok "$BIN_SRC"; then bad "El binario $BIN_SRC no es $ARCH; usa --bin con el de tu arquitectura"; exit 1; fi
  if ! cmd_exists ss; then bad "Falta el comando ss (paquete iproute2 / iproute)"; exit 1; fi

  note "Deteniendo instancia previa..."; svc_stop; free_port_53

  note "Instalando binario en $BIN_DST"
  if [ "$(readlink -f "$BIN_SRC")" != "$(readlink -f "$BIN_DST")" ]; then
    install -m 755 "$BIN_SRC" "$BIN_DST"
  fi
  if [ -n "$DL_TMP" ]; then rm -f "$DL_TMP"; fi
  install_cmd; save_conf; touch "$LOG_FILE"; ok "Config guardada en $CONF_FILE"

  if has_systemd; then write_unit; ok "Servicio systemd creado"
  else warn "Sin systemd: se usará nohup + pidfile"; fi

  if [ "$WITH_OPENVPN" = 1 ]; then
    setup_openvpn || warn "El upstream OpenVPN no quedó listo; FastDNS arranca igual pero no tendrá a quién relevar"
  else
    note "OpenVPN omitido (--no-openvpn); se asume un upstream en $UPSTREAM"
  fi

  open_firewall; note "Arrancando..."; svc_start; sleep 1
  if is_running; then
    ok "FastDNS corriendo: $ARGS"
    if [ "$WITH_OPENVPN" = 1 ] && [ -e "$CLIENT_OVPN" ]; then note "Perfil cliente listo en:  $CLIENT_OVPN"; fi
    note "Abre el menú cuando quieras con:  sudo fastdns"
  else
    bad "No arrancó. Revisa los logs."; exit 1
  fi
}
do_uninstall() {
  need_root; load_conf; svc_stop
  if has_systemd; then
    ok_run systemctl disable "$NAME"; rm -f "$UNIT_FILE"; systemctl daemon-reload
  fi
  close_firewall
  if [ -e "$RESOLVED_DROPIN" ]; then
    rm -f "$RESOLVED_DROPIN"
    if has_systemd; then ok_run systemctl restart systemd-resolved; fi
    if [ -e /run/systemd/resolve/stub-resolv.conf ]; then ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; fi
  fi
  rm -f "$BIN_DST" "$PID_FILE" "$CMD_DST"
  rm -rf "$CONF_DIR"
  if [ "$WITH_OPENVPN" = 1 ]; then remove_openvpn; fi
  ok "Desinstalado"
}

# ────────────────────────── diagnóstico ──────────────────────────
yn()  { "$@" >/dev/null 2>&1 && echo 1 || echo 0; }
chk() { # $1 = 1 bien / 0 mal, $2 = mensaje, $3 = pista
  if [ "$1" = 1 ]; then ok "$2"
  else
    bad "$2"
    if [ -n "${3:-}" ]; then printf '      %s↳ %s%s\n' "$C_MUT" "$3" "$C_RST"; fi
  fi
}
do_diag() {
  load_conf
  local port uhost uport
  port=$(port_of)
  uhost=${UPSTREAM%:*}
  uport=${UPSTREAM##*:}

  chk "$(yn is_root)" "Corriendo como root" "Ejecuta con sudo"
  chk "$(yn [ -n "$ARCH" ])" "Arquitectura compatible ($(uname_m)${ARCH:+ → $ARCH})" "Solo amd64 o arm64"
  chk "$(yn cmd_exists ss)" "Comando ss disponible" "Instala iproute2"
  if [ -e "$BIN_SRC" ]; then chk 1 "Binario original junto al script"; else warn "Binario original no está junto al script"; fi
  chk "$(yn is_installed)" "Binario instalado en $BIN_DST" "Usa la opción 1"
  chk "$(yn [ -e "$CONF_FILE" ])" "Config presente" "Usa la opción 1"
  if has_systemd; then chk "$(yn [ -e "$UNIT_FILE" ])" "Servicio systemd creado" "Usa la opción 1"; fi
  chk "$(yn is_running)" "Servicio corriendo" "Usa la opción 2"
  chk "$(yn port_busy "$port")" "Puerto $port/udp escuchando" "Revisa logs con la opción 10"

  if [ "$port" = 53 ] && ! is_running && ss -H -lun "sport = :53" 2>/dev/null | grep -q 127.0.0.53; then
    chk 0 "systemd-resolved ocupa el puerto 53" "Reinstala con la opción 1 para liberar el puerto"
  fi

  if [ "$uhost" = 127.0.0.1 ] || [ "$uhost" = localhost ] || [ "$uhost" = 0.0.0.0 ] || [ -z "$uhost" ]; then
    chk "$(yn port_busy "$uport")" "Upstream local escuchando en $uport/udp" "Levanta el servicio upstream (OpenVPN UDP)"
  else
    warn "Upstream remoto ($uhost), no se puede verificar desde aquí"
  fi

  chk "$(yn fw_has_rule "$port")" "Firewall ($(fw_kind)) permite $port/udp" "Reinstala o abre el puerto a mano"

  if [ -e "$OVPN_SERVER_CONF" ] || ovpn_running; then
    chk "$(yn cmd_exists openvpn)" "OpenVPN instalado" "Reinstala con la opción 1"
    chk "$(yn [ -e "$OVPN_SERVER_CONF" ])" "Config OpenVPN presente" "Reinstala con la opción 1"
    local pki=1 f
    for f in ca.crt server.crt server.key client.crt client.key ta.key; do
      if [ ! -e "$PKI_DIR/$f" ]; then pki=0; break; fi
    done
    if [ "$pki" = 1 ]; then chk 1 "PKI completo en $PKI_DIR"; else chk 0 "PKI incompleto" "Usa --regen-pki"; fi
    chk "$(yn ovpn_running)" "OpenVPN ($OVPN_UNIT) activo" "journalctl -u $OVPN_UNIT -n 50"
    chk "$(yn [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1 ])" "ip_forward activado" "sysctl -w net.ipv4.ip_forward=1"
    if [ -e "$CLIENT_OVPN" ]; then chk 1 "Perfil cliente en $CLIENT_OVPN"; else warn "Sin perfil cliente (regénralo en el menú)"; fi
  else
    warn "OpenVPN no desplegado por este script (upstream externo o --no-openvpn)"
  fi

  if has_systemd && [ -e "$UNIT_FILE" ]; then
    local n
    n=$(trim "$(journalctl -u "$NAME" -n 100 --no-pager 2>/dev/null | grep -ciE 'error|panic|fatal' || true)")
    if [ -n "$n" ] && [ "$n" != 0 ]; then warn "Hay $n líneas con error/panic/fatal en los últimos 100 logs"
    else chk 1 "Sin errores recientes en los logs"; fi
  fi
}

# ────────────────────────── UI menú ──────────────────────────
rdline() {
  printf '  %s❯%s %s' "$C_ACC" "$C_RST" "$1"
  RL_R=""
  IFS= read -r RL_R || RL_R=""
}
ask() { # $1 = etiqueta, $2 = default → resultado en ASK_R
  printf '  %s❯%s %s %s[%s]%s: ' "$C_ACC" "$C_RST" "$1" "$C_MUT" "$2" "$C_RST"
  local v
  if ! IFS= read -r v; then ASK_R=$2; return; fi
  ASK_R=${v:-$2}
}
ask_yn() {
  local def=$1 label=$2 d v
  if [ "$def" = 1 ]; then d=s; else d=n; fi
  printf '  %s❯%s %s (s/n) %s[%s]%s: ' "$C_ACC" "$C_RST" "$label" "$C_MUT" "$d" "$C_RST"
  if ! IFS= read -r v; then v=$d; fi
  v=${v:-$d}
  [ "$v" = s ] || [ "$v" = S ] || [ "$v" = y ] || [ "$v" = Y ] || [ "$v" = 1 ]
}
confirm() {
  local v
  printf '  %s❯%s %s (s/n) %s[n]%s: ' "$C_WARN" "$C_RST" "$1" "$C_MUT" "$C_RST"
  IFS= read -r v || return 1
  [ "$v" = s ] || [ "$v" = S ] || [ "$v" = y ] || [ "$v" = Y ]
}
pause_menu() {
  printf '\n  %s⏎  Enter para volver al menú%s' "$C_MUT" "$C_RST"
  local _; IFS= read -r _
}

# ── dibujo de cajas (dos columnas) ──
BOXW=60            # runas entre esquinas
COL=28; GAP=2      # 28 + 2 + 28 = 58 (contenido)
runelen() { # cuenta caracteres UTF-8 sin depender del locale
  local LC_ALL=C s=$1 t
  t=${s//[$'\200'-$'\277']/}
  echo "${#t}"
}
spaces() { if [ "$1" -gt 0 ]; then printf '%*s' "$1" ''; fi; }
hline()  { local s; if [ "$1" -gt 0 ]; then printf -v s '%*s' "$1" ''; printf '%s' "${s// /─}"; fi; }
box_top() {
  local t=$1 used
  if [ -z "$t" ]; then printf '  %s╭%s%s╮%s\n' "$BC" "$(hline "$BOXW")" "$BC" "$C_RST"; return; fi
  used=$((5 + $(runelen "$t")))
  printf '  %s╭─┤ %s%s %s%s├%s%s╮%s\n' "$BC" "$C_BLD" "$t" "$C_RST" "$BC" "$(hline $((BOXW - used)))" "$BC" "$C_RST"
}
box_mid() { printf '  %s├%s┤%s\n' "$BC" "$(hline "$BOXW")" "$C_RST"; }
box_bot() { printf '  %s╰%s╯%s\n' "$BC" "$(hline "$BOXW")" "$C_RST"; }
# fila de dos columnas
row2() { # lp lc rp rc
  local pl pr
  pl=$((COL - $(runelen "$1"))); pr=$((COL - $(runelen "$3")))
  [ "$pl" -lt 0 ] && pl=0; [ "$pr" -lt 0 ] && pr=0
  printf '  %s│%s %s%s%s%s%s %s│%s\n' "$BC" "$C_RST" "$2" "$(spaces "$pl")" "$(spaces "$GAP")" "$4" "$(spaces "$pr")" "$BC" "$C_RST"
}
padp() { local p=$(( $2 - $(runelen "$1") )); printf '%s' "$1"; spaces "$p"; }
trunc() { # recorte por runas
  local LC_ALL=C s=$1 w=$2 o="" n=0 i=0 len c step
  if [ "$(runelen "$s")" -le "$w" ]; then printf '%s' "$s"; return; fi
  len=${#s}
  while [ "$i" -lt "$len" ] && [ "$n" -lt "$w" ]; do
    printf -v c '%d' "'${s:i:1}"
    if [ "$c" -lt 128 ]; then step=1
    elif [ "$c" -ge 192 ] && [ "$c" -lt 224 ]; then step=2
    elif [ "$c" -ge 224 ] && [ "$c" -lt 240 ]; then step=3
    else step=4; fi
    o+=${s:i:step}; i=$((i + step)); n=$((n + 1))
  done
  printf '%s' "$o"
}

# celdas: cada constructor deja el texto plano en CP y el coloreado en CC
cell_kv() { # k v col
  local vv; vv=$(trunc "$2" $((COL - 10)))
  CP="$(padp "$1" 9) $vv"
  CC="${C_MUT}$(padp "$1" 9)${C_RST} ${3}${vv}${C_RST}"
}
cell_badge() { # lab bg
  local b=" $1 "
  CP=$b; CC="${2}${b}${C_RST}"
}
cell_hdr() { CP="◆ $1"; CC="${C_ACC}◆ ${C_RST}${C_BLD}${C_ACC}${1}${C_RST}"; }
cell_item() { # n t
  local nn badge tt
  nn="$(spaces $((2 - $(runelen "$1"))))$1"   # "10" o " 1"
  badge=" $nn "                               # ancho fijo 4
  tt=$(trunc "$2" $((COL - 6)))
  CP="$badge $tt"; CC="${BG_NUM}${badge}${C_RST} ${C_TXT}${tt}${C_RST}"
}
cell_empty() { CP=""; CC=""; }
addL() { Lp+=("$CP"); Lc+=("$CC"); }
addR() { Rp+=("$CP"); Rc+=("$CC"); }
emit_rows() {
  local n i
  n=${#Lp[@]}; [ "${#Rp[@]}" -gt "$n" ] && n=${#Rp[@]}
  for ((i = 0; i < n; i++)); do
    row2 "${Lp[i]:-}" "${Lc[i]:-}" "${Rp[i]:-}" "${Rc[i]:-}"
  done
}

logo() {
  printf '\n  %s%s   ⚡  F A S T D N S%s   %s·  relay DNS → OpenVPN  ·  manager%s\n\n' "$C_BLD" "$C_ACC" "$C_RST" "$C_MUT" "$C_RST"
}
dashboard() {
  load_conf
  local port; port=$(port_of)
  logo
  box_top "PANEL"
  Lp=(); Lc=(); Rp=(); Rc=()
  # columna izquierda: estado del servicio
  if ! is_installed; then
    cell_badge "○ NO INSTALADO" "$BG_WARN"; addL
    cell_kv "PID" "—" "$C_MUT"; addL; cell_kv "Uptime" "—" "$C_MUT"; addL
    cell_kv "CPU" "—" "$C_MUT"; addL; cell_kv "Memoria" "—" "$C_MUT"; addL
    cell_kv "Puerto" "—" "$C_MUT"; addL
  elif is_running; then
    local pid="" up="—" cpu="0" mem="0"
    if has_systemd && [ -e "$UNIT_FILE" ]; then pid=$(trim "$(systemctl show -p MainPID --value "$NAME" 2>/dev/null)")
    elif [ -e "$PID_FILE" ]; then pid=$(trim "$(cat "$PID_FILE" 2>/dev/null)"); fi
    [ "$pid" = 0 ] && pid=""
    if [ -n "$pid" ]; then
      up=$(trim "$(ps -o etime= -p "$pid" 2>/dev/null)")
      cpu=$(trim "$(ps -o pcpu= -p "$pid" 2>/dev/null)")
      mem=$(trim "$(ps -o rss= -p "$pid" 2>/dev/null)")
    fi
    [[ $mem =~ ^[0-9]+$ ]] || mem=0
    cell_badge "● CORRIENDO" "$BG_OK"; addL
    cell_kv "PID" "${pid:-n/d}" "$C_TXT"; addL
    cell_kv "Uptime" "${up:-n/d}" "$C_TXT"; addL
    cell_kv "CPU" "$cpu%" "$C_TXT"; addL
    cell_kv "Memoria" "$((mem / 1024)) MB" "$C_TXT"; addL
    if port_busy "$port"; then cell_kv "Puerto" "$port/udp" "$C_OK"; else cell_kv "Puerto" "$port libre" "$C_ERR"; fi; addL
  else
    cell_badge "■ DETENIDO" "$BG_ERR"; addL
    cell_kv "PID" "—" "$C_MUT"; addL; cell_kv "Uptime" "—" "$C_MUT"; addL
    cell_kv "CPU" "—" "$C_MUT"; addL; cell_kv "Memoria" "—" "$C_MUT"; addL
    cell_kv "Puerto" "—" "$C_MUT"; addL
  fi
  # columna derecha: configuración
  cell_hdr "CONFIG"; addR
  cell_kv "Escucha" "$LISTEN" "$C_TXT"; addR
  cell_kv "Upstream" "$UPSTREAM" "$C_TXT"; addR
  cell_kv "Idle" "$IDLE" "$C_TXT"; addR
  cell_kv "Cola" "$QUEUE pkts" "$C_TXT"; addR
  local pv vv
  if [ "$POLL_ONLY" = 1 ]; then pv=poll; else pv=push; fi
  if [ "$VERBOSE" = 1 ]; then vv=verb; else vv="—"; fi
  cell_kv "Poll/Verb" "$pv/$vv" "$C_MUT"; addR
  emit_rows
  box_mid
  local boot=0 ipl fwk fwc fwv btv btc
  if has_systemd && [ -e "$UNIT_FILE" ] && ok_run systemctl is-enabled --quiet "$NAME"; then boot=1; fi
  ipl=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}')
  local fwhas=0; fw_has_rule "$port" && fwhas=1
  if [ "$fwhas" = 1 ]; then fwv="$(fw_kind) · ok"; fwc=$C_OK; else fwv="$(fw_kind) · off"; fwc=$C_WARN; fi
  local fw_p fw_c bt_p bt_c ov_p ov_c ip_p ip_c
  cell_kv "Firewall" "$fwv" "$fwc"; fw_p=$CP; fw_c=$CC
  if [ "$boot" = 1 ]; then cell_kv "Arranque" "auto" "$C_OK"; else cell_kv "Arranque" "manual" "$C_WARN"; fi; bt_p=$CP; bt_c=$CC
  if [ -e "$OVPN_SERVER_CONF" ]; then
    if ovpn_running; then cell_kv "OpenVPN" "activo :$OVPN_PORT" "$C_OK"; else cell_kv "OpenVPN" "detenido" "$C_ERR"; fi
  else
    cell_kv "OpenVPN" "no desplegado" "$C_MUT"
  fi; ov_p=$CP; ov_c=$CC
  cell_kv "IP" "${ipl:-n/d}" "$C_TXT"; ip_p=$CP; ip_c=$CC
  row2 "$fw_p" "$fw_c" "$ip_p" "$ip_c"
  row2 "$bt_p" "$bt_c" "$ov_p" "$ov_c"
  box_bot
}
menu_screen() {
  dashboard
  printf '\n'
  box_top "MENÚ"
  Lp=(); Lc=(); Rp=(); Rc=()
  cell_hdr "SERVICIO"; addL
  cell_item 1 "Instalar / reinstalar"; addL; cell_item 2 "Iniciar"; addL
  cell_item 3 "Detener"; addL; cell_item 4 "Reiniciar"; addL
  cell_empty; addL
  cell_hdr "AJUSTES"; addL
  cell_item 5 "Cambiar config"; addL; cell_item 6 "Ver config"; addL; cell_item 7 "Inicio automático"; addL
  cell_hdr "MONITOREO"; addR
  cell_item 8 "Estado detallado"; addR; cell_item 9 "Logs en vivo"; addR
  cell_item 10 "Últimos logs"; addR; cell_item 11 "Diagnóstico"; addR
  cell_empty; addR
  cell_hdr "OPENVPN"; addR
  cell_item 13 "Regenerar client.ovpn"; addR; cell_item 14 "Estado OpenVPN"; addR; cell_item 16 "Ver config OpenVPN"; addR
  emit_rows
  box_mid
  local ap ac bp bc
  cell_item 15 "Ver ruta client.ovpn"; ap=$CP; ac=$CC
  cell_item 12 "Desinstalar"; bp=$CP; bc=$CC
  row2 "$ap" "$ac" "$bp" "$bc"
  cell_item 0 "Salir"; ap=$CP; ac=$CC
  cell_empty; bp=$CP; bc=$CC
  row2 "$ap" "$ac" "$bp" "$bc"
  box_bot
  printf '  %steclea un número y Enter%s\n' "$C_MUT" "$C_RST"
}
title() { printf '\n'; box_top "$1"; box_bot; }

prompt_config() {
  ask "Escuchar en (IP:PUERTO)" "$LISTEN"; LISTEN=$ASK_R
  ask "Upstream UDP (IP:PUERTO)" "$UPSTREAM"; UPSTREAM=$ASK_R
  ask "Timeout de sesión inactiva" "$IDLE"; IDLE=$ASK_R
  ask "Cola de paquetes por sesión" "$QUEUE"; QUEUE=$ASK_R
  if ask_yn "$([ "$POLL_ONLY" = 1 ] && echo 1 || echo 0)" "¿Modo poll-only?"; then POLL_ONLY=1; else POLL_ONLY=0; fi
  if ask_yn "$([ "$VERBOSE" = 1 ] && echo 1 || echo 0)" "¿Verbose (log de cada paquete)?"; then VERBOSE=1; else VERBOSE=0; fi
}
kvline() { printf '    %s%-11s%s %s%s%s\n' "$C_MUT" "$1" "$C_RST" "$C_TXT" "$2" "$C_RST"; }
show_summary() {
  build_args
  printf '\n'; note "Resumen"
  kvline "Escucha" "$LISTEN"; kvline "Upstream" "$UPSTREAM"; kvline "Idle" "$IDLE"; kvline "Cola" "$QUEUE"
  if [ "$POLL_ONLY" = 1 ]; then kvline "Poll-only" "sí"; else kvline "Poll-only" "no"; fi
  if [ "$VERBOSE" = 1 ]; then kvline "Verbose" "sí"; else kvline "Verbose" "no"; fi
  printf '\n'
}

menu_install() {
  title "INSTALAR"; load_conf
  ask "Link raw del binario (Enter = mantener, - = quitar)" "$BIN_URL"; BIN_URL=$ASK_R
  if [ "$BIN_URL" = "-" ]; then BIN_URL=""; fi
  if [ -z "$BIN_URL" ] && [ ! -e "$BIN_SRC" ] && ! is_exec "$BIN_DST"; then
    warn "No encontré el binario junto al script."
    ask "Ruta del binario" "$BIN_SRC"; BIN_SRC=$ASK_R
  fi
  prompt_config; show_summary
  if confirm "¿Instalar con esta configuración?"; then do_install; else note "Cancelado"; fi
}
menu_config() {
  title "CAMBIAR CONFIGURACIÓN"
  if ! is_installed; then bad "Primero instala (opción 1)"; return; fi
  load_conf; prompt_config; show_summary
  if confirm "¿Aplicar y reiniciar?"; then
    save_conf; free_port_53; open_firewall; svc_start; sleep 1
    if is_running; then ok "Config aplicada: $ARGS"; else bad "No levantó con la nueva config, revisa los logs"; fi
  else
    note "Cancelado, no se cambió nada"
  fi
}
menu_show_config() {
  title "ARCHIVO DE CONFIG"
  if [ -e "$CONF_FILE" ]; then note "$CONF_FILE"; printf '\n'; sed 's/^/      /' "$CONF_FILE"
  else bad "Sin config, instala primero"; fi
}
menu_boot() {
  title "INICIO AUTOMÁTICO"
  if ! has_systemd || [ ! -e "$UNIT_FILE" ]; then warn "Solo disponible con systemd y el servicio instalado"; return; fi
  if ok_run systemctl is-enabled --quiet "$NAME"; then ok_run systemctl disable "$NAME"; ok "Inicio automático desactivado"
  else ok_run systemctl enable "$NAME"; ok "Inicio automático activado"; fi
}
menu_ovpn_client() {
  title "REGENERAR CLIENT.OVPN"
  if [ ! -e "$PKI_DIR/client.key" ]; then bad "No hay PKI; instala el stack completo primero (opción 1)"; return; fi
  ask "IP pública para el route (Enter = autodetectar)" "$PUBLIC_IP"; PUBLIC_IP=$ASK_R
  gen_client_ovpn
}
menu_ovpn_status() {
  title "ESTADO OPENVPN"
  if [ ! -e "$OVPN_SERVER_CONF" ]; then warn "OpenVPN no está desplegado por este script"; return; fi
  if has_systemd; then systemctl --no-pager -n 12 status "$OVPN_UNIT" || true
  else
    if ovpn_running; then ok "OpenVPN corriendo"; else bad "OpenVPN detenido"; fi
  fi
}
menu_ovpn_path() {
  title "CLIENT.OVPN"
  if [ -e "$CLIENT_OVPN" ]; then
    note "Perfil cliente: $CLIENT_OVPN"
    note "Descárgalo con, por ejemplo:  scp root@IP:$CLIENT_OVPN ."
  else bad "Aún no hay perfil; genéralo con la opción 13"; fi
}
# ver la config OpenVPN sin ir a la ruta
menu_ovpn_showconf() {
  title "CONFIG OPENVPN"
  if [ -e "$OVPN_SERVER_CONF" ]; then note "Server: $OVPN_SERVER_CONF"; printf '\n'; sed 's/^/      /' "$OVPN_SERVER_CONF"
  else bad "Sin config de servidor (instala con la opción 1)"; fi
  printf '\n'
  if [ -e "$CLIENT_OVPN" ]; then
    note "Cliente: $CLIENT_OVPN  (certificados ocultos)"
    printf '\n'
    # muestra el .ovpn pero colapsa los bloques de certificados para no llenar la pantalla
    awk 'BEGIN{s=0} /<(ca|cert|key|tls-crypt)>/{print "      "$0"  [...]"; s=1; next} /<\/(ca|cert|key|tls-crypt)>/{s=0; next} s==0{print "      "$0}' "$CLIENT_OVPN"
  else warn "Aún no hay perfil cliente (opción 13)"; fi
}

menu_loop() {
  need_root
  local opt
  while true; do
    if [ -t 1 ]; then clear; fi
    menu_screen
    rdline ""; opt=$RL_R
    if   [ "$opt" = 1 ]; then menu_install; pause_menu
    elif [ "$opt" = 2 ]; then title "INICIAR"
      if ! is_installed; then bad "No está instalado"
      else svc_start; sleep 1; if is_running; then ok "Servicio corriendo"; else bad "No arrancó, revisa los logs (opción 10)"; fi; fi
      pause_menu
    elif [ "$opt" = 3 ]; then title "DETENER"
      if ! is_installed; then bad "No está instalado"; else svc_stop; ok "Servicio detenido"; fi
      pause_menu
    elif [ "$opt" = 4 ]; then title "REINICIAR"
      if ! is_installed; then bad "No está instalado"
      else svc_start; sleep 1; if is_running; then ok "Servicio reiniciado"; else bad "No arrancó, revisa los logs (opción 10)"; fi; fi
      pause_menu
    elif [ "$opt" = 5 ]; then menu_config; pause_menu
    elif [ "$opt" = 6 ]; then menu_show_config; pause_menu
    elif [ "$opt" = 7 ]; then menu_boot; pause_menu
    elif [ "$opt" = 8 ]; then title "ESTADO DETALLADO"; if ! is_installed; then bad "No está instalado"; else svc_status; fi; pause_menu
    elif [ "$opt" = 9 ]; then title "LOGS EN VIVO"
      if ! is_installed; then bad "No está instalado"
      else note "Ctrl+C para volver al menú"; sleep 1; trap : INT; svc_logs; trap - INT; fi
    elif [ "$opt" = 10 ]; then title "ÚLTIMOS LOGS"; if ! is_installed; then bad "No está instalado"; else svc_logs_last; fi; pause_menu
    elif [ "$opt" = 11 ]; then title "DIAGNÓSTICO"; do_diag; pause_menu
    elif [ "$opt" = 12 ]; then title "DESINSTALAR"
      if ! is_installed && [ ! -e "$CONF_FILE" ]; then bad "No hay nada que desinstalar"
      elif confirm "¿Seguro que quieres quitar todo (incluido OpenVPN y el PKI)?"; then do_uninstall
      else note "Cancelado"; fi
      pause_menu
    elif [ "$opt" = 13 ]; then menu_ovpn_client; pause_menu
    elif [ "$opt" = 14 ]; then menu_ovpn_status; pause_menu
    elif [ "$opt" = 15 ]; then menu_ovpn_path; pause_menu
    elif [ "$opt" = 16 ]; then menu_ovpn_showconf; pause_menu
    elif [ "$opt" = 0 ] || [ "$opt" = q ] || [ "$opt" = Q ]; then printf '\n'; ok "Nos vemos"; return
    else bad "Opción inválida"; sleep 1; fi
  done
}

# ────────────────────────── usage / main ──────────────────────────
usage() {
  cat <<'EOF'
Uso: fastdns [comando] [opciones]

Sin comando abre el menú interactivo.

Comandos:
  menu        Menú interactivo
  install     Instala binario, config, servicio y stack OpenVPN
  uninstall   Quita todo
  start | stop | restart | status | logs | diag
  config      Muestra la config actual
  ovpn-conf   Muestra la config OpenVPN (server + client)
  self-install  Instala el comando global "fastdns"

Opciones de install:
  --listen DIR:PUERTO   (default :53)
  --upstream DIR:PUERTO (default 127.0.0.1:1194)
  --idle DUR  --queue N  --poll-only  --verbose
  --bin RUTA   --url LINK   --sha256 HASH
  --no-openvpn  --regen-pki  --public-ip IP
EOF
}

setup_globals() {
  ARCH=$(detect_arch)
  BIN_NAME="fastdns-server-linux-${ARCH:-amd64}"
  SCRIPT_DIR=$(trim "$(dirname "$(self_path)")")
  BIN_SRC=$(find_local_bin)
  BIN_URL="$BIN_URL_BASE/$BIN_NAME"
  if [ -n "${FASTDNS_BIN_URL:-}" ]; then BIN_URL=$FASTDNS_BIN_URL; fi
}

main() {
  init_colors; setup_globals

  local cmd=${1:-menu}
  [ $# -gt 0 ] && shift

  if [ "$cmd" = install ]; then
    nx() { # valor de la opción $1
      if [ $# -lt 2 ]; then bad "Falta valor para $1"; exit 1; fi
    }
    while [ $# -gt 0 ]; do
      local a=$1
      case $a in
        --listen)      nx "$@"; LISTEN=$2; shift ;;
        --upstream)    nx "$@"; UPSTREAM=$2; shift ;;
        --idle)        nx "$@"; IDLE=$2; shift ;;
        --queue)       nx "$@"; QUEUE=$2; shift ;;
        --poll-only)   POLL_ONLY=1 ;;
        --verbose)     VERBOSE=1 ;;
        --bin)         nx "$@"; BIN_SRC=$2; shift ;;
        --url)         nx "$@"; BIN_URL=$2; shift ;;
        --sha256)      nx "$@"; BIN_SHA256=$2; shift ;;
        --no-openvpn)  WITH_OPENVPN=0 ;;
        --regen-pki)   REGEN_PKI=1 ;;
        --public-ip)   nx "$@"; PUBLIC_IP=$2; shift ;;
        -h|--help)     usage; return 0 ;;
        *)             bad "Opción desconocida: $a"; usage; return 1 ;;
      esac
      shift
    done
  fi

  case $cmd in
    menu)         menu_loop ;;
    install)      do_install ;;
    uninstall)    do_uninstall ;;
    start)        need_root; svc_start; svc_status ;;
    stop)         need_root; svc_stop; ok "Detenido" ;;
    restart)      need_root; svc_start; svc_status ;;
    status)       svc_status ;;
    logs)         svc_logs ;;
    diag)         do_diag ;;
    config)       load_conf; if [ -e "$CONF_FILE" ]; then cat "$CONF_FILE"; else bad "Sin config, corre install"; fi ;;
    ovpn-conf)    menu_ovpn_showconf ;;
    self-install) need_root; install_cmd ;;
    -h|--help|help) usage ;;
    *)            bad "Comando desconocido: $cmd"; usage; return 1 ;;
  esac
  return 0
}

main "$@"
exit $?
