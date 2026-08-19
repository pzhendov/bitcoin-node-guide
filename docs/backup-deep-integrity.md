# Deep Bitcoin Backup Integrity Verification

This guide describes the monthly deep-integrity audit for Bitcoin blockchain backups stored on macOS.

The audit recalculates each archive’s SHA-256 checksum and tests the complete Zstandard stream. It is designed to detect silent corruption that metadata-only freshness checks cannot detect.

## Why this is separate from daily monitoring

The daily backup freshness monitor checks:

- Backup files exist
- Backup sets are complete
- Filenames and dates are valid
- Files have safe permissions
- The newest backup is recent
- Free disk space is sufficient
- The newest external copy exists when the drive is mounted

Those checks are fast because they do not read the complete 47 GB archives.

The deep audit reads every byte of each selected archive twice:

1. Once to recalculate SHA-256
2. Once to run `zstd --test`

This work is intentionally scheduled monthly instead of daily.

## Safety boundary

The deep audit never modifies or deletes:

- Backup archives
- Checksum sidecars
- Backup manifests
- Bitcoin Core data
- Wallet data
- Multipass virtual machines

Successful verification receipts are written separately under:

```text
~/Library/Application Support/bitcoin-node-guide/deep-integrity/
```

The receipts record when an archive passed both checks.

## Status levels

The audit reports:

```text
HEALTHY
WARNING
CRITICAL
```

Exit codes are:

```text
0 = HEALTHY
1 = WARNING
2 = CRITICAL
```

A checksum mismatch or failed Zstandard test is always `CRITICAL`.

## Repository files

The feature uses:

```text
scripts/macos-bitcoin-node-backup-deep-audit.sh
scripts/macos-bitcoin-node-backup-deep-notify.sh
launchd/com.pzhendov.bitcoin-node-backup-deep-notify.plist
```

The audit script performs integrity verification.

The notification wrapper prevents idle sleep while verification runs and sends a macOS notification only when the result changes.

The LaunchAgent schedules the audit monthly.

## Required macOS tools

The audit requires:

```text
awk
date
mkdir
mktemp
mv
shasum
sort
stat
zstd
```

macOS includes all required tools except `zstd`.

Install Zstandard through Homebrew:

```bash
brew install zstd
```

Verify it:

```bash
command -v zstd
zstd --version
```

On Apple Silicon, Homebrew normally installs it at:

```text
/opt/homebrew/bin/zstd
```

The script discovers `zstd` through the current command path, allowing it to work on both Apple Silicon and Intel macOS environments.

## Validate repository files

From the repository:

```bash
cd ~/bitcoin-node-guide

bash -n \
  scripts/macos-bitcoin-node-backup-deep-audit.sh

bash -n \
  scripts/macos-bitcoin-node-backup-deep-notify.sh

shellcheck \
  scripts/macos-bitcoin-node-backup-deep-audit.sh \
  scripts/macos-bitcoin-node-backup-deep-notify.sh

plutil -lint \
  launchd/com.pzhendov.bitcoin-node-backup-deep-notify.plist
```

All commands should complete successfully.

## Install the scripts

Install the deep audit:

```bash
sudo install -o root -g wheel -m 0755 \
  scripts/macos-bitcoin-node-backup-deep-audit.sh \
  /usr/local/bin/bitcoin-node-backup-deep-audit
```

Install the notification wrapper:

```bash
sudo install -o root -g wheel -m 0755 \
  scripts/macos-bitcoin-node-backup-deep-notify.sh \
  /usr/local/bin/bitcoin-node-backup-deep-notify
```

Verify ownership and permissions:

```bash
ls -l \
  /usr/local/bin/bitcoin-node-backup-deep-audit \
  /usr/local/bin/bitcoin-node-backup-deep-notify
```

Both files should be owned by `root:wheel` and executable.

## Run a metadata-only dry run

A dry run checks the inventory and plans the verification without reading archive contents:

```bash
/usr/local/bin/bitcoin-node-backup-deep-audit \
  --dry-run
```

A healthy two-backup inventory ends with output similar to:

```text
[SUMMARY] status=HEALTHY mode=DRY_RUN verified=0 planned=2 warnings=0 critical=0
```

Check the exit code immediately:

```bash
echo $?
```

Expected:

```text
0
```

## Verify only the newest backup

For a shorter controlled test:

```bash
/usr/bin/caffeinate -i \
  /usr/local/bin/bitcoin-node-backup-deep-audit \
    --newest-only
```

This performs both SHA-256 and Zstandard verification on the newest local backup.

The archive remains unchanged.

## Verify all retained local backups

Run the complete audit:

```bash
/usr/bin/caffeinate -i \
  /usr/local/bin/bitcoin-node-backup-deep-audit
```

With two approximately 47 GB archives, this reads approximately 188 GB:

```text
47 GB × 2 checks × 2 backups ≈ 188 GB
```

Runtime depends on storage speed and system load.

Keep the Mac:

- Connected to power
- Awake
- With its lid open
- Connected to the backup storage

The wrapper and documented command use `caffeinate -i` to prevent idle sleep during execution.

## External-copy behavior

The external backup directory defaults to:

```text
/Volumes/Backup_8TB/bitcoin-node-backups
```

When the drive is disconnected, external verification is skipped with an informational result.

When the directory is mounted, the audit deeply verifies the newest external archive and compares its recorded checksum with the trusted newest local checksum.

To require the external drive:

```bash
/usr/local/bin/bitcoin-node-backup-deep-audit \
  --require-external
```

A disconnected required external drive produces a warning.

## Verification receipts

After successful verification, receipts are stored under:

```text
~/Library/Application Support/bitcoin-node-guide/deep-integrity/
```

List them:

```bash
find \
  "$HOME/Library/Application Support/bitcoin-node-guide/deep-integrity" \
  -maxdepth 1 \
  -type f \
  -name '*.deep-integrity.txt' \
  -print
```

Inspect a receipt:

```bash
cat \
  "$HOME/Library/Application Support/bitcoin-node-guide/deep-integrity/RECEIPT_NAME"
```

A successful receipt contains:

```text
verification_status=HEALTHY
verified_at_utc=...
location=local
archive_name=...
archive_size_bytes=...
sha256=...
sha256_check=passed
zstd_test=passed
```

Receipts use permission mode `0600`.

A receipt proves that an archive passed at the recorded time. It does not guarantee that the file cannot become corrupted later, which is why verification is repeated monthly.

## Install the monthly LaunchAgent

Create the user LaunchAgents directory if needed:

```bash
mkdir -p "$HOME/Library/LaunchAgents"
```

Install the plist:

```bash
install -m 0644 \
  launchd/com.pzhendov.bitcoin-node-backup-deep-notify.plist \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-backup-deep-notify.plist"
```

Validate the installed copy:

```bash
plutil -lint \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-backup-deep-notify.plist"
```

Load it:

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-backup-deep-notify.plist"
```

Enable it:

```bash
launchctl enable \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-deep-notify"
```

The schedule is:

```text
First day of every month at 09:00
```

The plist intentionally does not use `RunAtLoad`, preventing an unexpected 188 GB scan immediately after installation.

## Inspect the monthly LaunchAgent

```bash
launchctl print \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-deep-notify" |
grep -E 'state =|program =|runs =|last exit code|event triggers|Day|Hour|Minute'
```

Before the first scheduled execution, normal output includes:

```text
state = not running
runs = 0
last exit code = (never exited)
Day = 1
Hour = 9
Minute = 0
```

`state = not running` is normal between monthly executions.

## Test notification delivery

This does not scan backups:

```bash
/usr/local/bin/bitcoin-node-backup-deep-notify \
  --test
```

Expected exit code:

```text
0
```

## Notification behavior

Notifications are displayed only when the audit state changes:

```text
HEALTHY -> WARNING
HEALTHY -> CRITICAL
WARNING -> HEALTHY
CRITICAL -> HEALTHY
```

Repeated audits in the same state do not create duplicate notifications.

The first healthy result is recorded silently.

## Logs and state

Notification log:

```text
~/Library/Logs/bitcoin-backup-deep-audit-notify.log
```

Show recent entries:

```bash
tail -n 30 \
  "$HOME/Library/Logs/bitcoin-backup-deep-audit-notify.log"
```

State file:

```text
~/Library/Application Support/bitcoin-node-guide/backup-deep-audit-last-state
```

## Disable the schedule

Disable and unload the monthly job:

```bash
launchctl disable \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-deep-notify"

launchctl bootout \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-deep-notify"
```

This does not remove scripts, receipts, logs or backup files.

## Re-enable the schedule

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-backup-deep-notify.plist"

launchctl enable \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-backup-deep-notify"
```

Do not use `kickstart` unless you intentionally want to begin a complete deep audit immediately.

## Interrupted audits

If the Mac shuts down, loses power or the process is interrupted:

- Backup archives remain unchanged
- No successful receipt is written for the interrupted archive
- Run the audit again when the Mac is stable
- Keep the Mac connected to power with the lid open

The audit does not resume halfway through an archive because both checks must read the complete file to be trusted.

## Checksum mismatch

A checksum mismatch means the archive no longer matches its saved SHA-256 value.

Do not:

- Rename the archive
- Replace its checksum with a newly calculated value
- Delete another known-good backup
- Treat the affected archive as a valid recovery point

Preserve the evidence, verify another retained backup and create a new cold backup if necessary.

## Zstandard test failure

A Zstandard failure means the compressed stream cannot be fully decoded.

Even if SHA-256 matches its current sidecar, the archive is not a valid recovery point unless `zstd --test` succeeds.

## Security

The deep audit processes only public pruned blockchain backup data.

Never include:

- Wallet files
- Private keys
- Seed phrases
- RPC passwords
- Bitcoin authentication cookies
- Telegram tokens
- Telegram chat IDs

The audit does not upload backup information or contact external services.

## Tested behavior

The implementation was tested for:

- Metadata-only dry run
- SHA-256 success
- Zstandard success
- Successful protected receipt creation
- SHA-256 mismatch detection
- Zstandard corruption detection
- Critical exit behavior
- Newest-only verification
- Optional disconnected external storage
- Initial healthy state handling
- Critical notification delivery
- Recovery notification delivery
- Duplicate-notification suppression
- macOS background scheduling
- Bash 3.2 compatibility
- ShellCheck compliance
- Valid LaunchAgent property-list syntax
- Temporary-file CI fixtures

The real newest retained local backup was deeply verified without modifying the archive.
