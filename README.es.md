# ⚡ FastDNS Server — VPS

[English](README.md) · **🌐 Español**

> Relay UDP‑sobre‑DNS + OpenVPN en un comando. Detecta **amd64 / arm64**.

El flujo del tráfico:

```
dispositivo → proxy local 127.0.0.1:8080 → DNS al VPS:53 (relay) → OpenVPN 127.0.0.1:1194 → internet
```

---

## 🚀 Instalar

```bash
sudo apt update && sudo apt upgrade -y && sudo apt install -y wget iproute2 && \
wget -O fastdns.sh https://raw.githubusercontent.com/JotchuaDevz/FastDNS-HexCustom/refs/heads/main/fastdns.sh && \
sudo bash fastdns.sh
```

Hace todo solo: baja el binario, instala el servicio + OpenVPN (PKI, server, NAT) y deja el perfil del cliente en `/root/fastdns-client.ovpn`.

## 📲 Obtener el cliente

```bash
scp root@TU_IP:/root/fastdns-client.ovpn .
```

## 🛠️ Administrar

```bash
sudo fastdns
```

Menú: estado, logs, diagnóstico (opción 11), regenerar `client.ovpn`, desinstalar.

---

## ⚙️ Flags de `install`

| Flag | Qué hace |
|------|----------|
| `--no-openvpn` | Solo el relay, sin OpenVPN |
| `--regen-pki` | Rehace los certificados |
| `--public-ip IP` | Fija la IP del `route` del `.ovpn` |
| `--listen` | Dirección/puerto de escucha (default `:53`) |
| `--upstream` | Upstream UDP (default `127.0.0.1:1194`) |
| `--bin` | Ruta a un binario local |
| `--url` | Link raw del binario |

## 🧩 Comandos

```
install   uninstall   start   stop   restart   status   logs   diag   config
```
