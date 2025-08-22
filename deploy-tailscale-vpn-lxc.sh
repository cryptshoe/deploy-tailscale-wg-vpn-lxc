#!/usr/bin/env bash
set -euo pipefail

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

echo "Proxmox LXC Tailscale + WireGuard VPN Node Deployment Script"

# Prompt for LXC container ID and hostname
read -rp "Enter desired LXC container ID (number, e.g. 100): " CTID
read -rp "Enter hostname for the LXC container (e.g. tailscale-vpn-node): " HOSTNAME

if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
  msg_error "Container ID must be a number."
  exit 1
fi

if [[ -z "$HOSTNAME" ]]; then
  HOSTNAME="tailscale-vpn-node"
fi

read -rp "Path to VPN WireGuard config file (local, e.g. /root/vpn.conf): " VPN_CONF_PATH
if [[ ! -f "$VPN_CONF_PATH" ]]; then
  msg_error "VPN config file not found at $VPN_CONF_PATH"
  exit 1
fi

read -rp "Enter your Tailscale Auth Key: " TS_AUTH_KEY
read -rp "Enter LAN subnets to advertise (comma-separated, e.g. 192.168.0.0/24,10.0.0.0/24): " SUBNETS

read -rsp "Enter root password for the LXC container: " CT_PASSWORD
echo
read -rsp "Confirm root password: " CT_PASSWORD_CONFIRM
echo
if [ "$CT_PASSWORD" != "$CT_PASSWORD_CONFIRM" ]; then
  echo "Error: Passwords do not match."
  exit 1
fi


STORAGE="local-lvm"
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
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

grep -qxF "lxc.cgroup2.devices.allow = c 10:200 rwm" "$CONFIG_FILE" || echo "lxc.cgroup2.devices.allow = c 10:200 rwm" >> "$CONFIG_FILE"
grep -qxF "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file" "$CONFIG_FILE" || echo "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file" >> "$CONFIG_FILE"
grep -qxF "lxc.apparmor.profile = unconfined" "$CONFIG_FILE" || echo "lxc.apparmor.profile = unconfined" >> "$CONFIG_FILE"
grep -qxF "lxc.cap.drop =" "$CONFIG_FILE" || echo "lxc.cap.drop =" >> "$CONFIG_FILE"

msg_info "Setting DNS servers for container..."
pct set $CTID --nameserver 1.1.1.1

msg_info "Starting container $CTID..."
pct start $CTID
sleep 5

msg_info "Fixing DNS inside container temporarily..."
pct exec $CTID -- bash -c 'cp /etc/resolv.conf /tmp/resolv.conf.backup; echo "nameserver 1.1.1.1" > /etc/resolv.conf'

msg_info "Setting root password..."
pct exec $CTID -- bash -c "echo root:${CT_PASSWORD} | chpasswd"

msg_info "Creating /etc/wireguard directory inside container..."
pct exec $CTID -- mkdir -p /etc/wireguard

msg_info "Copying VPN config into container..."
pct push $CTID "$VPN_CONF_PATH" /etc/wireguard/vpn.conf

msg_info "Changing vpn.conf permissions..."
pct exec $CTID -- bash -c 'chown root:root /etc/wireguard/vpn.conf && chmod 600 /etc/wireguard/vpn.conf'

msg_info "Verifying /etc/wireguard/vpn.conf inside container..."
pct exec $CTID -- ls -l /etc/wireguard/vpn.conf

msg_info "Waiting for VPN config file presence inside container (retry up to 5 times)..."
pct exec $CTID -- bash -c '
for i in {1..5}; do
  if [ -f /etc/wireguard/vpn.conf ]; then
    echo "VPN config found on attempt $i"
    exit 0
  fi
  echo "VPN config not found on attempt $i, retrying..."
  sleep 1
done
echo "ERROR: VPN config file /etc/wireguard/vpn.conf missing after retries"
exit 1
'

SUBNETS=${SUBNETS//\"/}


msg_info "Generating setup.sh inside container..."

pct exec $CTID -- bash -c "cat > /root/setup.sh" <<EOF
#!/bin/bash
set -euo pipefail

VPN_CONF=\"/etc/wireguard/vpn.conf\"
TS_AUTH_KEY=\"${TS_AUTH_KEY}\"
SUBNETS=\"${SUBNETS}\"
VPN_INTERFACE=\"wg0\"
TS_DEV=\"tailscale0\"

echo \"Installing dependencies and locales...\"
apt-get update -qq
apt-get install -y locales curl gnupg lsb-release iptables wireguard resolvconf uuid-runtime

sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo "Restarting networking service before adding Tailscale repo..."
systemctl restart networking

curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" | tee /etc/apt/sources.list.d/tailscale.list

apt-get update -qq
apt-get install -y tailscale

# Enable IP forwarding
cat <<EOT >/etc/sysctl.d/99-tailscale.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOT

sysctl --system

# Disable GRO and GSO on eth0 for better UDP forwarding (optional)
ethtool -K eth0 gro off gso off || true

systemctl enable wg-quick@vpn
systemctl enable --now tailscaled

echo \"Starting Tailscale with auth key...\"
tailscale up --authkey="${TS_AUTH_KEY}" --advertise-exit-node --advertise-routes="${SUBNETS}" --accept-routes=true --accept-dns=true

echo \"Setting up iptables rules...\"
iptables -t nat -F
iptables -F

iptables -t nat -A POSTROUTING -o \$VPN_INTERFACE -j MASQUERADE
iptables -A FORWARD -i \$TS_DEV -o \$VPN_INTERFACE -j ACCEPT
iptables -A FORWARD -i \$VPN_INTERFACE -o \$TS_DEV -j ACCEPT

echo \"Creating tailscale-vpn-exit systemd service...\"

cat <<SERVICE > /etc/systemd/system/tailscale-vpn-exit.service
[Unit]
Description=Tailscale Exit Node with PN backend
After=network-online.target wg-quick@vpn.service tailscaled.service
Wants=network-online.target wg-quick@vpn.service tailscaled.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStartPre=/usr/bin/tailscale down
ExecStart=/usr/bin/tailscale up --authkey="${TS_AUTH_KEY}" --advertise-exit-node --advertise-routes="${SUBNETS}" --accept-routes=true --accept-dns=true
ExecStartPost=/usr/sbin/iptables -t nat -F
ExecStartPost=/usr/sbin/iptables -F
ExecStartPost=/usr/sbin/iptables -t nat -A POSTROUTING -j MASQUERADE
ExecStartPost=/usr/sbin/iptables -A FORWARD -i \$TS_DEV -j ACCEPT
ExecStartPost=/usr/sbin/iptables -A FORWARD -i \$VPN_INTERFACE -j ACCEPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

echo \"Reloading systemd and enabling services...\"
systemctl daemon-reload
systemctl enable tailscaled
systemctl enable tailscale-vpn-exit

echo \"Setup complete.\"
EOF

msg_info "Making setup script executable and running it inside the container..."
pct exec $CTID -- chmod +x /root/setup.sh
pct exec $CTID -- /root/setup.sh

msg_info "Restoring original DNS configuration inside container..."
pct exec $CTID -- bash -c 'if [ -f /tmp/resolv.conf.backup ]; then mv /tmp/resolv.conf.backup /etc/resolv.conf; fi'

msg_info "Starting VPN and Tailscale services..."
pct exec $CTID -- systemctl start wg-quick@vpn
pct exec $CTID -- systemctl start tailscaled
pct exec $CTID -- systemctl start tailscale-vpn-exit

msg_ok "LXC container $CTID ($HOSTNAME) created and configured successfully!"
