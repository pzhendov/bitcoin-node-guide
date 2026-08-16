# Pruned blockchain backup and restore

This runbook creates and restores a cold backup of Bitcoin Core’s pruned blockchain validation data.

The procedure was tested on an Apple Silicon Mac using Multipass, Ubuntu ARM64 and Bitcoin Core 31.1.

## Important security boundary

This is not a wallet backup.

The archive contains only:

```text
blocks/
chainstate/
```

It explicitly excludes:

- Wallets
- Private keys
- Seed phrases
- `wallet.dat`
- `.cookie`
- `bitcoin.conf`
- RPC credentials
- Telegram credentials
- Logs
- Peer data
- systemd configuration
- Chrony configuration

The blockchain data is public. Restoring it can reduce recovery time, but it cannot recover bitcoin or authorize transactions.

## Why use a cold backup?

Bitcoin Core updates `blocks/` and `chainstate/` together.

Copying these directories while Bitcoin Core is writing to them can create an inconsistent backup. This procedure stops Bitcoin Core cleanly and requires the log to end with:

```text
Shutdown done
```

Bitcoin Core remains stopped until the archive has been created.

## Tested result

The tested backup contained:

- Bitcoin Core 31.1 validation data
- Block height: 962141
- Header height: 962141
- Best block hash: `00000000000000000000b8f8c9ce662619f05211df6671e6433387fe942c828d`
- Initial block download: false
- Pruned: true
- Prune height: 933554
- Bitcoin-reported data size: 52,371,284,486 bytes
- `blocks/`: approximately 49 GiB
- `chainstate/`: approximately 16 GiB
- Compressed archive: 50,433,087,046 bytes
- Decoded archive: 68,809,134,080 bytes
- Archive members: 1,212

The restored node started near the backed-up height, caught up to the network in minutes, reached 100% verification and survived a complete VM stop/start test.

## Storage requirements

The tested backup required temporary free space in two locations:

- Approximately 47 GiB inside the source VM
- Approximately 47 GiB on the Mac

The restored data required approximately 65 GiB in the test VM.

Check space before starting:

```bash
multipass info bitcoin-node
multipass exec -n bitcoin-node -- df -h /
df -h ~
```

Allow additional free space for Bitcoin growth and temporary files.

## Create a private backup directory

On the Mac:

```bash
mkdir -m 700 ~/bitcoin-node-backups
ls -ld ~/bitcoin-node-backups
```

Expected permissions begin with:

```text
drwx------
```

Keep this directory outside the Git repository.

## Record the healthy baseline

Run:

```bash
multipass exec -n bitcoin-node -- bitcoin-cli getblockchaininfo |
jq '{
  blocks,
  headers,
  bestblockhash,
  verificationprogress,
  initialblockdownload,
  pruned,
  pruneheight,
  size_on_disk
}'
```

Do not start a backup unless:

- Blocks equal headers
- Verification progress is 100%
- Initial block download is false
- Pruning has the expected value
- Bitcoin warnings are empty
- The VM clock is correct

Record this output in the backup manifest.

## Pause automated monitoring

Pause the VM timers:

```bash
multipass exec -n bitcoin-node -- sudo systemctl stop \
  bitcoin-node-health.timer \
  bitcoin-node-clock-recovery.timer
```

Confirm that they are inactive but still enabled:

```bash
multipass exec -n bitcoin-node -- systemctl is-active \
  bitcoin-node-health.timer \
  bitcoin-node-clock-recovery.timer

multipass exec -n bitcoin-node -- systemctl is-enabled \
  bitcoin-node-health.timer \
  bitcoin-node-clock-recovery.timer
```

Expected:

```text
inactive
inactive
enabled
enabled
```

Pause the macOS notification monitor:

```bash
launchctl bootout \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify"
```

A nonzero lookup result afterward means the service is no longer loaded:

```bash
launchctl print \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify" \
  >/dev/null 2>&1

echo $?
```

The plist remains installed and can be loaded again later.

## Stop Bitcoin Core cleanly

Run:

```bash
multipass exec -n bitcoin-node -- sudo systemctl stop bitcoind
multipass exec -n bitcoin-node -- systemctl is-active bitcoind
multipass exec -n bitcoin-node -- tail -n 5 \
  /home/ubuntu/.bitcoin/debug.log
```

Required results:

```text
inactive
Shutdown done
```

Do not continue if shutdown did not complete cleanly.

## Create the archive inside the VM

Do not stream a very large archive directly through:

```text
multipass exec ... > backup.tar.zst
```

During testing, a large streamed archive was silently truncated even though the remote compression command returned exit code `0`. The incomplete archive later failed with:

```text
premature end
```

Instead, create a real archive file inside the VM, test it there and then transfer it.

The tested archive name was:

```text
bitcoin-node-pruned-962141-2026-08-12.tar.zst
```

Use a `.partial` suffix until all verification succeeds:

```bash
multipass exec -n bitcoin-node -- sudo bash -o pipefail -c \
  'tar --numeric-owner -C /home/ubuntu/.bitcoin -cf - blocks chainstate |
   zstd -T0 -3 -o /home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial'

echo $?
```

The exit code must be `0`.

Show the result:

```bash
multipass exec -n bitcoin-node -- ls -lh \
  /home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial
```

## Test compressed-data integrity

Inside the VM:

```bash
multipass exec -n bitcoin-node -- sudo zstd --test \
  /home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial

echo $?
```

The exit code must be `0`.

## Calculate the VM-side checksum

Run:

```bash
multipass exec -n bitcoin-node -- sudo sha256sum \
  /home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial
```

Record the checksum.

The tested checksum was:

```text
2be4e2f79b8c44eea3b505f194a7ba99c89afdb91ed9989465c41dc37af8cc10
```

## Transfer the verified archive

Transfer the tested VM archive to a Mac `.partial` file:

```bash
multipass transfer \
  bitcoin-node:/home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial
```

Protect it:

```bash
chmod 600 \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial
```

Calculate the Mac-side checksum:

```bash
shasum -a 256 \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial
```

The Mac and VM checksums must match exactly.

## Finalize the archive

Only after the checksums match:

```bash
mv \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst
```

## Create the checksum file

Create:

```bash
nano ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst.sha256
```

Add:

```text
2be4e2f79b8c44eea3b505f194a7ba99c89afdb91ed9989465c41dc37af8cc10  bitcoin-node-pruned-962141-2026-08-12.tar.zst
```

Protect and verify it:

```bash
chmod 600 \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst.sha256

cd ~/bitcoin-node-backups

shasum -a 256 -c \
  bitcoin-node-pruned-962141-2026-08-12.tar.zst.sha256
```

Expected:

```text
bitcoin-node-pruned-962141-2026-08-12.tar.zst: OK
```

## Create a backup manifest

Create a private manifest beside the archive containing:

- Archive filename
- Checksum filename
- Creation time
- Compressed and decoded sizes
- SHA-256 checksum
- Source environment
- Bitcoin Core version
- Block and header heights
- Best block hash
- Initial block download state
- Pruning state and prune height
- Included paths
- Explicitly excluded paths
- Creation and verification method
- Restore requirements

Protect it:

```bash
chmod 600 \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.manifest.txt
```

## Remove temporary files

After the Mac checksum matches and the final archive exists, remove the temporary VM archive:

```bash
multipass exec -n bitcoin-node -- sudo rm -- \
  /home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst.partial
```

Do not delete the final Mac archive, checksum or manifest.

## Restore production services

Start Bitcoin and both timers:

```bash
multipass exec -n bitcoin-node -- sudo systemctl start bitcoind

multipass exec -n bitcoin-node -- sudo systemctl start \
  bitcoin-node-health.timer \
  bitcoin-node-clock-recovery.timer
```

Reload the macOS LaunchAgent:

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-health-notify.plist"

launchctl enable \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify"

launchctl kickstart -k \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify"
```

Verify production:

```bash
multipass exec -n bitcoin-node -- systemctl is-active \
  bitcoind \
  bitcoin-node-health.timer \
  bitcoin-node-clock-recovery.timer

multipass exec -n bitcoin-node -- bitcoin-cli -getinfo
multipass exec -n bitcoin-node -- chronyc -N tracking
```

## Restore rehearsal

A backup should not be trusted until it has been restored successfully.

The tested disposable VM used:

- Name: `bitcoin-backup-test`
- Ubuntu 26.04 LTS ARM64
- 4 virtual CPUs
- 6 GiB memory
- 150 GiB disk

Create it:

```bash
multipass launch 26.04 \
  --name bitcoin-backup-test \
  --cpus 4 \
  --memory 6G \
  --disk 150G
```

Verify initialization:

```bash
multipass exec -n bitcoin-backup-test -- cloud-init status --wait --long
multipass exec -n bitcoin-backup-test -- uname -m
multipass exec -n bitcoin-backup-test -- date -u
date -u
```

## Transfer and verify the restore archive

Transfer the archive and checksum:

```bash
multipass transfer \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst \
  bitcoin-backup-test:/home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst

multipass transfer \
  ~/bitcoin-node-backups/bitcoin-node-pruned-962141-2026-08-12.tar.zst.sha256 \
  bitcoin-backup-test:/home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst.sha256
```

Verify inside the VM:

```bash
multipass exec -n bitcoin-backup-test -- \
  bash -c 'cd /home/ubuntu &&
    sha256sum --check bitcoin-node-pruned-962141-2026-08-12.tar.zst.sha256'
```

Expected:

```text
bitcoin-node-pruned-962141-2026-08-12.tar.zst: OK
```

## Inspect archive paths before extraction

Reject absolute paths, traversal paths and unexpected top-level content:

```bash
multipass exec -n bitcoin-backup-test -- sudo bash -o pipefail -c '
  zstd -dc /home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst |
  tar -tf - |
  awk '\''
    BEGIN { bad = 0 }
    {
      count++
      if ($0 ~ /^\// ||
          $0 ~ /(^|\/)\.\.(\/|$)/ ||
          $0 !~ /^(blocks|chainstate)(\/|$)/) {
        print "UNSAFE_MEMBER:", $0
        bad = 1
      }
      split($0, part, "/")
      top[part[1]] = 1
    }
    END {
      for (name in top) print "top_level=" name
      print "member_count=" count
      exit bad
    }
  '\''
'

echo $?
```

The tested archive returned:

```text
top_level=chainstate
top_level=blocks
member_count=1212
```

The exit code was `0`.

## Extract the archive

Confirm that the destination does not already exist:

```bash
multipass exec -n bitcoin-backup-test -- \
  ls -la /home/ubuntu/.bitcoin
```

Create it:

```bash
multipass exec -n bitcoin-backup-test -- sudo install \
  -d -o ubuntu -g ubuntu -m 0700 \
  /home/ubuntu/.bitcoin
```

Extract:

```bash
multipass exec -n bitcoin-backup-test -- sudo bash -o pipefail -c \
  'zstd -dc /home/ubuntu/bitcoin-node-pruned-962141-2026-08-12.tar.zst |
   tar --numeric-owner -xpf - -C /home/ubuntu/.bitcoin'

echo $?
```

The exit code must be `0`.

Set explicit ownership and permissions:

```bash
multipass exec -n bitcoin-backup-test -- sudo chown -R \
  ubuntu:ubuntu \
  /home/ubuntu/.bitcoin

multipass exec -n bitcoin-backup-test -- sudo chmod 700 \
  /home/ubuntu/.bitcoin
```

Verify restored sizes:

```bash
multipass exec -n bitcoin-backup-test -- sudo du -sh \
  /home/ubuntu/.bitcoin/blocks \
  /home/ubuntu/.bitcoin/chainstate
```

## Restore software separately

Bitcoin Core binaries, configuration and systemd units are intentionally not stored in the blockchain archive.

Install a compatible, cryptographically verified Bitcoin Core release by following the main installation or disaster-recovery runbook.

Restore:

```text
bitcoin.conf
bitcoind.service
Chrony configuration
health monitoring
alerting credentials
```

as separate recovery dependencies.

Never place wallet seeds, private keys, RPC cookies or Telegram credentials inside this blockchain archive.

## Start the restored node

After verified Bitcoin Core binaries and configuration are installed:

```bash
sudo systemctl daemon-reload
sudo systemctl enable bitcoind
sudo systemctl start bitcoind
```

Check:

```bash
bitcoin-cli -getinfo
```

The restored test node started near the backup height instead of block zero and caught up in minutes.

Final tested state:

```text
Blocks: 962150
Headers: 962150
Verification progress: 100%
Initial block download: false
Pruned: true
Prune height: 933554
Time offset: 0
Warnings: none
```

## Test automatic startup

Stop Bitcoin cleanly:

```bash
sudo systemctl stop bitcoind
systemctl is-active bitcoind
tail -n 5 ~/.bitcoin/debug.log
```

Require:

```text
inactive
Shutdown done
```

Restart the VM:

```bash
multipass stop bitcoin-backup-test
multipass start --timeout 120 bitcoin-backup-test
```

Verify:

```bash
multipass exec -n bitcoin-backup-test -- systemctl is-active bitcoind
multipass exec -n bitcoin-backup-test -- bitcoin-cli -getinfo
multipass exec -n bitcoin-backup-test -- chronyc -N tracking
```

The tested node returned active, synchronized, connected and warning-free after restart.

## Backup limitations

This backup becomes older with time. A restored node must download and validate every block created after the backup height.

A pruned backup does not provide historical blocks below its prune height.

This archive does not replace:

- A wallet backup
- Seed-phrase recovery
- Bitcoin Core release verification
- Configuration backup
- Alert credential backup
- Off-site disaster recovery

A backup stored only on the same Mac is vulnerable to disk failure, loss, theft and filesystem damage.

Keep at least one additional verified copy on a separate encrypted device. Recheck its SHA-256 checksum periodically.

## Tested automated restore rehearsal

A complete restore rehearsal was successfully performed on 16 August 2026 using a cold backup created by the automated backup workflow on 14 August 2026.

### Backup evidence

- Source node: pruned Bitcoin Core 31.1 mainnet node
- Backup block height: `962373`
- Archive format: Zstandard-compressed tar archive
- Archive size: approximately 47 GiB
- Archive contents: `blocks/` and `chainstate/` only
- SHA-256: `560aaffd6285ade6850835902f16e6ef45a1188d802c18c40dc08ab3fd43e03d`
- Mac-side checksum verification: passed
- External-drive checksum verification: passed

### Restore environment

The archive was restored into a fresh disposable Multipass VM named `bitcoin-backup-test` with:

- Ubuntu 26.04 LTS ARM64
- 4 virtual CPU cores
- 6 GiB memory
- 150 GB virtual disk
- Bitcoin Core 31.1 installed from a checksum-verified and signature-verified official release

The Bitcoin configuration and systemd service were restored separately from the tagged repository. No wallet, seed phrase, private key, RPC password or Telegram credential was copied into the test VM.

### Restore validation

Before extraction:

- The transferred archive passed SHA-256 verification.
- The archive paths were inspected.
- The only top-level archive entries were `blocks/` and `chainstate/`.

After extraction, Bitcoin Core loaded the restored block index and resumed synchronization from the backup height.

The restored node then reached:

```text
Blocks: 962780
Headers: 962780
Verification progress: 100.0000%
Initial block download: false
Pruned: true
Prune height: 934218
Size on disk: approximately 48.74 GiB
Network connections: 10
Time offset: -1 second
Warnings: none
```

The restored node also passed a clean stop and automatic-start test:

- `bitcoind.service` was enabled.
- Bitcoin Core shut down cleanly with `Shutdown done`.
- The disposable VM was stopped and started again.
- `bitcoind.service` started automatically.
- The restored node returned to 100% synchronization with no warnings.

### Rehearsal cleanup

After successful validation:

- Bitcoin Core in the disposable VM was stopped cleanly.
- The production VM was restarted and verified healthy.
- Production health and clock-recovery timers were active.
- Chrony reported `Leap status: Normal`.
- The macOS notification monitor was restored and exited successfully.
- The disposable restore VM was permanently removed.

This rehearsal demonstrates that the automated cold-backup archive is usable for recovery and not merely present or checksum-valid. Future backups should still be tested periodically because software versions, operating-system images and recovery procedures can change.

---

## Final backup checklist

- [ ] Production node fully synchronized before backup
- [ ] Time offset near zero
- [ ] Monitoring paused
- [ ] Bitcoin Core cleanly stopped
- [ ] `Shutdown done` confirmed
- [ ] Archive created inside the VM
- [ ] Archive contains only `blocks/` and `chainstate/`
- [ ] `zstd --test` passed
- [ ] VM-side SHA-256 recorded
- [ ] Mac-side SHA-256 matched
- [ ] Archive renamed only after verification
- [ ] Checksum sidecar created
- [ ] Manifest created
- [ ] Files protected with mode `0600`
- [ ] Temporary files removed
- [ ] Production services restored
- [ ] Production node returned healthy
- [ ] Disposable restore VM created
- [ ] Restore checksum passed
- [ ] Archive paths inspected safely
- [ ] Restored node reached 100%
- [ ] Restored node passed stop/start testing
- [ ] Additional encrypted off-device copy planned
