# Supplemental Documentation

The main installation and operations guide is maintained in the repository's root [README](../README.md).

This directory contains focused operational guides:

- [Monitoring](monitoring.md) — automated node-health checks, thresholds, exit codes and troubleshooting
- [Alerting](alerting.md) — Telegram alerts and macOS Notification Center integration
- [Clock recovery](../README.md#automatic-recovery-from-severe-clock-drift) — automatic recovery from severe Multipass VM clock drift
- [Disaster recovery](disaster-recovery.md) — rebuilding the node in a fresh virtual machine
- [Blockchain backup and restore](blockchain-backup-restore.md) — tested cold backup, integrity verification and restoration of pruned blockchain data

## Security

Do not place live logs, wallet data, RPC credentials, Telegram credentials, seed phrases, private keys, blockchain data, backup archives or virtual-machine images in this directory.

The documentation and example configurations are safe to publish only when they contain no credentials or private wallet information.
