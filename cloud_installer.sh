#!/bin/bash

# parse arguments
if [ $# -ne 1 ]; then
	cat <<USAGE
Usage:
	$0 wgiface
	e.g.
		$0 wg0
USAGE
	exit 1
fi
wgiface=$1

###
### Part 1 - install
###

# install WireGuard
echo "> installing Wireguard"
sudo apt update -y && sudo apt upgrade -y && sudo apt install wireguard wireguard-tools qrencode -y

# download wireguard-vanity-keygen
if [ ! -d "wgvkg" ]; then
	echo "> installing wireguard-vanity-keygen"
	arch=""
	case $(uname -m) in
		i386)   arch="386" ;;
		i686)   arch="386" ;;
		x86_64) arch="amd64" ;;
		arm)    dpkg --print-architecture | grep -q "arm64" && arch="arm64" || arch="arm" ;;
	esac
	if [ -z "$arch" ]; then
		echo "! cannot determine architecure for wireguard-vanity-keygen download"
		exit 1
	fi
	wgvkgzip="wireguard-vanity-keygen-linux-$arch.tar.gz"
	wget https://github.com/axllent/wireguard-vanity-keygen/releases/download/0.1.1/$wgvkgzip || (echo "! cannot download wireguard-vanity-keygen" && exit 1)
	mkdir wgvkg
	tar zxf $wgvkgzip -C wgvkg
	rm $wgvkgzip
fi
wgvkg="wgvkg/wireguard-vanity-keygen"
if [ ! -x $wgvkg ]; then
	echo "! cannot find wireguard-vanity-keygen after download"
	exit 1
fi

###
### Part 2 - generate Wireguard keys
###

# generate server key
echo "> generate server key"
read -r server_pub server_priv <<< $($wgvkg -c S1/ | awk '/^private/ { print $4, $2 }')
# check matches expectation, e.g: private SLUxHwlBLdNKG5DOB5SLkB/sTsPtLjSVzhA4SyF1iXQ=   public S1/66Viu3Zo455JEdzToDuSky5fvaxpCAxcPZFJSFBs=
if [ "${server_priv:43:1}" != "=" ] || [ "${server_pub:0:3}" != "S1/" ] || [ "${server_pub:43:1}" != "=" ]; then
	echo "! key output unexpected, priv: $server_priv pub: $server_pub"
	echo "! looks like the occasional bug in wireguard-vanity-keygen, re-run the script"
	exit 1
fi

# generate client keys
echo "> generate 8 client keys"
while read -r pub priv; do
	# check matches expectation, e.g: private oP7jDPiY4IBOXZVxXKri+NsgkN2vvHAITAY2KG77Z0o=   public C2/DYlECwuT5EF0nGCYmy1XM1EMJPYge37vsZBzQPTc=
	if [ "${priv:43:1}" != "=" ] || [ "${pub:0:1}" != "C" ] || [ "${pub:2:1}" != "/" ] || [ "${pub:43:1}" != "=" ]; then
		echo "! key output unexpected, priv: $priv pub: $pub"
		echo "! looks like the occasional bug in wireguard-vanity-keygen, re-run the script"
		exit 1
	fi
	i=${pub:1:1}
	client_priv[$i]=$priv
	client_pub[$i]=$pub
done <<< $($wgvkg -c C2/ C3/ C4/ C5/ C6/ C7/ C8/ C9/ | awk '/^private/ { print $4, $2 }' | sort)
if [ "${#client_priv[@]}" -ne 8 ]; then	
	echo "! insufficient keys created"
	exit 1
fi

###
### Part 3 - determine port numbers and IP address ranges
###

# generate random port number, between 50100 and 65254, which we will
# also use in the IP address ranges, ensure it is not in use
while :; do
	ipA=$(($RANDOM%(65-50+1)+50))
	ipB=$(($RANDOM%(254-100+1)+100))
	port="$ipA$ipB"
	if [[ $(ss -tuan | awk '{print $4}' | cut -d':' -f2 | grep $port) ]]; then
		# port in use
		echo "$port is in use, selecting another"
	else
		# port not in use
		break
	fi
done

# create an ip4 prefix to use in the VPN
ip4_prefix="10.$ipA.$ipB."

# create an ip6 prefix to use in the VPN
sha=$(echo `cat /etc/machine-id``date +%s%N` | sha1sum)
ip6_prefix="fd${sha:35:2}:${sha:37:3}${ipA:0:1}:${ipA:1:1}$ipB::"
echo "> using port: $port ip4: $ip4_prefix ip6: $ip6_prefix"

# get default interface
iface=$(ip route show default| awk '{print $5}')

# get the global ipv4 address
ip4=$(ip -4 addr show dev $iface scope global | sed -e's/^.*inet \([^ ]*\)\/.*$/\1/;t;d')

# get the global ipv6 address
ip6=$(ip -6 addr show dev $iface scope global | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d')
echo "> system default network interface: $iface ip4: $ip4 ip6: $ip6"

###
### Part 4 - create server Wireguard config
###

echo -n "> creating Wireguard server config /etc/wireguard/$wgiface.conf"
sudo tee /etc/wireguard/$wgiface.conf >/dev/null <<EOF
[Interface]
PrivateKey = $server_priv
ListenPort = $port 
Address = ${ip4_prefix}1/24, ${ip6_prefix}1/64
PostUp = iptables -A FORWARD -i $wgiface -j ACCEPT; iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE
PostDown = iptables -D FORWARD -i $wgiface -j ACCEPT; iptables -t nat -D POSTROUTING -o $iface -j MASQUERADE

EOF

# append config for each peer
echo -n "; peers:"
for i in {2..9}; do
	echo -n " .$i"
	sudo tee -a /etc/wireguard/$wgiface.conf >/dev/null <<EOF
[Peer] 
PublicKey = ${client_pub[$i]}
AllowedIPs = ${ip4_prefix}$i/32, ${ip6_prefix}$i/128

EOF
done
echo

###
### Part 5 - create client Wireguard configs
###

# determine endpoints
echo "> determine endpoint"
ip4_endpoint=""
ip6_endpoint=""
endpoint=""
if [[ "$ip4" ]]; then
	ip4_endpoint="$ip4:$port"
	endpoint="$ip4:$port"
fi
if [[ "$ip6" ]]; then
	if [ -z "$endpoint" ]; then
		endpoint="[$ip6]:$port"
	fi
	ip6_endpoint="[$ip6]:$port"
fi

# loop and create each client config in sub-directory
for i in {2..9}; do
	dir="C$i"
	cfg="$dir/$wgiface.conf"
	echo "> creating Wireguard client config $cfg"
	if [ ! -d "$dir" ]; then
		mkdir "$dir"
	fi
	cat > "$cfg" <<EOF
[Interface]
PrivateKey = ${client_priv[$i]}
Address = ${ip4_prefix}$i/24, ${ip6_prefix}$i/64
DNS = ${ip4_prefix}1, ${ip6_prefix}1
# alternative DNS setup
#PostUp = resolvectl dns $wgiface ${ip4_prefix}1

[Peer]
PublicKey = $server_pub
EndPoint = $endpoint
#EndPoint = $ip4_endpoint # IPv4
#EndPoint = $ip6_endpoint # IPv6
#PersistentKeepalive = 25 # if behind NAT firewall
AllowedIPs = 0.0.0.0/0, ::/0 # all through VPN
#AllowedIPs = ${ip4_prefix}0/24, ${ip6_prefix}/64 # or just the VPN subnet
EOF
done

###
### Part 6 - enable port forwarding
###

restartsysctl=0

# ipv4 forwarding
if [[ "$ip4" ]]; then
	if [[ $(cat /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
		echo "> configuring ipv4 port forwarding"
		echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.conf >/dev/null
		restartsysctl=1
	fi
fi

# ipv6 forwarding
if [[ "$ip6" ]]; then
	if [[ $(cat /proc/sys/net/ipv6/conf/all/forwarding) -eq 0 ]]; then
		echo "> configuring ipv6 port forwarding"
		echo "net.ipv6.conf.all.forwarding=1" | sudo tee /etc/sysctl.conf >/dev/null
		restartsysctl=1
	fi
fi

# need to restart?
if [[ "$restartsysctl" -eq 1 ]]; then
	sudo sysctl -p /etc/sysctl.conf
fi

###
### Part 7 - configure firewall
###

echo "> configuring firewall"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow domain
sudo ufw allow ${port}/udp
sudo ufw logging on
sudo ufw --force enable

###
### Part 8 - enable & start wireguard
###

# enable service
sudo systemctl enable wg-quick@$wgiface

# start Wireguard service
echo "> starting Wireguard"
sudo systemctl start wg-quick@$wgiface 

###
### Part 9 - configure a stub DNS server
###

echo "> configuring DNS server"
if [ ! -d /etc/systemd/resolved.conf.d ]; then
	sudo mkdir /etc/systemd/resolved.conf.d
fi
sudo tee /etc/systemd/resolved.conf.d/$wgiface.conf >/dev/null <<EOF
[Resolve]
DNSStubListenerExtra=${ip4_prefix}1
DNSStubListenerExtra=${ip6_prefix}1
EOF
sudo systemctl restart systemd-resolved

###
### Part 10 - done
###

echo "> complete; QR code of the client configs can be created on the terminal using:"
for i in {2..9}; do
	echo "qrencode -t ANSIUTF8 < C$i/$wgiface.conf"
done
