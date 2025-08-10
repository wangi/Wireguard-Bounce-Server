# Wireguard-Bounce-Server
Install &amp; configure a Wireguard VPN bounce server / road-warrior server on Ubuntu. The `cloud_installer.sh` script is a comprehensive automation tool for setting up a WireGuard VPN server and multiple clients on an Ubuntu system. 8 client configurations are created. It is intended to be run on a fresh Cloud VPS server:

```bash
wget https://raw.githubusercontent.com/wangi/Wireguard-Bounce-Server/refs/heads/main/cloud_installer.sh
more cloud_installer.sh # read and review the script!
bash cloud_installer.sh interface
```

Where `interface` is the name you want to use for the Wireguard VPN, e.g. `wg0` or `devpn0`.

## Overview of script functionality
### Installation
Updates system packages, upgrades and then installs WireGuard and related tools (wireguard, wireguard-tools, qrencode).
Downloads and extracts [wireguard-vanity-keygen](https://github.com/axllent/wireguard-vanity-keygen) for generating keys with specific prefixes.

### Key generation
Uses `wireguard-vanity-keygen` to generate keys with readable public key prefixes:
* 1 server key with prefix S1/
* 8 client keys with prefixes C2/ to C9/

Validates key formats to catch known bugs in the keygen tool.

### Network configuration
Randomly selects a port (between 50100–65254) not currently in use.
Constructs IPv4 and IPv6 address prefixes based on the port and system identifiers. Given the random port is in the format `AABBB` then the addresses generated are:
* IPv4: `10.AA.BBB.`
* IPv6: `fdRR:RRRA:ABBB::`
* *(`R` = randomly generated using current time and `machine-id`)*

Detects the system's default network interface and its global IP addresses.

### Wireguard server configuration
Creates `/etc/wireguard/<interface>.conf` with:
* Server private key
* IP addresses
* NAT and forwarding rules

Appends peer (client) configurations for each of the 8 clients.

### Wireguard client configuration
Creates individual config files (`C2/<interface>.conf`, ..., `C9/<interface>.conf`) for each client. Includes:
* Client private key
* IP addresses
* DNS settings
* Server public key and endpoint
* Routing rules

The client configuration include additional commented out sections, these can be used to specifically use IPv4 or IPv6 for the `EndPoint`, enable `PersistentKeepalive`, or pick between routing all traffic through VPN (default) or just the VPN subnet.

### Port forwarding
Enables IPv4 and IPv6 forwarding if not already enabled.
Updates `/etc/sysctl.conf` and reloads settings if needed.

### Firewall setup
Configures `ufw` to:
* Deny incoming by default
* Allow outgoing, SSH, DNS, and the selected Wireguard port
* Enable logging and activate the firewall

### Wireguard activation
Enables and starts the Wireguard service using `wg-quick`.

### DNS stub configuration
Sets up a stub DNS listener for the VPN IPs using `systemd-resolved`.

### QR Code generation
Suggests using `qrencode` to generate QR codes for client configs, for easy mobile setup.
