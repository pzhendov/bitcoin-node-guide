# Safe blockchain backup automation

This guide documents the tested automation for creating a cold backup of the
pruned Bitcoin blockchain from a Multipass VM on macOS.

The automation complements the manual procedure in
[blockchain-backup-restore.md](blockchain-backup-restore.md). Read that guide
before using the scripts, especially its security boundary, restore procedure
and limitations.

## Security boundary

This is not a wallet backup.

The archive contains only:

```text
blocks/
chainstate/
```

It does not contain wallets, private keys, seed phrases, `wallet.dat`, the RPC
cookie, `bitcoin.conf`, Telegram credentials or other authentication material.
The archived blockchain data is public and cannot authorize Bitcoin spending.

## Components

The automation uses two scripts:

- `scripts/macos-bitcoin-node-backup.sh` coordinates validation, execution,
  transfer, Mac-side checksum verification, artifact finalization and cleanup.
- `scripts/bitcoin-node-backup-create.sh` runs as root inside the VM, pauses
  monitoring, stops Bitcoin Core cleanly, creates the archive, verifies it and
  restores production services.

The Mac coordinator transfers the VM helper from the checked-out repository,
verifies its SHA-256 checksum after transfer and installs it as:

```text
/usr/local/bin/bitcoin-node-backup-create
```

## Safety properties

Before execution, the coordinator requires all of the following:

- The destination directory exists and is writable.
- The named Multipass VM exists and is running.
- Required host and VM tools are available.
- `bitcoind.service` is active.
- Both monitoring timers are active.
- Blocks equal headers.
- Initial block download is complete.
- The node is pruned.
- Bitcoin Core reports no warnings.
- At least one peer is connected.
- Bitcoin time offset is no more than 60 seconds.
- Chrony reports `Leap status: Normal`.
- The VM and destination have sufficient free space.
- No output artifact with the planned name already exists.
- The caller supplies the explicit cold-backup confirmation flag.

Both scripts use non-blocking locks to prevent overlapping backup operations.
The VM helper records an in-progress state marker so a later run can recognize
an interrupted operation and restore Bitcoin Core and the monitoring timers.

On failure, the scripts attempt to:

- Remove incomplete Mac-side artifacts.
- Remove an incomplete VM archive created by the active helper run.
- Restart Bitcoin Core.
- Restart the health and clock-recovery timers.
- Restore the macOS notification monitor if it was previously loaded.

A verified VM archive is retained if a later host transfer or verification step
fails, allowing an operator to inspect it before deciding whether to remove it.

## Validate the scripts

From the repository root:

```bash
bash -n scripts/bitcoin-node-backup-create.sh
bash -n scripts/macos-bitcoin-node-backup.sh

shellcheck \
  scripts/bitcoin-node-backup-create.sh \
  scripts/macos-bitcoin-node-backup.sh

git diff --check
```

All commands must return exit code `0` before running a backup.

## Run the read-only preflight

The dry-run performs validation but does not stop services or create, transfer,
rename or delete backup files:

```bash
./scripts/macos-bitcoin-node-backup.sh --dry-run
```

The final output should include:

```text
[BACKUP] Read-only preflight stage passed
[BACKUP] No services were stopped and no backup files were created
```

## Run a real cold backup

Keep the Mac connected to power with its lid open. The coordinator invokes
`caffeinate` during long archive and transfer operations.

Run:

```bash
./scripts/macos-bitcoin-node-backup.sh \
  --execute \
  --confirm-cold-backup
```

The confirmation option is deliberately required because execution temporarily
stops Bitcoin Core and creates a large archive.

The workflow is:

1. Re-run all preflight checks.
2. Verify and install the VM-side helper.
3. Pause the macOS notification monitor when it is loaded.
4. Pause both VM monitoring timers.
5. Stop Bitcoin Core and confirm `Shutdown done` in `debug.log`.
6. Archive `blocks/` and `chainstate/` with `tar` and `zstd`.
7. Test the compressed archive and calculate its VM-side SHA-256 checksum.
8. Restart Bitcoin Core and both VM timers.
9. Transfer the verified archive to a `.partial` file on macOS.
10. Calculate the Mac-side SHA-256 checksum and require an exact match.
11. Create the checksum file and manifest as temporary files.
12. Protect all artifacts with mode `0600` and finalize their names.
13. Remove the temporary archive from the VM.
14. Confirm the required VM services are active.
15. Restore the macOS notification monitor.

Do not interrupt the Terminal while the archive is being created or
transferred. Limited output during these stages is normal.

## Output artifacts

The default destination is:

```text
~/bitcoin-node-backups
```

Each completed backup contains:

```text
bitcoin-node-pruned-HEIGHT-YYYY-MM-DD.tar.zst
bitcoin-node-pruned-HEIGHT-YYYY-MM-DD.tar.zst.sha256
bitcoin-node-pruned-HEIGHT-YYYY-MM-DD.manifest.txt
```

All three files are created with mode `0600`.

Change the destination when required:

```bash
./scripts/macos-bitcoin-node-backup.sh \
  --dry-run \
  --destination /path/to/private/backup-directory
```

Always run a dry-run against a new destination before execution.

## Verify a completed backup

Enter the backup directory and verify the checksum file:

```bash
cd ~/bitcoin-node-backups

shasum -a 256 -c \
  bitcoin-node-pruned-HEIGHT-YYYY-MM-DD.tar.zst.sha256
```

Expected:

```text
bitcoin-node-pruned-HEIGHT-YYYY-MM-DD.tar.zst: OK
```

Check for unfinished host artifacts:

```bash
find ~/bitcoin-node-backups \
  -maxdepth 1 \
  -name '*.partial' \
  -print
```

Check for unfinished VM archives:

```bash
multipass exec -n bitcoin-node -- \
  find /home/ubuntu \
    -maxdepth 1 \
    -name 'bitcoin-node-pruned-*.tar.zst.partial' \
    -print
```

Both commands should produce no output after a successful run.

## Verify production recovery

After every backup:

```bash
multipass exec -n bitcoin-node -- systemctl is-active bitcoind
multipass exec -n bitcoin-node -- systemctl is-active bitcoin-node-health.timer
multipass exec -n bitcoin-node -- systemctl is-active bitcoin-node-clock-recovery.timer
multipass exec -n bitcoin-node -- bitcoin-cli -getinfo
```

Require:

- All three units are active.
- Blocks equal headers after the node catches up.
- Verification progress is 100%.
- Time offset is near zero.
- Peers are connected.
- Warnings are empty.

## Tested execution

The complete automation was tested successfully on 14 August 2026.

The test:

- Backed up block and header height `962373`.
- Archived approximately 64.1 GiB of pruned validation data.
- Produced an approximately 47 GiB compressed archive.
- Tested 68,806,123,520 decoded bytes with `zstd`.
- Matched the VM-side and Mac-side SHA-256 checksum:
  `560aaffd6285ade6850835902f16e6ef45a1188d802c18c40dc08ab3fd43e03d`.
- Removed all `.partial` files.
- Removed the temporary VM archive.
- Restored Bitcoin Core and both monitoring timers.
- Restored the macOS notification monitor.
- Returned exit code `0`.
- Returned the node to 100% synchronization with ten peers, zero-second time
  offset and no warnings.

The recorded checksum proves the tested archive's identity. It is included as
test evidence, not as the expected checksum for future backups.

## Exit codes

- `0`: dry-run passed or backup completed successfully.
- `1`: invalid command usage or missing confirmation.
- `2`: preflight, backup, verification, transfer, cleanup or recovery failure.

If execution returns `2`, do not immediately rerun it. First inspect:

```bash
multipass exec -n bitcoin-node -- systemctl is-active bitcoind
multipass exec -n bitcoin-node -- systemctl is-active bitcoin-node-health.timer
multipass exec -n bitcoin-node -- systemctl is-active bitcoin-node-clock-recovery.timer

find ~/bitcoin-node-backups -maxdepth 1 -name '*.partial' -print

multipass exec -n bitcoin-node -- \
  find /home/ubuntu \
    -maxdepth 1 \
    -name 'bitcoin-node-pruned-*.tar.zst.partial' \
    -print
```

Preserve the error output until the recovery state is understood.

## Limitations

- This automation backs up blockchain validation data, not wallet secrets.
- A backup becomes stale as new blocks arrive.
- The node is offline while the VM archive is created.
- Temporary free space is required inside the VM and at the destination.
- A backup on the same Mac does not protect against Mac loss or disk failure.
- The archive still requires a compatible Bitcoin Core installation,
  configuration and services during restoration.
- A restore is not complete until the restored node catches up and passes all
  health checks.

Keep at least one separately verified copy on another physical device when
practical.
