# proxmox

Proxmox utilities for deploying and managing VMs in a lab environment.

## Scripts

### `deploy-vm.sh`
An interactive script to deploy a new Proxmox VM from a ZFS template.

**Features:**
- Clones a template (default ID `900`) to a new VM on `local-zfs`.
- Interactively configures the VM Name, ID, CPU, RAM, Disk, and IP.
- Enforces lab resource limits (e.g., max 8 Cores, 16GB RAM, 200GB disk increment).
- Configures the VM using `qm` commands and applies Cloud-Init settings for networking (IP, Gateway, DNS) and OS hostname.
- Automatically starts the VM and provides the SSH connection command.

**Usage:**
Run as `root` on the Proxmox host:
```bash
./deploy-vm.sh
```

### `grow-fs.sh`
An LVM disk expander script to be run *inside* the deployed VM after its virtual disk boundary has been increased.

**Features:**
- Auto-detects the underlying disk and Volume Group (VG).
- Uses `growpart` to expand the extended and LVM partitions.
- Resizes the Physical Volume (PV) to recognize the newly available space.
- Displays free space and current LV sizes.
- Interactively asks how to allocate the new space (in GB) across specific Logical Volumes (`/root`, `/var`, `/home`, `/tmp`).
- Automatically applies the extensions and seamlessly resizes the filesystems.

**Usage:**
Run as `root` inside the guest VM:
```bash
./grow-fs.sh
```

## Troubleshooting

### `troubleshooting/replace-backup-hdd.md`
Step-by-step procedure to replace the failing 2 TB backup HDD (`hdd` storage at `/mnt/pve/hdd`): install the new disk, partition and format it, rsync the vzdump backups, repoint the systemd mount unit and remove the old disk.

### `troubleshooting/disaster-recovery.md`
Disaster Recovery plan for the host: what to back up to the NAS beforehand (guest backups, host configuration archive, secrets), then the full rebuild on two new SSDs: Proxmox install as ZFS mirror, network, ProxMenux, GPU passthrough, storages, guest restore order, users/tokens/jobs, per-app checks and a verification list.
