#!/bin/bash
# Stops cpufan, hands the fans back to macOS, and removes it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  exec osascript -e "do shell script \"/bin/bash \" & (quoted form of \"$DIR/uninstall.sh\") with administrator privileges with prompt \"cpufan needs your password to uninstall its fan service.\""
fi

LABEL=com.local.cpufan
launchctl bootout system/$LABEL 2>/dev/null || true
/usr/local/bin/cpufan auto 2>/dev/null || true
rm -f /Library/LaunchDaemons/$LABEL.plist /usr/local/bin/cpufan /var/log/cpufan.log
rm -rf "/Library/Application Support/cpufan"
echo "cpufan removed; fans are back on automatic."
