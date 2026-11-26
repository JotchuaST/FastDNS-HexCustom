# ⚡ FastDNS Server — VPS

**🌐 English** · [Español](README.es.md)

> UDP‑over‑DNS relay + OpenVPN in a single command. Auto‑detects **amd64 / arm64**.

Traffic flow:

```
device → local proxy 127.0.0.1:8080 → DNS to VPS:53 (relay) → OpenVPN 127.0.0.1:1194 → internet
```

---

## 🚀 Install

```bash
sudo apt update && sudo apt upgrade -y && sudo apt install -y wget iproute2 && \
wget -O fastdns.sh https://raw.githubusercontent.com/JotchuaDevz/FastDNS-HexCustom/refs/heads/main/fastdns.sh && \
sudo bash fastdns.sh
```

Does everything for you: downloads the binary, installs the service + OpenVPN (PKI, server, NAT) and drops the client profile at `/root/fastdns-client.ovpn`.

## 📲 Get the client

```bash
scp root@YOUR_IP:/root/fastdns-client.ovpn .
```

## 🛠️ Manage

```bash
sudo fastdns
```

Menu: status, logs, diagnostics (option 11), regenerate `client.ovpn`, uninstall.

---

## ⚙️ `install` flags

| Flag | What it does |
|------|--------------|
| `--no-openvpn` | Relay only, no OpenVPN |
| `--regen-pki` | Rebuild the certificates |
| `--public-ip IP` | Set the IP used in the `.ovpn` `route` |
| `--listen` | Listen address/port (default `:53`) |
| `--upstream` | UDP upstream (default `127.0.0.1:1194`) |
| `--bin` | Path to a local binary |
| `--url` | Raw link to the binary |

## 🧩 Commands

```
install   uninstall   start   stop   restart   status   logs   diag   config
```
