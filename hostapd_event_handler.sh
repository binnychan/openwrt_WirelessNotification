#!/bin/sh

# hostapd_event_handler.sh
# - AP-STA-CONNECTED/AP-STA-DISCONNECTED actions
# - In-memory disconnection tracker at $WL_FILE
# - WLCleanUp mode: clear old entries by delay (default 5m)
# - Per-MAC custom delays supported

telegramBotID="YOUR_BOT_TOKEN"
telegramChatID="YOUR_CHAT_ID"

# Cleanup config (adjust these)
DEFAULT_DELAY=300                       # seconds; default 5 minutes
MAC_DELAYS=""                           # example: comma/space-separated
WL_FILE="/tmp/wl_disconnected"

sendMessage() {
    local action="$1"
    local interface="$2"
    local mac="$3"
    local telegram="$4"
    local age_hms="$5"
    local delay_hms="$6"

    local ip=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $3}')
    local clientname=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
    local ssid=$(iwinfo "$interface" info | grep "ESSID:" | awk '{print $3}' | tr -d '"')

    if [ -n "$telegram" ]; then
        local msg="Wireless $interface($ssid) $mac $ip $clientname has $action."
        if [ -n "$age_hms" ] && [ -n "$delay_hms" ]; then
            msg="$msg (age: $age_hms, delay: $delay_hms)"
        fi
        curl -s -X POST "https://api.telegram.org/bot$telegramBotID/sendMessage" \
            -d chat_id="$telegramChatID" -d text="$msg" > /dev/null
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
    [ ! -f "$WL_FILE" ] && return

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
            # debug:
            # echo "Removed old entry: interface=$interface mac=$mac (age=$age_hms, delay=$delay_hms)"
            logger -t hostapd-event "AP-STA-DISCONNECTED $1 $3 (Cleanup - age=$age_hms, delay=$delay_hms)"
            sendMessage "disconnected" "$interface" "$mac" "SendNotification" "$age_hms" "$delay_hms"
        else
            kept=$((kept+1))
        fi
    done < "$WL_FILE"

    # echo "Cleanup complete: kept=$kept removed=$removed"
}

# Mode: WLCleanUp
if [ "$1" = "WLCleanUp" ]; then
    cleanup_disconnected_entries
    exit 0
fi

# Regular hostapd event handling
case "$2" in
    AP-STA-CONNECTED)
        
        if grep -qF "$3" "$WL_FILE" 2>/dev/null; then
            # Get the old interface from the entry
            old_entry=$(grep " $3$" "$WL_FILE")
            old_interface=$(echo "$old_entry" | awk '{print $2}')
            sed -i "\|^.* $3\$|d" "$WL_FILE"
            if [ "$old_interface" = "$1" ]; then
                logger -t hostapd-event "AP-STA-CONNECTED $1 $3 (Reconnected same interface)"
            else
                logger -t hostapd-event "AP-STA-CONNECTED $1 $3 (Roamed from $old_interface to $1)"
                # sendMessage "roamed from $old_interface to $1" "$1" "$3" "SendNotification"
            fi
        else
            logger -t hostapd-event "AP-STA-CONNECTED $1 $3 (New)"
            sendMessage "connected" "$1" "$3" "SendNotification"
        fi
        ;;
    AP-STA-DISCONNECTED)
        logger -t hostapd-event "AP-STA-DISCONNECTED $1 $3 (Pending Cleanup)"
        echo "$(date -Iseconds) $1 $3" >> "$WL_FILE"
        # sendMessage "disconnected" "$1" "$3" "SendNotification"
        ;;
esac
