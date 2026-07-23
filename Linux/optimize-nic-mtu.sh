#!/usr/bin/env bash
#
# optimize-nic-mtu.sh
#
# Detect the IPv4 Path MTU using ICMP Echo with DF (Don't Fragment),
# and apply it to a Linux network interface.
#
# Required commands:
#   bash, ip (iproute2), ping (iputils), getent, awk, grep, sed
#
set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
IPV4_ICMP_HEADER_BYTES=28

TARGET=""
INTERFACE=""
MINIMUM_MTU=576
MAXIMUM_MTU=1500
ATTEMPTS=3
TIMEOUT_SECONDS=2
SAFETY_MARGIN=0
DETECT_ONLY=0
SHOW_PROBES=0
ADJUST_PROBE_MTU=1
PERSIST_NETWORKMANAGER=0
NM_CONNECTION=""

TARGET_IP=""
ROUTE_INTERFACE=""
ORIGINAL_MTU=""
SEARCH_MAXIMUM_MTU=""
DETECTED_MTU=""
APPLIED_MTU=""
PROBE_MTU_ADJUSTED=0
MTU_COMMITTED=0
NM_PERSISTED=0
ORIGINAL_NM_MTU=""
NM_MTU_PROPERTY=""

usage() {
    cat <<USAGE
Usage:
  $PROGRAM_NAME --target HOST [options]

Required:
  -t, --target HOST
      IPv4 address or hostname to use for MTU measurement.

Options:
  -i, --interface NAME
      Network interface to configure. If omitted, it is detected automatically using "ip route get".

  --min-mtu N
      Minimum MTU to search. Default: $MINIMUM_MTU

  --max-mtu N
      Maximum MTU to search. Default: $MAXIMUM_MTU

  --attempts N
      Number of ping attempts for each size. If at least one attempt succeeds, the size is treated as usable.
      Default: $ATTEMPTS

  --timeout SECONDS
      Timeout in seconds for each ping attempt. Default: $TIMEOUT_SECONDS

  --safety-margin N
      Safety margin to subtract from the detected value. Default: $SAFETY_MARGIN

  --detect-only
      Show only the detection result without changing the MTU.

  --show-probes
      Show detailed probe results for each MTU size.

  --no-probe-mtu-adjustment
      Do not temporarily raise the interface MTU to the search maximum before probing.
      MTU values larger than the current interface MTU may not be detectable.

  --persist-networkmanager
      Save the detected MTU to the NetworkManager connection profile
      in addition to applying it to the active interface.

  --nm-connection NAME
      Explicitly specify the NetworkManager connection name to persist.
      Use this together with --persist-networkmanager.

  -h, --help
      Show this help message.

Examples:
  sudo ./$PROGRAM_NAME -t 192.168.10.254

  sudo ./$PROGRAM_NAME \
      -t 1.1.1.1 \
      -i enp1s0 \
      --detect-only \
      --show-probes

  sudo ./$PROGRAM_NAME \
      -t 1.1.1.1 \
      --safety-margin 8 \
      --persist-networkmanager
USAGE
}

log() {
    printf '%s\n' "$*"
}

info() {
    printf '\033[36m%s\033[0m\n' "$*"
}

success() {
    printf '\033[32m%s\033[0m\n' "$*"
}

warn() {
    printf '\033[33mWarning: %s\033[0m\n' "$*" >&2
}

die() {
    printf '\033[31mError: %s\033[0m\n' "$*" >&2
    exit 1
}

is_unsigned_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

get_interface_mtu() {
    local interface="$1"
    local line mtu

    line="$(ip -o link show dev "$interface" 2>/dev/null)" ||
        return 1

    mtu="$(awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "mtu") {
                print $(i + 1)
                exit
            }
        }
    }' <<<"$line")"

    [[ -n "$mtu" ]] || return 1
    printf '%s\n' "$mtu"
}

set_interface_mtu() {
    local interface="$1"
    local mtu="$2"
    local actual

    ip link set dev "$interface" mtu "$mtu"

    actual="$(get_interface_mtu "$interface")" ||
        die "Could not verify the network interface after setting the MTU: $interface"

    [[ "$actual" == "$mtu" ]] ||
        die "MTU verification failed. Requested=$mtu Actual=$actual"
}

resolve_target_ipv4() {
    local target="$1"
    local address

    address="$(
        getent ahostsv4 "$target" 2>/dev/null |
            awk 'NR == 1 { print $1; exit }'
    )"

    [[ -n "$address" ]] ||
        die "Could not resolve the target to an IPv4 address: $target"

    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        die "The resolved address is not a valid IPv4 address: $address"

    printf '%s\n' "$address"
}

get_route_interface() {
    local target_ip="$1"
    local route_line
    local -a fields
    local index

    route_line="$(ip -4 route get "$target_ip" 2>/dev/null | head -n 1)" ||
        return 1

    [[ -n "$route_line" ]] || return 1

    read -r -a fields <<<"$route_line"

    for ((index = 0; index < ${#fields[@]}; index++)); do
        if [[ "${fields[$index]}" == "dev" ]] &&
           ((index + 1 < ${#fields[@]})); then
            printf '%s\n' "${fields[$((index + 1))]}"
            return 0
        fi
    done

    return 1
}

ping_supports_pmtu() {
    ping -4 -n -c 1 -W 1 -M do -s 0 127.0.0.1 \
        >/dev/null 2>&1
}

probe_mtu() {
    local mtu="$1"
    local payload=$((mtu - IPV4_ICMP_HEADER_BYTES))
    local attempt
    local output=""
    local status=1

    ((payload >= 0)) ||
        die "The ICMP payload calculated from the MTU is negative: MTU=$mtu"

    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        set +e
        output="$(
            ping -4 -n \
                -c 1 \
                -W "$TIMEOUT_SECONDS" \
                -M do \
                -s "$payload" \
                -I "$INTERFACE" \
                "$TARGET_IP" 2>&1
        )"
        status=$?
        set -e

        if ((status == 0)); then
            if ((SHOW_PROBES)); then
                printf '  MTU=%-5s Payload=%-5s Result=OK Attempt=%s\n' \
                    "$mtu" "$payload" "$attempt"
            else
                printf '  MTU %5s: OK\n' "$mtu"
            fi
            return 0
        fi

        if grep -Eiq \
            'message too long|packet too big|frag needed|mtu[ =:]' \
            <<<"$output"; then
            break
        fi
    done

    if ((SHOW_PROBES)); then
        local summary
        summary="$(
            tr '\n' ' ' <<<"$output" |
                sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
        )"
        printf '  MTU=%-5s Payload=%-5s Result=NG Detail=%s\n' \
            "$mtu" "$payload" "${summary:-no response}"
    else
        printf '  MTU %5s: NG\n' "$mtu"
    fi

    return 1
}

find_nm_connection() {
    local interface="$1"
    local connection

    if [[ -n "$NM_CONNECTION" ]]; then
        nmcli -g connection.id connection show "$NM_CONNECTION" \
            >/dev/null 2>&1 ||
            die "NetworkManager connection not found: $NM_CONNECTION"

        printf '%s\n' "$NM_CONNECTION"
        return 0
    fi

    connection="$(
        nmcli -g GENERAL.CONNECTION device show "$interface" 2>/dev/null |
            head -n 1
    )"

    [[ -n "$connection" && "$connection" != "--" ]] ||
        die "Could not get the active NetworkManager connection for interface '$interface'."

    printf '%s\n' "$connection"
}

get_nm_mtu_property() {
    local connection="$1"
    local type

    type="$(nmcli -g connection.type connection show "$connection" 2>/dev/null |
        head -n 1)"

    case "$type" in
        802-3-ethernet|ethernet)
            printf '%s\n' "802-3-ethernet.mtu"
            ;;
        802-11-wireless|wifi)
            printf '%s\n' "802-11-wireless.mtu"
            ;;
        vlan)
            printf '%s\n' "vlan.mtu"
            ;;
        bond)
            printf '%s\n' "bond.mtu"
            ;;
        bridge)
            printf '%s\n' "bridge.mtu"
            ;;
        *)
            die "Persisting the MTU is not supported for NetworkManager connection type '$type'."
            ;;
    esac
}

persist_networkmanager_mtu() {
    local mtu="$1"
    local connection

    require_command nmcli

    connection="$(find_nm_connection "$INTERFACE")"
    NM_CONNECTION="$connection"
    NM_MTU_PROPERTY="$(get_nm_mtu_property "$connection")"

    ORIGINAL_NM_MTU="$(
        nmcli -g "$NM_MTU_PROPERTY" connection show "$connection" 2>/dev/null |
            head -n 1
    )"

    nmcli connection modify "$connection" "$NM_MTU_PROPERTY" "$mtu"
    NM_PERSISTED=1

    success "Saved MTU $mtu to NetworkManager connection '$connection'."
    log "It will also be applied after the connection is reactivated or the system is rebooted."
}

restore_networkmanager_mtu() {
    if ((NM_PERSISTED == 0)); then
        return 0
    fi

    if [[ -n "$ORIGINAL_NM_MTU" ]]; then
        nmcli connection modify \
            "$NM_CONNECTION" \
            "$NM_MTU_PROPERTY" \
            "$ORIGINAL_NM_MTU" || true
    else
        nmcli connection modify \
            "$NM_CONNECTION" \
            "$NM_MTU_PROPERTY" \
            0 || true
    fi

    warn "Restored the NetworkManager connection MTU to its original value."
    NM_PERSISTED=0
}

cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM

    if ((exit_status != 0)); then
        if ((NM_PERSISTED)); then
            restore_networkmanager_mtu
        fi

        if ((MTU_COMMITTED || PROBE_MTU_ADJUSTED)) &&
           [[ -n "$ORIGINAL_MTU" ]] &&
           [[ -n "$INTERFACE" ]]; then
            if ip link show dev "$INTERFACE" >/dev/null 2>&1; then
                ip link set dev "$INTERFACE" mtu "$ORIGINAL_MTU" || true
                warn "Restored interface '$INTERFACE' MTU to the original value $ORIGINAL_MTU."
            fi
        fi
    elif ((PROBE_MTU_ADJUSTED)) && ((MTU_COMMITTED == 0)); then
        ip link set dev "$INTERFACE" mtu "$ORIGINAL_MTU" || true
        log "Restored the probe MTU to the original value $ORIGINAL_MTU."
    fi

    exit "$exit_status"
}

while (($# > 0)); do
    case "$1" in
        -t|--target)
            (($# >= 2)) || die "$1 requires a value."
            TARGET="$2"
            shift 2
            ;;
        -i|--interface)
            (($# >= 2)) || die "$1 requires a value."
            INTERFACE="$2"
            shift 2
            ;;
        --min-mtu)
            (($# >= 2)) || die "$1 requires a value."
            MINIMUM_MTU="$2"
            shift 2
            ;;
        --max-mtu)
            (($# >= 2)) || die "$1 requires a value."
            MAXIMUM_MTU="$2"
            shift 2
            ;;
        --attempts)
            (($# >= 2)) || die "$1 requires a value."
            ATTEMPTS="$2"
            shift 2
            ;;
        --timeout)
            (($# >= 2)) || die "$1 requires a value."
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --safety-margin)
            (($# >= 2)) || die "$1 requires a value."
            SAFETY_MARGIN="$2"
            shift 2
            ;;
        --detect-only)
            DETECT_ONLY=1
            shift
            ;;
        --show-probes)
            SHOW_PROBES=1
            shift
            ;;
        --no-probe-mtu-adjustment)
            ADJUST_PROBE_MTU=0
            shift
            ;;
        --persist-networkmanager)
            PERSIST_NETWORKMANAGER=1
            shift
            ;;
        --nm-connection)
            (($# >= 2)) || die "$1 requires a value."
            NM_CONNECTION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$TARGET" ]] || {
    usage >&2
    die "Please specify --target."
}

for value_name in \
    MINIMUM_MTU \
    MAXIMUM_MTU \
    ATTEMPTS \
    TIMEOUT_SECONDS \
    SAFETY_MARGIN; do
    value="${!value_name}"
    is_unsigned_integer "$value" ||
        die "$value_name must be a non-negative integer: $value"
done

((MINIMUM_MTU >= 576)) ||
    die "For the minimum IPv4 MTU, --min-mtu must be 576 or higher."

((MAXIMUM_MTU <= 65528)) ||
    die "--max-mtu must be 65528 or lower."

((MINIMUM_MTU <= MAXIMUM_MTU)) ||
    die "--min-mtu must be less than or equal to --max-mtu."

((ATTEMPTS >= 1 && ATTEMPTS <= 20)) ||
    die "--attempts must be between 1 and 20."

((TIMEOUT_SECONDS >= 1 && TIMEOUT_SECONDS <= 30)) ||
    die "--timeout must be between 1 and 30 seconds."

((SAFETY_MARGIN <= 512)) ||
    die "--safety-margin must be between 0 and 512."

if ((PERSIST_NETWORKMANAGER)) && ((DETECT_ONLY)); then
    die "--persist-networkmanager and --detect-only cannot be used together."
fi

if [[ -n "$NM_CONNECTION" ]] && ((PERSIST_NETWORKMANAGER == 0)); then
    die "--nm-connection also requires --persist-networkmanager."
fi

require_command ip
require_command ping
require_command getent
require_command awk
require_command grep
require_command sed

TARGET_IP="$(resolve_target_ipv4 "$TARGET")"

ROUTE_INTERFACE="$(get_route_interface "$TARGET_IP")" ||
    die "Could not determine the network interface used for the route to '$TARGET_IP'."

if [[ -z "$INTERFACE" ]]; then
    INTERFACE="$ROUTE_INTERFACE"
elif [[ "$INTERFACE" != "$ROUTE_INTERFACE" ]]; then
    die "The specified interface '$INTERFACE' does not match the actual route interface '$ROUTE_INTERFACE'."
fi

ip link show dev "$INTERFACE" >/dev/null 2>&1 ||
    die "Network interface not found: $INTERFACE"

ORIGINAL_MTU="$(get_interface_mtu "$INTERFACE")" ||
    die "Could not get the current MTU for interface '$INTERFACE'."

if ((EUID != 0)); then
    if ((DETECT_ONLY == 0)); then
        die "Root privileges are required to set the MTU on the interface. Please run this script with sudo."
    fi

    if ((ADJUST_PROBE_MTU)) && ((MAXIMUM_MTU != ORIGINAL_MTU)); then
        die "Root privileges are required to temporarily change the probe MTU. Specify --no-probe-mtu-adjustment or run this script with sudo."
    fi
fi

ping_supports_pmtu ||
    die "This ping command does not support '-M do'. Please install the iputils version of ping."

trap cleanup EXIT INT TERM

info "IPv4 Path MTU detection"
log "  Target         : $TARGET ($TARGET_IP)"
log "  NIC            : $INTERFACE"
log "  Current MTU    : $ORIGINAL_MTU"
log "  Search range   : $MINIMUM_MTU - $MAXIMUM_MTU"
log "  Attempts       : $ATTEMPTS"
log "  Timeout        : ${TIMEOUT_SECONDS}s"
log ""

info "Checking standard-size ICMP connectivity..."

if ! ping -4 -n \
    -c "$ATTEMPTS" \
    -W "$TIMEOUT_SECONDS" \
    -I "$INTERFACE" \
    "$TARGET_IP" >/dev/null 2>&1; then
    die "Could not get an ICMP Echo response from the target: $TARGET_IP"
fi

SEARCH_MAXIMUM_MTU="$MAXIMUM_MTU"

if ((ADJUST_PROBE_MTU)); then
    if ((ORIGINAL_MTU != MAXIMUM_MTU)); then
        info "Temporarily changing the interface MTU from $ORIGINAL_MTU to $MAXIMUM_MTU during probing..."

        if ! ip link set dev "$INTERFACE" mtu "$MAXIMUM_MTU" 2>/dev/null; then
            warn "Could not change the interface MTU to $MAXIMUM_MTU."
            warn "Limiting the search maximum to the current MTU $ORIGINAL_MTU."
            SEARCH_MAXIMUM_MTU="$ORIGINAL_MTU"
        else
            PROBE_MTU_ADJUSTED=1
            sleep 0.3
        fi
    fi
else
    if ((MAXIMUM_MTU > ORIGINAL_MTU)); then
        warn "Values larger than the current MTU cannot be detected, so the search maximum is limited to $ORIGINAL_MTU."
        SEARCH_MAXIMUM_MTU="$ORIGINAL_MTU"
    fi
fi

if ((SEARCH_MAXIMUM_MTU < MINIMUM_MTU)); then
    die "The effective search maximum $SEARCH_MAXIMUM_MTU is below the minimum value $MINIMUM_MTU."
fi

info "Starting binary search..."

if ! probe_mtu "$MINIMUM_MTU"; then
    die "No response even at the minimum MTU $MINIMUM_MTU. No settings were changed."
fi

low="$MINIMUM_MTU"
high="$SEARCH_MAXIMUM_MTU"
best="$MINIMUM_MTU"

while ((low <= high)); do
    mid=$(((low + high) / 2))

    if ((mid == MINIMUM_MTU && low == MINIMUM_MTU)); then
        best="$MINIMUM_MTU"
        low=$((MINIMUM_MTU + 1))
        continue
    fi

    if probe_mtu "$mid"; then
        best="$mid"
        low=$((mid + 1))
    else
        high=$((mid - 1))
    fi
done

DETECTED_MTU="$best"
APPLIED_MTU=$((DETECTED_MTU - SAFETY_MARGIN))

((APPLIED_MTU >= 576)) ||
    die "The MTU after applying the safety margin would be below 576: $APPLIED_MTU"

log ""
success "Detection complete"
log "  Detected Path MTU: $DETECTED_MTU"
log "  Safety margin: $SAFETY_MARGIN"
log "  MTU to apply     : $APPLIED_MTU"
log "  Estimated TCP MSS: $((APPLIED_MTU - 40))"

if ((DETECTED_MTU == SEARCH_MAXIMUM_MTU)); then
    warn "Probing succeeded up to the search maximum. The actual Path MTU may be even larger."
fi

if ((DETECT_ONLY)); then
    success "Detection-only mode complete. The final interface configuration was not changed."
    exit 0
fi

info "Setting MTU $APPLIED_MTU on interface '$INTERFACE'..."

set_interface_mtu "$INTERFACE" "$APPLIED_MTU"
MTU_COMMITTED=1
PROBE_MTU_ADJUSTED=0

sleep 0.3

info "Checking connectivity after applying the setting..."

if ! probe_mtu "$APPLIED_MTU"; then
    die "MTU verification failed after applying the setting."
fi

if ((PERSIST_NETWORKMANAGER)); then
    persist_networkmanager_mtu "$APPLIED_MTU"
fi

log ""
success "MTU configuration complete."
log "  Target        : $TARGET_IP"
log "  Interface     : $INTERFACE"
log "  Original MTU  : $ORIGINAL_MTU"
log "  Detected MTU  : $DETECTED_MTU"
log "  Applied MTU   : $APPLIED_MTU"

if ((PERSIST_NETWORKMANAGER)); then
    log "  Persistent    : NetworkManager ($NM_CONNECTION)"
else
    log "  Persistent    : No (runtime configuration only)"
fi
