# Sparrow Wallet and Bitcoin Core

This guide connects Sparrow Wallet on the Mac directly to the Bitcoin Core
node running inside the `bitcoin-node` Multipass VM.

The design was tested with:

- An Apple Silicon Mac
- Multipass with the QEMU driver
- A pruned Bitcoin Core mainnet node
- Sparrow Wallet using its built-in Cormorant Bitcoin Core connector

The connection test reported the Bitcoin Core implementation banner and the
current node height. No user wallet or hardware device was required for that
test. Cormorant automatically created an internal descriptor wallet named
`cormorant`; Bitcoin Core reported `private_keys_enabled: false`.

## Security model

The bridge deliberately exposes Bitcoin Core RPC only on the private Multipass
network shared by the Mac and VM.

The configuration:

- Uses Bitcoin Core `rpcauth` instead of a plaintext `rpcpassword` directive
- Creates a dedicated RPC identity named `sparrow`
- Binds RPC to localhost and the VM's private Multipass IPv4 address
- Allows the exact Mac bridge IPv4 address with a `/32` rule
- Refuses `0.0.0.0` wildcard addresses
- Stores the generated password only in a root-owned mode-`0600` file
- Keeps the RPC include owned by `ubuntu` with mode `0600`
- Creates a timestamped copy of the previous `bitcoin.conf`
- Restores the previous configuration if Bitcoin Core fails validation

RPC traffic on this bridge is not encrypted. The restriction to the private
Multipass network and one exact client address is therefore essential. Never
forward port `8332`, expose it through a router, or reuse the RPC password.

## Wallet boundary

The standard node configuration uses `disablewallet=1`. Sparrow's direct
Bitcoin Core connector needs the Bitcoin Core wallet subsystem for descriptor
and transaction tracking, so the dedicated setup changes this to
`disablewallet=0`.

This does not place hardware-wallet private keys in Bitcoin Core. With a Trezor
hardware wallet:

- Sparrow stores public wallet information and constructs transactions
- Bitcoin Core validates the chain and supplies wallet history
- The Trezor holds private keys and signs transactions on the device

Never enter a Trezor seed phrase, PIN or passphrase into Bitcoin Core, the VM,
Terminal, Git, this repository or a chat.

## Pruned-node limitation

A pruned node is suitable for a newly created wallet. It cannot rescan wallet
history earlier than its oldest retained block. For a wallet with historical
transactions, use a node that retains the required blocks or restore the
needed history through an appropriate recovery procedure.

## Requirements

Before configuration, require all of the following:

- `bitcoin-node` is running
- Bitcoin Core is fully synchronized
- Blocks equal headers
- Verification progress is 100%
- Initial block download is false
- Bitcoin warnings are empty
- Chrony leap status is `Normal`
- The official Bitcoin Core `share/rpcauth/rpcauth.py` file is available
- The Mac and VM private IPv4 addresses have been verified

Check the node:

```bash
multipass exec -n bitcoin-node -- bitcoin-cli -getinfo

multipass exec -n bitcoin-node -- chronyc -N tracking
```

Inspect the VM address:

```bash
multipass info bitcoin-node | grep '^IPv4:'
```

Inspect the Mac Multipass bridge:

```bash
ipconfig getifaddr bridge100
```

Example addresses used during the test were:

```text
VM:  192.168.252.3
Mac: 192.168.252.1
```

Always use the current addresses reported on your own Mac.

## Install the setup command

Transfer the repository script into the VM:

```bash
cd ~/bitcoin-node-guide

multipass transfer \
  scripts/bitcoin-node-sparrow-rpc-setup.sh \
  bitcoin-node:/home/ubuntu/bitcoin-node-sparrow-rpc-setup.sh
```

Install it with root ownership:

```bash
multipass exec -n bitcoin-node -- sudo install \
  -o root -g root -m 0755 \
  /home/ubuntu/bitcoin-node-sparrow-rpc-setup.sh \
  /usr/local/bin/bitcoin-node-sparrow-rpc-setup
```

Verify its syntax and help output:

```bash
multipass exec -n bitcoin-node -- \
  bash -n /usr/local/bin/bitcoin-node-sparrow-rpc-setup

multipass exec -n bitcoin-node -- \
  /usr/local/bin/bitcoin-node-sparrow-rpc-setup --help
```

## Install a new bridge

Locate the official authentication generator:

```bash
multipass exec -n bitcoin-node -- \
  find /home/ubuntu -type f -path '*/share/rpcauth/rpcauth.py' -print
```

Run the explicitly confirmed installation with the current VM address, Mac
bridge address and returned `rpcauth.py` path:

```bash
multipass exec -n bitcoin-node -- sudo \
  /usr/local/bin/bitcoin-node-sparrow-rpc-setup \
    --install \
    --confirm-sparrow-rpc \
    --server-ip 192.168.252.3 \
    --client-ip 192.168.252.1 \
    --rpcauth-tool \
      /home/ubuntu/bitcoin-download/bitcoin-31.1/share/rpcauth/rpcauth.py
```

Replace all example paths and addresses with the currently verified values.

The command does not print the generated password. Successful output reports:

- Restricted listener validation
- Protected credential-file validation
- The timestamped rollback-file path
- The root-only credential-file path

If the bridge already exists, `--install` performs validation without rotating
the working credential.

## Run a read-only bridge check

The normal operational command is read-only:

```bash
multipass exec -n bitcoin-node -- sudo \
  /usr/local/bin/bitcoin-node-sparrow-rpc-setup --check
```

Also confirm that the Mac can reach the private RPC listener:

```bash
nc -vz -w 5 192.168.252.3 8332
```

Expected output reports a successful TCP connection.

## Copy the RPC password without displaying it

The following Mac command reads the password from the protected VM file,
places it on the macOS clipboard and clears the shell variable. It does not
print the password:

```bash
rpc_password="$(
  multipass exec -n bitcoin-node -- sudo awk \
    'found { print; exit } /^Your password:/ { found = 1 }' \
    /root/sparrow-rpc-credentials.txt
)"

if [[ -z "$rpc_password" ]]; then
  echo "RPC password was not found" >&2
  unset rpc_password
  return 1 2>/dev/null || exit 1
fi

printf '%s' "$rpc_password" | pbcopy
unset rpc_password
```

The clipboard now contains sensitive data. Paste it only into Sparrow's
Bitcoin Core password field. Copy harmless text after the connection succeeds
to replace it on the clipboard:

```bash
printf '%s' 'clipboard cleared' | pbcopy
```

## Configure Sparrow

Open Sparrow and select:

```text
Tools -> Preferences -> Server
```

Set:

```text
Type:           Bitcoin Core
URL:            current bitcoin-node IPv4 address
Port:           8332
Authentication: User / Pass
User:           sparrow
Password:       protected password copied from the VM
Use Proxy:      Off
```

Click **Test Connection**.

Successful output resembles:

```text
Connected to Cormorant ...
Batched RPC enabled.
Server Banner: Cormorant ...
/Satoshi:.../
```

The Sparrow status bar then reports the private RPC URL and current block
height.

## macOS Local Network permission

If Sparrow reports `No route to host` while Terminal can ping the VM and reach
port `8332`, enable:

```text
System Settings
  -> Privacy & Security
  -> Local Network
  -> Sparrow: On
```

Quit Sparrow completely with `Command + Q`, reopen it and test the connection
again. Do not change a working username or password for a local-network
permission error.

## Post-connection verification

Confirm that Cormorant's internal wallet contains no private keys:

```bash
multipass exec -n bitcoin-node -- bitcoin-cli \
  -rpcwallet=cormorant getwalletinfo |
jq '{
  walletname,
  format,
  private_keys_enabled,
  descriptors,
  external_signer
}'
```

Require:

```text
"private_keys_enabled": false
"descriptors": true
```

Check the production services and node:

```bash
multipass exec -n bitcoin-node -- systemctl is-active bitcoind
multipass exec -n bitcoin-node -- systemctl is-active bitcoin-node-health.timer
multipass exec -n bitcoin-node -- systemctl is-active bitcoin-node-clock-recovery.timer
multipass exec -n bitcoin-node -- bitcoin-cli -getinfo
multipass exec -n bitcoin-node -- chronyc -N tracking
```

Require:

- All three units active
- Blocks equal headers
- Verification progress 100%
- Time offset near zero
- Bitcoin warnings empty
- Chrony leap status `Normal`

Inspect RPC listeners without exposing credentials:

```bash
multipass exec -n bitcoin-node -- sudo ss -lntp |
grep ':8332'
```

Expected listeners include localhost and the VM's private address. There must
be no `0.0.0.0:8332` listener.

## Rollback

Use the exact rollback path reported during installation:

```bash
multipass exec -n bitcoin-node -- sudo \
  /usr/local/bin/bitcoin-node-sparrow-rpc-setup \
    --rollback \
      /home/ubuntu/.bitcoin/bitcoin.conf.before-sparrow-YYYYMMDDTHHMMSSZ \
    --confirm-rollback
```

Rollback:

- Stops Bitcoin Core
- Restores the selected previous `bitcoin.conf`
- Removes the Sparrow RPC include and credential file
- Starts Bitcoin Core
- Requires Bitcoin RPC to become healthy

After rollback, verify that RPC is local-only:

```bash
multipass exec -n bitcoin-node -- sudo ss -lntp |
grep ':8332'
```

## Trezor safety checkpoint

Do not create or import a real wallet until the hardware-device procedure is
ready. For a previously used Trezor:

1. Confirm that no funds remain in any standard or passphrase-hidden wallet.
2. Verify the device and firmware through official Trezor software.
3. Reset the device only after the balance check.
4. Generate a new seed on the physical device.
5. Record the seed offline and never photograph or type it into the Mac.
6. Import only the hardware wallet's public information into Sparrow.
7. Verify every receive address on the Trezor screen.
8. Test first with a small amount before transferring the intended balance.

The Bitcoin Core bridge can be prepared and tested without connecting the
Trezor.

## Final checklist

- [ ] Bitcoin node fully synchronized
- [ ] Chrony synchronized
- [ ] Current VM and Mac bridge IPv4 addresses verified
- [ ] Official `rpcauth.py` used
- [ ] Dedicated `sparrow` RPC identity created
- [ ] RPC include mode `0600` and owned by `ubuntu`
- [ ] Credential file mode `0600` and owned by `root`
- [ ] No plaintext RPC password in Bitcoin configuration
- [ ] RPC not bound to `0.0.0.0`
- [ ] Exact Mac `/32` allow rule configured
- [ ] Bitcoin restart validation passed
- [ ] Mac TCP test passed
- [ ] Sparrow Local Network permission enabled
- [ ] Cormorant connection test passed
- [ ] Cormorant wallet reports `private_keys_enabled: false`
- [ ] Node services remained healthy
- [ ] Clipboard replaced with harmless text
- [ ] Timestamped rollback file recorded
- [ ] No Trezor secret entered into the computer
