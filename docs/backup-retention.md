# Safe Bitcoin backup retention

This guide explains how to inventory, verify and safely remove older local pruned-blockchain backups while protecting the newest recovery points.

The retention tool is:

```text
scripts/macos-bitcoin-node-backup-retention.sh
```

## Purpose

Each automated pruned-blockchain backup is approximately 47 GiB. Keeping every backup indefinitely can eventually consume significant Mac storage.

The retention tool:

- Inventories complete backup sets
- Verifies every archive checksum
- Protects the newest configured number of backups
- Reports older verified backups as retention candidates
- Defaults to a non-destructive dry-run
- Requires explicit confirmation before deletion
- Refuses to continue when a backup is incomplete, corrupted or unexpectedly named
- Deletes only exact verified files, never broad directory patterns

## Backup-set structure

A complete backup set contains three files with the same block height and date:

```text
bitcoin-node-pruned-BLOCK-DATE.tar.zst
bitcoin-node-pruned-BLOCK-DATE.tar.zst.sha256
bitcoin-node-pruned-BLOCK-DATE.manifest.txt
```

For example:

```text
bitcoin-node-pruned-962373-2026-08-14.tar.zst
bitcoin-node-pruned-962373-2026-08-14.tar.zst.sha256
bitcoin-node-pruned-962373-2026-08-14.manifest.txt
```

The archive, checksum and manifest are treated as one recovery unit.

## Default retention policy

The default policy keeps the newest two complete backup sets.

Two backups provide a minimum fallback:

- The newest backup is the preferred recovery point.
- The previous backup remains available if the newest backup is damaged or later found unsuitable.
- A failed backup creation cannot immediately remove the last known-good recovery point.
- Manifests and checksums can be compared between recovery points.

The tool refuses a keep count below two.

An external verified copy is an additional protection layer and does not replace the two-backup local retention policy.

## Security and safety boundaries

The retention script operates only on files matching the documented Bitcoin backup naming convention inside the selected destination directory.

It does not:

- Stop or start Bitcoin Core
- Contact the Bitcoin VM
- Modify blockchain data inside the VM
- Modify wallet data
- Delete incomplete backup sets
- Delete archives with failed checksum verification
- Delete unexpectedly named archives
- Follow a keep count below two
- Run deletion without both execution options
- Automatically manage external-drive copies
- Run on a schedule by default

Deletion is permanent. Always run and review a dry-run first.

## Requirements

The script is designed for macOS and uses standard system commands:

```bash
command -v bash
command -v awk
command -v df
command -v find
command -v rm
command -v shasum
command -v sort
command -v stat
```

The backup destination must exist and be readable. Execution also requires it to be writable.

## Validate the script

From the repository root:

```bash
bash -n scripts/macos-bitcoin-node-backup-retention.sh

shellcheck scripts/macos-bitcoin-node-backup-retention.sh

git diff --check
```

All commands should complete successfully.

## Run a dry-run

The default local backup directory is:

```text
~/bitcoin-node-backups
```

Run the retention inventory while keeping the newest two backups:

```bash
caffeinate -i \
  scripts/macos-bitcoin-node-backup-retention.sh \
    --dry-run \
    --keep 2 \
    --destination "$HOME/bitcoin-node-backups"
```

The script calculates the SHA-256 hash of every archive. Large archives can take several minutes to verify.

A dry-run never deletes backup files.

## Interpret dry-run results

Protected backups are reported as:

```text
[RETENTION] PROTECT: block=962373 date=2026-08-14 size=46.95GiB
```

Older verified backups beyond the keep count are reported as:

```text
[RETENTION] CANDIDATE: block=962141 date=2026-08-12 size=46.97GiB
```

The summary reports:

```text
complete=3 protected=2 candidates=1
```

It also reports:

- Available destination space
- Approximate space that execution could reclaim
- Whether the current policy is already satisfied

## Execute confirmed retention

Only after reviewing a successful dry-run, run:

```bash
scripts/macos-bitcoin-node-backup-retention.sh \
  --execute \
  --confirm-retention-delete \
  --keep 2 \
  --destination "$HOME/bitcoin-node-backups"
```

Both options are required:

```text
--execute
--confirm-retention-delete
```

Without the confirmation option, execution exits before inventory or deletion.

During execution, the script:

1. Acquires a host-side execution lock.
2. Rejects partial or incomplete artifacts.
3. Validates every archive filename.
4. Requires each archive to have a checksum and manifest.
5. Calculates and compares every archive SHA-256.
6. Protects the newest configured number of complete backups.
7. Rechecks candidate files immediately before deletion.
8. Deletes only the exact archive, checksum and manifest belonging to each approved candidate.
9. Reports the deleted block height, date and approximate reclaimed space.

## Use another destination

To inspect backups stored elsewhere:

```bash
scripts/macos-bitcoin-node-backup-retention.sh \
  --dry-run \
  --keep 2 \
  --destination "/path/to/backup-directory"
```

For an external drive:

```bash
scripts/macos-bitcoin-node-backup-retention.sh \
  --dry-run \
  --keep 2 \
  --destination "/Volumes/Backup_8TB/bitcoin-node-backups"
```

The external volume must be mounted before running the command.

Run a dry-run independently for each destination. The script does not assume that local and external backup inventories are identical.

## Failure behavior

The script exits with code `2` and deletes nothing when it detects:

- A `.partial` backup artifact
- A checksum without its archive
- A manifest without its archive
- An unexpected archive filename
- An archive without its checksum
- An archive without its manifest
- An invalid checksum value
- A checksum mismatch
- An unreadable destination
- A candidate that changes before deletion
- Another active retention execution

These conditions require manual inspection.

Do not rename, remove or recreate files until the reason for the failure is understood.

## Exit codes

```text
0 = inventory completed or confirmed retention completed
1 = invalid command usage
2 = verification or retention safety check failed
```

## Tested behavior

The retention workflow was tested on macOS on 19 August 2026.

The live dry-run inspected two real backups totaling approximately 94 GiB:

```text
block=962373 date=2026-08-14 size=46.95GiB
block=962141 date=2026-08-12 size=46.97GiB
```

With `--keep 2`, both backups were protected and no candidates were selected.

Disposable fixtures then validated:

- Three complete sets produced two protected backups and one candidate.
- Dry-run left all nine fixture files unchanged.
- Confirmed execution deleted only the oldest archive, checksum and manifest.
- The six protected fixture files remained.
- A corrupted candidate archive caused checksum failure and exit code `2`.
- A missing manifest caused exit code `2`.
- Unexpected archive names caused exit code `2`.
- Unconfirmed execution was rejected with exit code `1`.
- A keep count below two was rejected with exit code `1`.
- The six real backup files remained untouched throughout fixture testing.

## Recommended operating practice

Use the following policy:

- Keep at least two verified backups on the Mac.
- Keep at least one verified copy on an external drive.
- Disconnect the external drive after verification when it is not needed.
- Run retention only after a newer backup completes successfully.
- Complete periodic restore rehearsals.
- Review every dry-run before confirmed deletion.
- Never delete the only tested recovery point.
- Never place backup archives inside the Git repository.

## Final retention checklist

- [ ] Correct backup destination selected
- [ ] Destination inventory reviewed
- [ ] At least two complete backups will remain
- [ ] Every archive checksum passed
- [ ] No `.partial` artifacts present
- [ ] No incomplete backup sets present
- [ ] No unexpected filenames present
- [ ] Dry-run completed with exit code `0`
- [ ] Protected block heights recorded
- [ ] Candidate block heights reviewed
- [ ] External verified copy considered
- [ ] Confirmed deletion used only after review
- [ ] Remaining files listed after execution
- [ ] Free disk space checked after execution
