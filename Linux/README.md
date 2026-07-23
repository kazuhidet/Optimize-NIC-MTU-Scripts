The script determines the route and network interface to the target host using `ip route get`, sets the IPv4 Don't Fragment (DF) flag with `ping -M do`, and uses a binary search to find the largest MTU that can pass through the route. Once detected, the MTU is applied to the NIC with `ip link set dev <NIC> mtu <value>`.

## Basic Usage

Administrator privileges are required. Run the script with `sudo`, or obtain root privileges with a command such as `su -` before executing it.

The `--target` option is required. It specifies the destination to which `ping` packets are sent in order to determine the optimal MTU. You can specify either an IPv4 address or a hostname.

```shell
chmod +x optimize-nic-mtu.sh
sudo ./optimize-nic-mtu.sh \
  --target 192.168.10.254
```

The NIC is automatically determined from the route to the target host.

## Specifying a NIC

Use the `--interface` option to specify the network interface whose optimal MTU should be detected and configured.

```shell
sudo ./optimize-nic-mtu.sh \
  --target 192.168.10.254 \
  --interface enp1s0
```

If the NIC specified with `--interface` does not match the actual route to the target, the script stops with an error to prevent the wrong NIC from being modified.

## Detecting the Optimal MTU Without Applying It

Use the `--detect-only` option to determine the optimal MTU without changing the NIC configuration.

```shell
sudo ./optimize-nic-mtu.sh \
  --target 192.168.10.254 \
  --detect-only
```

## Displaying Detailed Ping Results

Use the `--show-probes` option to display detailed progress during the binary search performed with `ping`.

```shell
sudo ./optimize-nic-mtu.sh \
  --target 192.168.10.254 \
  --detect-only \
  --show-probes
```

## Detecting the MTU of an Internet Connection

When you specify a router on the local network, such as `192.168.10.254`, the script normally measures only the LAN path between the Linux machine and the router.

To measure an external path that includes PPPoE or a VPN, specify an IPv4 host outside the local network that responds to `ping` requests.

```shell
sudo ./optimize-nic-mtu.sh \
  --target 1.1.1.1
```

## Setting a Safety Margin

The following example subtracts 8 bytes from the detected value before applying it.

Use the `--safety-margin` option to specify how many bytes should be subtracted from the detected MTU.

```shell
sudo ./optimize-nic-mtu.sh \
  --target 1.1.1.1 \
  --safety-margin 8
```

## Saving the MTU Persistently with NetworkManager

A normal MTU change made with `ip link set` affects only the currently running system. On systems managed by NetworkManager, use the following option to save the MTU in the connection profile as well.

```shell
sudo ./optimize-nic-mtu.sh \
  --target 1.1.1.1 \
  --persist-networkmanager
```

To explicitly specify the connection profile name:

```shell
sudo ./optimize-nic-mtu.sh \
  --target 1.1.1.1 \
  --persist-networkmanager \
  --nm-connection "Wired connection 1"
```

## Changing the Search Limit

For standard Ethernet connections, the script searches up to the default maximum of 1500 bytes. The following example limits the search to 1492 bytes for a PPPoE connection:

```shell
sudo ./optimize-nic-mtu.sh \
  --target 1.1.1.1 \
  --max-mtu 1492
```

## Detecting Jumbo Frame Support

Use the `--max-mtu` option to set the maximum packet size to test. The following example checks values up to 9000 bytes against a jumbo-frame-capable server on the local network:

```shell
sudo ./optimize-nic-mtu.sh \
  --target 192.168.10.10 \
  --interface enp2s0 \
  --max-mtu 9000
```

During the search, the script temporarily changes the NIC's MTU to the configured search limit. If that change fails, it continues using the NIC's current MTU as the search limit. If an error occurs, the original MTU is restored.
