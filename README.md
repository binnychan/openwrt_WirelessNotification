# hostapd_event_handler.sh

A shell script for OpenWRT that handles hostapd wireless events, tracks client disconnections, and sends Telegram notifications. It includes features for skipping notifications on quick reconnects and automatic cleanup of old disconnection records.

## Features

- **Event Handling**: Processes `AP-STA-CONNECTED` and `AP-STA-DISCONNECTED` events from hostapd.
- **Disconnection Tracking**: Maintains a log of disconnections with timestamps, interface names, and MAC addresses.
- **Reconnect Logic**: Skips "connected" notifications if the client reconnects within a configurable delay period.
- **Telegram Notifications**: Sends alerts to a Telegram chat for connection and disconnection events.
- **Automatic Cleanup**: Removes old disconnection entries based on configurable delays (default 5 minutes).
- **Per-MAC Delays**: Supports custom delay periods for specific MAC addresses.
- **OpenWRT Compatible**: Uses busybox-compatible tools like `awk mktime` for timestamp parsing.

## Requirements

- OpenWRT with hostapd
- `iwinfo` package (usually installed by default)
- `curl` for Telegram API calls
- Access to `/tmp/dhcp.leases` for client information

## Installation

1. Copy `hostapd_event_handler.sh` to `/usr/sbin/` on your OpenWRT device.
2. Make it executable: `chmod +x /usr/sbin/hostapd_event_handler.sh`
3. Copy `99-hostapd_cli_starter` to `/etc/hotplug.d/net/` on your OpenWRT device.
4. Make it executable: `chmod +x /etc/hotplug.d/net/99-hostapd_cli_starter`

## Configuration

Edit the script variables at the top:

```bash
telegramBotID="YOUR_BOT_TOKEN"          # Your Telegram bot token
telegramChatID="YOUR_CHAT_ID"           # Your Telegram chat ID
DEFAULT_DELAY=300                       # Default delay in seconds (5 minutes)
MAC_DELAYS="aa:bb:cc:dd:ee:ff=600"      # Custom delays: MAC=seconds (comma/space separated)
WL_FILE="/tmp/wl_disconnected"          # File to store disconnection records
```

### Telegram Setup

1. Create a bot with [@BotFather](https://t.me/botfather) on Telegram.
2. Get your bot token (e.g., `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`).
3. Create a private channel or group, add your bot as administrator.
4. Get the chat ID:
   - Send a message to the channel/group.
   - Visit `https://api.telegram.org/bot<YourBOTToken>/getUpdates` to find the chat ID.

## Hotplug Script

The `99-hostapd_cli_starter` script is a hotplug handler that automatically starts `hostapd_cli` with the event handler for all wireless interfaces when they come up. It ensures the event monitoring is active without manual intervention.

Key features:
- Logs environment variables for debugging
- Kills any existing `hostapd_cli` processes to avoid conflicts
- Dynamically discovers wireless interfaces using `iwinfo`
- Starts `hostapd_cli` in background mode (-B) for each interface with the event handler

- Placed in `/etc/hotplug.d/net/`
- Triggers on network interface events (ACTION=add for wlan interfaces)
- Runs `hostapd_cli -a /usr/sbin/hostapd_event_handler.sh -B -i $INTERFACE`

## Cron Setup for Cleanup

Add a cron job to run cleanup periodically:

```bash
# Run cleanup every minute
* * * * * /usr/sbin/hostapd_event_handler.sh WLCleanUp
```

Edit `/etc/crontabs/root` and add the line above.

## Usage

The script is called automatically by hostapd on events. You can also run it manually:

- **Cleanup Mode**: `./hostapd_event_handler.sh WLCleanUp`
  - Cleans up old disconnection entries based on configured delays.
  - Sends notifications for cleaned-up entries.

- **Event Mode**: Called by hostapd with arguments: `interface event mac`
  - `interface`: Wireless interface (e.g., wlan0)
  - `event`: AP-STA-CONNECTED or AP-STA-DISCONNECTED
  - `mac`: Client MAC address

## File Format

Disconnection records are stored in `/tmp/wl_disconnected` with format:
```
timestamp interface mac
```

Example:
```
2026-03-25T12:34:56+0000 wlan0 aa:bb:cc:dd:ee:ff
```

## Notifications

- **Connected**: Sent when a client connects (unless recently disconnected).
- **Disconnected**: Sent when a client disconnects (only during cleanup if aged out).

Message format: `Wireless interface(ssid) mac ip hostname has action. (age: HH:MM:SS, delay: HH:MM:SS)`

## Troubleshooting

- **No notifications**: Check Telegram bot token and chat ID.
- **SSID not showing**: Ensure `iwinfo` is installed and interface name matches.
- **Cleanup not working**: Verify cron job and file permissions.
- **Timestamp errors**: Script uses `awk mktime` for busybox compatibility.

## License

This script is provided as-is for educational and personal use.
