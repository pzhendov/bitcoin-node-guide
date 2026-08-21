# Bitcoin Node Guide

[![Validate repository](https://github.com/pzhendov/bitcoin-node-guide/actions/workflows/validate.yml/badge.svg)](https://github.com/pzhendov/bitcoin-node-guide/actions/workflows/validate.yml)

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

## Automatic recovery from severe clock drift

A Multipass VM can resume after macOS sleep with a stale system clock. In testing, the VM clock remained many hours behind the Mac even though Chrony initially appeared synchronized.

Bitcoin Core reported the problem through a large peer-time offset:

```text
Time offset (s): 45837
```

Chrony sources also showed that the VM was approximately one day behind:

```text
-86480s
```

The project includes an automatic recovery service that detects this condition, stops Bitcoin Core safely, refreshes Chrony and restarts Bitcoin Core only after the system clock has been verified.

### Recovery files

Repository files:

```text
scripts/bitcoin-node-clock-recovery.sh
systemd/bitcoin-node-clock-recovery.service
systemd/bitcoin-node-clock-recovery.timer
```

Installed locations inside the VM:

```text
/usr/local/bin/bitcoin-node-clock-recovery
/etc/systemd/system/bitcoin-node-clock-recovery.service
/etc/systemd/system/bitcoin-node-clock-recovery.timer
```

### Recovery sequence

Every five minutes, the timer starts a one-shot recovery service.

The recovery script:

1. Acquires an exclusive lock to prevent overlapping checks.
2. Determines whether Bitcoin Core is active or an unfinished automatic recovery is pending.
3. Reads Bitcoin Core’s peer-time offset through local cookie-authenticated RPC.
4. Exits without interrupting Bitcoin when the absolute offset is below 60 seconds.
5. Records a persistent recovery marker and stops Bitcoin Core cleanly when the offset is 60 seconds or greater.
6. Restarts Chrony to discard stale time measurements.
7. Retries the Chrony control connection while the daemon starts.
8. Requests fresh network-time samples.
9. Waits for Chrony to select a valid source.
10. Steps the VM system clock.
11. Verifies that Chrony reports a normal leap status.
12. Verifies that the Chrony system offset is no greater than 0.1 seconds.
13. Restarts Bitcoin Core only after successful clock verification.
14. Removes the recovery marker only after Bitcoin Core is active.

The absolute offset is evaluated, so both positive and negative clock differences can trigger recovery.

### Fail-safe behavior

If a required recovery step fails after Bitcoin Core has stopped, the script records a persistent recovery marker, leaves Bitcoin Core stopped and exits with code `2`.

This prevents Bitcoin Core from continuing with an unverified system clock. The failure and its reason are recorded in the system journal.

On the next timer run, the marker tells the service that Bitcoin was stopped by automatic recovery. The service retries clock recovery even though Bitcoin Core is inactive. After the clock is verified and Bitcoin Core restarts successfully, the marker is removed.

An inactive Bitcoin service without the marker is treated as an intentional shutdown. Automatic recovery is skipped, so planned maintenance is not overridden.

### Service privileges and hardening

The recovery service runs as `root` because it must stop and start system services.

The service retains filesystem, home-directory, kernel, control-group, personality, SUID/SGID and address-family restrictions.

`NoNewPrivileges=true` is intentionally not used for this service. During testing, that restriction prevented `chronyc` from dropping privileges to the Chrony system user:

```text
setuid(...) failed: Operation not permitted
```

The service correctly treated this as a recovery failure and left Bitcoin Core stopped.

### Install the recovery script

Transfer the script from the repository to the VM:

```bash
multipass transfer \
  scripts/bitcoin-node-clock-recovery.sh \
  bitcoin-node:/home/ubuntu/bitcoin-node-clock-recovery.sh
```

Install it as a root-owned executable:

```bash
multipass exec -n bitcoin-node -- sudo install \
  -o root -g root -m 0755 \
  /home/ubuntu/bitcoin-node-clock-recovery.sh \
  /usr/local/bin/bitcoin-node-clock-recovery
```

### Install the systemd units

Transfer the service:

```bash
multipass transfer \
  systemd/bitcoin-node-clock-recovery.service \
  bitcoin-node:/home/ubuntu/bitcoin-node-clock-recovery.service
```

Transfer the timer:

```bash
multipass transfer \
  systemd/bitcoin-node-clock-recovery.timer \
  bitcoin-node:/home/ubuntu/bitcoin-node-clock-recovery.timer
```

Install both unit files:

```bash
multipass exec -n bitcoin-node -- sudo install \
  -o root -g root -m 0644 \
  /home/ubuntu/bitcoin-node-clock-recovery.service \
  /home/ubuntu/bitcoin-node-clock-recovery.timer \
  /etc/systemd/system/
```

Validate the installed units:

```bash
multipass exec -n bitcoin-node -- sudo systemd-analyze verify \
  /etc/systemd/system/bitcoin-node-clock-recovery.service \
  /etc/systemd/system/bitcoin-node-clock-recovery.timer
```

Ubuntu may print unrelated warnings about the removed `CPUAccounting` option in XFS units. The clock-recovery units are valid when no errors mention them and the command returns exit code `0`.

Reload systemd:

```bash
multipass exec -n bitcoin-node -- sudo systemctl daemon-reload
```

Enable and start the timer:

```bash
multipass exec -n bitcoin-node -- sudo systemctl enable --now \
  bitcoin-node-clock-recovery.timer
```

### Verify the timer

Confirm that the timer is enabled:

```bash
multipass exec -n bitcoin-node -- systemctl is-enabled \
  bitcoin-node-clock-recovery.timer
```

Expected output:

```text
enabled
```

Confirm that it is active:

```bash
multipass exec -n bitcoin-node -- systemctl is-active \
  bitcoin-node-clock-recovery.timer
```

Expected output:

```text
active
```

Show the previous and next scheduled checks:

```bash
multipass exec -n bitcoin-node -- systemctl list-timers \
  bitcoin-node-clock-recovery.timer \
  --no-pager
```

### Inspect automatic checks

Show checks from the last 30 minutes:

```bash
multipass exec -n bitcoin-node -- journalctl \
  -u bitcoin-node-clock-recovery.service \
  --since "30 minutes ago" \
  --no-pager
```

A normal healthy check resembles:

```text
[CLOCK-RECOVERY] Clock is healthy: Bitcoin time offset is -1s
```

A successful recovery records these stages:

```text
[CLOCK-RECOVERY] Severe Bitcoin time offset detected
[CLOCK-RECOVERY] Bitcoin Core stopped cleanly
[CLOCK-RECOVERY] Fresh Chrony samples requested
[CLOCK-RECOVERY] Chrony selected a fresh time source
[CLOCK-RECOVERY] Clock recovery verified
[CLOCK-RECOVERY] Recovery completed successfully
```

### Verify Bitcoin after recovery

Check Bitcoin Core:

```bash
multipass exec -n bitcoin-node -- bitcoin-cli -getinfo
```

Healthy output should show:

- Blocks equal to headers after catching up
- Verification progress at 100%
- Connected outbound peers
- Time offset close to zero
- No warnings

Check Chrony:

```bash
multipass exec -n bitcoin-node -- chronyc -N tracking
```

Healthy output should include:

```text
Leap status     : Normal
```

### Tested behavior

The implementation was tested on the running Apple Silicon Multipass node.

The healthy-clock path:

- Returned exit code `0`
- Reported a healthy Bitcoin time offset
- Left the Bitcoin process ID unchanged
- Did not interrupt Bitcoin Core

The forced recovery path:

- Detected the configured recovery condition
- Stopped Bitcoin Core cleanly
- Restarted Chrony
- Retried Chrony while its control interface became ready
- Requested fresh time samples
- Selected a valid NTP source
- Verified a near-zero clock offset
- Restarted Bitcoin Core
- Returned exit code `0`
- Preserved 100% blockchain synchronization
- Reconnected Bitcoin peers
- Produced no Bitcoin warnings

The failure-and-resume path was also tested. When Chrony could not select a source, the service:

- Returned exit code `2`
- Recorded the exact error in the journal
- Left Bitcoin Core stopped
- Preserved the persistent recovery marker
- Retried recovery on a later service run
- Verified the recovered clock
- Restarted Bitcoin Core automatically
- Cleared the recovery marker after success

An intentional Bitcoin shutdown without a recovery marker was also tested and remained inactive as expected.

### Disable automatic recovery

Disable and stop the timer:

```bash
multipass exec -n bitcoin-node -- sudo systemctl disable --now \
  bitcoin-node-clock-recovery.timer
```

Disabling the timer does not stop Bitcoin Core and does not remove the installed files.

Manual clock recovery remains available if automatic recovery cannot complete.

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

---

# Disaster recovery

The project includes a tested disaster-recovery runbook for rebuilding the node in a fresh Multipass VM from a tagged repository release.

The procedure covers Bitcoin Core checksum and signature verification, configuration restoration, systemd services, Chrony, health monitoring, secret handling, restart validation and full synchronization requirements.

See [docs/disaster-recovery.md](docs/disaster-recovery.md) for the complete recovery procedure, limitations, checklist and Multipass troubleshooting evidence.

---

# Pruned blockchain backup and restore

The project includes a tested cold-backup procedure for preserving and restoring the validated pruned blockchain state.

The backup contains only the public `blocks/` and `chainstate/` directories. It does not contain wallets, private keys, seed phrases, RPC credentials or other secret material.

The documented procedure covers clean Bitcoin Core shutdown, compressed archive creation, integrity verification, transfer to the Mac, restoration into a disposable VM and a complete synchronization and restart test.

The repository also includes tested automation that performs strict preflight checks, coordinates the cold backup, verifies the VM and Mac checksums, creates a manifest, restores services and cleans up temporary artifacts.

See [docs/blockchain-backup-restore.md](docs/blockchain-backup-restore.md) for the complete backup, restore, verification and recovery procedure.

See [docs/backup-automation.md](docs/backup-automation.md) for automated backup installation, safety behavior, execution, verification and troubleshooting.

The project also includes checksum-verified backup retention with a mandatory dry-run, protection for the newest two complete recovery points and explicitly confirmed deletion of older verified sets.

See [docs/backup-retention.md](docs/backup-retention.md) for retention policy, safety barriers, dry-run interpretation, controlled deletion, failure behavior and tested evidence.

The project also includes a daily read-only backup freshness audit. It checks local backup completeness, backup age, artifact permissions, remaining Mac storage and the newest external copy when the external drive is mounted.

The audit does not hash, transfer, modify or delete backup archives. Its macOS LaunchAgent sends notifications only when the result changes between `HEALTHY`, `WARNING` and `CRITICAL`.

See [docs/backup-freshness-monitor.md](docs/backup-freshness-monitor.md) for policy defaults, installation, notification behavior, testing and troubleshooting.

The project also includes a monthly read-only deep-integrity audit. It recalculates SHA-256 checksums and tests the complete Zstandard stream of retained backups without modifying the archives.

Successful checks create protected verification receipts. The optional external backup is checked when its drive is mounted, and state-change notifications report failures and recovery without repeating unchanged results.

See [docs/backup-deep-integrity.md](docs/backup-deep-integrity.md) for installation, verification scope, receipts, scheduling, notifications, resource requirements and troubleshooting.

The project also includes safe manual replication of the newest complete local backup to a removable external drive. It verifies the local checksum, transfers through `.partial` files, recalculates SHA-256 from the external copy and never overwrites or deletes an existing backup.

See [docs/backup-external-replication.md](docs/backup-external-replication.md) for the safety model, dry-run, confirmed execution, independent verification, failure handling and tested evidence.

---

# Sparrow Wallet and hardware-wallet preparation

The project includes a restricted Bitcoin Core RPC bridge for connecting Sparrow Wallet on the Mac directly to the pruned node inside Multipass.

The setup uses a dedicated `rpcauth` identity, root-protected credentials, the VM's private IPv4 address and an exact `/32` allow rule for the Mac bridge. It refuses wildcard RPC exposure, creates a rollback copy and restores the previous Bitcoin configuration if restart validation fails.

Sparrow's built-in Cormorant connector was tested against the node without creating a user wallet or connecting a hardware device. Cormorant created an internal descriptor wallet named `cormorant`; Bitcoin Core reported `private_keys_enabled: false`. The bridge therefore enables watch-only tracking without giving Bitcoin Core or Sparrow access to hardware-wallet private keys.

See [docs/sparrow-bitcoin-core.md](docs/sparrow-bitcoin-core.md) for the security model, setup command, protected password transfer, macOS Local Network permission, connection testing, rollback and Trezor safety checkpoint.

---

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
├── .github/
│   └── workflows/
│       └── validate.yml
├── .gitignore
├── LICENSE
├── README.md
├── config/
│   └── bitcoin.conf.example
├── docs/
│   ├── README.md
│   ├── alerting.md
│   ├── backup-automation.md
│   ├── backup-deep-integrity.md
│   ├── backup-external-replication.md
│   ├── backup-freshness-monitor.md
│   ├── backup-retention.md
│   ├── blockchain-backup-restore.md
│   ├── disaster-recovery.md
│   ├── monitoring.md
│   └── sparrow-bitcoin-core.md
├── launchd/
│   ├── com.pzhendov.bitcoin-node-backup-deep-notify.plist
│   ├── com.pzhendov.bitcoin-node-backup-notify.plist
│   └── com.pzhendov.bitcoin-node-health-notify.plist
├── scripts/
│   ├── bitcoin-node-backup-create.sh
│   ├── bitcoin-node-clock-recovery.sh
│   ├── bitcoin-node-health-runner.sh
│   ├── bitcoin-node-health.sh
│   ├── bitcoin-node-sparrow-rpc-setup.sh
│   ├── bitcoin-node-telegram-alert.sh
│   ├── macos-bitcoin-node-backup-audit.sh
│   ├── macos-bitcoin-node-backup-deep-audit.sh
│   ├── macos-bitcoin-node-backup-deep-notify.sh
│   ├── macos-bitcoin-node-backup-notify.sh
│   ├── macos-bitcoin-node-backup-replicate.sh
│   ├── macos-bitcoin-node-backup-retention.sh
│   ├── macos-bitcoin-node-backup.sh
│   └── macos-bitcoin-node-notify.sh
└── systemd/
    ├── bitcoin-node-clock-recovery.service
    ├── bitcoin-node-clock-recovery.timer
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
