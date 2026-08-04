# Bitcoin Node Disaster Recovery

This runbook explains how to rebuild the documented Bitcoin Core node in a fresh Multipass virtual machine without relying on the original VM, blockchain data or secret credentials.

It is intended both as an operational recovery procedure and as a repeatable disaster-recovery exercise.

## Tested recovery

The procedure was tested on 4 August 2026 with:

- Bitcoin Node Guide `v1.0.0`
- Commit `c34a84e53bc9ee216eba4ca491398c9c0d234b8c`
- Bitcoin Core 31.1 ARM64
- Multipass 1.16.3 using QEMU
- Ubuntu 26.04 LTS ARM64
- Apple M1 Pro with 16 GiB memory
- Four virtual CPUs
- 6 GiB VM memory
- 150 GiB virtual disk
- 50,000 MiB Bitcoin pruning target

The recovered node successfully:

- Started Bitcoin Core on mainnet
- Connected to outbound peers
- Began initial block download
- Preserved blockchain progress across a VM stop/start cycle
- Started `bitcoind` automatically through systemd
- Started the health-monitoring timer automatically
- Maintained a zero Bitcoin time offset
- Restored Chrony synchronization
- Reported no Bitcoin Core warnings

Initial block download must still reach 100% before the recovered node is considered fully synchronized.

### Rehearsal completion versus production recovery

A recovery rehearsal does not need to repeat the complete blockchain synchronization when the original production node is still healthy.

The tested rehearsal was intentionally stopped after proving the rebuild and operational recovery:

- Recovered height: 271,250
- Network headers: 960,989
- Verification progress: approximately 1.99%
- Initial block download: active, as expected
- Connected peers: 10
- Pruning: enabled
- Bitcoin time offset: 0 seconds
- Bitcoin warnings: none
- Bitcoin service survived a complete VM stop/start cycle
- Health-monitoring timer survived a complete VM stop/start cycle
- Chrony returned to normal synchronization after startup

This proves that the released repository, official Bitcoin Core artifacts and public Bitcoin network are sufficient to rebuild an operational node.

A real replacement node is not fully recovered for current production use until synchronization reaches 100%, blocks equal headers and `initialblockdownload` becomes `false`.

After the rehearsal, `bitcoin-recovery` was stopped and the original `bitcoin-node` was restored successfully at 100% synchronization with 10 peers, zero time offset, normal Chrony status and no warnings. Host-side macOS monitoring was then re-enabled.

## Recovery model

The public repository restores:

- Example Bitcoin Core configuration
- systemd service definitions
- Health-monitoring scripts
- Telegram alert dispatcher
- macOS notification script
- LaunchAgent example
- Operational documentation

The repository does not restore:

- Bitcoin blockchain or chainstate data
- Wallet files
- Seed phrases
- Private keys
- Bitcoin authentication cookies
- Telegram bot tokens
- Telegram chat IDs
- Local alert state
- VM images

A fresh pruned node must download and independently validate the blockchain again.

## Security rules

Never place any of the following in Git:

- Seed phrases
- Private keys
- Wallet files
- `.cookie`
- RPC passwords
- Telegram tokens
- Telegram chat IDs
- Live blockchain data
- VM images

This recovery procedure uses a node with wallet functionality disabled:

```ini
disablewallet=1
```

A Bitcoin node improves independent validation and privacy. It does not replace secure wallet custody or seed backups.

## Recovery objectives

The recovery is successful when:

- The released repository version is verified
- Bitcoin Core binaries pass checksum and signature verification
- The expected configuration is restored
- `bitcoind.service` is enabled and active
- The health timer is enabled and active
- Chrony is synchronized
- Bitcoin has peers
- Bitcoin reports no warnings
- The node resumes correctly after a VM stop/start cycle
- Initial block download eventually finishes
- Blocks and headers match
- `initialblockdownload` becomes `false`

## Resource planning

The tested production-sized VM uses:

```text
4 CPUs
6 GiB memory
150 GiB disk
```

On a Mac with 16 GiB memory, avoid synchronizing two 6 GiB Bitcoin VMs at the same time.

Check capacity before creating a recovery VM:

```bash
multipass list
multipass info bitcoin-node
df -h /
```

## Recovery VM naming

For a rehearsal, use:

```text
bitcoin-recovery
```

For a real replacement after the original VM is lost, use:

```text
bitcoin-node
```

Using the original production name allows existing host-side monitoring scripts to continue targeting the expected VM.

## Pause host-side monitoring during a rehearsal

The macOS LaunchAgent checks the VM every five minutes. During the tested exercise, those checks caused the stopped primary VM to start again.

Temporarily unload it:

```bash
launchctl bootout \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify"
```

Verify that it is unloaded:

```bash
launchctl print \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify"
```

The expected result is:

```text
Could not find service
```

Restore the LaunchAgent only after the intended production VM is running again.

## Record the healthy baseline

Before a planned rehearsal, record the current node state:

```bash
multipass exec bitcoin-node -- systemctl is-active bitcoind
multipass exec bitcoin-node -- bitcoin-cli -getinfo
multipass exec bitcoin-node -- chronyc -N tracking
```

A healthy baseline should show:

- Active Bitcoin service
- Blocks equal to headers
- 100% verification
- Connected peers
- Near-zero time offset
- No warnings
- Normal Chrony leap status

## Stop the original node safely

Stop Bitcoin Core first:

```bash
multipass exec bitcoin-node -- sudo systemctl stop bitcoind
```

Verify shutdown:

```bash
multipass exec bitcoin-node -- systemctl is-active bitcoind
multipass exec bitcoin-node -- tail -n 12 /home/ubuntu/.bitcoin/debug.log
```

The log should end with:

```text
Shutdown done
```

Stop the VM:

```bash
multipass stop bitcoin-node
```

## Create the recovery VM

For a rehearsal:

```bash
multipass launch 26.04 \
  --name bitcoin-recovery \
  --cpus 4 \
  --memory 6G \
  --disk 150G
```

Verify:

```bash
multipass info bitcoin-recovery
multipass list
```

## Verify cloud-init before continuing

Do not update or reboot the VM until cloud-init has completed:

```bash
multipass exec -n bitcoin-recovery -- cloud-init status --long
```

Required result:

```text
status: done
errors: []
```

Check the completion marker:

```bash
multipass exec -n bitcoin-recovery -- \
  test -e /var/lib/cloud/instance/boot-finished
```

## Verify architecture and time

```bash
multipass exec -n bitcoin-recovery -- whoami
multipass exec -n bitcoin-recovery -- hostname
multipass exec -n bitcoin-recovery -- uname -m
multipass exec -n bitcoin-recovery -- date -u
multipass exec -n bitcoin-recovery -- systemctl is-active chrony
```

Expected architecture:

```text
aarch64
```

## Update Ubuntu

```bash
multipass exec -n bitcoin-recovery -- sudo apt update
multipass exec -n bitcoin-recovery -- sudo apt upgrade
multipass exec -n bitcoin-recovery -- apt list --upgradable
```

After updating, test a controlled stop/start instead of immediately using `multipass restart`:

```bash
multipass stop bitcoin-recovery
multipass start --timeout 120 bitcoin-recovery
```

Verify cloud-init and Chrony again.

## Restore the tagged repository release

Clone the immutable release:

```bash
multipass exec -n bitcoin-recovery -- \
  git clone \
    --branch v1.0.0 \
    --depth 1 \
    https://github.com/pzhendov/bitcoin-node-guide.git \
    /home/ubuntu/bitcoin-node-guide
```

Verify the commit and tag:

```bash
multipass exec -n bitcoin-recovery -- \
  git -C /home/ubuntu/bitcoin-node-guide rev-parse HEAD

multipass exec -n bitcoin-recovery -- \
  git -C /home/ubuntu/bitcoin-node-guide describe --tags --exact-match
```

Expected:

```text
c34a84e53bc9ee216eba4ca491398c9c0d234b8c
v1.0.0
```

## Verify required tools

```bash
multipass exec -n bitcoin-recovery -- command -v git
multipass exec -n bitcoin-recovery -- command -v jq
multipass exec -n bitcoin-recovery -- command -v wget
multipass exec -n bitcoin-recovery -- command -v gpg
multipass exec -n bitcoin-recovery -- command -v sha256sum
multipass exec -n bitcoin-recovery -- command -v tar
```

## Check the current Bitcoin Core release

Before installing, check the official Bitcoin Core download page to determine whether the pinned version has been replaced by a newer security release:

https://bitcoincore.org/en/download/

This tested runbook uses Bitcoin Core 31.1.

## Download Bitcoin Core

Inside the recovery VM:

```bash
mkdir -p ~/bitcoin-download
cd ~/bitcoin-download
```

Download the ARM64 archive and verification files:

```bash
wget https://bitcoincore.org/bin/bitcoin-core-31.1/bitcoin-31.1-aarch64-linux-gnu.tar.gz
wget https://bitcoincore.org/bin/bitcoin-core-31.1/SHA256SUMS
wget https://bitcoincore.org/bin/bitcoin-core-31.1/SHA256SUMS.asc
```

## Verify the checksum

```bash
sha256sum --ignore-missing --check SHA256SUMS
```

Required result:

```text
bitcoin-31.1-aarch64-linux-gnu.tar.gz: OK
```

Do not continue after a failed checksum.

## Verify release signatures

Clone the Bitcoin Core reproducible-build signature repository:

```bash
git clone https://github.com/bitcoin-core/guix.sigs
```

Import the public builder keys:

```bash
gpg --import guix.sigs/builder-keys/*.gpg
```

Verify the signed checksum file:

```bash
gpg --verify SHA256SUMS.asc
```

The tested recovery produced 11 good signatures and no bad signatures.

Warnings about unknown trust do not indicate a cryptographic failure. Stop immediately if any signature is reported as bad.

## Inspect and extract Bitcoin Core

```bash
tar -tzf bitcoin-31.1-aarch64-linux-gnu.tar.gz | head -n 25
tar -xzf bitcoin-31.1-aarch64-linux-gnu.tar.gz
ls -lh bitcoin-31.1/bin
```

The archive should contain only the expected `bitcoin-31.1/` top-level directory.

## Install Bitcoin Core

```bash
sudo install -m 0755 -o root -g root \
  -t /usr/local/bin \
  bitcoin-31.1/bin/*
```

Verify:

```bash
command -v bitcoind
command -v bitcoin-cli
bitcoind --version
bitcoin-cli --version
```

Expected version:

```text
v31.1.0
```

## Restore Bitcoin configuration

```bash
install -d -m 0700 ~/.bitcoin
```

```bash
install -m 0600 \
  ~/bitcoin-node-guide/config/bitcoin.conf.example \
  ~/.bitcoin/bitcoin.conf
```

Verify:

```bash
ls -ld ~/.bitcoin
ls -l ~/.bitcoin/bitcoin.conf
cat ~/.bitcoin/bitcoin.conf
```

## Test Bitcoin Core manually

```bash
bitcoind -daemon
```

After a short wait:

```bash
bitcoin-cli -getinfo
bitcoin-cli getblockchaininfo
```

Expected:

- Mainnet
- Initial block download active
- Pruning enabled
- Outbound peers connecting
- No warnings

Stop the manual daemon:

```bash
bitcoin-cli stop
```

Verify:

```bash
pgrep -a bitcoind
tail -n 12 ~/.bitcoin/debug.log
```

The log should end with:

```text
Shutdown done
```

## Restore the Bitcoin systemd service

```bash
sudo install -m 0644 -o root -g root \
  ~/bitcoin-node-guide/systemd/bitcoind.service \
  /etc/systemd/system/bitcoind.service
```

Validate:

```bash
sudo systemd-analyze verify \
  /etc/systemd/system/bitcoind.service
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now bitcoind
```

Verify:

```bash
systemctl is-enabled bitcoind
systemctl is-active bitcoind
bitcoin-cli -getinfo
```

## Restore permanent clock recovery

Inspect the default setting:

```bash
grep -n '^[[:space:]]*makestep' /etc/chrony/chrony.conf
```

Create a rollback copy:

```bash
sudo cp -a \
  /etc/chrony/chrony.conf \
  /etc/chrony/chrony.conf.before-bitcoin-recovery
```

Apply the recovery setting:

```bash
sudo sed -i \
  's/^[[:space:]]*makestep[[:space:]].*/makestep 1 -1/' \
  /etc/chrony/chrony.conf
```

Restart and verify:

```bash
sudo systemctl restart chrony
chronyc -N tracking
bitcoin-cli -getinfo
```

Required:

- `Leap status: Normal`
- Near-zero Chrony offset
- Near-zero Bitcoin time offset

## Restore health-monitoring commands

The repository scripts have `.sh` filenames. Their installed production names do not.

Install with the correct mappings:

```bash
sudo install -m 0755 -o root -g root \
  ~/bitcoin-node-guide/scripts/bitcoin-node-health.sh \
  /usr/local/bin/bitcoin-node-health

sudo install -m 0755 -o root -g root \
  ~/bitcoin-node-guide/scripts/bitcoin-node-health-runner.sh \
  /usr/local/bin/bitcoin-node-health-runner

sudo install -m 0755 -o root -g root \
  ~/bitcoin-node-guide/scripts/bitcoin-node-telegram-alert.sh \
  /usr/local/bin/bitcoin-node-telegram-alert
```

Install the units:

```bash
sudo install -m 0644 -o root -g root \
  ~/bitcoin-node-guide/systemd/bitcoin-node-health.service \
  ~/bitcoin-node-guide/systemd/bitcoin-node-health.timer \
  /etc/systemd/system/
```

Validate:

```bash
sudo systemd-analyze verify \
  /etc/systemd/system/bitcoin-node-health.service \
  /etc/systemd/system/bitcoin-node-health.timer
```

## Test health monitoring

```bash
/usr/local/bin/bitcoin-node-health
echo $?
```

During initial synchronization, the expected status is `WARNING` with exit code `1`.

Enable the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now bitcoin-node-health.timer
```

Verify:

```bash
systemctl is-enabled bitcoin-node-health.timer
systemctl is-active bitcoin-node-health.timer
systemctl list-timers bitcoin-node-health.timer --no-pager
```

## Telegram credentials are a separate recovery dependency

Telegram credentials are intentionally absent from Git.

Do not copy them from the failed VM during a real recovery. Restore them from a secure password manager or generate a new bot token.

Until credentials are restored, create a temporary no-Telegram override:

```bash
sudo mkdir -p \
  /etc/systemd/system/bitcoin-node-health.service.d
```

Create:

```text
/etc/systemd/system/bitcoin-node-health.service.d/10-recovery-no-telegram.conf
```

Content:

```ini
[Service]
Environment=ALERT_SCRIPT=/usr/bin/true
```

Apply it:

```bash
sudo chmod 0644 \
  /etc/systemd/system/bitcoin-node-health.service.d/10-recovery-no-telegram.conf

sudo systemctl daemon-reload
```

Test:

```bash
sudo systemctl start bitcoin-node-health.service

systemctl show bitcoin-node-health.service \
  --property=Result \
  --property=ExecMainStatus
```

During synchronization, expected values are:

```text
Result=success
ExecMainStatus=1
```

No new Telegram credential errors should appear.

After securely restoring Telegram credentials, remove the temporary override:

```bash
sudo rm -- \
  /etc/systemd/system/bitcoin-node-health.service.d/10-recovery-no-telegram.conf

sudo systemctl daemon-reload
```

Then follow `docs/alerting.md` to recreate and test the protected credential file.

## Test automatic startup

Record current progress:

```bash
bitcoin-cli -getinfo
```

Leave the VM:

```bash
exit
```

Stop and start it from macOS:

```bash
multipass stop bitcoin-recovery
multipass start --timeout 120 bitcoin-recovery
```

Verify:

```bash
multipass exec -n bitcoin-recovery -- systemctl is-active bitcoind
multipass exec -n bitcoin-recovery -- systemctl is-active bitcoin-node-health.timer
multipass exec -n bitcoin-recovery -- bitcoin-cli -getinfo
multipass exec -n bitcoin-recovery -- chronyc -N tracking
```

A temporary RPC error such as this is normal immediately after startup:

```text
Loading block index…
```

Wait briefly and try again.

## Monitor initial synchronization

```bash
multipass exec -n bitcoin-recovery -- \
  bitcoin-cli getblockchaininfo |
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

Full recovery requires:

```text
blocks = headers
progress_percent = 100
initial_block_download = false
pruned = true
automatic_pruning = true
```

## Multipass stuck in Starting or Restarting

During the tested recovery, Multipass remained in `Starting` or `Restarting` even though Ubuntu was reachable.

Inspect state:

```bash
multipass list
```

Inspect the host ARP table:

```bash
arp -an | grep '192.168.252'
```

Test the discovered guest address:

```bash
ping -c 3 RECOVERY_VM_IP
nc -vz -w 3 RECOVERY_VM_IP 22
```

Inspect Multipass logs:

```bash
sudo tail -n 180 /Library/Logs/Multipass/multipassd.log
```

On macOS, Multipass daemon logs are stored under:

```text
/Library/Logs/Multipass/multipassd.log
```

If ping and SSH port 22 work but Multipass remains stuck, inspect the internal key directory without exposing its contents:

```bash
sudo ls -la \
  "/var/root/Library/Application Support/multipassd/ssh-keys"
```

Never print, copy, upload or commit the private key.

An advanced read-only authentication test can use the internal key:

```bash
sudo ssh \
  -i "/var/root/Library/Application Support/multipassd/ssh-keys/id_rsa" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ubuntu@RECOVERY_VM_IP \
  'whoami; hostname; cloud-init status --long'
```

If the guest is healthy but Multipass state remains stale, shut down the guest cleanly through that SSH connection:

```bash
sudo ssh \
  -i "/var/root/Library/Application Support/multipassd/ssh-keys/id_rsa" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ubuntu@RECOVERY_VM_IP \
  'sudo systemctl poweroff'
```

Confirm that no Bitcoin QEMU process remains:

```bash
ps -axo pid,stat,etime,command |
grep -E '[m]ultipassd|[q]emu-system.*bitcoin-(node|recovery)'
```

Only when no VM QEMU process is running, restart the Multipass daemon:

```bash
sudo launchctl kickstart -k \
  system/com.canonical.multipassd
```

Verify:

```bash
multipass version
multipass list
```

This repaired the stale Multipass control state during the tested recovery.

## Restore normal macOS monitoring after the drill

The macOS notification script currently targets the production VM named `bitcoin-node`.

After the rehearsal:

1. Stop `bitcoin-recovery`.
2. Start the original `bitcoin-node`.
3. Verify Bitcoin, Chrony and health monitoring.
4. Reload the macOS LaunchAgent.

Reload it:

```bash
launchctl bootstrap \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.pzhendov.bitcoin-node-health-notify.plist"
```

Enable and test it:

```bash
launchctl enable \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify"

launchctl kickstart -k \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify"
```

Verify:

```bash
launchctl print \
  "gui/$(id -u)/com.pzhendov.bitcoin-node-health-notify"
```

## Recovery limitations

A pruned node without a trusted blockchain backup must repeat initial block download.

The recovery time therefore includes:

- VM creation
- Ubuntu updates
- Bitcoin Core verification
- Configuration restoration
- Blockchain download
- Full independent validation
- Pruning
- Alert credential restoration
- Operational validation

Do not declare full recovery merely because `bitcoind` is active. Require completed synchronization and `initialblockdownload: false`.

## Final recovery checklist

- [ ] Correct repository tag restored
- [ ] Correct commit verified
- [ ] Latest suitable Bitcoin Core release confirmed
- [ ] SHA-256 checksum passed
- [ ] Multiple good signatures verified
- [ ] No bad signatures
- [ ] Bitcoin binaries installed as root-owned executables
- [ ] Bitcoin configuration restored with mode `0600`
- [ ] Wallet disabled
- [ ] Pruning enabled
- [ ] Bitcoin systemd service enabled and active
- [ ] Chrony synchronized
- [ ] `makestep 1 -1` configured
- [ ] Health scripts installed with correct production names
- [ ] Health timer enabled and active
- [ ] Secrets restored separately or alerting explicitly disabled
- [ ] VM stop/start test passed
- [ ] Peers connected
- [ ] Bitcoin warnings empty
- [ ] Blocks equal headers
- [ ] Verification progress 100%
- [ ] Initial block download false
- [ ] Normal production monitoring restored
