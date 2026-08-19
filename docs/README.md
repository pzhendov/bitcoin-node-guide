# Supplemental Documentation

The main installation and operations guide is maintained in the repository's root [README](../README.md).

This directory contains focused operational guides:

- [Monitoring](monitoring.md) — automated node-health checks, thresholds, exit codes and troubleshooting
- [Alerting](alerting.md) — Telegram alerts and macOS Notification Center integration
- [Clock recovery](../README.md#automatic-recovery-from-severe-clock-drift) — automatic recovery from severe Multipass VM clock drift
- [Disaster recovery](disaster-recovery.md) — rebuilding the node in a fresh virtual machine
- [Blockchain backup and restore](blockchain-backup-restore.md) — tested cold backup, integrity verification and restoration of pruned blockchain data
- [Safe backup automation](backup-automation.md) — automated preflight, cold archive creation, transfer, checksum verification and service recovery
- [Safe backup retention](backup-retention.md) — checksum-verified inventory, two-backup protection, dry-run decisions and explicitly confirmed deletion
- [Backup freshness monitoring](backup-freshness-monitor.md) — daily read-only checks for backup completeness, age, free space and external-copy status with macOS state-change notifications
- [Deep backup integrity](backup-deep-integrity.md) — monthly SHA-256 and Zstandard verification with protected receipts and state-change notifications

## Security

Do not place live logs, wallet data, RPC credentials, Telegram credentials, seed phrases, private keys, blockchain data, backup archives or virtual-machine images in this directory.

The documentation and example configurations are safe to publish only when they contain no credentials or private wallet information.
