# Disaster Recovery: rebuild the Proxmox host on two new SSDs

Sanitized copy. Placeholders in angle brackets (`<PVE_IP>`, `<NAS_USER>`, `<HDD_UUID>`, ...) are the real values of your own host; fill them from your inventory. The guest IDs, names and paths are the ones used on the host this was written for.

Written 2026-11-14 from a live inventory of the host. Scenario: rpool (a RAID0 stripe of two 240 GB SSDs: WD Green and Kingston A400) dies. Everything on it is lost: the Proxmox OS, every VM and container disk, ISOs. The backup HDD (`hdd`, Seagate <HDD_SERIAL>) and the NAS (QNAP, <NAS_IP>) survive.

Part 1 is what must exist before the disaster. Do it now, it takes about 30 minutes. Part 2 is the rebuild. Part 3 is the verification. Part 4 is the reference copy of the current config.

Commands run as root on the Proxmox host unless stated otherwise. Paste one fenced block at a time.

## 0. What is on this host and where its data lives

| ID | Name | Role | Data that matters | Backed up today |
|---|---|---|---|---|
| LXC 100 | adguard | LAN DNS (<DNS_IP>). Every other guest and the house point at it | /opt/AdGuardHome/AdGuardHome.yaml + data/ | hdd vzdump every 2 days |
| LXC 107 | casa-ranking | House rating app, http://<CASA_IP> | SQLite /opt/casa-ranking/data/casa-ranking.db, .env | hdd only |
| LXC 111 | wireguard | Tailscale subnet router `<TAILSCALE_NODE>` (remote access), WireGuard standby, DuckDNS | /var/lib/tailscale, /etc/wireguard, /opt/duckdns | hdd only |
| LXC 150 | ticket-mgmt | Ticket Desk hub, https://<TD_HUB_IP> | SQLite /opt/ticket-mgmt/data/tm.db + folders/*.tar.gz, /etc/ticket-mgmt/*.env + tls/ | hdd only |
| LXC 151 | td-worker | Ticket Desk worker (<TD_WORKER_IP>), td-lab | /home/td/.config/ticket-mgmt/*.env (PVE token, Claude token) | hdd only |
| VM 101 | k8s-master | k3s, Ubuntu 24.04, <K3S_IP>: El Plan Z (https://<K3S_FQDN>:30300), Jellyfin, qBittorrent | Postgres PVC + elplanazo-data PVC under /var/lib/rancher/k3s/storage; Jellyfin config PVC | hdd vzdump + **nightly app-level backup to NAS backup-r1/elplanazo** with restore test (see elplanazo/docs/DISASTER-RECOVERY.md) |
| VM 102 | wazuh-aio | Wazuh 4.x lab, 2 snapshots | lab only | hdd |
| VM 105 | ollama | LLM host, RX 580 passthrough (hostpci0 01:00) | models, re-downloadable | hdd |
| VM 103, 106, 108 | debian-agent, wazuh5night, debian13-update | labs | none | hdd |
| VM 900 | debian13-gold | **Template** used by deploy-vm.sh for new Debian 13 VMs (LVM layout, cloud-init) | the disk itself, 861 MB compressed | hdd |
| VM 200, 201, 202 | td-tpl-* | Ticket Desk templates (Ubuntu 24.04, Wazuh AiO, Wazuh manager) | the disks | hdd |
| host | proxmox | PVE 9.2, ZFS, ProxMenux 1.2.4, vfio, log2ram, backup jobs, user <ADMIN_USER>, API user ticketdesk@pve with token | /etc, /etc/pve (incl. priv/), /usr/local/bin, /usr/local/share/proxmenux | **nothing** |

What the HDD alone does not cover: nothing is on the NAS except elplanazo, so if the HDD dies with the host (same PSU, same case) you lose everything except El Plan Z. And the host config is not backed up anywhere. Part 1 fixes both.

## 1. Before the disaster: set this up now

### 1.1 Add the NAS backup share as Proxmox storage

The NAS share `backup-r1` is a RAID1 volume with 1.4 TB free (2026-11-14). elplanazo already writes there. Proxmox needs the CIFS username and password (the `<NAS_USER>` user, password in KeePass).

```
pvesm add cifs nas-backup --server <NAS_IP> --share backup-r1 --username <NAS_USER> --password 'PASTE_PASSWORD' --content backup --subdir /proxmox --prune-backups keep-last=7
pvesm status
ls /mnt/pve/nas-backup
```

`nas-backup` must show `active`. The password goes to /etc/pve/priv/storage/nas-backup.pw, not to the shell history: run `history -d $((HISTCMD-1))` or clear the line afterwards.

### 1.2 Backup jobs to the NAS

Two jobs. Daily for the small guests that hold data (about 3.5 GB per run), weekly for the big VMs and templates (about 45 GB). Keep 7 daily and 2 weekly: about 115 GB on the NAS.

```
pvesh create /cluster/backup --id nas-daily --schedule '02:30' --storage nas-backup --vmid 100,107,111,150,151,900 --mode snapshot --compress zstd --enabled 1 --notes-template '{{guestname}}' --prune-backups keep-last=7 --mailnotification failure --mailto <EMAIL>
pvesh create /cluster/backup --id nas-weekly --schedule 'sun 03:00' --storage nas-backup --vmid 101,102,105,200,201,202 --mode snapshot --compress zstd --enabled 1 --notes-template '{{guestname}}' --prune-backups keep-last=2 --mailnotification failure --mailto <EMAIL>
pvesh get /cluster/backup --output-format json | grep -oE '"id":"[^"]+"'
```

Run the daily one now so the NAS has a copy tonight and you see it works:

```
vzdump 100 107 111 150 151 900 --storage nas-backup --mode snapshot --compress zstd
ls -lh /mnt/pve/nas-backup/proxmox/dump
```

Note on the existing job `<HDD_JOB_ID>` (every 2 days 01:00 to `hdd`): leave it, the HDD stays the first line of defense and holds 7 copies of everything.

### 1.3 Host configuration archive to the NAS

Everything that makes this host "this host" is in /etc (network, modprobe, kernel cmdline, cron, systemd units, sudoers, ssh), /etc/pve (storage.cfg, jobs.cfg, user.cfg with pools/roles/ACLs, guest configs, priv/ with the NAS passwords, the API token secret and the SSH/authkey), /usr/local/bin and the ProxMenux state. One tar every night, 30 kept.

```
mkdir -p /mnt/pve/nas-backup/proxmox/host-config
cat > /etc/cron.d/host-config-backup <<'CRON'
# Nightly archive of the Proxmox host configuration to the NAS (keeps 30)
15 2 * * * root tar --warning=no-file-changed -czpf /mnt/pve/nas-backup/proxmox/host-config/proxmox-config-$(date +\%F).tgz /etc /usr/local/bin /usr/local/share/proxmenux/*.json /root/.ssh /home/<ADMIN_USER>/.ssh /var/spool/cron /etc/telegram-notify.conf 2>/dev/null; dpkg --get-selections > /mnt/pve/nas-backup/proxmox/host-config/dpkg-selections-$(date +\%F).txt; find /mnt/pve/nas-backup/proxmox/host-config -type f -mtime +30 -delete
CRON
chmod 644 /etc/cron.d/host-config-backup
```

Run it once by hand and check:

```
tar --warning=no-file-changed -czpf /mnt/pve/nas-backup/proxmox/host-config/proxmox-config-$(date +%F).tgz /etc /usr/local/bin /usr/local/share/proxmenux/*.json /root/.ssh /home/<ADMIN_USER>/.ssh /var/spool/cron /etc/telegram-notify.conf 2>/dev/null
ls -lh /mnt/pve/nas-backup/proxmox/host-config/
tar -tzf /mnt/pve/nas-backup/proxmox/host-config/proxmox-config-$(date +%F).tgz | grep -E 'etc/pve/(storage.cfg|jobs.cfg|user.cfg|priv/token.cfg)|interfaces$|vfio.conf|10-nic0.link|mnt-pve-hdd.mount'
```

The grep must print all seven paths. The archive contains secrets (NAS passwords, API token, SSH keys): it is readable only by root on the host and lives on the NAS share, which is fine for a home LAN. Do not copy it anywhere public.

### 1.4 Things that must live outside the host (KeePass)

- Proxmox root password, and the <ADMIN_USER> SSH private key (on the laptop, also the Tailscale node key for remote access).
- NAS admin and `<NAS_USER>` passwords.
- Ticket Desk: Jira API tokens, Claude OAuth token (both are in the LXC backups too, but regenerating them is the fallback).
- The private CA from `homelab-internal-ca` (on the laptop, copy on backup-r1/elplanazo/pki-ca/): needed to re-issue certs for <K3S_FQDN> and the Ticket Desk hub if they change.
- El Plan Z: IOL credentials, CoinGecko key (KeePass already, per its own DR doc).
- A copy of this file. The repo copy is sanitized; keep this local copy somewhere off the host too (the NAS backup-r1/proxmox folder is a good place).

```
cp <repo path>/proxmox/troubleshooting/disaster-recovery.local.md /mnt/nas/...   # from the laptop, wherever backup-r1 is mounted
```

### 1.5 Test once a quarter

Restore one small guest from the NAS copy under a new ID and start it. Takes 5 minutes:

```
pct restore 999 /mnt/pve/nas-backup/proxmox/dump/vzdump-lxc-107-*.tar.zst --storage local-zfs --hostname casa-ranking-test --unprivileged 1
pct set 999 --net0 name=eth0,bridge=vmbr0,ip=<TEST_IP>/24,gw=<GATEWAY> --onboot 0
pct start 999 && sleep 10 && curl -s -o /dev/null -w '%{http_code}\n' http://<TEST_IP>/healthz
pct stop 999 && pct destroy 999
```

Expect `200`. Also check nightly that `LAST_RUN.txt` on backup-r1/elplanazo says OK, and monthly that `ls /mnt/pve/nas-backup/proxmox/dump | tail` shows fresh dates.

## 2. The rebuild

Time: about 2 hours of hands-on work plus restore time (VM 101 is a 14 GB archive, about 10 minutes from the NAS over gigabit).

### 2.1 Hardware

- Two new SATA SSDs, same size, at least 480 GB (rpool uses 181 GB today; 240 GB was already tight for the Kingston). Plug them into the ports the old SSDs used (ata0 and ata5, the first and the last port on the board). Keep the Seagate HDD on its port.
- BIOS on the ASUS MAXIMUS XI HERO: UEFI boot, SATA mode AHCI, VT-d enabled (needed for the GPU passthrough), Primary display = onboard/CPU so the RX 580 is free for vfio. CSM off.
- Laptop: Proxmox VE 9.x ISO from https://www.proxmox.com/en/downloads on a USB stick (`dd if=proxmox-ve_9.x.iso of=/dev/sdX bs=4M status=progress`, or Ventoy).

### 2.2 Install Proxmox VE

Boot the USB, graphical installer:

- Target: **ZFS (RAID1)** on the two new SSDs only. Advanced: ashift 12, compression on, checksum on. Do not include the HDD.
- Country Argentina, timezone America/Argentina/Mendoza, keyboard es (datacenter.cfg had `keyboard: es`).
- Root password (KeePass), email <EMAIL>.
- Network: bridge interface = the onboard Intel I219-V, hostname `proxmox.local`, IP <PVE_IP>/24, gateway <GATEWAY>, DNS <GATEWAY> (AdGuard is down at this point, so use the router).

Reboot, remove the USB, log in at https://<PVE_IP>:8006 as root.

### 2.3 First login: repos, updates, packages, user

```
# repositories: disable enterprise, enable no-subscription (ProxMenux post-install does the same)
sed -i 's/^Enabled: true/Enabled: false/' /etc/apt/sources.list.d/pve-enterprise.sources
sed -i 's/^Enabled: true/Enabled: false/' /etc/apt/sources.list.d/ceph.sources
cat > /etc/apt/sources.list.d/proxmox.sources <<'SRC'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SRC
apt update && apt dist-upgrade -y
apt install -y sudo git curl wget rsync htop jq tree bc ethtool gdisk smartmontools cifs-utils nfs-common nmap tcpdump lsof strace sqlite3 socat genisoimage dtach
```

Admin user with passwordless sudo and your SSH key (the key is in the config archive at home/<ADMIN_USER>/.ssh/authorized_keys, or paste it from the laptop):

```
adduser --gecos '' <ADMIN_USER>
echo '<ADMIN_USER> ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/<ADMIN_USER> && chmod 440 /etc/sudoers.d/<ADMIN_USER>
mkdir -p /home/<ADMIN_USER>/.ssh && chmod 700 /home/<ADMIN_USER>/.ssh
# paste the public key:
cat > /home/<ADMIN_USER>/.ssh/authorized_keys <<'KEY'
ssh-ed25519 AAAA... <ADMIN_USER>
KEY
chown -R <ADMIN_USER>:<ADMIN_USER> /home/<ADMIN_USER>/.ssh && chmod 600 /home/<ADMIN_USER>/.ssh/authorized_keys
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

Keep `PermitRootLogin yes` (key only): the Ticket Desk deploy scripts and casa-ranking's deploy.sh ssh as root. Put the same public key in /root/.ssh/authorized_keys.

### 2.4 Mount the NAS and fetch the config archive

```
mkdir -p /mnt/nasbk
mount -t cifs //<NAS_IP>/backup-r1 /mnt/nasbk -o username=<NAS_USER>,password='PASTE',vers=3.0
ls /mnt/nasbk/proxmox/host-config/ | tail -3
mkdir -p /root/oldcfg && cd /root/oldcfg
tar -xzpf /mnt/nasbk/proxmox/host-config/proxmox-config-LATEST-DATE.tgz
ls /root/oldcfg/etc/pve
```

Everything below copies files from /root/oldcfg. Do not untar straight over the live /etc.

### 2.5 Network: pinned NIC name, bridge, e1000e workaround

The old host named the onboard NIC `nic0` through a systemd link file and disables TSO/GSO/GRO on it (known e1000e "Hardware Unit Hang" bug on the I219-V). Restore both. If the motherboard changed, update the MAC in the link file.

```
cp /root/oldcfg/etc/systemd/network/10-nic0.link /etc/systemd/network/
cat /etc/systemd/network/10-nic0.link      # MACAddress=<NIC_MAC> -> Name=nic0
cp /root/oldcfg/etc/network/interfaces /etc/network/interfaces
cat /etc/network/interfaces               # vmbr0 <PVE_IP>/24, bridge-ports nic0, post-up ethtool -K nic0 tso off gso off gro off
cp /root/oldcfg/etc/hosts /etc/hosts
update-initramfs -u -k all
reboot
```

After the reboot: `ip -br a` must show `nic0` and `vmbr0` with <PVE_IP>, and `ethtool -k nic0 | grep -E 'tcp-segmentation|generic-(segmentation|receive)'` must show all three `off`.

### 2.6 ProxMenux and the post-install tweaks

```
bash -c "$(wget -qLO - https://raw.githubusercontent.com/MacRimi/ProxMenux/main/install_proxmenux.sh)"
menu
```

In ProxMenux: Post-install (customizable) and tick the same set the old host had: apt IPv4, apt languages, system limits, entropy (haveged), memory settings, kernel panic, network optimization, bashrc custom, log2ram, logrotate, persistent network, figurine. That recreates /etc/sysctl.d entries, log2ram (SIZE=512M in /etc/log2ram.conf, plus the 6-hourly flush cron) and the `proxmenux-fwbr-tune` and `proxmenux-monitor` units. Compare afterwards:

```
diff <(grep -rhv '^#' /root/oldcfg/etc/sysctl.d/ | sort) <(grep -rhv '^#' /etc/sysctl.d/ | sort)
diff /root/oldcfg/etc/log2ram.conf /etc/log2ram.conf
```

### 2.7 GPU passthrough (VM 105 ollama, RX 580 at 01:00)

```
cp /root/oldcfg/etc/modprobe.d/vfio.conf /etc/modprobe.d/        # options vfio-pci ids=1002:6fdf,1002:aaf0 + softdep amdgpu pre: vfio-pci
cp /root/oldcfg/etc/modprobe.d/blacklist.conf /etc/modprobe.d/   # blacklist radeon, amdgpu
cp /root/oldcfg/etc/modprobe.d/zfs.conf /etc/modprobe.d/         # zfs_arc_max=7388608000 (about 6.9 GiB)
cp /root/oldcfg/etc/modules /etc/modules                          # vfio vfio_iommu_type1 vfio_pci vfio_virqfd
cp /root/oldcfg/etc/modules-load.d/wireguard.conf /etc/modules-load.d/
# the host boots with systemd-boot (proxmox-boot-tool), so the cmdline lives here, not in GRUB:
echo 'root=ZFS=rpool/ROOT/pve-1 boot=zfs intel_iommu=on iommu=pt' > /etc/kernel/cmdline
proxmox-boot-tool refresh
update-initramfs -u -k all
reboot
```

Check: `dmesg | grep -E 'DMAR: IOMMU enabled|vfio-pci 0000:01:00'` and `lspci -nnk -s 01:00` must show `Kernel driver in use: vfio-pci` for both functions.

### 2.8 Storages

The HDD mount unit (by UUID) and the storage definitions:

```
mkdir -p /mnt/pve/hdd
cp /root/oldcfg/etc/systemd/system/mnt-pve-hdd.mount /etc/systemd/system/
blkid | grep <HDD_UUID_PREFIX>          # the Seagate; if it was replaced, fix What= in the unit
systemctl daemon-reload && systemctl enable --now mnt-pve-hdd.mount
df -h /mnt/pve/hdd
```

Storage definitions. `local` and `local-zfs` already exist after the install. Add the rest with pvesm, using the passwords from /root/oldcfg/etc/pve/priv/storage/:

```
pvesm add dir hdd --path /mnt/pve/hdd --content vztmpl,backup,snippets,images,rootdir,iso --is_mountpoint 1
pvesm add cifs NAS --server <NAS_IP> --share Public --username <NAS_USER> --password "$(cat /root/oldcfg/etc/pve/priv/storage/NAS.pw)" --content images --prune-backups keep-all=1
pvesm add cifs nas-backup --server <NAS_IP> --share backup-r1 --username <NAS_USER> --password "$(cat /root/oldcfg/etc/pve/priv/storage/nas-backup.pw)" --content backup --subdir /proxmox --prune-backups keep-last=7
pvesm status
```

All five must be `active`. `local-zfs` must be `sparse 1` as before: `grep -A3 local-zfs /etc/pve/storage.cfg`, add `sparse 1` under it if missing.

### 2.9 Restore the guests

Use the NAS copies (`/mnt/pve/nas-backup/proxmox/dump`) or, if the HDD survived and is newer, `/mnt/pve/hdd/dump`. Same IDs as before, so every static IP, DNS entry, deploy script and Ticket Desk config keeps working. Order matters: DNS first.

```
D=/mnt/pve/hdd/dump            # or /mnt/pve/nas-backup/proxmox/dump
latest() { ls -t $D/vzdump-$1-*.{tar.zst,vma.zst} 2>/dev/null | head -1; }

pct restore 100 $(latest lxc-100) --storage local-zfs && pct start 100     # adguard: LAN DNS is back
pct restore 111 $(latest lxc-111) --storage local-zfs && pct start 111     # tailscale/wireguard
pct restore 107 $(latest lxc-107) --storage local-zfs && pct start 107     # casa-ranking
pct restore 150 $(latest lxc-150) --storage local-zfs && pct start 150     # ticket-desk hub
pct restore 151 $(latest lxc-151) --storage local-zfs && pct start 151     # ticket-desk worker
qmrestore $(latest qemu-101) 101 --storage local-zfs && qm start 101       # k3s: El Plan Z, Jellyfin
qmrestore $(latest qemu-900) 900 --storage local-zfs                       # gold template (stays a template)
qmrestore $(latest qemu-200) 200 --storage local-zfs
qmrestore $(latest qemu-201) 201 --storage local-zfs
qmrestore $(latest qemu-202) 202 --storage local-zfs
qmrestore $(latest qemu-102) 102 --storage local-zfs && qm start 102       # wazuh lab
qmrestore $(latest qemu-105) 105 --storage local-zfs && qm start 105       # ollama (needs 2.7 done)
```

The archives carry the full guest config (cores, memory, net0 with the same MAC and static IP, onboot, hostpci0, template flag, tags), so no `pct set` or `qm set` is needed. VM snapshots inside 102 are not in a vzdump; only the live state is. Labs 103, 106, 108 and any td-ws-* VM are not worth restoring; td-lab recreates labs from 200/201/202.

Now switch the host's own DNS back to AdGuard: `echo -e 'search local\nnameserver <DNS_IP>\nnameserver <GATEWAY>' > /etc/resolv.conf`.

### 2.10 Proxmox users, pool, roles, API token, backup jobs

The Ticket Desk worker authenticates with the token `ticketdesk@pve!worker`, limited by two custom roles and four ACLs. The token's secret is in priv/token.cfg. Restoring both files brings it back unchanged, so the worker's pve.env keeps working.

```
cp /root/oldcfg/etc/pve/user.cfg /etc/pve/user.cfg
cp /root/oldcfg/etc/pve/priv/token.cfg /etc/pve/priv/token.cfg
cp /root/oldcfg/etc/pve/datacenter.cfg /etc/pve/datacenter.cfg
cp /root/oldcfg/etc/pve/jobs.cfg /etc/pve/jobs.cfg
pveum user list; pveum pool list; pveum acl list
pvesh get /cluster/backup --output-format json | grep -oE '"id":"[^"]+"'
```

Expect user ticketdesk@pve, pool ticketdesk (members will be empty until td-lab clones labs; templates 200-202 belong to it: `pvesh set /pools/ticketdesk --vms 200,201,202`), the two TicketDesk roles, and the three backup jobs (hdd every 2 days with the 153-198 exclude, nas-daily, nas-weekly).

Other host bits from the archive. Notifications go to Telegram: the PVE webhook target and its matcher are in notifications.cfg, the bot token and chat id live in priv/notifications.cfg (webhook secrets) and in /etc/telegram-notify.conf (used by the smartd and ZED hook script):

```
cp /root/oldcfg/etc/cron.d/host-config-backup /etc/cron.d/
cp /root/oldcfg/etc/pve/notifications.cfg /etc/pve/notifications.cfg
cp /root/oldcfg/etc/pve/priv/notifications.cfg /etc/pve/priv/notifications.cfg
cp /root/oldcfg/usr/local/bin/telegram-notify.sh /usr/local/bin/ && chmod 755 /usr/local/bin/telegram-notify.sh
cp /root/oldcfg/etc/telegram-notify.conf /etc/ && chmod 600 /etc/telegram-notify.conf
cp /root/oldcfg/etc/zfs/zed.d/zed.rc /etc/zfs/zed.d/zed.rc && systemctl restart zfs-zed
pvesh create /cluster/notifications/targets/telegram/test
# host alerts (boot/shutdown message, per-minute health checks)
cp /root/oldcfg/usr/local/bin/host-lifecycle-notify.sh /root/oldcfg/usr/local/bin/host-health-check.sh /usr/local/bin/ && chmod 755 /usr/local/bin/host-*.sh
cp /root/oldcfg/etc/host-health.conf /etc/
cp /root/oldcfg/etc/systemd/system/telegram-lifecycle.service /root/oldcfg/etc/systemd/system/telegram-health.service /root/oldcfg/etc/systemd/system/telegram-health.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now telegram-lifecycle.service telegram-health.timer
cp /root/oldcfg/etc/smartd.conf /etc/smartd.conf && systemctl restart smartd
cp -r /root/oldcfg/root/.ssh /root/
cp /root/oldcfg/etc/default/locale /etc/default/locale
```

### 2.11 Per-application checks after the restore

- **adguard (100):** `dig @<DNS_IP> <K3S_FQDN>` answers <K3S_IP>. Web UI http://<DNS_IP>:3000. If the house lost DNS during the outage, nothing to redo: the router hands out .100.
- **wireguard/tailscale (111):** `pct exec 111 -- tailscale status` shows `<TAILSCALE_NODE>` online. If the node key expired, `tailscale up --advertise-routes=<LAN>/24` and approve the route in the Tailscale admin console.
- **casa-ranking (107):** `curl http://<CASA_IP>/healthz` returns 200. Docker starts the container from the image already in the container's /var/lib/docker; if it does not, `cd /opt/casa-ranking && docker compose up -d --build`.
- **ticket-desk (150/151):** https://<TD_HUB_IP> logs in; `systemctl status tm-web tm-poll.timer` on 150 and `tm-worker-system` on 151. `td-lab list` on 151 proves the PVE token works. If the Proxmox TLS cert changed (it does after a reinstall), the worker's PVE_CA_FILE must be refreshed: copy /etc/pve/pve-root-ca.pem to the path pve.env names.
- **El Plan Z (101):** https://<K3S_FQDN>:30300 loads. Data inside the VM is as old as the vzdump (up to 7 days from the NAS weekly). Bring it to last night with its own backup: follow elplanazo/docs/DISASTER-RECOVERY.md Scenario B (restore db.sql.gz from backup-r1/elplanazo/daily/<last night>/ into the running cluster). A copy of that guide sits next to the backups on the NAS.
- **gold template (900):** `qm config 900 | grep template` says `template: 1`; `bash deploy-vm.sh` from this repo creates a VM from it.
- **Ticket Desk templates:** `qm config 201 | grep template` and the pool membership, then `td-lab create` from the worker.
- **ollama (105):** `qm config 105 | grep hostpci0`; inside the VM, `rocm-smi` or `ollama ps` shows the GPU.

## 3. Verification checklist

- [ ] `zpool status rpool` shows `mirror-0` with two ONLINE disks (RAID1, not the old stripe).
- [ ] `ip -br a` shows nic0 and vmbr0 at <PVE_IP>; offloads off.
- [ ] `pvesm status` shows local, local-zfs, hdd, NAS, nas-backup active.
- [ ] `pct list` / `qm list`: 100, 107, 111, 150, 151 running; 101, 102, 105 running; 900, 200, 201, 202 templates.
- [ ] DNS, Tailscale, casa-ranking, Ticket Desk, El Plan Z answer (2.11).
- [ ] `pveum acl list` has the four ticketdesk entries; `td-lab list` works.
- [ ] `pvesh get /cluster/backup` lists three jobs; run `vzdump 100 --storage nas-backup` once to prove writes.
- [ ] `ls /etc/cron.d/host-config-backup` and a fresh tgz on the NAS the next morning.
- [ ] `lspci -nnk -s 01:00` shows vfio-pci; VM 105 sees the GPU.
- [ ] `menu` opens ProxMenux; `systemctl is-active log2ram proxmenux-monitor`.
- [ ] Update this file and `proxmox-lab-server` notes with the new SSD models/serials.

## 4. Reference: the current configuration (2026-11-14)

Hardware: ASUS ROG MAXIMUS XI HERO (WI-FI), i7-9700KF, 32 GB DDR4, Radeon RX 580 (01:00, vfio), Intel I219-V (MAC <NIC_MAC>, pinned to `nic0`). UEFI, systemd-boot via proxmox-boot-tool. PVE 9.2.10, kernel 7.0.14-12-pve.

/etc/network/interfaces:
```
auto lo
iface lo inet loopback
iface nic0 inet manual
auto vmbr0
iface vmbr0 inet static
	address <PVE_IP>/24
	gateway <GATEWAY>
	bridge-ports nic0
	bridge-stp off
	bridge-fd 0
	post-up /usr/sbin/ethtool -K nic0 tso off gso off gro off
iface nic1 inet manual
source /etc/network/interfaces.d/*
```

/etc/pve/storage.cfg (before Part 1 adds nas-backup):
```
dir: local            path /var/lib/vz, content iso,vztmpl,backup,import
zfspool: local-zfs    pool rpool/data, content images,rootdir, sparse 1
dir: hdd              path /mnt/pve/hdd, content vztmpl,backup,snippets,images,rootdir,iso, is_mountpoint 1, nodes proxmox
cifs: NAS             server <NAS_IP>, share Public, username <NAS_USER>, content images, prune-backups keep-all=1
```

/etc/systemd/system/mnt-pve-hdd.mount: What=/dev/disk/by-uuid/<HDD_UUID>, Where=/mnt/pve/hdd, Type=ext4, WantedBy=multi-user.target.

/etc/pve/jobs.cfg: vzdump <HDD_JOB_ID>, schedule `*-*-*/2 01:00`, all 1, exclude 153-198, storage hdd, mode snapshot, zstd, keep-last 7, mailto <EMAIL>.

/etc/pve/user.cfg: users root@pam, ticketdesk@pve (token `worker`); pool ticketdesk; roles TicketDeskInfra (Datastore.AllocateSpace, Datastore.Audit, SDN.Use, Sys.Audit) and TicketDeskLab (Pool.Audit, VM.Allocate, VM.Audit, VM.Clone, VM.Config.*, VM.Console, VM.GuestAgent.Audit, VM.PowerMgmt, VM.Snapshot, VM.Snapshot.Rollback); ACLs for ticketdesk@pve on /nodes/proxmox, /pool/ticketdesk, /sdn/zones/localnetwork/vmbr0, /storage/local-zfs. Recreatable from ticket-desk/deploy/proxmox-iam.sh if the archive is lost.

Kernel/modules: /etc/kernel/cmdline `root=ZFS=rpool/ROOT/pve-1 boot=zfs` (IOMMU on by kernel default on this Intel CPU; add intel_iommu=on iommu=pt explicitly on the rebuild). /etc/modprobe.d/vfio.conf `options vfio-pci ids=1002:6fdf,1002:aaf0` + `softdep amdgpu pre: vfio-pci`; blacklist.conf `blacklist radeon`, `blacklist amdgpu`; zfs.conf `options zfs zfs_arc_max=7388608000`; /etc/modules vfio, vfio_iommu_type1, vfio_pci, vfio_virqfd; modules-load.d/wireguard.conf.

ProxMenux 1.2.4 at /usr/local/share/proxmenux, launcher /usr/local/bin/menu; post-install options enabled: apt_ipv4, apt_languages, system_limits, entropy, memory_settings, kernel_panic, network_optimization, bashrc_custom, log2ram (512M, 6 h flush), logrotate, persistent_network, figurine.

Guest static IPs: 100 .100, 101 .101, 102 .102, 105 .105, 107 .107, 111 .160, 150 .150, 151 .152, 900 .99 (template), labs .153-.198 via td-lab. Gateway .1, DNS .100 then .1, search domain `local` (VMs) or `<HOME_DOMAIN>` (containers).

Local ISOs/images on /var/lib/vz (re-downloadable): debian-13.3.0 netinst, ubuntu-24.04.3 and 22.04.5 server, CentOS Stream 9, debian-live-11.11 KDE, cloudimg/noble.img (Ubuntu 24.04 cloud image for td-lab and repro VMs), template/cache debian-13-standard_13.1-2 LXC template.
