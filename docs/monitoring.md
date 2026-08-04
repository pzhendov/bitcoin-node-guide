# Bitcoin node health monitoring

This project includes an automated health monitor for the Bitcoin Core node.

The monitor runs as the unprivileged `ubuntu` user, reads Bitcoin Core data through local cookie-authenticated RPC and writes its results to the systemd journal. It does not transmit monitoring data to an external service.

## Files

```text
scripts/bitcoin-node-health.sh
systemd/bitcoin-node-health.service
systemd/bitcoin-node-health.timer
```

Installed locations inside the VM:

```text
/usr/local/bin/bitcoin-node-health
/etc/systemd/system/bitcoin-node-health.service
/etc/systemd/system/bitcoin-node-health.timer
```

## Checks

The monitor checks:

- `bitcoind.service` is active
- Initial block download is complete
- Block height is close to header height
- Pruning is active
- Bitcoin network activity is enabled
- At least one outbound peer is connected
- Bitcoin peer time offset is acceptable
- Chrony reports a normal leap status
- Chrony system time offset is acceptable
- Sufficient disk space is available
- Sufficient memory is available

## Default thresholds

| Check | Warning | Critical |
|---|---:|---:|
| Block/header gap | More than 6 blocks | Not applicable |
| Bitcoin time offset | 10 seconds | 60 seconds |
| Free disk space | 20% or less | 10% or less |
| Available memory | 512 MiB or less | 256 MiB or less |
| Outbound peers | Zero | Not applicable |
| Chrony system offset | More than 1 second | Not applicable |

## Exit codes

| Exit code | Meaning |
|---:|---|
| `0` | Healthy |
| `1` | Warning |
| `2` | Critical |

The systemd service treats exit code `1` as a successful execution so that a warning is recorded without leaving the service in a failed state. Exit code `2` marks the service as failed.

## Install the script

From the project repository on the Mac:

```bash
multipass transfer \
  scripts/bitcoin-node-health.sh \
  bitcoin-node:/home/ubuntu/bitcoin-node-health.sh
```

Install it inside the VM:

```bash
multipass exec bitcoin-node -- \
  sudo install \
    -o root \
    -g root \
    -m 0755 \
    /home/ubuntu/bitcoin-node-health.sh \
    /usr/local/bin/bitcoin-node-health
```

Run it manually:

```bash
multipass exec bitcoin-node -- \
  /usr/local/bin/bitcoin-node-health
```

## Install the systemd units

Transfer the unit files:

```bash
multipass transfer \
  systemd/bitcoin-node-health.service \
  bitcoin-node:/home/ubuntu/bitcoin-node-health.service

multipass transfer \
  systemd/bitcoin-node-health.timer \
  bitcoin-node:/home/ubuntu/bitcoin-node-health.timer
```

Validate them:

```bash
multipass exec bitcoin-node -- \
  sudo systemd-analyze verify \
    /home/ubuntu/bitcoin-node-health.service \
    /home/ubuntu/bitcoin-node-health.timer
```

Install them:

```bash
multipass exec bitcoin-node -- \
  sudo install -o root -g root -m 0644 \
    /home/ubuntu/bitcoin-node-health.service \
    /etc/systemd/system/bitcoin-node-health.service

multipass exec bitcoin-node -- \
  sudo install -o root -g root -m 0644 \
    /home/ubuntu/bitcoin-node-health.timer \
    /etc/systemd/system/bitcoin-node-health.timer
```

Reload systemd:

```bash
multipass exec bitcoin-node -- sudo systemctl daemon-reload
```

Enable the timer:

```bash
multipass exec bitcoin-node -- \
  sudo systemctl enable --now bitcoin-node-health.timer
```

## Verify the timer

Check whether it is enabled and active:

```bash
multipass exec bitcoin-node -- \
  systemctl is-enabled bitcoin-node-health.timer

multipass exec bitcoin-node -- \
  systemctl is-active bitcoin-node-health.timer
```

Display the next scheduled execution:

```bash
multipass exec bitcoin-node -- \
  systemctl list-timers bitcoin-node-health.timer \
    --all \
    --no-pager
```

## Read monitoring results

Show recent health checks:

```bash
multipass exec bitcoin-node -- \
  journalctl -u bitcoin-node-health.service \
    --since "30 minutes ago" \
    --no-pager
```

Show only summaries:

```bash
multipass exec bitcoin-node -- \
  journalctl -u bitcoin-node-health.service \
    --no-pager |
grep '\[SUMMARY\]'
```

Show warnings and critical results:

```bash
multipass exec bitcoin-node -- \
  journalctl -u bitcoin-node-health.service \
    --no-pager |
grep -E '\[(WARNING|CRITICAL)\]'
```

## Run an immediate check

```bash
multipass exec bitcoin-node -- \
  sudo systemctl start bitcoin-node-health.service
```

Inspect the result:

```bash
multipass exec bitcoin-node -- \
  systemctl show bitcoin-node-health.service \
    --property=Result \
    --property=ExecMainStatus
```

## Stop or disable monitoring

The following commands are provided for future maintenance. Do not run them when monitoring should remain active.

Stop the timer temporarily:

```bash
multipass exec bitcoin-node -- \
  sudo systemctl stop bitcoin-node-health.timer
```

Disable the timer permanently:

```bash
multipass exec bitcoin-node -- \
  sudo systemctl disable --now bitcoin-node-health.timer
```

The monitor observes and reports node health. It does not automatically restart Bitcoin Core, modify its configuration or send external notifications.
