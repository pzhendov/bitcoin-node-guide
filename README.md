# Bitcoin Node Guide

A reproducible, beginner-friendly guide for running a pruned Bitcoin Core node inside an Ubuntu Multipass virtual machine on an Apple Silicon Mac.

## Tested environment

This setup was built and tested with:

- MacBook Pro 16-inch, 2021
- Apple M1 Pro
- 16 GB unified memory
- Multipass 1.16
- Ubuntu 26.04 LTS ARM64
- Bitcoin Core 31.1
- systemd
- 4 virtual CPU cores
- 6 GiB VM memory
- 150 GB virtual disk
- 50,000 MiB pruning target

## What this node does

The node:

- Connects to Bitcoin mainnet
- Downloads the complete blockchain history
- Independently validates blocks and transactions
- Rejects data that violates Bitcoin’s consensus rules
- Relays valid blocks and transactions
- Provides local access through `bitcoin-cli`
- Starts automatically whenever the VM starts
- Retains only a pruned portion of historical block data

A pruned node still validates the complete blockchain. Pruning reduces retained disk usage, but it does not avoid the initial blockchain download.

## What this node does not do

This node:

- Does not mine Bitcoin
- Does not generate income
- Does not currently contain a wallet
- Does not store seed phrases or private keys
- Does not automatically protect a separate wallet
- Does not replace secure wallet backups

Wallet functionality is deliberately disabled:

```ini
disablewallet=1
```

This reduces risk while the node is being used for learning and validation.

## Architecture

```text
Apple Silicon Mac
│
├── Multipass
│   │
│   └── Ubuntu VM: bitcoin-node
│       │
│       ├── Bitcoin Core daemon: bitcoind
│       ├── Local RPC client: bitcoin-cli
│       ├── Automatic startup: systemd
│       ├── Configuration: ~/.bitcoin/bitcoin.conf
│       └── Pruned blockchain data: ~/.bitcoin
│
└── Optional future wallet
    ├── Desktop wallet on macOS
    ├── Hardware wallet for private-key protection
    └── Bitcoin node for private transaction validation
```

## Security model

The node and wallet have different responsibilities:

```text
Hardware wallet → protects and signs with private keys
Desktop wallet  → creates and displays transactions
Bitcoin node    → validates balances, transactions and Bitcoin rules
```

The current VM contains no private keys. A future hardware wallet can sign transactions while this node independently verifies and broadcasts them.

Never type, photograph, upload or commit a seed phrase.

---

# 1. Create the Multipass VM

Inspect existing VMs:

```bash
multipass list
```

Inspect available Ubuntu images:

```bash
multipass find
```

Create the Bitcoin node VM:

```bash
multipass launch 26.04 \
  --name bitcoin-node \
  --cpus 4 \
  --memory 6G \
  --disk 150G
```

Verify its configuration:

```bash
multipass info bitcoin-node
```

Enter the VM:

```bash
multipass shell bitcoin-node
```

Confirm the user, hostname and architecture:

```bash
whoami
hostname
uname -m
```

Expected architecture:

```text
aarch64
```

---

# 2. Update Ubuntu

Refresh the package catalogue:

```bash
sudo apt update
```

Review available upgrades:

```bash
apt list --upgradable
```

Install reviewed upgrades:

```bash
sudo apt upgrade
```

Confirm no upgrades remain:

```bash
apt list --upgradable
```

Check the required tools:

```bash
command -v wget
command -v sha256sum
command -v gpg
command -v tar
command -v git
```

---

# 3. Download Bitcoin Core

Create a dedicated download directory:

```bash
mkdir -p ~/bitcoin-download
cd ~/bitcoin-download
```

This guide is pinned to Bitcoin Core 31.1. Check the official Bitcoin Core website before installing to determine whether a newer security release is available.

Download the ARM64 Linux archive:

```bash
wget https://bitcoincore.org/bin/bitcoin-core-31.1/bitcoin-31.1-aarch64-linux-gnu.tar.gz
```

Download the published checksums:

```bash
wget https://bitcoincore.org/bin/bitcoin-core-31.1/SHA256SUMS
```

Download the checksum signatures:

```bash
wget https://bitcoincore.org/bin/bitcoin-core-31.1/SHA256SUMS.asc
```

Inspect the downloaded files:

```bash
ls -lh
```

---

# 4. Verify the Bitcoin Core download

Downloading over HTTPS is not the final verification step. Verify both the archive checksum and the signatures protecting the checksum file.

## Verify the SHA-256 checksum

Run:

```bash
sha256sum --ignore-missing --check SHA256SUMS
```

Expected:

```text
bitcoin-31.1-aarch64-linux-gnu.tar.gz: OK
```

Do not continue if the result says `FAILED`.

## Download contributor signing keys

Clone the Bitcoin Core reproducible-build signature repository:

```bash
git clone https://github.com/bitcoin-core/guix.sigs
```

Import the public builder keys:

```bash
gpg --import guix.sigs/builder-keys/*.gpg
```

Public keys are not passwords or private keys. They allow GPG to validate signatures created by the corresponding private keys.

A message such as this is expected:

```text
gpg: no ultimately trusted keys found
```

Importing a key does not automatically establish personal trust in the claimed identity.

## Verify the signed checksum file

Run:

```bash
gpg --verify SHA256SUMS.asc
```

Look for:

```text
gpg: Good signature
```

Stop immediately if any output reports:

```text
gpg: BAD signature
```

Warnings saying that a key is not certified with a trusted signature concern identity trust. They do not mean the cryptographic signature is invalid.

For stronger assurance, independently confirm trusted signer fingerprints through multiple reputable sources.

---

# 5. Inspect and extract the archive

Inspect the archive before extraction:

```bash
tar -tzf bitcoin-31.1-aarch64-linux-gnu.tar.gz | head -n 25
```

The archive should contain a single top-level directory:

```text
bitcoin-31.1/
```

Extract it:

```bash
tar -xzf bitcoin-31.1-aarch64-linux-gnu.tar.gz
```

Inspect the executables:

```bash
ls -lh bitcoin-31.1/bin
```

Important executables include:

- `bitcoind` — the Bitcoin node daemon
- `bitcoin-cli` — the local RPC command-line client
- `bitcoin-qt` — the graphical Bitcoin Core interface
- `bitcoin-wallet` — wallet maintenance utility
- `bitcoin-tx` — transaction utility
- `bitcoin-util` — general Bitcoin utility

This setup uses the headless daemon and command-line client.

---

# 6. Install Bitcoin Core

Install the verified executables under `/usr/local/bin`:

```bash
sudo install -m 0755 -o root -g root \
  -t /usr/local/bin \
  bitcoin-31.1/bin/*
```

Verify the installed path:

```bash
command -v bitcoind
```

Expected:

```text
/usr/local/bin/bitcoind
```

Verify the versions:

```bash
bitcoind --version
bitcoin-cli --version
```

Expected version:

```text
v31.1.0
```

---

# 7. Configure the pruned node

Create Bitcoin Core’s protected data directory:

```bash
mkdir -p ~/.bitcoin
chmod 700 ~/.bitcoin
```

Verify its permissions:

```bash
ls -ld ~/.bitcoin
```

Expected permissions begin with:

```text
drwx------
```

Create the configuration:

```bash
nano ~/.bitcoin/bitcoin.conf
```

Use:

```ini
# Storage and synchronization
prune=50000
dbcache=2048

# Security
disablewallet=1
server=1

# Network limits
maxconnections=40
maxuploadtarget=5000
```

Protect the file:

```bash
chmod 600 ~/.bitcoin/bitcoin.conf
```

Verify it:

```bash
ls -l ~/.bitcoin/bitcoin.conf
cat ~/.bitcoin/bitcoin.conf
```

## Configuration explanation

### `prune=50000`

Targets 50,000 MiB of retained raw block and undo data.

This is not a hard limit for the complete `~/.bitcoin` directory. Chain state, logs, indexes and supporting files require additional space.

### `dbcache=2048`

Allows Bitcoin Core to use up to approximately 2 GiB of memory for database caching, improving initial synchronization performance.

This memory is not necessarily allocated immediately.

### `disablewallet=1`

Disables Bitcoin Core wallet functionality.

The node validates Bitcoin without storing private keys or funds.

### `server=1`

Allows local `bitcoin-cli` access.

Bitcoin Core uses a private authentication cookie by default. This setup does not expose RPC access to the network.

### `maxconnections=40`

Limits peer connections and associated resource consumption.

### `maxuploadtarget=5000`

Sets a historical-block upload target of approximately 5,000 MiB per 24-hour period.

This does not limit the initial blockchain download.

---

# 8. Perform the first manual start

Start Bitcoin Core manually:

```bash
bitcoind -daemon
```

Expected:

```text
Bitcoin Core starting
```

Check the node:

```bash
bitcoin-cli -getinfo
```

Inspect detailed blockchain information:

```bash
bitcoin-cli getblockchaininfo
```

Important fields:

```text
chain
blocks
headers
verificationprogress
initialblockdownload
pruned
automatic_pruning
prune_target_size
warnings
```

Confirm:

```json
"chain": "main"
```

```json
"pruned": true
```

```json
"automatic_pruning": true
```

The configured pruning target should appear as:

```json
"prune_target_size": 52428800000
```

This equals 50,000 MiB.

## Inspect the log

```bash
tail -n 30 ~/.bitcoin/debug.log
```

During synchronization, healthy progress normally appears as repeated `UpdateTip` entries.

---

# 9. Stop Bitcoin Core safely

Use:

```bash
bitcoin-cli stop
```

Expected:

```text
Bitcoin Core stopping
```

Confirm the process exited:

```bash
pgrep -a bitcoind
```

No output means the process is no longer running.

Check the final log entries:

```bash
tail -n 12 ~/.bitcoin/debug.log
```

A clean shutdown ends with:

```text
Shutdown done
```

Avoid forcibly killing Bitcoin Core when `bitcoin-cli stop` or systemd shutdown is available.

---

# 10. Create the systemd service

Create:

```bash
sudo nano /etc/systemd/system/bitcoind.service
```

Use:

```ini
[Unit]
Description=Bitcoin Core daemon
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
User=ubuntu
Group=ubuntu
ExecStart=/usr/local/bin/bitcoind -datadir=/home/ubuntu/.bitcoin
ExecStop=/usr/local/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin stop
Restart=on-failure
RestartSec=10
TimeoutStopSec=600
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Do not add `-daemon` to `ExecStart`. Systemd needs Bitcoin Core to remain in the foreground so it can supervise the real process.

Validate the unit:

```bash
sudo systemd-analyze verify /etc/systemd/system/bitcoind.service
```

Immediately inspect the exit status:

```bash
echo $?
```

Expected:

```text
0
```

Warnings concerning unrelated preinstalled Ubuntu services do not affect the Bitcoin unit.

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable automatic startup:

```bash
sudo systemctl enable bitcoind
```

Verify:

```bash
systemctl is-enabled bitcoind
```

Expected:

```text
enabled
```

Start the service:

```bash
sudo systemctl start bitcoind
```

Inspect its status:

```bash
systemctl status bitcoind --no-pager
```

Expected:

```text
Active: active (running)
```

---

# 11. Test automatic startup

Reboot the VM from inside Ubuntu:

```bash
sudo reboot
```

After returning to the Mac Terminal, check the VM:

```bash
multipass list
```

Verify the service without entering the VM:

```bash
multipass exec bitcoin-node -- systemctl is-enabled bitcoind
```

Expected:

```text
enabled
```

Check whether it started:

```bash
multipass exec bitcoin-node -- systemctl is-active bitcoind
```

Expected:

```text
active
```

Check Bitcoin Core:

```bash
multipass exec bitcoin-node -- bitcoin-cli -getinfo
```

If the block height continues from its earlier value, synchronization state was preserved successfully.

---

# 12. Monitor synchronization

## Simple status

From the Mac:

```bash
multipass exec bitcoin-node -- bitcoin-cli -getinfo
```

## Focused JSON status

```bash
multipass exec bitcoin-node -- bitcoin-cli getblockchaininfo |
  jq '{
    blocks,
    headers,
    progress_percent: (.verificationprogress * 100),
    initial_block_download: .initialblockdownload,
    pruned,
    size_on_disk_gib: (.size_on_disk / 1073741824)
  }'
```

## Data-directory size

```bash
multipass exec bitcoin-node -- du -sh /home/ubuntu/.bitcoin
```

## Service status

```bash
multipass exec bitcoin-node -- systemctl is-active bitcoind
```

## Recent service logs

```bash
multipass exec bitcoin-node -- journalctl \
  -u bitcoind \
  -n 30 \
  --no-pager
```

## Synchronization completion

Initial synchronization is complete when:

```text
blocks equals headers
verification progress is approximately 100%
initialblockdownload is false
```

The chain tip continues increasing as miners produce new blocks, so the final block height will be higher than values shown in this guide.

Verification progress is not proportional to the number of blocks. Later blocks contain more transactions and require more validation work.

---

# 13. Keep the Mac awake during synchronization

On macOS, open a separate Terminal tab and run:

```bash
caffeinate -i
```

While this command remains active:

- The Mac does not enter automatic idle system sleep.
- The display can turn off.
- macOS can lock for privacy.
- Multipass VMs continue running.
- Bitcoin Core continues synchronizing.
- Local automations continue running.

Keep the Mac connected to power and leave the laptop lid open.

Stop `caffeinate` by pressing:

```text
Control+C
```

Closing that Terminal window also stops it.

`caffeinate` does not prevent manual shutdown, restart, explicit sleep, power failure or internet interruption.

---

# 14. Everyday VM operations

## Start the VM

```bash
multipass start bitcoin-node
```

The enabled systemd service starts Bitcoin Core automatically.

## Check the VM

```bash
multipass info bitcoin-node
```

## Enter the VM

```bash
multipass shell bitcoin-node
```

## Leave the VM shell

```bash
exit
```

## Stop the VM safely

From the Mac:

```bash
multipass stop bitcoin-node
```

During a normal VM shutdown, systemd asks Bitcoin Core to stop and flush its databases.

## Start Bitcoin Core manually through systemd

```bash
multipass exec bitcoin-node -- sudo systemctl start bitcoind
```

## Stop Bitcoin Core manually through systemd

```bash
multipass exec bitcoin-node -- sudo systemctl stop bitcoind
```

## Restart Bitcoin Core

```bash
multipass exec bitcoin-node -- sudo systemctl restart bitcoind
```

## Inspect full service status

```bash
multipass exec bitcoin-node -- systemctl status bitcoind --no-pager
```

Do not use `multipass delete bitcoin-node` unless the VM and its blockchain data are intentionally being destroyed.

---

# 15. Important files and directories

Inside the VM:

```text
/home/ubuntu/.bitcoin/
```

Bitcoin Core’s data directory.

```text
/home/ubuntu/.bitcoin/bitcoin.conf
```

Active node configuration.

```text
/home/ubuntu/.bitcoin/debug.log
```

Bitcoin Core operational log.

```text
/home/ubuntu/.bitcoin/blocks/
```

Raw block and undo data.

```text
/home/ubuntu/.bitcoin/chainstate/
```

Validated UTXO database.

```text
/home/ubuntu/.bitcoin/.cookie
```

Temporary local RPC authentication cookie. Never commit or share it.

```text
/etc/systemd/system/bitcoind.service
```

Automatic-start service definition.

```text
/usr/local/bin/bitcoind
```

Bitcoin Core node daemon.

```text
/usr/local/bin/bitcoin-cli
```

Bitcoin Core RPC client.

---

# 16. Git safety

Safe repository contents include:

- Installation documentation
- Example configuration without credentials
- systemd service templates
- Monitoring commands
- Security explanations
- Architecture notes
- Download-verification instructions

Never commit:

- `~/.bitcoin`
- Seed phrases
- Private keys
- Wallet backups
- `.cookie`
- RPC passwords
- `wallet.dat`
- `wallets/`
- `blocks/`
- `chainstate/`
- `indexes/`
- `debug.log`
- `peers.dat`
- `mempool.dat`
- VM disk images
- Downloaded Bitcoin Core binaries
- Screenshots containing serial numbers or private information

Before every commit, inspect:

```bash
git status --short
git diff
git diff --staged
```

Never use:

```bash
git add .
```

without first inspecting every untracked file.

---

# 17. Future wallet integration

After synchronization is complete and the node is stable, it can later be used as a private backend for a compatible wallet.

A strong future arrangement is:

```text
Hardware wallet
    ↓ signs transactions without exposing private keys

Desktop wallet
    ↓ constructs transactions and displays balances

Personal Bitcoin node
    ↓ validates the blockchain and broadcasts transactions
```

Before using real BTC:

1. Choose a reputable wallet.
2. Verify the wallet download.
3. Create the wallet privately.
4. Record the recovery seed offline.
5. Never photograph or digitally upload the seed.
6. Verify receiving addresses on the hardware device.
7. Test wallet recovery before depositing significant funds.
8. Begin with a small test transaction.
9. Keep the node fully synchronized.
10. Maintain an inheritance or emergency-recovery plan.

Running a node improves validation and privacy. It does not protect a compromised or lost seed phrase.

---

# 18. Mining note

A local VM is useful for learning Bitcoin mining concepts in regtest mode, but it is not economically realistic for mainnet mining.

Creating more VMs does not create more physical computing power. The VMs divide the same Mac CPU resources.

Competitive Bitcoin mining requires specialized SHA-256 ASIC hardware, suitable electricity pricing, cooling and usually participation in a mining pool.

A future educational mining lab can use Bitcoin Core regtest mode to study:

- Block generation
- Coinbase rewards
- Confirmation maturity
- Mining difficulty
- Mempools
- Transaction selection
- Pool shares

Regtest BTC has no monetary value.

---

# 19. Troubleshooting

## The VM is stopped

```bash
multipass start bitcoin-node
```

## The service is inactive

```bash
multipass exec bitcoin-node -- systemctl status bitcoind --no-pager
```

Inspect recent logs:

```bash
multipass exec bitcoin-node -- journalctl \
  -u bitcoind \
  -n 50 \
  --no-pager
```

## `bitcoin-cli` cannot connect

Check the service:

```bash
multipass exec bitcoin-node -- systemctl is-active bitcoind
```

Check whether initialization is still underway:

```bash
multipass exec bitcoin-node -- bitcoin-cli -getinfo
```

Bitcoin Core may briefly return an initialization message while loading or verifying databases.

## Synchronization stopped progressing

Check:

```bash
multipass exec bitcoin-node -- bitcoin-cli -getinfo
```

```bash
multipass exec bitcoin-node -- systemctl status bitcoind --no-pager
```

```bash
multipass exec bitcoin-node -- df -h /
```

```bash
multipass exec bitcoin-node -- journalctl \
  -u bitcoind \
  -n 100 \
  --no-pager
```

Look for:

- Disk exhaustion
- Network failure
- Permission errors
- Configuration errors
- Database errors
- Repeated service restarts

## The Mac slept

Start or inspect the VM:

```bash
multipass list
multipass start bitcoin-node
```

Bitcoin Core should resume from its last safely stored state.

---

# 20. Updating Bitcoin Core

Do not replace Bitcoin Core binaries while the node is running.

A safe upgrade process is:

1. Read the new release notes.
2. Download the correct ARM64 Linux archive.
3. Download the new checksum and signature files.
4. Verify the archive checksum.
5. Verify contributor signatures.
6. Stop the systemd service.
7. Back up configuration and any future wallet data.
8. Install the verified new binaries.
9. Start the service.
10. Confirm the version, logs and synchronization state.

Stop the service:

```bash
sudo systemctl stop bitcoind
```

Verify it stopped:

```bash
systemctl is-active bitcoind
```

Install only after completing release verification.

Start it again:

```bash
sudo systemctl start bitcoind
```

Check the version:

```bash
bitcoind --version
bitcoin-cli --version
```

Check the service:

```bash
systemctl status bitcoind --no-pager
```

---
# Completed synchronization and validation

The initial block download was completed successfully. The node independently validated the blockchain and reached the network tip.

Final results included:

- Blocks equal to headers
- Verification progress at `100%`
- `initialblockdownload` set to `false`
- Automatic pruning enabled
- Approximately 48.7 GiB stored with a 50,000 MiB pruning target
- Bitcoin Core enabled and active under systemd
- Successful automatic startup after a controlled VM restart
- Multiple outbound peers connected
- No Bitcoin Core warnings

Check the current node status from the macOS host:

```bash
multipass exec bitcoin-node -- bitcoin-cli -getinfo
```

A synchronized node should show:

- `Blocks` equal or very close to `Headers`
- Verification progress near `100%`
- A time offset close to zero
- Connected peers
- `Warnings: (none)`

Display detailed blockchain and pruning information:

```bash
multipass exec bitcoin-node -- bitcoin-cli getblockchaininfo |
jq '{
  blocks,
  headers,
  progress_percent: (.verificationprogress * 100),
  initial_block_download: .initialblockdownload,
  pruned,
  pruneheight,
  automatic_pruning,
  size_on_disk_gib: (.size_on_disk / 1073741824)
}'
```

Confirm that the service starts automatically and is currently running:

```bash
multipass exec bitcoin-node -- systemctl is-enabled bitcoind
multipass exec bitcoin-node -- systemctl is-active bitcoind
```

Expected results:

```text
enabled
active
```

---

# Clock synchronization in a Multipass VM

A Multipass VM may resume with an incorrect clock after the Mac sleeps. Bitcoin Core can report a large value for:

```text
Time offset (s)
```

A large clock difference can disrupt peer communication and Bitcoin consensus checks. Ubuntu 26.04 uses Chrony for network time synchronization.

Check the Mac and VM clocks:

```bash
date -u
multipass exec bitcoin-node -- date -u
```

Inspect Chrony:

```bash
multipass exec bitcoin-node -- chronyc -N tracking
multipass exec bitcoin-node -- chronyc -N sources -v
```

Healthy output should show:

```text
Leap status     : Normal
```

The default Chrony configuration contained:

```text
makestep 1 3
```

This permits an immediate correction larger than one second only during the first three clock updates after Chrony starts. For this dedicated Bitcoin VM, it was changed to:

```text
makestep 1 -1
```

The negative limit permits Chrony to correct a large clock difference even after the VM has been running for some time.

Back up the configuration before changing it:

```bash
sudo cp -a /etc/chrony/chrony.conf /etc/chrony/chrony.conf.backup
```

Edit it:

```bash
sudo nano /etc/chrony/chrony.conf
```

Verify the setting:

```bash
grep -n '^[[:space:]]*makestep' /etc/chrony/chrony.conf
```

Expected output:

```text
40:makestep 1 -1
```

Restart Chrony and verify synchronization:

```bash
sudo systemctl restart chrony
systemctl is-active chrony
chronyc -N tracking
```

This setting allows the system clock to jump when a difference greater than one second is detected. That behaviour is intentional for this dedicated VM but might not be appropriate for systems running applications that require strictly monotonic wall-clock time.

## Manual recovery from a large clock offset

Stop Bitcoin Core before manually forcing a large clock correction:

```bash
multipass exec bitcoin-node -- sudo systemctl stop bitcoind
multipass exec bitcoin-node -- systemctl is-active bitcoind
```

Restart Chrony to obtain fresh time measurements:

```bash
multipass exec bitcoin-node -- sudo systemctl restart chrony
```

Force the correction if it is still required:

```bash
multipass exec bitcoin-node -- sudo chronyc makestep
```

Compare the clocks:

```bash
date -u
multipass exec bitcoin-node -- date -u
```

Restart Bitcoin Core:

```bash
multipass exec bitcoin-node -- sudo systemctl start bitcoind
```

Verify recovery:

```bash
multipass exec bitcoin-node -- bitcoin-cli -getinfo
```

The time offset should be close to zero and Bitcoin Core should report no warnings.

---

# Safe daily operation

Start the VM:

```bash
multipass start bitcoin-node
```

Bitcoin Core starts automatically through systemd. After approximately 30 seconds, check it:

```bash
multipass exec bitcoin-node -- bitcoin-cli -getinfo
```

Safely stop Bitcoin Core and the VM:

```bash
multipass exec bitcoin-node -- sudo systemctl stop bitcoind
multipass exec bitcoin-node -- systemctl is-active bitcoind
multipass stop bitcoin-node
```

Do not stop the VM until Bitcoin Core reports `inactive`.

To prevent idle sleep on macOS while leaving the display free to lock or turn off:

```bash
caffeinate -i
```

Keep the Mac connected to power and its lid open. Stop `caffeinate` with `Control + C`.

# Automated health monitoring

The project includes an automated Bitcoin node health monitor.

It checks Bitcoin Core synchronization, peers, time offset, Chrony status, pruning, disk space and available memory. A systemd timer runs the check every five minutes and records the results in the system journal.

Run an immediate health check:

```bash
multipass exec bitcoin-node -- \
  /usr/local/bin/bitcoin-node-health
```

Show recent automated results:

```bash
multipass exec bitcoin-node -- \
  journalctl -u bitcoin-node-health.service \
    --since "30 minutes ago" \
    --no-pager
```

See [docs/monitoring.md](docs/monitoring.md) for installation, thresholds, exit codes, timer management and troubleshooting.

---

# Telegram and macOS alerts

The node monitor supports state-change notifications through Telegram and macOS Notification Center.

Alerts are sent when the node changes between:

- `HEALTHY`
- `WARNING`
- `CRITICAL`

Repeated checks in the same state do not produce duplicate notifications. A recovery notification is sent when an unhealthy node returns to `HEALTHY`.

Telegram credentials are stored only inside the VM in a root-protected file. Tokens and chat IDs must never be committed to Git.

The macOS LaunchAgent checks the Multipass node every five minutes and displays local notifications. The Telegram dispatcher runs with the systemd health monitor inside the VM.

See [docs/alerting.md](docs/alerting.md) for architecture, installation, testing, security and troubleshooting.

---

# Repository structure

```text
bitcoin-node-guide/
├── README.md
├── LICENSE
├── .gitignore
├── config/
│   └── bitcoin.conf.example
├── docs/
│   ├── README.md
│   ├── alerting.md
│   └── monitoring.md
├── launchd/
│   └── com.pzhendov.bitcoin-node-health-notify.plist
├── scripts/
│   ├── bitcoin-node-health-runner.sh
│   ├── bitcoin-node-health.sh
│   ├── bitcoin-node-telegram-alert.sh
│   └── macos-bitcoin-node-notify.sh
└── systemd/
    ├── bitcoind.service
    ├── bitcoin-node-health.service
    └── bitcoin-node-health.timer
```

---

# References

- [Bitcoin Core official website](https://bitcoincore.org/)
- [Bitcoin Core downloads](https://bitcoincore.org/en/download/)
- [Bitcoin Core source code](https://github.com/bitcoin/bitcoin)
- [Bitcoin Core reproducible-build signatures](https://github.com/bitcoin-core/guix.sigs)
- [Running a Bitcoin full node](https://bitcoin.org/en/full-node)
- [Securing a Bitcoin wallet](https://bitcoin.org/en/secure-your-wallet)
- [Bitcoin developer documentation](https://developer.bitcoin.org/)

---

# Disclaimer

This repository is educational material and not financial advice.

Running Bitcoin software and taking custody of bitcoin involves operational and financial risk. Verify software, commands, wallet procedures, backups and recovery plans independently before using real funds.
