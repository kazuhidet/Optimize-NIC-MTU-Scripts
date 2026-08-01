#!/usr/bin/env bash
#
# optimize-nic-mtu-macos.sh
#
# Detects the IPv4 Path MTU using ICMP Echo with DF (Don't Fragment),
# then applies it to a macOS network interface.
#
# Supported environment:
#   macOS / Bash 3.2 or later
#
# Required commands:
#   bash, ping, route, ifconfig, dscacheutil, networksetup,
#   awk, grep, sed, tr, uname
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
PERSIST_NETWORKSETUP=0

TARGET_IP=""
ROUTE_INTERFACE=""
ORIGINAL_MTU=""
SEARCH_MAXIMUM_MTU=""
DETECTED_MTU=""
APPLIED_MTU=""
TIMEOUT_MILLISECONDS=""
PROBE_MTU_ADJUSTED=0
MTU_COMMITTED=0
NETWORKSETUP_PERSISTED=0
ORIGINAL_NETWORKSETUP_MTU=""
ORIGINAL_NETWORKSETUP_AUTOMATIC=0

usage() {
    cat <<USAGE
Usage:
  $PROGRAM_NAME --target HOST [OPTIONS]

Required:
  -t, --target HOST
      IPv4 address or hostname used to measure the Path MTU.

Options:
  -i, --interface NAME
      Network interface to configure. If omitted, it is detected automatically
      using "route -n get". Examples: en0, en1, bridge0, utun3

  --min-mtu N
      Minimum MTU to search. Default: $MINIMUM_MTU

  --max-mtu N
      Maximum MTU to search. Default: $MAXIMUM_MTU

  --attempts N
      Number of ping attempts for each size. The size is accepted if at least
      one attempt succeeds. Default: $ATTEMPTS

  --timeout SECONDS
      Timeout in seconds for each ping attempt. Default: $TIMEOUT_SECONDS
      The value is converted to milliseconds for the macOS ping command.

  --safety-margin N
      Safety margin subtracted from the detected MTU. Default: $SAFETY_MARGIN

  --detect-only
      Display the detected MTU without changing the interface configuration.

  --show-probes
      Display detailed probe results for each tested MTU size.

  --no-probe-mtu-adjustment
      Do not temporarily raise the interface MTU to the search maximum before
      probing. MTU values above the current interface MTU may not be detected.

  --persist-networksetup
      Save the detected MTU through networksetup so that the setting persists
      after reconnecting or restarting the system.

  -h, --help
      Display this help message.

Examples:
  sudo ./$PROGRAM_NAME -t 192.168.10.254

  ./$PROGRAM_NAME \
      -t 1.1.1.1 \
      --detect-only \
      --no-probe-mtu-adjustment \
      --show-probes

  sudo ./$PROGRAM_NAME \
      -t 1.1.1.1 \
      -i en0 \
      --safety-margin 8 \
      --persist-networksetup
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

is_ipv4_address() {
    local address="$1"
    local old_ifs="$IFS"
    local octet
    local -a octets

    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        return 1

    IFS='.'
    read -r -a octets <<<"$address"
    IFS="$old_ifs"

    ((${#octets[@]} == 4)) || return 1

    for octet in "${octets[@]}"; do
        is_unsigned_integer "$octet" || return 1
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

get_interface_mtu() {
    local interface="$1"
    local mtu

    mtu="$(
        ifconfig "$interface" 2>/dev/null |
            awk '{
                for (i = 1; i <= NF; i++) {
                    if ($i == "mtu" && (i + 1) <= NF) {
                        print $(i + 1)
                        exit
                    }
                }
            }'
    )" || return 1

    [[ -n "$mtu" ]] || return 1
    is_unsigned_integer "$mtu" || return 1
    printf '%s\n' "$mtu"
}

set_interface_mtu() {
    local interface="$1"
    local mtu="$2"
    local actual

    ifconfig "$interface" mtu "$mtu"

    actual="$(get_interface_mtu "$interface")" ||
        die "Unable to verify the interface after setting the MTU: $interface"

    [[ "$actual" == "$mtu" ]] ||
        die "MTU verification failed. Requested=$mtu Actual=$actual"
}

resolve_target_ipv4() {
    local target="$1"
    local address

    if is_ipv4_address "$target"; then
        printf '%s\n' "$target"
        return 0
    fi

    address="$(
        dscacheutil -q host -a name "$target" 2>/dev/null |
            awk '$1 == "ip_address:" && $2 ~ /^[0-9]+\./ {
                print $2
                exit
            }'
    )"

    [[ -n "$address" ]] ||
        die "Unable to resolve the target to an IPv4 address: $target"

    is_ipv4_address "$address" ||
        die "The resolved address is not a valid IPv4 address: $address"

    printf '%s\n' "$address"
}

get_route_interface() {
    local target_ip="$1"
    local interface

    interface="$(
        route -n get -inet "$target_ip" 2>/dev/null |
            awk '$1 == "interface:" { print $2; exit }'
    )" || return 1

    [[ -n "$interface" ]] || return 1
    printf '%s\n' "$interface"
}

ping_once() {
    local use_df="$1"
    local payload="$2"
    local output=""
    local status=1
    local -a command

    command=(
        ping
        -n
        -c 1
        -W "$TIMEOUT_MILLISECONDS"
        -t "$TIMEOUT_SECONDS"
        -b "$INTERFACE"
    )

    if ((use_df)); then
        command+=( -D )
    fi

    if ((payload >= 0)); then
        command+=( -s "$payload" )
    fi

    command+=( "$TARGET_IP" )

    set +e
    output="$("${command[@]}" 2>&1)"
    status=$?
    set -e

    printf '%s\n' "$output"
    return "$status"
}

check_basic_connectivity() {
    local attempt
    local output=""

    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        if output="$(ping_once 0 -1)"; then
            return 0
        fi
    done

    if ((SHOW_PROBES)) && [[ -n "$output" ]]; then
        warn "Final output from the standard ping: $(
            tr '\n' ' ' <<<"$output" |
                sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
        )"
    fi

    return 1
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
        output="$(ping_once 1 "$payload")"
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
            'message too long|packet too big|frag needed|fragmentation needed|mtu[ =:]' \
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

read_networksetup_mtu() {
    local output
    local current

    output="$(networksetup -getMTU "$INTERFACE" 2>/dev/null)" ||
        return 1

    current="$(
        sed -nE \
            's/.*Current Setting:[[:space:]]*([^)]*)\).*/\1/p' \
            <<<"$output" |
            sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
    )"

    if is_unsigned_integer "$current"; then
        ORIGINAL_NETWORKSETUP_MTU="$current"
        ORIGINAL_NETWORKSETUP_AUTOMATIC=0
    else
        ORIGINAL_NETWORKSETUP_MTU=""
        ORIGINAL_NETWORKSETUP_AUTOMATIC=1
    fi
}

persist_networksetup_mtu() {
    local mtu="$1"

    require_command networksetup

    read_networksetup_mtu ||
        die "Unable to retrieve the MTU setting for interface '$INTERFACE' using networksetup."

    networksetup -setMTU "$INTERFACE" "$mtu"
    NETWORKSETUP_PERSISTED=1

    success "Saved MTU $mtu for interface '$INTERFACE' using networksetup."
    log "The setting will remain in effect after reconnecting or restarting."
}

restore_networksetup_mtu() {
    if ((NETWORKSETUP_PERSISTED == 0)); then
        return 0
    fi

    if ((ORIGINAL_NETWORKSETUP_AUTOMATIC)); then
        networksetup -setMTUAndMediaAutomatically "$INTERFACE" || true
    elif [[ -n "$ORIGINAL_NETWORKSETUP_MTU" ]]; then
        networksetup -setMTU \
            "$INTERFACE" \
            "$ORIGINAL_NETWORKSETUP_MTU" || true
    fi

    warn "Restored the original networksetup MTU setting."
    NETWORKSETUP_PERSISTED=0
}

cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM

    if ((exit_status != 0)); then
        if ((NETWORKSETUP_PERSISTED)); then
            restore_networksetup_mtu
        fi

        if ((MTU_COMMITTED || PROBE_MTU_ADJUSTED)) &&
           [[ -n "$ORIGINAL_MTU" ]] &&
           [[ -n "$INTERFACE" ]]; then
            if ifconfig "$INTERFACE" >/dev/null 2>&1; then
                ifconfig "$INTERFACE" mtu "$ORIGINAL_MTU" || true
                warn "Restored interface '$INTERFACE' to its original MTU of $ORIGINAL_MTU."
            fi
        fi
    elif ((PROBE_MTU_ADJUSTED)) && ((MTU_COMMITTED == 0)); then
        ifconfig "$INTERFACE" mtu "$ORIGINAL_MTU" || true
        log "Restored the temporary probe MTU to its original value of $ORIGINAL_MTU."
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
        --persist-networksetup)
            PERSIST_NETWORKSETUP=1
            shift
            ;;
        --persist-networkmanager)
            die "Use --persist-networksetup on macOS."
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
    die "Specify --target."
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
    die "--min-mtu must be at least 576, the minimum IPv4 MTU."

((MAXIMUM_MTU <= 65535)) ||
    die "--max-mtu must not exceed 65535, the maximum IPv4 packet length."

((MINIMUM_MTU <= MAXIMUM_MTU)) ||
    die "--min-mtu must be less than or equal to --max-mtu."

((ATTEMPTS >= 1 && ATTEMPTS <= 20)) ||
    die "--attempts must be between 1 and 20."

((TIMEOUT_SECONDS >= 1 && TIMEOUT_SECONDS <= 30)) ||
    die "--timeout must be between 1 and 30 seconds."

((SAFETY_MARGIN <= 512)) ||
    die "--safety-margin must be between 0 and 512."

if ((PERSIST_NETWORKSETUP)) && ((DETECT_ONLY)); then
    die "--persist-networksetup and --detect-only cannot be used together."
fi

[[ "$(uname -s)" == "Darwin" ]] ||
    die "This script is intended for macOS only."

require_command ping
require_command route
require_command ifconfig
require_command dscacheutil
require_command awk
require_command grep
require_command sed
require_command tr

if ((PERSIST_NETWORKSETUP)); then
    require_command networksetup
fi

TARGET_IP="$(resolve_target_ipv4 "$TARGET")"

ROUTE_INTERFACE="$(get_route_interface "$TARGET_IP")" ||
    die "Unable to determine the interface used to reach '$TARGET_IP'."

if [[ -z "$INTERFACE" ]]; then
    INTERFACE="$ROUTE_INTERFACE"
elif [[ "$INTERFACE" != "$ROUTE_INTERFACE" ]]; then
    die "The specified interface '$INTERFACE' does not match the route interface '$ROUTE_INTERFACE'."
fi

ifconfig "$INTERFACE" >/dev/null 2>&1 ||
    die "Network interface not found: $INTERFACE"

ORIGINAL_MTU="$(get_interface_mtu "$INTERFACE")" ||
    die "Unable to retrieve the current MTU for interface '$INTERFACE'."

TIMEOUT_MILLISECONDS=$((TIMEOUT_SECONDS * 1000))

if ((EUID != 0)); then
    if ((DETECT_ONLY == 0)); then
        die "Root privileges are required to set the interface MTU. Run this script with sudo."
    fi

    if ((ADJUST_PROBE_MTU)) && ((MAXIMUM_MTU > ORIGINAL_MTU)); then
        die "Root privileges are required to temporarily adjust the probe MTU. Use --no-probe-mtu-adjustment or run this script with sudo."
    fi
fi

trap cleanup EXIT INT TERM

info "IPv4 Path MTU Detection (macOS)"
log "  Target         : $TARGET ($TARGET_IP)"
log "  NIC            : $INTERFACE"
log "  Current MTU    : $ORIGINAL_MTU"
log "  Search range   : $MINIMUM_MTU - $MAXIMUM_MTU"
log "  Attempts       : $ATTEMPTS"
log "  Timeout        : ${TIMEOUT_SECONDS}s"
log ""

info "Checking basic ICMP connectivity..."

if ! check_basic_connectivity; then
    die "No ICMP Echo response received from the target: $TARGET_IP"
fi

SEARCH_MAXIMUM_MTU="$MAXIMUM_MTU"

if ((ADJUST_PROBE_MTU)); then
    if ((MAXIMUM_MTU > ORIGINAL_MTU)); then
        info "Temporarily changing the interface MTU from $ORIGINAL_MTU to $MAXIMUM_MTU for probing..."

        if ! ifconfig "$INTERFACE" mtu "$MAXIMUM_MTU" 2>/dev/null; then
            warn "Unable to change the interface MTU to $MAXIMUM_MTU."
            warn "Limiting the search maximum to the current MTU of $ORIGINAL_MTU."
            SEARCH_MAXIMUM_MTU="$ORIGINAL_MTU"
        else
            PROBE_MTU_ADJUSTED=1
            sleep 0.3
        fi
    fi
else
    if ((MAXIMUM_MTU > ORIGINAL_MTU)); then
        warn "MTU values above the current interface MTU cannot be detected; limiting the search maximum to $ORIGINAL_MTU."
        SEARCH_MAXIMUM_MTU="$ORIGINAL_MTU"
    fi
fi

if ((SEARCH_MAXIMUM_MTU < MINIMUM_MTU)); then
    die "The effective search maximum $SEARCH_MAXIMUM_MTU is below the minimum $MINIMUM_MTU."
fi

info "Starting binary search..."

if ! probe_mtu "$MINIMUM_MTU"; then
    die "No response was received even at the minimum MTU of $MINIMUM_MTU. No settings were changed."
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
log "  MTU to apply    : $APPLIED_MTU"
log "  Estimated TCP MSS: $((APPLIED_MTU - 40))"

if ((DETECTED_MTU == SEARCH_MAXIMUM_MTU)); then
    warn "The probe succeeded at the search maximum. The actual Path MTU may be larger."
fi

if ((DETECT_ONLY)); then
    success "Detection-only mode complete. The final interface configuration was not changed."
    exit 0
fi

info "Applying MTU $APPLIED_MTU to interface '$INTERFACE'..."

set_interface_mtu "$INTERFACE" "$APPLIED_MTU"
MTU_COMMITTED=1
PROBE_MTU_ADJUSTED=0

sleep 0.3

info "Verifying connectivity after applying the MTU..."

if ! probe_mtu "$APPLIED_MTU"; then
    die "MTU verification failed after applying the setting."
fi

if ((PERSIST_NETWORKSETUP)); then
    persist_networksetup_mtu "$APPLIED_MTU"
fi

log ""
success "MTU configuration complete."
log "  Target        : $TARGET_IP"
log "  Interface     : $INTERFACE"
log "  Original MTU  : $ORIGINAL_MTU"
log "  Detected MTU  : $DETECTED_MTU"
log "  Applied MTU   : $APPLIED_MTU"

if ((PERSIST_NETWORKSETUP)); then
    log "  Persistent    : networksetup ($INTERFACE)"
else
    log "  Persistent    : no (current session only)"
fi
