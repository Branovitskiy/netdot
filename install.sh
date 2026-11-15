#!/bin/bash
# Puts NetDot in place for the current user. Run from the repository folder.
# Does not need sudo itself; the last step (the root helper) asks for it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ks="${HOME}/Library/Application Support/amnezia-manual-ks"
app="${HOME}/Applications/NetDot.app"
agent="${HOME}/Library/LaunchAgents/local.branovitskiy.netdot.plist"

command -v swiftc >/dev/null || { echo "Нужны Xcode Command Line Tools: xcode-select --install"; exit 1; }

mkdir -p "${ks}/NetDot" "${HOME}/bin" "${app}/Contents/MacOS" "${HOME}/Library/LaunchAgents"
cp "${here}/lib.sh" "${ks}/lib.sh"
cp "${here}/NetDot/main.swift" "${here}/NetDot/build.sh" "${ks}/NetDot/"
cp "${here}/NetDot/Info.plist" "${app}/Contents/Info.plist"
cp "${here}/bin/internet-on" "${here}/bin/internet-off" "${here}/bin/internet-shield" \
   "${here}/bin/install-netdot-helper" "${HOME}/bin/"
chmod +x "${ks}/NetDot/build.sh" "${HOME}/bin/internet-on" "${HOME}/bin/internet-off" \
   "${HOME}/bin/internet-shield" "${HOME}/bin/install-netdot-helper"

if [[ ! -f "${ks}/config.env" ]]; then
  cp "${here}/config.example.env" "${ks}/config.env"
  echo "Создан ${ks}/config.env — впиши туда адрес своего VPN-сервера."
fi

cat > "${agent}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.branovitskiy.netdot</string>
  <key>ProgramArguments</key>
  <array>
    <string>${app}/Contents/MacOS/NetDot</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

"${ks}/NetDot/build.sh"

echo
echo "Осталось один раз поставить помощника (спросит пароль администратора):"
echo "  sudo ${HOME}/bin/install-netdot-helper"
