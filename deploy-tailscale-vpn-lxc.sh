#!/usr/bin/env bash
set -e

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

echo "Proxmox LXC Tailscale + WireGuard VPN Node Deployment Script"

# Prompt for LXC container ID and hostname
read -rp "Enter desired LXC container ID (number, e.g. 100): " CTID
read -rp "Enter hostname for the LXC container (e.g. tailscale-vpn-node): " HOSTNAME

# Validate container ID is numeric
if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
  msg_error "Container ID must be a number."
  exit 1
fi

# If hostname is empty, fallback to default
if [[ -z "$HOSTNAME" ]]; then
  HOSTNAME="tailscale-vpn-node"
fi

# Prompt user for input variables
read -rp "Path to VPN WireGuard config file (local, e.g. /root/vpn.conf): " VPN_CONF_PATH
if [[ ! -f "$VPN_CONF_PATH" ]]; then
  msg_error "VPN config file not found at $VPN_CONF_PATH"
  exit 1
fi

read -rp "Enter your Tailscale Auth Key: " TS_AUTH_KEY
read -rp "Enter LAN subnets to advertise (comma-separated, e.g. 192.168.0.0/24,10.0.0.0/24): " SUBNETS

# Default variables for container creation
STORAGE="local-lvm"
TEMPLATE="local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst"
MEMORY=512
CPU=1
DISK=4
BRIDGE="vmbr0"
UNPRIVILEGED=1

header_info "Tailscale WireGuard VPN Node"

echo "Creating LXC container $CTID with hostname $HOSTNAME..."

pct create $CTID $TEMPLATE \
  --hostname $HOSTNAME \
  --cores $CPU \
  --memory $MEMORY \
  --rootfs $STORAGE:$DISK \
  --net0 name=eth0,bridge=$BRIDGE,ip=dhcp,firewall=1 \
  --unprivileged $UNPRIVILEGED

CONFIG_FILE="/etc/pve/lxc/${CTID}.conf"
echo "Configuring container $CTID for TUN device access..."

echo "lxc.cgroup2.devices.allow = c 10:200 rwm" >> $CONFIG_FILE
echo "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file" >> $CONFIG_FILE
echo "lxc.apparmor.profile = unconfined" >> $CONFIG_FILE
echo "lxc.cap.drop =" >> $CONFIG_FILE

msg_info "Starting container $CTID..."
pct start $CTID
sleep 5

msg_info "Copying VPN config into container..."
pct push $CTID "$VPN_CONF_PATH" /etc/wireguard/vpn.conf

msg_info "Generating setup.sh inside container..."

pct exec $CTID -- bash -c "cat > /root/setup.sh" <<EOF
#!/bin/bash
set -e

VPN_CONF="/etc/wireguard/vpn.conf"
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
  echo "ERROR: Missing VPN WireGuard config at \$VPN_CONF"
  exit 1
fi

systemctl enable wg-quick@vpn

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
Description=Tailscale Exit Node with PN backend
After=network-online.target wg-quick@vpn.service tailscaled.service
Wants=network-online.target wg-quick@vpn.service tailscaled.service

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

msg_info "Making setup script executable and running it inside the container..."
pct exec $CTID -- chmod +x /root/setup.sh
pct exec $CTID -- /root/setup.sh

msg_info "Finalizing by starting VPN and Tailscale exit services..."
pct exec $CTID -- systemctl start wg-quick@vpn
pct exec $CTID -- systemctl start tailscaled
pct exec $CTID -- systemctl start tailscale-vpn-exit

msg_ok "LXC container $CTID ($HOSTNAME) created and configured successfully!"
