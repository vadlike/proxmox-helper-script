<p align="center">
  <img src="https://visitor-badge.laobi.icu/badge?page_id=vadlike.proxmox-helper-script" alt="visitors">
  <img src="https://img.shields.io/github/last-commit/vadlike/proxmox-helper-script" alt="last commit">
  <img src="https://img.shields.io/badge/platform-Proxmox%20VE%208%2F9-E57000" alt="platform">
  <img src="https://img.shields.io/badge/license-MIT-16A34A" alt="license">
</p>

# Proxmox Helper Script

Mount disks on Proxmox host, attach bind mounts to LXC, and manage partitions with a CLI GParted-style workflow.

Repository:

- Main repo: `https://github.com/vadlike/proxmox-helper-script`
- Reference repo: `https://github.com/vadlike/proxmox-intel-vgpu-installer`

## Screenshot

<p align="center">
  <img src="./pic.png" alt="Proxmox Helper Script" width="70%">
</p>

## Features

- Host mount (`temporary` or `persist in /etc/fstab`)
- LXC bind attach/remove
- Remove host and LXC mounts
- Status report
- Disk editor mode:
  - inspect
  - wipe signatures
  - create/replace partition table
  - create/delete/resize partition
  - format filesystems

## Quick Install

### wget

```bash
wget -O proxmox-disk-mount-helper.sh https://raw.githubusercontent.com/vadlike/proxmox-helper-script/main/proxmox-disk-mount-helper.sh && chmod +x proxmox-disk-mount-helper.sh && ./proxmox-disk-mount-helper.sh
```

### curl

```bash
curl -fsSL -o proxmox-disk-mount-helper.sh https://raw.githubusercontent.com/vadlike/proxmox-helper-script/main/proxmox-disk-mount-helper.sh && chmod +x proxmox-disk-mount-helper.sh && ./proxmox-disk-mount-helper.sh
```

## Run Local Copy

```bash
chmod +x ./proxmox-disk-mount-helper.sh
./proxmox-disk-mount-helper.sh
```
