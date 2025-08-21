# Proxmox LXC Tailscale Exit Node with VPN WireGuard

This project provides an automated deployment script that creates and configures a Proxmox LXC container to serve as a **Tailscale exit node** which routes all traffic through **VPN using WireGuard**. The container also advertises local subnets to Tailscale clients, enabling seamless access to network resources behind the node.

## Features

- Automated Proxmox LXC container creation with Debian 12.
- Full Tailscale installation and configuration as an exit node.
- VPN WireGuard tunnel integration for outbound VPN routing.
- Advertising of user-specified local subnets to connected Tailscale devices.
- Systemd services for reliable startup and management.
- LXC configuration tweaks to allow `/dev/net/tun` access for VPNs.
- User-friendly prompts for setup variables: VPN config, Tailscale auth key, and subnets.

## Prerequisites

- Proxmox VE environment with LXC support.
- VPN WireGuard config file available locally on Proxmox host.
- Tailscale auth key generated from your Tailscale account.
- Basic familiarity with running shell scripts on the Proxmox host.

## Usage

Run the deployment script directly on your Proxmox host with:
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cryptshoe/deploy-tailscale-wg-vpn-lxc/main/deploy-tailscale-vpn-lxc.sh)"
```

You will be prompted to provide:

- Path to your local VPN WireGuard config file (e.g. `/root/vpn.conf`)
- Your Tailscale auth key for unattended authentication.
- The local subnet(s) you want to advertise (comma-separated, e.g. `192.168.0.0/24,10.0.0.0/24`)

Once completed, the script will:

- Create and start a new LXC container configured with TUN device access.
- Inject and run a setup script inside the container to install and configure Tailscale and WireGuard.
- Enable systemd services for automatic startup of Tailscale and the VPN tunnel.
- Configure IP forwarding and firewall rules for subnet routing and exit-node functionality.

## Customization

- Modify container resource allocations (CPU, RAM, disk) directly in the script variables.
- Adjust or extend network bridge settings to fit your environment.
- You can update the VPN config by replacing `/etc/wireguard/vpn.conf` inside the container and restarting the WireGuard service.

## Troubleshooting

- Make sure the host kernel has the `tun` module loaded (`modprobe tun`).
- Verify LXC container config allows `/dev/net/tun` passthrough.
- Check systemd service statuses inside the container with:
```
pct exec <CTID> -- systemctl status tailscaled
pct exec <CTID> -- systemctl status wg-quick@vpn
pct exec <CTID> -- systemctl status tailscale-vpn-exit
```
- Inspect logs with `journalctl` inside container for errors.


