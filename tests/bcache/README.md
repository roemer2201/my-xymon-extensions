# bcache test fixtures

Recorded on Ubuntu 24.04 (kernel 6.8.0-138-generic) with one cache set
on an NVMe partition and six HDD backing devices in writeback mode:

- `bdev.txt` - `grep -s . * stats_total/* stats_five_minute/*` in
  `/sys/block/bcache0/bcache/` (backing device sdf)
- `cset.txt` - `grep -s . * internal/* stats_total/*` in
  `/sys/fs/bcache/<set-uuid>/`
- `cache.txt` - `grep -s . *` in `/sys/block/nvme0n1/nvme0n1p1/bcache/`
- `bcache0.stat`, `cache.stat` - `/sys/block/bcache0/stat` and
  `/sys/block/nvme0n1/nvme0n1p1/stat`

tests/run.sh builds a sysfs tree from these files (one file per
attribute, the symlinks `cache`, `dev`, `bdevN` and `cacheN` like the
kernel creates them). The other five backing devices are copies of
sdf with the UUIDs from the host's /dev/bcache/by-uuid/.
