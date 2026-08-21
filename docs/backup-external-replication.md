# Safe external backup replication

This guide installs and operates the macOS replication command for copying the
newest complete local Bitcoin blockchain backup to a removable external drive.

The default paths are:

```text
Local source:
~/bitcoin-node-backups

External destination:
/Volumes/Backup_8TB/bitcoin-node-backups
```

The workflow is intentionally manual. Connecting an external drive never starts
a copy automatically.

## Safety model

The replication command:

- Defaults to dry-run mode
- Selects the newest local backup by Bitcoin block height
- Requires an archive, checksum and manifest
- Recalculates the local archive SHA-256 before copying
- Requires the destination to be on a separate mounted volume
- Requires at least the archive size plus 1 GiB of free space
- Copies into `.partial` files
- Recalculates SHA-256 from the external `.partial` archive
- Publishes final names only after verification
- Never overwrites an existing final file
- Never deletes a local or external backup
- Retains partial artifacts after failure for operator inspection
- Prevents idle Mac sleep during an active copy

If the newest backup already exists externally, the command compares its
checksum and manifest with the local files and recalculates the external
archive SHA-256. A matching copy is reported as already synchronized.

## Important security boundary

The blockchain backup contains public `blocks/` and `chainstate/` data. It does
not contain a wallet, seed phrase, private key, RPC password or Telegram token.

The external drive uses ExFAT so it can also store ordinary family files and be
read by macOS and Windows. ExFAT does not provide strong per-file permissions or
native encryption. Keep the drive physically secure. Do not store wallet seeds,
private keys or unencrypted secret files beside the blockchain backup.

## Requirements

The host requires:

- macOS
- Bash
- `awk`
- `caffeinate`
- `cmp`
- `df`
- `mkdir`
- `mv`
- `rsync`
- `shasum`
- `sort`
- `stat`
- `sync`

The Bitcoin node VM can remain stopped. Replication reads only the completed
backup files already stored on the Mac.

## Install the command

From the repository root:

```bash
sudo install -o root -g wheel -m 0755 \
  scripts/macos-bitcoin-node-backup-replicate.sh \
  /usr/local/bin/bitcoin-node-backup-replicate
```

Verify the installed file:

```bash
ls -l /usr/local/bin/bitcoin-node-backup-replicate

/usr/local/bin/bitcoin-node-backup-replicate --help
```

## Connect and inspect the external drive

Connect the drive and verify the expected mount:

```bash
diskutil info "/Volumes/Backup_8TB" |
grep -E \
  'Volume Name|Mounted|Mount Point|File System Personality|Volume Free Space|Read-Only'
```

Expected properties include:

```text
Volume Name: Backup_8TB
Mounted: Yes
Mount Point: /Volumes/Backup_8TB
Media Read-Only: No
Volume Read-Only: No
```

Create the dedicated backup directory once if it does not exist:

```bash
mkdir -p "/Volumes/Backup_8TB/bitcoin-node-backups"
```

## Run the mandatory dry-run

Dry-run performs the full local verification and destination preflight but
does not create, change or delete any file:

```bash
/usr/local/bin/bitcoin-node-backup-replicate --dry-run
```

A new backup that is ready to copy reports messages similar to:

```text
[REPLICATION] Newest local backup verified: block=... date=... size=...GiB
[REPLICATION] External free space is sufficient: ...GiB
[REPLICATION] DRY-RUN: would replicate bitcoin-node-pruned-...tar.zst
[REPLICATION] Dry-run completed; no files were created or modified
```

If the external copy already exists and passes verification, dry-run reports:

```text
[REPLICATION] External backup is already synchronized and verified: ...
```

## Execute a replication

Only after dry-run succeeds, run:

```bash
/usr/local/bin/bitcoin-node-backup-replicate \
  --execute \
  --confirm-external-replication
```

The confirmation flag prevents accidental execution. `--execute` without it
returns exit code `1` and copies nothing.

For a 47 GiB archive, transfer and external checksum verification can take a
long time. Keep the drive connected until the command finishes. The command
uses `caffeinate` so idle sleep does not interrupt an active run.

Successful output ends with:

```text
[REPLICATION] External SHA-256 verified: ...
[REPLICATION] External replication completed successfully
[REPLICATION] Archive: /Volumes/Backup_8TB/bitcoin-node-backups/...
[REPLICATION] Checksum: /Volumes/Backup_8TB/bitcoin-node-backups/...
[REPLICATION] Manifest: /Volumes/Backup_8TB/bitcoin-node-backups/...
```

## Verify the result independently

List the newest external files:

```bash
find "/Volumes/Backup_8TB/bitcoin-node-backups" \
  -maxdepth 1 \
  -type f \
  -name 'bitcoin-node-pruned-*' \
  -print |
sort
```

Confirm there are no partial artifacts:

```bash
find "/Volumes/Backup_8TB/bitcoin-node-backups" \
  -maxdepth 1 \
  -type f \
  -name '*.partial' \
  -print
```

No output is expected from the partial-artifact check.

Run the existing freshness audit:

```bash
/usr/local/bin/bitcoin-node-backup-audit \
  --require-external
```

## Safely disconnect the drive

First leave any Terminal directory located on the drive:

```bash
cd ~
```

Then eject it:

```bash
diskutil eject /dev/disk4
```

Confirm the disk identifier with `diskutil list external` before ejecting. The
identifier can change between connections.

## Custom paths

The source and destination can be changed explicitly:

```bash
/usr/local/bin/bitcoin-node-backup-replicate \
  --dry-run \
  --source "$HOME/bitcoin-node-backups" \
  --destination "/Volumes/Backup_8TB/bitcoin-node-backups"
```

Production destinations must resolve beneath `/Volumes/` and must be on a
different filesystem from the local source.

## Failure behavior

### External drive is not mounted

The command exits with code `2`:

```text
[REPLICATION] ERROR: External backup directory does not exist: ...
```

Reconnect the correct drive and rerun dry-run.

### A `.partial` artifact exists

The command refuses to proceed. A partial file may represent an interrupted
copy and must never be renamed without verification.

Inspect it:

```bash
find "/Volumes/Backup_8TB/bitcoin-node-backups" \
  -maxdepth 1 \
  -type f \
  -name '*.partial' \
  -ls
```

Do not delete it until the failure has been understood. If a new run is needed,
verify that the partial belongs to the failed replication before removing it.

### Existing external files differ

The command refuses to overwrite them. Preserve both the local and external
evidence and compare their checksums and manifests manually.

### Transfer is interrupted

Final filenames are not published. Partial artifacts remain for inspection,
and the local source is unchanged.

### External checksum fails

The command exits with code `2` and keeps the partial artifacts. Do not trust
the external archive or rename it to its final name.

## Exit codes

- `0`: dry-run passed, replication succeeded, or the verified copy already exists
- `1`: invalid command usage or missing execution confirmation
- `2`: safety, integrity, storage or replication failure

## Relationship to other backup controls

This command copies only the newest complete local set. It does not create a
blockchain backup, remove old backups, perform a restore rehearsal or replace
the monthly deep-integrity audit.

Use:

- `macos-bitcoin-node-backup.sh` to create a new cold backup
- `macos-bitcoin-node-backup-replicate.sh` to replicate it externally
- `macos-bitcoin-node-backup-retention.sh` to report controlled local retention
- `macos-bitcoin-node-backup-audit.sh` for daily freshness checks
- `macos-bitcoin-node-backup-deep-audit.sh` for monthly deep verification

## Final replication checklist

- [ ] Correct external volume mounted
- [ ] External directory writable
- [ ] Local newest backup set complete
- [ ] Local SHA-256 passed
- [ ] Dry-run passed
- [ ] Explicit execution confirmation supplied
- [ ] Transfer completed to `.partial` files
- [ ] External SHA-256 passed
- [ ] Final archive, checksum and manifest published
- [ ] No `.partial` artifacts remain after success
- [ ] Existing backups were not overwritten or deleted
- [ ] External drive ejected safely after use
