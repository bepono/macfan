#!/bin/bash
# Installs cpufan as a background service that starts at boot.
# Fan curve: minimum RPM at or below LOW C, maximum at or above HIGH C.
LOW=55
HIGH=85

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  if [ ! -x "$DIR/cpufan" ]; then
    clang -O2 -Wall -framework IOKit -o "$DIR/cpufan" "$DIR/cpufan.c"
  fi
  exec osascript -e "do shell script \"/bin/bash \" & (quoted form of \"$DIR/install.sh\") with administrator privileges with prompt \"cpufan needs your password to install its fan service.\""
fi

LABEL=com.local.cpufan
PLIST=/Library/LaunchDaemons/$LABEL.plist

launchctl bootout system/$LABEL 2>/dev/null || true

# Folder the menu bar app uses to start/stop CPU control without a password: the service
# only checks whether a "paused" file exists in it. Owned by the logged-in user.
STATE="/Library/Application Support/cpufan"
mkdir -p "$STATE"
chown "$(stat -f %Su /dev/console)" "$STATE"
chmod 755 "$STATE"
rm -f "$STATE/paused"

mkdir -p /usr/local/bin
install -o root -g wheel -m 755 "$DIR/cpufan" /usr/local/bin/cpufan

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/cpufan</string><string>run</string><string>$LOW</string><string>$HIGH</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>/var/log/cpufan.log</string>
  <key>StandardErrorPath</key><string>/var/log/cpufan.log</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
echo "cpufan installed and running."
