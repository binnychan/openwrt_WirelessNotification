#!/bin/sh

# hostapd_event_handler.sh
# - AP-STA-CONNECTED/AP-STA-DISCONNECTED actions
# - In-memory disconnection tracker at $WL_FILE
# - WLCleanUp mode: clear old entries by delay (default 5m)
# - Per-MAC custom delays supported
# - Supports both OpenWrt and GLiNet formats

# GLiNet format: global IFNAME=wlan12 <3>AP-STA-CONNECTED ee:cb:41:d6:ef:a3
# OpenWrt format: wlan0 AP-STA-CONNECTED ee:cb:41:d6:ef:a3

# Debug flag: set to 1 to enable debug output
DEBUG=0

telegramBotID="YOUR_BOT_TOKEN"
telegramChatID="YOUR_CHAT_ID"

# Cleanup config (adjust these)
DEFAULT_DELAY=300                       # seconds; default 5 minutes
MAC_DELAYS=""                           # example: comma/space-separated
WL_FILE="/tmp/wl_disconnected"

# Debug logging helper
debug_log() {
    [ "$DEBUG" = "1" ] && echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

# Parse GLiNet format arguments
parse_glinet_args() {
    # GLiNet: $1=global, $2=IFNAME=wlan12, $3=<3>AP-STA-CONNECTED, $4=MAC
    # Extract interface from IFNAME=wlan12
    INTERFACE="${2#IFNAME=}"
    
    # Extract event from <3>AP-STA-CONNECTED -> AP-STA-CONNECTED
    # Use sed to remove everything up to and including '>'
    EVENT=$(echo "$3" | sed 's/^[^>]*>//')
    
    # MAC is $4
    MAC="$4"
    
    debug_log "GLiNet parse: INTERFACE=$INTERFACE EVENT=$EVENT MAC=$MAC"
}

# Parse OpenWrt format arguments
parse_openwrt_args() {
    # OpenWrt: $1=interface, $2=event, $3=MAC
    INTERFACE="$1"
    EVENT="$2"
    MAC="$3"
    
    debug_log "OpenWrt parse: INTERFACE=$INTERFACE EVENT=$EVENT MAC=$MAC"
}

sendMessage() {
    local action="$1"
    local interface="$2"
    local mac="$3"
    local telegram="$4"
    local age_hms="$5"
    local delay_hms="$6"

    debug_log "sendMessage called: action=$action interface=$interface mac=$mac telegram=$telegram"

    local ip=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $3}')
    local clientname=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
    if [ -z "$clientname" ]; then clientname="[Unknown]"; fi
    local ssid=$(iwinfo "$interface" info | grep "ESSID:" | awk '{print $3}' | tr -d '"')

    debug_log "Lookup: ip=$ip clientname=$clientname ssid=$ssid"

    if [ -n "$telegram" ]; then
        local msg="Wireless $interface($ssid) $mac $ip $clientname has $action."
        if [ -n "$age_hms" ] && [ -n "$delay_hms" ]; then
            msg="$msg (age: $age_hms, delay: $delay_hms)"
        fi
        debug_log "Sending Telegram: $msg"
        curl -s -X POST "https://api.telegram.org/bot$telegramBotID/sendMessage" \
            -d chat_id="$telegramChatID" -d text="$msg" > /dev/null
    else
        debug_log "Telegram notification skipped (telegram param empty)"
    fi
}

get_mac_delay() {
    local mac="$1"
    for entry in $MAC_DELAYS; do
        [ -z "$entry" ] && continue
        local key="${entry%%=*}"
        local val="${entry#*=}"
        if [ "$mac" = "$key" ]; then
            echo "$val"
            return
        fi
    done
    echo "$DEFAULT_DELAY"
}

seconds_to_hms() {
    local s=$1
    [ "$s" -lt 0 ] && s=0
    printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

cleanup_disconnected_entries() {
    [ ! -f "$WL_FILE" ] && debug_log "WL_FILE not found, skipping cleanup" && return

    debug_log "Starting cleanup of disconnected entries"
    now=$(date +%s)
    kept=0
    removed=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        set -- $line
        timestamp="$1"
        interface="$2"
        mac="$3"

        # Parse ISO 8601 timestamp using awk mktime
        year=$(echo "$timestamp" | cut -d'T' -f1 | cut -d'-' -f1)
        month=$(echo "$timestamp" | cut -d'T' -f1 | cut -d'-' -f2)
        day=$(echo "$timestamp" | cut -d'T' -f1 | cut -d'-' -f3)
        time=$(echo "$timestamp" | cut -d'T' -f2 | cut -d'+' -f1)
        hour=$(echo "$time" | cut -d':' -f1)
        min=$(echo "$time" | cut -d':' -f2)
        sec=$(echo "$time" | cut -d':' -f3)

        entry_epoch=$(awk "BEGIN { print mktime(\"$year $month $day $hour $min $sec\") }")

        age=$((now - entry_epoch))
        delay=$(get_mac_delay "$mac")

        if [ "$age" -gt "$delay" ]; then
            sed -i "\|^$timestamp $interface $mac\$|d" "$WL_FILE"
            removed=$((removed+1))
            age_hms=$(seconds_to_hms "$age")
            delay_hms=$(seconds_to_hms "$delay")
            debug_log "Removed old entry: interface=$interface mac=$mac (age=$age_hms, delay=$delay_hms)"
            logger -t hostapd-event "AP-STA-DISCONNECTED $interface $mac (Cleanup - age=$age_hms, delay=$delay_hms)"
            sendMessage "disconnected" "$interface" "$mac" "SendNotification" "$age_hms" "$delay_hms"
        else
            kept=$((kept+1))
        fi
    done < "$WL_FILE"

    # echo "Cleanup complete: kept=$kept removed=$removed"
}

# Mode: WLCleanUp
if [ "$1" = "WLCleanUp" ]; then
    debug_log "Running WLCleanUp mode"
    cleanup_disconnected_entries
    exit 0
fi

# Detect format: GLiNet has "global" as first arg and "IFNAME=" in second
debug_log "Raw args: $1 | $2 | $3 | $4"
if [ "$1" = "global" ] && echo "$2" | grep -q "^IFNAME="; then
    debug_log "Detected GLiNet format"
    parse_glinet_args $1 $2 $3 $4
else
    debug_log "Detected OpenWrt format"
    parse_openwrt_args $1 $2 $3
fi

# Regular hostapd event handling
debug_log "Processing event: $EVENT"
case "$EVENT" in
    AP-STA-CONNECTED)
        debug_log "Handling AP-STA-CONNECTED for MAC: $MAC"
        
        if grep -qF "$MAC" "$WL_FILE" 2>/dev/null; then
            # Get the old interface from the entry
            old_entry=$(grep " $MAC$" "$WL_FILE")
            old_interface=$(echo "$old_entry" | awk '{print $2}')
            sed -i "\|^.* $MAC\$|d" "$WL_FILE"
            if [ "$old_interface" = "$INTERFACE" ]; then
                logger -t hostapd-event "AP-STA-CONNECTED $INTERFACE $MAC (Reconnected same interface)"
            else
                logger -t hostapd-event "AP-STA-CONNECTED $INTERFACE $MAC (Roamed from $old_interface to $INTERFACE)"
                # sendMessage "roamed from $old_interface to $INTERFACE" "$INTERFACE" "$MAC" "SendNotification"
            fi
        else
            logger -t hostapd-event "AP-STA-CONNECTED $INTERFACE $MAC (New)"
            debug_log "Sending connected notification"
            sendMessage "connected" "$INTERFACE" "$MAC" "SendNotification"
        fi
        ;;
    AP-STA-DISCONNECTED)
        debug_log "Handling AP-STA-DISCONNECTED for MAC: $MAC"
        logger -t hostapd-event "AP-STA-DISCONNECTED $INTERFACE $MAC (Pending Cleanup)"
        echo "$(date -Iseconds) $INTERFACE $MAC" >> "$WL_FILE"
        # sendMessage "disconnected" "$INTERFACE" "$MAC" "SendNotification"
        ;;
esac
