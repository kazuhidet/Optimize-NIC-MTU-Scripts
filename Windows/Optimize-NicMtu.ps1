#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Detects the optimal IPv4 Path MTU using ping and applies it to the active NIC.

.DESCRIPTION
    Sends ICMP Echo Requests with the Don't Fragment flag set,
    then uses a binary search to find the largest packet size that receives a response.

        MTU = ICMP payload + IPv4 header (20 bytes) + ICMP header (8 bytes)

    Automatically detects the NIC from the best route to the target host.
    Temporarily changes the ActiveStore MTU to MaximumMtu during the binary search,
    and restores the original value when only detecting the MTU or when an error occurs.

.EXAMPLE
    .\Optimize-NicMtu.ps1 -Target 1.1.1.1

.EXAMPLE
    .\Optimize-NicMtu.ps1 -Target 8.8.8.8 -InterfaceAlias "Ethernet"

.EXAMPLE
    .\Optimize-NicMtu.ps1 -Target 1.1.1.1 -DetectOnly

.EXAMPLE
    .\Optimize-NicMtu.ps1 -Target 192.168.1.10 -MaximumMtu 9000
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Target,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InterfaceAlias,

    [Parameter()]
    [ValidateRange(576, 65528)]
    [int]$MinimumMtu = 576,

    [Parameter()]
    [ValidateRange(576, 65528)]
    [int]$MaximumMtu = 1500,

    [Parameter()]
    [ValidateRange(1, 20)]
    [int]$Attempts = 3,

    [Parameter()]
    [ValidateRange(100, 30000)]
    [int]$TimeoutMs = 1500,

    [Parameter()]
    [ValidateRange(0, 512)]
    [int]$SafetyMargin = 0,

    [Parameter()]
    [switch]$DetectOnly,

    [Parameter()]
    [switch]$Temporary,

    [Parameter()]
    [switch]$SkipProbeMtuAdjustment,

    [Parameter()]
    [switch]$ShowProbeDetails
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$HeaderBytes = 28

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-IPv4 {
    param([Parameter(Mandatory)][string]$Name)

    $ip = $null
    if ([Net.IPAddress]::TryParse($Name, [ref]$ip)) {
        if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Please specify an IPv4 address: $Name"
        }
        return $ip
    }

    try {
        $addresses = [Net.Dns]::GetHostAddresses($Name)
    }
    catch {
        throw "Failed to resolve the name: $Name"
    }

    $ipv4 = @($addresses | Where-Object {
        $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
    })

    if ($ipv4.Count -eq 0) {
        throw "Could not obtain an IPv4 address: $Name"
    }

    return $ipv4[0]
}

function Get-Mtu {
    param(
        [Parameter(Mandatory)][uint32]$InterfaceIndex,
        [Parameter(Mandatory)]
        [ValidateSet("ActiveStore", "PersistentStore")]
        [string]$PolicyStore
    )

    $item = Get-NetIPInterface `
        -InterfaceIndex $InterfaceIndex `
        -AddressFamily IPv4 `
        -PolicyStore $PolicyStore `
        -ErrorAction Stop |
        Select-Object -First 1

    if ($null -eq $item) {
        throw "Could not retrieve interface information from $PolicyStore."
    }

    return [int]$item.NlMtu
}

function Set-Mtu {
    param(
        [Parameter(Mandatory)][uint32]$InterfaceIndex,
        [Parameter(Mandatory)][ValidateRange(576, 65528)][int]$Mtu,
        [Parameter(Mandatory)]
        [ValidateSet("ActiveStore", "PersistentStore")]
        [string]$PolicyStore
    )

    Set-NetIPInterface `
        -InterfaceIndex $InterfaceIndex `
        -AddressFamily IPv4 `
        -NlMtuBytes $Mtu `
        -PolicyStore $PolicyStore `
        -Confirm:$false `
        -ErrorAction Stop

    $actual = Get-Mtu -InterfaceIndex $InterfaceIndex -PolicyStore $PolicyStore
    if ($actual -ne $Mtu) {
        throw "Failed to set the MTU in $PolicyStore. Requested=$Mtu Actual=$actual"
    }
}

function Invoke-DfPing {
    param(
        [Parameter(Mandatory)][Net.IPAddress]$Address,
        [Parameter(Mandatory)][ValidateRange(0, 65500)][int]$PayloadSize
    )

    $buffer = New-Object byte[] $PayloadSize
    $options = New-Object Net.NetworkInformation.PingOptions(128, $true)
    $statuses = New-Object 'System.Collections.Generic.List[string]'

    for ($i = 1; $i -le $Attempts; $i++) {
        $ping = New-Object Net.NetworkInformation.Ping
        try {
            $reply = $ping.Send($Address, $TimeoutMs, $buffer, $options)
            [void]$statuses.Add([string]$reply.Status)

            if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                return [pscustomobject]@{
                    Success  = $true
                    Reason   = "Success"
                    Statuses = $statuses.ToArray()
                }
            }

            if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::PacketTooBig) {
                return [pscustomobject]@{
                    Success  = $false
                    Reason   = "PacketTooBig"
                    Statuses = $statuses.ToArray()
                }
            }
        }
        catch {
            [void]$statuses.Add(
                "Exception: $($_.Exception.GetBaseException().Message)"
            )
        }
        finally {
            $ping.Dispose()
        }
    }

    [pscustomobject]@{
        Success  = $false
        Reason   = "NoReply"
        Statuses = $statuses.ToArray()
    }
}

function Test-MtuSize {
    param(
        [Parameter(Mandatory)][Net.IPAddress]$Address,
        [Parameter(Mandatory)][int]$Mtu
    )

    $payload = $Mtu - $HeaderBytes
    $result = Invoke-DfPing -Address $Address -PayloadSize $payload

    if ($ShowProbeDetails) {
        Write-Host ("  MTU={0}, Payload={1}, Result={2}, Status={3}" -f `
            $Mtu, $payload, $result.Reason, ($result.Statuses -join ", "))
    }
    else {
        $mark = if ($result.Success) { "OK" } else { "NG" }
        Write-Host ("  MTU {0,5}: {1} ({2})" -f $Mtu, $mark, $result.Reason)
    }

    return $result
}

if (-not (Test-Administrator)) {
    throw "Please run PowerShell as Administrator."
}

if ($MinimumMtu -gt $MaximumMtu) {
    throw "MinimumMtu must be less than or equal to MaximumMtu."
}

$started = Get-Date
$address = Resolve-IPv4 -Name $Target

try {
    $routeResult = @(Find-NetRoute `
        -RemoteIPAddress $address.IPAddressToString `
        -ErrorAction Stop)
}
catch {
    throw "Could not retrieve the route to the target: $($_.Exception.Message)"
}

$route = $routeResult |
    Where-Object {
        $null -ne $_.InterfaceIndex -and $_.AddressFamily -eq "IPv4"
    } |
    Select-Object -First 1

if ($null -eq $route) {
    throw "No IPv4 route to the target was found."
}

$routeIndex = [uint32]$route.InterfaceIndex

if ([string]::IsNullOrWhiteSpace($InterfaceAlias)) {
    $iface = Get-NetIPInterface `
        -InterfaceIndex $routeIndex `
        -AddressFamily IPv4 `
        -PolicyStore ActiveStore `
        -ErrorAction Stop |
        Select-Object -First 1
}
else {
    $iface = Get-NetIPInterface `
        -InterfaceAlias $InterfaceAlias `
        -AddressFamily IPv4 `
        -PolicyStore ActiveStore `
        -ErrorAction Stop |
        Select-Object -First 1

    if ([uint32]$iface.InterfaceIndex -ne $routeIndex) {
        throw @"
The specified NIC does not match the actual route to the target.
Specified NIC: $($iface.InterfaceAlias) (ifIndex $($iface.InterfaceIndex))
Actual route : $($route.InterfaceAlias) (ifIndex $routeIndex)
"@
    }
}

$ifIndex = [uint32]$iface.InterfaceIndex
$ifAlias = [string]$iface.InterfaceAlias

$adapter = Get-NetAdapter `
    -InterfaceIndex $ifIndex `
    -IncludeHidden `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($null -ne $adapter -and $adapter.Status -ne "Up") {
    throw "NIC '$ifAlias' is not in the Up state: $($adapter.Status)"
}

$originalActive = Get-Mtu `
    -InterfaceIndex $ifIndex `
    -PolicyStore ActiveStore

try {
    $originalPersistent = Get-Mtu `
        -InterfaceIndex $ifIndex `
        -PolicyStore PersistentStore
}
catch {
    $originalPersistent = $originalActive
    Write-Warning "Failed to read PersistentStore; ActiveStore will be used as the restore value."
}

Write-Host ""
Write-Host "IPv4 Path MTU Detection" -ForegroundColor Cyan
Write-Host "  Target        : $Target ($address)"
Write-Host "  NIC           : $ifAlias"
Write-Host "  InterfaceIndex: $ifIndex"
Write-Host "  Current MTU   : $originalActive"
Write-Host "  Search range  : $MinimumMtu - $MaximumMtu"
Write-Host ""

$probeAdjusted = $false
$persistentChanged = $false
$committed = $false
$detected = $null
$applied = $null

try {
    $smallPing = Invoke-DfPing -Address $address -PayloadSize 32
    if (-not $smallPing.Success) {
        throw "Could not receive an ICMP response from the target: $($smallPing.Statuses -join ', ')"
    }

    if (-not $SkipProbeMtuAdjustment -and $originalActive -ne $MaximumMtu) {
        Write-Host "Temporarily changing the ActiveStore MTU to $MaximumMtu for probing." `
            -ForegroundColor Cyan

        Set-Mtu `
            -InterfaceIndex $ifIndex `
            -Mtu $MaximumMtu `
            -PolicyStore ActiveStore

        $probeAdjusted = $true
        Start-Sleep -Milliseconds 300
    }
    elseif ($SkipProbeMtuAdjustment -and $originalActive -lt $MaximumMtu) {
        Write-Warning "Values larger than the current MTU may not be detected correctly."
    }

    Write-Host "Starting binary search..." -ForegroundColor Cyan

    $minResult = Test-MtuSize -Address $address -Mtu $MinimumMtu
    if (-not $minResult.Success) {
        throw "No response even with the minimum MTU $MinimumMtu."
    }

    $low = $MinimumMtu
    $high = $MaximumMtu
    $best = $MinimumMtu

    while ($low -le $high) {
        $mid = [int][Math]::Floor(($low + $high) / 2)

        if ($mid -eq $MinimumMtu -and $low -eq $MinimumMtu) {
            $low = $MinimumMtu + 1
            continue
        }

        $r = Test-MtuSize -Address $address -Mtu $mid

        if ($r.Success) {
            $best = $mid
            $low = $mid + 1
        }
        else {
            $high = $mid - 1
        }
    }

    $detected = $best
    $applied = $detected - $SafetyMargin

    if ($applied -lt 576) {
        throw "The MTU after applying SafetyMargin is below 576: $applied"
    }

    Write-Host ""
    Write-Host "Detected Path MTU: $detected" -ForegroundColor Green
    Write-Host "MTU to apply     : $applied"
    Write-Host "Estimated TCP MSS: $($applied - 40)"

    if ($detected -eq $MaximumMtu) {
        Write-Warning "The probe succeeded up to the search upper bound. The actual Path MTU may be higher."
    }

    if ($DetectOnly) {
        Write-Host "DetectOnly is enabled; no MTU setting will be changed." -ForegroundColor Yellow
    }
    else {
        if (-not $Temporary) {
            Set-Mtu `
                -InterfaceIndex $ifIndex `
                -Mtu $applied `
                -PolicyStore PersistentStore
            $persistentChanged = $true
        }

        Set-Mtu `
            -InterfaceIndex $ifIndex `
            -Mtu $applied `
            -PolicyStore ActiveStore

        $committed = $true
        $probeAdjusted = $false
        Start-Sleep -Milliseconds 300

        $verify = Test-MtuSize -Address $address -Mtu $applied
        if (-not $verify.Success) {
            throw "Connectivity verification failed after applying the MTU setting."
        }

        if ($Temporary) {
            Write-Host "Temporarily applied MTU $applied." -ForegroundColor Green
        }
        else {
            Write-Host "Persistently applied MTU $applied." -ForegroundColor Green
        }
    }
}
catch {
    if ($persistentChanged) {
        try {
            Set-Mtu `
                -InterfaceIndex $ifIndex `
                -Mtu $originalPersistent `
                -PolicyStore PersistentStore
            Write-Warning "Restored PersistentStore to $originalPersistent."
        }
        catch {
            Write-Warning "Failed to restore PersistentStore."
        }
    }

    if ($committed -or $probeAdjusted) {
        try {
            Set-Mtu `
                -InterfaceIndex $ifIndex `
                -Mtu $originalActive `
                -PolicyStore ActiveStore
            Write-Warning "Restored ActiveStore to $originalActive."
        }
        catch {
            Write-Warning "Failed to restore ActiveStore."
        }
    }

    throw
}
finally {
    if ($probeAdjusted -and -not $committed) {
        try {
            Set-Mtu `
                -InterfaceIndex $ifIndex `
                -Mtu $originalActive `
                -PolicyStore ActiveStore
            Write-Host "Restored the probe MTU to $originalActive." `
                -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "Failed to restore the probe MTU."
        }
    }
}

$finished = Get-Date

[pscustomobject]@{
    Target                = $Target
    ResolvedIPv4          = $address.IPAddressToString
    InterfaceAlias        = $ifAlias
    InterfaceIndex        = $ifIndex
    OriginalActiveMtu     = $originalActive
    OriginalPersistentMtu = $originalPersistent
    DetectedPathMtu       = $detected
    AppliedMtu            = if ($DetectOnly) { $null } else { $applied }
    EstimatedTcpMss       = $applied - 40
    Persistent            = (-not $DetectOnly -and -not $Temporary)
    UpperBoundReached     = ($detected -eq $MaximumMtu)
    DurationSeconds       = [Math]::Round(($finished - $started).TotalSeconds, 2)
}

