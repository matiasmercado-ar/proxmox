# Replace the failing backup HDD (`hdd` storage)

Host: the Proxmox node, PVE 9.2. SSH in as your admin user, then `sudo -i`. Every command below runs as root on the host unless stated otherwise.

## Current state (2026-11-13)

Placeholders: `<OLD_SERIAL>` is the failing disk serial, `<OLD_UUID>` its ext4 UUID, `<BACKUP_JOB_ID>` the vzdump job id from `cat /etc/pve/jobs.cfg`. Fill them from `lsblk -o NAME,SERIAL`, `blkid` and `jobs.cfg` on your own host.

| Item | Value |
|---|---|
| Failing disk | `/dev/sdb` WD Black 2 TB, model WD2002FAEX-007BA0, serial <OLD_SERIAL> |
| SATA port | ata1 (kernel `1:0:0:0`) |
| Health | 47423 power-on hours, 274 ATA errors, Current_Pending_Sector 5 (was 29), read errors in the past |
| Partition | GPT, single partition `sdb1`, ext4, UUID `<OLD_UUID>` |
| Mount | `/mnt/pve/hdd` via `/etc/systemd/system/mnt-pve-hdd.mount` (by UUID) |
| Proxmox storage | `hdd` (type dir, `is_mountpoint 1`) in `/etc/pve/storage.cfg`, referenced only by path |
| Content | 571 GB in `dump/` (vzdump backups, keep-last 7 for every guest). `images/`, `template/`, `snippets/` are empty |
| Backup job | `<BACKUP_JOB_ID>`, every 2 days at 01:00, all guests, storage `hdd` |
| Free SATA ports | ata3, ata4, ata6 (no link) |

Because Proxmox only knows the storage by path, nothing in `storage.cfg` or the backup job changes. Only the mount unit UUID changes.

## Plan

1. Disable the backup job so nothing writes to the old disk during the copy.
2. Power off, install the new disk on a free SATA port, keep the old one connected.
3. Partition and format the new disk.
4. Copy the backups with rsync.
5. Point the mount unit at the new disk and remount.
6. Test a backup, re-enable the job.
7. Power off, remove the old disk, boot, verify.

Total time: about 1.5 to 2 hours, mostly the copy.

## 1. Disable the backup job

```
pvesh set /cluster/backup/<BACKUP_JOB_ID> --enabled 0
pvesh get /cluster/backup/<BACKUP_JOB_ID> --output-format json | grep enabled
```

Expect `"enabled":0`. Make sure no backup task is running: Datacenter > Tasks in the GUI, or `ps aux | grep vzdump`.

## 2. Install the new disk

Shut the host down (this stops every VM and container):

```
shutdown -h now
```

Install the new 2 TB HDD on any free SATA port (the ones with nothing plugged in). Leave the old WD Black connected. Power on and wait for the host to come back, then SSH in and `sudo -i`.

Identify the new disk. Device letters (`sdb`, `sdd`) can shift between boots, so always work with `/dev/disk/by-id` names:

```
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
ls -l /dev/disk/by-id/ | grep -E 'ata-' | grep -v part
```

The new disk is the 1.8T one that is not `<OLD_SERIAL>` and has no partitions. Note its by-id name. The rest of this doc uses `NEW` as a placeholder for the by-id name, for example `ata-WDC_WD20XXXX_WD-WCCXXXXXXXXX`. Set it once in the shell so the commands below can be pasted as-is:

```
NEW=/dev/disk/by-id/ata-PUT_THE_REAL_NAME_HERE
lsblk $NEW
```

`lsblk $NEW` must print a 1.8T disk with no partitions. Do not continue if it prints anything else.

Quick health check of the new disk (2 minutes):

```
smartctl -t short $NEW
sleep 150
smartctl -l selftest $NEW
smartctl -A $NEW | grep -E 'Reallocated|Pending|Uncorrect'
```

Expect `Completed without error` and all three counters at 0.

## 3. Partition and format

GPT with a single ext4 partition, same layout as the old disk. Reserved blocks set to 0 since this is a backup store, not a root filesystem.

```
sgdisk --zap-all $NEW
sgdisk -n 1:0:0 -t 1:8300 -c 1:hdd $NEW
partx -u $NEW
mkfs.ext4 -L hdd -m 0 ${NEW}-part1
blkid ${NEW}-part1
```

Write down the `UUID=` value from `blkid`. It is needed in step 5.

Mount it temporarily:

```
mkdir -p /mnt/newhdd
mount ${NEW}-part1 /mnt/newhdd
df -h /mnt/newhdd
```

## 4. Copy the backups

571 GB over SATA takes 1 to 1.5 hours. Run it under `nohup` so a dropped SSH session does not kill it:

```
nohup rsync -aHAX --info=progress2 /mnt/pve/hdd/ /mnt/newhdd/ > /root/rsync-hdd.log 2>&1 &
```

Follow progress from another shell:

```
tail -f /root/rsync-hdd.log
```

When it finishes:

```
tail -3 /root/rsync-hdd.log
grep -i 'error' /root/rsync-hdd.log
```

The old disk has pending sectors, so a few files may fail with `Input/output error`. rsync skips them and keeps going, then exits with code 23. If that happens, the `grep` shows which backups were unreadable. Those are older copies of guests that have 6 other good backups each, so losing them is acceptable. Note the file names and move on.

Compare the result:

```
du -sh /mnt/pve/hdd/dump /mnt/newhdd/dump
ls /mnt/pve/hdd/dump | wc -l
ls /mnt/newhdd/dump | wc -l
```

The counts should match except for the files rsync reported as unreadable. The old disk holds 639 files.

Run rsync a second time. It finishes in seconds and copies only what changed or was missed:

```
rsync -aHAX --info=progress2 /mnt/pve/hdd/ /mnt/newhdd/
```

## 5. Switch the mount to the new disk

Unmount both and edit the mount unit:

```
umount /mnt/newhdd
systemctl stop mnt-pve-hdd.mount
mountpoint /mnt/pve/hdd
```

`mountpoint` must say `is not a mountpoint`. Now replace the UUID in the unit with the one from step 3:

```
cp /etc/systemd/system/mnt-pve-hdd.mount /root/mnt-pve-hdd.mount.bak
sed -i 's|^What=.*|What=/dev/disk/by-uuid/PUT_THE_NEW_UUID_HERE|' /etc/systemd/system/mnt-pve-hdd.mount
grep What= /etc/systemd/system/mnt-pve-hdd.mount
systemctl daemon-reload
systemctl start mnt-pve-hdd.mount
```

Verify:

```
df -h /mnt/pve/hdd
lsblk -o NAME,SIZE,SERIAL,MOUNTPOINT | grep -B1 /mnt/pve/hdd
pvesm status
pvesm list hdd | tail -5
```

`df` must show about 1.8T with 571G used, `lsblk` must show the new serial next to `/mnt/pve/hdd`, and `pvesm status` must list `hdd` as `active`. The GUI (Datacenter > Storage > hdd, and the node's Backups view) should show all backups.

## 6. Test a backup and re-enable the job

Back up the smallest guest (template 900, about 20 seconds) to the new disk:

```
vzdump 900 --storage hdd --mode snapshot --compress zstd
ls -lt /mnt/pve/hdd/dump | head -3
```

Then re-enable the scheduled job:

```
pvesh set /cluster/backup/<BACKUP_JOB_ID> --enabled 1
pvesh get /cluster/backup/<BACKUP_JOB_ID> --output-format json | grep enabled
```

## 7. Remove the old disk

Wipe its signatures first so nothing ever auto-mounts it by the old UUID. Double check the serial before wiping:

```
OLD=/dev/disk/by-id/ata-WDC_WD2002FAEX-007BA0_<OLD_SERIAL>
lsblk $OLD
wipefs -a ${OLD}-part1
wipefs -a $OLD
```

If the disk will leave the house (RMA, disposal), overwrite it as well. This takes 4 to 6 hours and can run while you do other things:

```
nohup dd if=/dev/zero of=$OLD bs=4M status=progress > /root/wipe-old-hdd.log 2>&1 &
```

Power off, pull the old WD Black from SATA port 1, power on. After boot:

```
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT
systemctl status mnt-pve-hdd.mount --no-pager
pvesm status
```

The old serial must be gone, the mount unit `active (mounted)`, storage `hdd` active. Start the guests that do not auto-start if needed.

## 8. Cleanup

```
rmdir /mnt/newhdd
rm /root/rsync-hdd.log /root/mnt-pve-hdd.mount.bak
```

Optionally run a long SMART test on the new disk overnight (about 5 hours on 2 TB):

```
smartctl -t long $NEW
```

Check the next day with `smartctl -l selftest $NEW`.

## Rollback

If anything goes wrong before step 7, the old disk is still intact. Restore the mount unit and remount:

```
systemctl stop mnt-pve-hdd.mount
cp /root/mnt-pve-hdd.mount.bak /etc/systemd/system/mnt-pve-hdd.mount
systemctl daemon-reload
systemctl start mnt-pve-hdd.mount
```
