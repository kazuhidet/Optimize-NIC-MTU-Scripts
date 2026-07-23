# Optimize NIC MTU

This script uses IPv4 ping with fragmentation disabled to perform a binary search for the largest packet size that does not require fragmentation. It then adds the 20-byte IPv4 header and the 8-byte ICMP header to the detected value and sets the result as the Path MTU for the NIC. With .NET `PingOptions.DontFragment`, packets that exceed the MTU can be detected as `PacketTooBig`.

The script automatically selects the NIC used for the route to the target host by checking the route with `Find-NetRoute`.

## Basic Usage

Run the script from a PowerShell session started with administrator privileges.
The `-Target` option is required. It specifies the destination used to send ping packets and determine the optimal MTU value.
`-Target` can be specified as either an IPv4 address or a host name.

```PowerShell
C:\Scripts\Optimize-NicMtu.ps1 -Target 1.1.1.1
```

By default, the script searches for the optimal MTU by changing the packet size within the following range:

- Minimum MTU: 576
- Maximum MTU: 1500
- Number of attempts for each size: 3

The detected MTU is saved to both the current configuration and the configuration that remains effective after reboot. The script sets the network-layer MTU for the NIC using `NlMtuBytes` in `Set-NetIPInterface`.

## Specifying a NIC

You can specify the interface, or NIC, to test and configure by using the `-InterfaceAlias` option.

```PowerShell
C:\Scripts\Optimize-NicMtu.ps1 `
    -Target 1.1.1.1 `
    -InterfaceAlias "Ethernet"
```

If the NIC specified with `-InterfaceAlias` does not match the actual route to the destination specified by `-Target`, the script stops with an error to avoid modifying the wrong NIC.

You can check NIC names on Windows with the following command:

```PowerShell
Get-NetAdapter
```

The `Get-NetAdapter` command displays the network adapters and interface names on Windows.

Example output from `Get-NetAdapter`:

```text
Name                      InterfaceDescription         ifIndex Status       MacAddress             LinkSpeed
----                      --------------------         ------- ------       ----------             ---------
Ethernet                  Ethernet Adapter                   9 Up           XX-XX-XX-XX-XX-XX        10 Gbps
```

## Detecting the Optimal MTU Only

Use the `-DetectOnly` option to detect only the optimal MTU value without changing the NIC configuration.

```PowerShell
C:\Scripts\Optimize-NicMtu.ps1 `
    -Target 1.1.1.1 `
    -DetectOnly
```

Any MTU value that is temporarily changed during the search is restored to the original value when the script exits.

## Applying the MTU Temporarily

Use the `-Temporary` option to apply the detected optimal MTU only until the next reboot, without changing the persistent configuration.

```PowerShell
C:\Scripts\Optimize-NicMtu.ps1 `
    -Target 1.1.1.1 `
    -Temporary
```

In this case, only `ActiveStore` is changed, and the persistent configuration is left unchanged. Windows manages the current `Active` configuration separately from the `Persistent` configuration that is retained after reboot.

## Setting a Safety Margin

The following example subtracts 8 bytes from the detected value before applying it.
By specifying a margin with the `-SafetyMargin` option, you can apply an MTU value reduced by that margin from the detected MTU.

```PowerShell
C:\Scripts\Optimize-NicMtu.ps1 `
    -Target 1.1.1.1 `
    -SafetyMargin 8
```

For example, if the detected value is 1500, the script applies 1492.

## Searching for Jumbo Frames

By specifying the maximum packet size to search with the `-MaximumMtu` option, you can test values up to 9000 against a jumbo-frame-capable server on the LAN, as shown below.

```PowerShell
C:\Scripts\Optimize-NicMtu.ps1 `
    -Target 192.168.1.10 `
    -InterfaceAlias "Ethernet 2" `
    -MaximumMtu 9000
```

## Showing Detailed Ping Results

Add the `-ShowProbeDetails` option to display detailed progress during the binary search performed with `ping`.

```PowerShell
C:\Scripts\Optimize-NicMtu.ps1 `
    -Target 1.1.1.1 `
    -ShowProbeDetails
```

Example output:

```Console
IPv4 Path MTU Detection
  Target        : 1.1.1.1
  NIC           : Ethernet
  InterfaceIndex: 12
  Current MTU   : 1500
  Search range  : 576 - 1500

Starting binary search...
  MTU  1038: OK (Success)
  MTU  1269: OK (Success)
  MTU  1385: OK (Success)
  MTU  1443: OK (Success)
  MTU  1472: OK (Success)
  MTU  1486: NG (PacketTooBig)
  MTU  1479: NG (PacketTooBig)
  MTU  1475: OK (Success)
  MTU  1477: OK (Success)
  MTU  1478: NG (PacketTooBig)

Detected Path MTU : 1477
MTU to be applied : 1477
Estimated TCP MSS : 1437
```

The standard Windows `ping` command also supports disabling fragmentation with the `/f` option and specifying the payload size with the `/l` option. However, `/f` is available only for IPv4. Likewise, this script works only in IPv4 environments.
