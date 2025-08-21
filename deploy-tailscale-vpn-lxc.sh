#!/usr/bin/env bash
set -e

echo "Proxmox LXC Tailscale + WireGuard VPN Node Deployment Script"

# Prompt user for input variables
read -rp "Path to ProtonVPN WireGuard config file (local, e.g. /root/protonvpn.conf): " VPN_CONF_PATH
if [[ ! -f "$VPN_CONF_PATH" ]]; then
  echo "Error: VPN config file not found at $VPN_CONF_PATH"
  exit 1
fi

read -rp "Enter your Tailscale Auth Key: " TS_AUTH_KEY
read -rp "Enter LAN subnets to advertise (comma-separated, e.g. 192.168.0.0/24,10.0.0.0/24): " SUBNETS

# Set variables for container creation
CTID=100
HOSTNAME="tailscale-vpn-node"
STORAGE="local-lvm"
TEMPLATE="local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst"
MEMORY=512
CPU=1
DISK=4
BRIDGE="vmbr0"
UNPRIVILEGED=1

echo "Creating LXC container $CTID..."

pct create $CTID $TEMPLATE \
  --hostname $HOSTNAME \
  --cores $CPU \
  --memory $MEMORY \
  --rootfs $STORAGE:$DISK \
  --net0 name=eth0,bridge=$BRIDGE,ip=dhcp,firewall=1 \
  --unprivileged $UNPRIVILEGED

CONFIG_FILE="/etc/pve/lxc/${CTID}.conf"
echo "Configuring container for TUN device access..."

echo "lxc.cgroup2.devices.allow = c 10:200 rwm" >> $CONFIG_FILE
echo "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file" >> $CONFIG_FILE
echo "lxc.apparmor.profile = unconfined" >> $CONFIG_FILE
echo "lxc.cap.drop =" >> $CONFIG_FILE

echo "Starting container..."
pct start $CTID
sleep 5

echo "Copying ProtonVPN config into container..."
pct push $CTID "$VPN_CONF_PATH" /etc/wireguard/protonvpn.conf

echo "Generating setup.sh script inside container..."

pct exec $CTID -- bash -c "cat > /root/setup.sh" <<EOF
#!/bin/bash
set -e

VPN_CONF="/etc/wireguard/protonvpn.conf"
TS_AUTH_KEY="${TS_AUTH_KEY}"
SUBNETS="${SUBNETS}"
TAILSCALE_ARGS="--advertise-exit-node --advertise-routes=\$SUBNETS"
VPN_INTERFACE="wg0"
TS_DEV="tailscale0"

echo "Updating system and installing dependencies..."
apt-get update && apt-get install -y curl gnupg lsb-release iptables wireguard

echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

echo "Enabling IP forwarding..."
cat <<EOT >/etc/sysctl.d/90-forwarding.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOT
sysctl -p /etc/sysctl.d/90-forwarding.conf

if [ ! -f "\$VPN_CONF" ]; then
  echo "ERROR: Missing ProtonVPN WireGuard config at \$VPN_CONF"
  exit 1
fi

systemctl enable wg-quick@protonvpn

systemctl enable --now tailscaled

echo "Starting up Tailscale with auth key..."
tailscale up --authkey=\${TS_AUTH_KEY} \${TAILSCALE_ARGS} --accept-routes=true --accept-dns=true

echo "Setting up iptables rules..."

iptables -t nat -F
iptables -F

iptables -t nat -A POSTROUTING -o \$VPN_INTERFACE -j MASQUERADE
iptables -A FORWARD -i \$TS_DEV -o \$VPN_INTERFACE -j ACCEPT
iptables -A FORWARD -i \$VPN_INTERFACE -o \$TS_DEV -j ACCEPT

echo "Creating tailscale-vpn-exit systemd service..."

cat <<SERVICE > /etc/systemd/system/tailscale-vpn-exit.service
[Unit]
Description=Tailscale Exit Node with ProtonVPN backend
After=network-online.target wg-quick@protonvpn.service tailscaled.service
Wants=network-online.target wg-quick@protonvpn.service tailscaled.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStartPre=/usr/bin/tailscale down
ExecStart=/usr/bin/tailscale up --authkey=\${TS_AUTH_KEY} \${TAILSCALE_ARGS} --accept-routes=true --accept-dns=true
ExecStartPost=/usr/sbin/iptables -t nat -F
ExecStartPost=/usr/sbin/iptables -F
ExecStartPost=/usr/sbin/iptables -t nat -A POSTROUTING -o \$VPN_INTERFACE -j MASQUERADE
ExecStartPost=/usr/sbin/iptables -A FORWARD -i \$TS_DEV -o \$VPN_INTERFACE -j ACCEPT
ExecStartPost=/usr/sbin/iptables -A FORWARD -i \$VPN_INTERFACE -o \$TS_DEV -j ACCEPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

echo "Reloading systemd and enabling services..."
systemctl daemon-reload
systemctl enable tailscaled
systemctl enable tailscale-vpn-exit

echo "Setup complete. Reboot the container or start services manually."
EOF

echo "Making setup script executable and running it inside container..."
pct exec $CTID -- chmod +x /root/setup.sh
pct exec $CTID -- /root/setup.sh

echo "Finalizing by starting VPN and tailscale exit services..."
pct exec $CTID -- systemctl start wg-quick@protonvpn
pct exec $CTID -- systemctl start tailscaled
pct exec $CTID -- systemctl start tailscale-vpn-exit

echo "LXC container $CTID created and configured successfully!"
