#!/bin/bash
# Removes NetDot. Opens the internet first so the Mac is not left blocked.
# Your settings in ~/Library/Application Support/amnezia-manual-ks are kept.
set -euo pipefail

if [[ -x "${HOME}/bin/internet-on" ]]; then
  sudo "${HOME}/bin/internet-on" || echo "internet-on failed; pf rules may still be loaded (sudo pfctl -d)"
fi

launchctl bootout "gui/$(id -u)/local.branovitskiy.netdot" 2>/dev/null || true
pkill -x NetDot 2>/dev/null || true
rm -rf "${HOME}/Applications/NetDot.app" "${HOME}/Library/LaunchAgents/local.branovitskiy.netdot.plist"

sudo launchctl bootout system/local.branovitskiy.netdot.helper 2>/dev/null || true
sudo launchctl bootout system/local.branovitskiy.netdot.boot 2>/dev/null || true
sudo rm -rf "/Library/Application Support/NetDot" \
  /Library/LaunchDaemons/local.branovitskiy.netdot.helper.plist \
  /Library/LaunchDaemons/local.branovitskiy.netdot.boot.plist \
  /var/run/netdot.sock /var/run/netdot.lock

rm -f "${HOME}/bin/internet-on" "${HOME}/bin/internet-off" "${HOME}/bin/internet-shield" \
  "${HOME}/bin/install-netdot-helper"
echo "NetDot removed."
