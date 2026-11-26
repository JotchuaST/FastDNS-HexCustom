#!/usr/bin/env bash
# Instalador mini de FastDNS: baja el manager compilado y lo ejecuta.
set -euo pipefail

REPO="JotchuaDevz/FastDNS-HexCustom"
BASE="https://raw.githubusercontent.com/$REPO/refs/heads/main"
DST="/usr/local/bin/fastdns"

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then exec sudo bash "$0" "$@"; fi
  echo "Necesitas root (sudo)." >&2; exit 1
fi

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Arquitectura $(uname -m) no soportada (solo amd64/arm64)." >&2; exit 1 ;;
esac

URL="$BASE/fastdns-linux-$ARCH"
echo ">> Descargando fastdns ($ARCH)..."
if command -v curl >/dev/null 2>&1; then
  curl -fSL --retry 3 -o "$DST" "$URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$DST" "$URL"
else
  echo "Necesitas curl o wget." >&2; exit 1
fi

if [ "$(head -c4 "$DST" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
  echo "Lo descargado no es un binario (¿URL mal?)." >&2; rm -f "$DST"; exit 1
fi

chmod 755 "$DST"
echo ">> Instalado en $DST"
exec "$DST" install "$@"
