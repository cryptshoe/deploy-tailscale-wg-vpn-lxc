#!/usr/bin/env bash
set -euo pipefail
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
echo "Proxmox LXC Tailscale + WireGuard VPN Node Deployment Script"

# Prompt for input as before
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
UNPRIVILEGED=0

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

msg_info "Starting container $CTID..."
pct start $CTID
sleep 5

msg_info "Setting root password..."
pct exec $CTID -- bash -c "echo root:${CT_PASSWORD} | chpasswd"

msg_info "Setting DNS servers for container temporarily..."
pct set $CTID --nameserver 1.1.1.1
pct exec $CTID -- bash -c 'cp /etc/resolv.conf /tmp/resolv.conf.backup; echo "nameserver 1.1.1.1" > /etc/resolv.conf'

msg_info "Enabling SSH root login inside container..."
pct exec $CTID -- bash -c '
  sed -i "s/^#PermitRootLogin prohibit-password/PermitRootLogin yes/" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
  sed -i "s/^PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
  systemctl restart sshd || systemctl restart ssh
'

msg_info "Waiting for container DHCP IP..."
CONTAINER_IP=""
for i in {1..15}; do
  CONTAINER_IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
  if [[ -n "$CONTAINER_IP" ]]; then
    echo "Container IP found: $CONTAINER_IP"
    break
  fi
  echo "Waiting for IP address... retry $i..."
  sleep 3
done
if [[ -z "$CONTAINER_IP" ]]; then
  echo "Error: Could not find container IP."
  exit 1
fi

msg_info "Copying WireGuard VPN config to container..."
pct exec $CTID -- mkdir -p /etc/wireguard
pct push $CTID "$VPN_CONF_PATH" /etc/wireguard/vpn.conf
pct exec $CTID -- bash -c 'chown root:root /etc/wireguard/vpn.conf && chmod 600 /etc/wireguard/vpn.conf'

SUBNETS=${SUBNETS//\"/}

# Create the setup.sh script locally to be SCP'ed into the container
cat > setup.sh <<EOF
#!/bin/bash
set -euo pipefail

VPN_CONF="/etc/wireguard/vpn.conf"
TS_AUTH_KEY="${TS_AUTH_KEY}"
SUBNETS="${SUBNETS}"
VPN_INTERFACE="wg0"
TS_DEV="tailscale0"

echo "Installing dependencies and locales..."
apt-get update -qq
apt-get install -y locales curl gnupg lsb-release iptables wireguard resolvconf openssh-client
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo "Restarting networking service before adding Tailscale repo..."
systemctl restart networking || true

curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" | tee /etc/apt/sources.list.d/tailscale.list

apt-get update -qq
apt-get install -y tailscale

sysctl --system || true

# Disable GRO and GSO on eth0 for better UDP forwarding (optional)
ethtool -K eth0 gro off gso off || true

systemctl enable wg-quick@vpn
systemctl enable --now tailscaled

# Wait up to 30s for tailscaled service to be active
for i in {1..30}; do
  if systemctl is-active --quiet tailscaled; then
    echo "tailscaled is active"
    break
  fi
  echo "Waiting for tailscaled to start..."
  sleep 1
done

if ! systemctl is-active --quiet tailscaled; then
  echo "Error: tailscaled failed to start"
  exit 1
fi

echo "Starting Tailscale with auth key..."
tailscale up --authkey="\${TS_AUTH_KEY}" --advertise-exit-node --advertise-routes="\${SUBNETS}" --accept-routes=true --accept-dns=true

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
ExecStart=/usr/bin/tailscale up --authkey="\${TS_AUTH_KEY}" --advertise-exit-node --advertise-routes="\${SUBNETS}" --accept-routes=true --accept-dns=true
ExecStartPost=/usr/sbin/iptables -t nat -F
ExecStartPost=/usr/sbin/iptables -F
ExecStartPost=/usr/sbin/iptables -t nat -A POSTROUTING -j MASQUERADE
ExecStartPost=/usr/sbin/iptables -A FORWARD -i \$TS_DEV -j ACCEPT
ExecStartPost=/usr/sbin/iptables -A FORWARD -i \$VPN_INTERFACE -j ACCEPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

echo "Reloading systemd and enabling services..."
systemctl daemon-reload
systemctl enable tailscaled
systemctl enable tailscale-vpn-exit

echo "Setup complete."
EOF

chmod +x setup.sh

msg_info "Waiting for SSH accessibility on $CONTAINER_IP..."

max_ssh_attempts=15
ssh_ok=0
for i in $(seq 1 "$max_ssh_attempts"); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$CONTAINER_IP" echo ok &>/dev/null; then
    echo "SSH available on $CONTAINER_IP"
    ssh_ok=1
    break
  fi
  echo "Waiting for SSH to become available... ($i)"
  sleep 3
done

if [ "$ssh_ok" -eq 0 ]; then
  echo "ERROR: SSH still not accessible on $CONTAINER_IP after $max_ssh_attempts attempts."
  echo "Running container diagnostics..."

  echo "--- SSH service status ---"
  pct exec $CTID -- systemctl status ssh || pct exec $CTID -- systemctl status sshd

  echo "--- SSHD listening ports ---"
  pct exec $CTID -- ss -tlnp | grep :22 || echo "No process listening on port 22"

  echo "--- Restarting SSH service ---"
  pct exec $CTID -- systemctl restart ssh || pct exec $CTID -- systemctl restart sshd

  echo "--- Recent auth and syslog entries ---"
  pct exec $CTID -- tail -n 20 /var/log/auth.log || echo "No auth.log found"
  pct exec $CTID -- tail -n 20 /var/log/syslog || echo "No syslog found"

  echo "--- Enable nesting feature (for compatibility) ---"
  pct set $CTID -features nesting=1

  echo "--- Restart container ---"
  pct restart $CTID

  echo "After diagnostics/fixes, please retry SSH manually:"
  echo "ssh -vvv root@$CONTAINER_IP"
  exit 1
fi

msg_info "Copying setup script to container via SCP..."
scp -o StrictHostKeyChecking=no setup.sh root@"$CONTAINER_IP":/root/setup.sh

msg_info "Running setup script inside the container via SSH..."
ssh -o StrictHostKeyChecking=no root@"$CONTAINER_IP" "bash /root/setup.sh"

msg_info "Restoring original DNS configuration inside container..."
pct exec $CTID -- bash -c 'if [ -f /tmp/resolv.conf.backup ]; then mv /tmp/resolv.conf.backup /etc/resolv.conf; fi'

msg_info "Starting VPN and Tailscale services..."
pct exec $CTID -- systemctl start wg-quick@vpn
pct exec $CTID -- systemctl start tailscaled
pct exec $CTID -- systemctl start tailscale-vpn-exit

msg_ok "LXC container $CTID ($HOSTNAME) created and configured successfully!"
