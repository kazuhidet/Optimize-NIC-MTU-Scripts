# optimize-nic-mtu-macos.sh

`optimize-nic-mtu-macos.sh` detects the IPv4 Path MTU to a target host on macOS and can apply the detected value to the network interface used for that route.

The script resolves the target to IPv4, determines the route and network interface with `route -n get`, sends ICMP Echo probes with the Don't Fragment (DF) flag using the macOS `ping -D` option, and performs a binary search for the largest MTU that can traverse the path. The detected MTU is applied with `ifconfig`, and it can optionally be saved persistently with `networksetup`.

## Requirements

- macOS
- Bash 3.2 or later
- The following standard commands:
  - `ping`
  - `route`
  - `ifconfig`
  - `dscacheutil`
  - `networksetup` when `--persist-networksetup` is used
  - `awk`, `grep`, `sed`, `tr`, and `uname`

Changing the interface MTU requires root privileges. Run the script with `sudo` when applying an MTU or when the script needs to temporarily raise the interface MTU during probing.

## Basic Usage

The `--target` option is required. It specifies the destination used to determine the Path MTU. You can specify either an IPv4 address or a hostname.

```shell
chmod +x optimize-nic-mtu-macos.sh
sudo ./optimize-nic-mtu-macos.sh \
  --target 192.168.10.254
```

If `--interface` is omitted, the script automatically determines the network interface from the route to the target.

## Specifying a Network Interface

Use `--interface` to explicitly specify the interface to test and configure.

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 192.168.10.254 \
  --interface en0
```

Typical macOS interface names include `en0`, `en1`, `bridge0`, and `utun3`.

If the interface specified with `--interface` does not match the actual route to the target, the script stops with an error to avoid modifying the wrong interface.

## Detecting the MTU Without Applying It

Use `--detect-only` to determine the Path MTU without applying the final value to the interface.

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 192.168.10.254 \
  --detect-only
```

By default, the script may temporarily raise the interface MTU to `--max-mtu` so that values larger than the current interface MTU can be tested. This temporary change still requires root privileges.

To perform detection without changing the interface MTU at all, combine `--detect-only` with `--no-probe-mtu-adjustment`:

```shell
./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1 \
  --detect-only \
  --no-probe-mtu-adjustment
```

When probe MTU adjustment is disabled, the search is limited to the interface's current MTU if `--max-mtu` is higher.

## Displaying Detailed Probe Results

Use `--show-probes` to display detailed results for each tested MTU during the binary search.

```shell
./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1 \
  --detect-only \
  --no-probe-mtu-adjustment \
  --show-probes
```

## Detecting the MTU of an Internet Connection

When you specify a router on the local network, such as `192.168.10.254`, the script normally measures only the path between the Mac and that router.

To measure a path that includes an Internet connection, PPPoE link, tunnel, or VPN, specify an external IPv4 host that responds to ICMP Echo requests.

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1
```

The result is the Path MTU to the specified target, so a different destination or route may produce a different value.

## Setting a Safety Margin

Use `--safety-margin` to subtract a number of bytes from the detected Path MTU before applying it.

The following example subtracts 8 bytes:

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1 \
  --safety-margin 8
```

The script also displays an approximate TCP MSS value calculated as the applied MTU minus 40 bytes for a standard IPv4/TCP header.

## Saving the MTU Persistently with networksetup

A normal MTU change made with `ifconfig` affects the currently running interface configuration. Use `--persist-networksetup` to also save the detected MTU with macOS `networksetup` so that it remains configured after reconnecting or restarting the system.

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1 \
  --interface en0 \
  --persist-networksetup
```

`--persist-networksetup` cannot be used together with `--detect-only`.

If an error occurs after the persistent setting has been changed, the script attempts to restore the previous `networksetup` MTU configuration.

## Changing the Search Range

The default search range is 576 to 1500 bytes.

Use `--min-mtu` and `--max-mtu` to change the range. For example, to limit the maximum to 1492 bytes:

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1 \
  --max-mtu 1492
```

The minimum MTU must be at least 576 bytes. The maximum MTU can be up to 65535 bytes.

## Detecting Jumbo Frame Support

Use `--max-mtu` to test values above the standard Ethernet MTU. For example, the following command searches up to 9000 bytes against a jumbo-frame-capable host on the local network:

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 192.168.10.10 \
  --interface en0 \
  --max-mtu 9000
```

Before probing, the script normally attempts to temporarily set the interface MTU to the configured search maximum. If macOS or the interface rejects that value, the search maximum is reduced to the current interface MTU.

## Disabling Temporary Probe MTU Adjustment

Use `--no-probe-mtu-adjustment` if you do not want the script to temporarily change the interface MTU before probing.

```shell
./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1 \
  --detect-only \
  --no-probe-mtu-adjustment
```

With this option enabled, values above the interface's current MTU cannot be detected and the effective search maximum is limited accordingly.

## Probe Attempts and Timeout

Use `--attempts` to control how many ICMP Echo requests are tried for each MTU size. A size is considered successful if at least one attempt succeeds.

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1 \
  --attempts 5
```

Use `--timeout` to set the timeout, in seconds, for each ping attempt:

```shell
sudo ./optimize-nic-mtu-macos.sh \
  --target 1.1.1.1 \
  --timeout 3
```

The default values are 3 attempts and a 2-second timeout.

## Error Recovery

The script records the interface's original MTU before probing.

If it temporarily changes the interface MTU and an error or signal occurs before the new MTU is committed, it attempts to restore the original value. If a persistent `networksetup` change has already been made and a later error occurs, the previous persistent setting is also restored when possible.

## Options

```text
-t, --target HOST
    IPv4 address or hostname used to measure the Path MTU.

-i, --interface NAME
    Network interface to configure. If omitted, it is detected automatically.

--min-mtu N
    Minimum MTU to search. Default: 576

--max-mtu N
    Maximum MTU to search. Default: 1500

--attempts N
    Number of ping attempts for each tested MTU. Default: 3

--timeout SECONDS
    Timeout for each ping attempt. Default: 2 seconds

--safety-margin N
    Number of bytes subtracted from the detected MTU. Default: 0

--detect-only
    Detect the MTU without applying the final value.

--show-probes
    Display detailed probe results.

--no-probe-mtu-adjustment
    Do not temporarily raise the interface MTU before probing.

--persist-networksetup
    Save the detected MTU persistently using macOS networksetup.

-h, --help
    Display the script's help message.
```
