# Bitcoin Backup Freshness Monitoring

This guide describes the read-only macOS backup audit and its state-change notifications.

The monitor checks whether local Bitcoin blockchain backups remain complete, recent and safely stored. It does not create, modify, hash, transfer, rename or delete backup files.

## What the audit checks

The audit verifies:

- The local backup directory exists and is readable
- At least two complete backup sets are present
- Every archive has a checksum sidecar and manifest
- Checksum sidecars contain a valid SHA-256 value
- Backup archives are non-empty
- Backup filenames contain valid block heights and dates
- Backup artifacts use permission mode `0600`
- No incomplete `.partial` artifacts remain
- The newest backup is not stale
- The Mac has sufficient free storage
- The newest backup has a matching external copy when the external drive is mounted

A complete backup set contains:

```text
bitcoin-node-pruned-BLOCK-DATE.tar.zst
bitcoin-node-pruned-BLOCK-DATE.tar.zst.sha256
bitcoin-node-pruned-BLOCK-DATE.manifest.txt
```

## Important safety boundary

The audit is metadata-only.

It does not calculate the SHA-256 checksum of the large archive during every daily check. Full archive integrity verification remains a separate maintenance operation:

```bash
cd ~/bitcoin-node-backups

shasum -a 256 -c \
  bitcoin-node-pruned-BLOCK-DATE.tar.zst.sha256
```

Replace `BLOCK` and `DATE` with the actual backup filename.

The audit never deletes older backups. Deletion is handled separately by the explicitly confirmed retention tool.

## Status levels

The audit reports one of three states:

- `HEALTHY` — backup requirements are satisfied
- `WARNING` — attention is recommended, but usable backup data remains
- `CRITICAL` — a required backup component or safety condition has failed

Exit codes are:

```text
0 = HEALTHY
1 = WARNING
2 = CRITICAL
```

## Default policy

The default policy is:

```text
Minimum complete local backups: 2
Stale warning:                 7 days
Critical stale age:           14 days
Free-space warning:           below 100 GiB
Free-space critical:          below 50 GiB
External drive:               optional while unmounted
```

When the external drive is mounted, the audit expects its backup directory to exist and checks whether the newest local archive, checksum and manifest are present there.

When the external drive is intentionally disconnected, the audit records an informational result instead of a warning.

## Repository files

The feature uses:

```text
scripts/macos-bitcoin-node-backup-audit.sh
scripts/macos-bitcoin-node-backup-notify.sh
launchd/com.pzhendov.bitcoin-node-backup-notify.plist
```

The audit script performs the read-only checks.

The notification wrapper records the previous state and displays a macOS notification only when the state changes.

The LaunchAgent runs the wrapper automatically once per day.

## Validate the repository files

From the repository:

```bash
cd ~/bitcoin-node-guide

bash -n scripts/macos-bitcoin-node-backup-audit.sh
bash -n scripts/macos-bitcoin-node-backup-notify.sh

shellcheck \
  scripts/macos-bitcoin-node-backup-audit.sh \
  scripts/macos-bitcoin-node-backup-notify.sh

plutil -lint \
  launchd/com.pzhendov.bitcoin-node-backup-notify.plist
```

All commands should complete successfully.

## Install the scripts

Install the audit:

```bash
sudo install -o root -g wheel -m 0755 \
  scripts/macos-bitcoin-node-backup-audit.sh \
  /usr/local/bin/bitcoin-node-backup-audit
```

Install the notification wrapper:

```bash
sudo install -o root -g wheel -m 0755 \
  scripts/macos-bitcoin-node-backup-notify.sh \
  /usr/local/bin/bitcoin-node-backup-notify
```

Verify them:

```bash
ls -l \
  /usr/local/bin/bitcoin-node-backup-audit \
  /usr/local/bin/bitcoin-node-backup-notify
```

Both files should be root-owned and executable.

## Install the LaunchAgent

Create the user LaunchAgents directory if necessary:

```bash
mkdir -p "$HOME/Library/LaunchAgents"
```

Install the plist:

```bash
install -m 0644 \
  launchd/com.pzhendov.bitcoin-node-backup-notify.plist \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-backup-notify.plist"
```

Validate the installed copy:

```bash
plutil -lint \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-backup-notify.plist"
```

Load it:

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-backup-notify.plist"
```

Enable it:

```bash
launchctl enable \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-notify"
```

Run an immediate check:

```bash
launchctl kickstart -k \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-notify"
```

If `bootstrap` reports that the service is already loaded, do not load a second copy. Use `kickstart` to run the existing service.

## Run a manual audit

Run the audit directly:

```bash
/usr/local/bin/bitcoin-node-backup-audit
```

A healthy result ends with:

```text
[SUMMARY] status=HEALTHY warnings=0 critical=0
```

Check its exit code immediately:

```bash
echo $?
```

Expected:

```text
0
```

## Test notification delivery

Display a harmless test notification:

```bash
/usr/local/bin/bitcoin-node-backup-notify --test
```

The command should return exit code `0` and macOS should display a notification.

## Inspect the LaunchAgent

Check the loaded service:

```bash
launchctl print \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-notify" |
grep -E 'state =|program =|runs =|last exit code'
```

A successful completed check normally shows:

```text
state = not running
program = /usr/local/bin/bitcoin-node-backup-notify
last exit code = 0
```

`state = not running` is normal between daily checks. The LaunchAgent starts, performs one audit and exits.

## Inspect recent results

Show recent log entries:

```bash
tail -n 20 \
  "$HOME/Library/Logs/bitcoin-backup-audit-notify.log"
```

The state file is stored at:

```text
~/Library/Application Support/bitcoin-node-guide/backup-audit-last-state
```

The first healthy execution records the initial state silently. Later notifications are displayed only when the state changes, for example:

```text
HEALTHY -> WARNING
WARNING -> HEALTHY
HEALTHY -> CRITICAL
CRITICAL -> HEALTHY
```

This prevents duplicate daily notifications when nothing has changed.

## Override audit thresholds

The audit supports explicit policy overrides:

```bash
/usr/local/bin/bitcoin-node-backup-audit \
  --local-directory "$HOME/bitcoin-node-backups" \
  --external-directory "/Volumes/Backup_8TB/bitcoin-node-backups" \
  --stale-days 7 \
  --critical-days 14 \
  --minimum-backups 2 \
  --warning-free-gib 100 \
  --critical-free-gib 50
```

To require the external drive during a manual audit:

```bash
/usr/local/bin/bitcoin-node-backup-audit \
  --require-external
```

This produces a warning when the external drive is not mounted.

## Disable the LaunchAgent

Disable and unload it:

```bash
launchctl disable \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-notify"

launchctl bootout \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-notify"
```

This stops automatic auditing but does not remove backups, scripts or logs.

## Re-enable the LaunchAgent

Load and enable it again:

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-backup-notify.plist"

launchctl enable \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-notify"
```

Run it immediately:

```bash
launchctl kickstart -k \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-notify"
```

## Troubleshooting

### The service is not found

If `launchctl print` reports that the service cannot be found, load the plist again with `launchctl bootstrap`.

### The LaunchAgent exits with a non-zero status

Run the audit directly:

```bash
/usr/local/bin/bitcoin-node-backup-audit

echo $?
```

Then inspect the notification log:

```bash
tail -n 30 \
  "$HOME/Library/Logs/bitcoin-backup-audit-notify.log"
```

### The external drive is disconnected

This is informational by default. Connect the drive when you want the audit to compare the newest local backup with its external copy.

### A backup is stale

Create a new verified cold backup using the documented automation. Do not delete either existing recovery point before the new archive, checksum and manifest have all been created and verified.

### A partial artifact is reported

A `.partial` file indicates an interrupted or incomplete operation. Inspect it manually. Do not rename it into a final backup archive unless the complete integrity and checksum procedure has passed.

## Security

The audit handles only public pruned blockchain backup data and metadata.

Never place any of the following in the backup directory or repository:

- Wallet files
- Private keys
- Seed phrases
- RPC passwords
- Bitcoin authentication cookies
- Telegram bot tokens
- Telegram chat IDs

The audit does not replace full checksum verification, restore rehearsals, off-device copies or normal Bitcoin node monitoring.

## Tested behavior

The implementation was tested for:

- Healthy local backup inventory
- Warning when fewer than two complete sets are present
- Critical failure when the local directory is missing
- State-change notification delivery
- Recovery notification delivery
- Duplicate-notification suppression
- Daily LaunchAgent execution
- Valid Bash syntax
- ShellCheck compliance
- Valid LaunchAgent property-list syntax
- CI fixtures that use only temporary test files

No real backup archives are changed or deleted by these tests.
