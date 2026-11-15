#!/bin/bash
# Rebuild NetDot and sign it with the Apple Development certificate.
# A stable signature keeps the macOS permissions ("управлять приложениями")
# across rebuilds; ad-hoc signing made every build look like a new app.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="${HOME}/Applications/NetDot.app"
tmp="$(mktemp -d)"
cp "${here}/main.swift" "${tmp}/NetDot.swift"
swiftc -O -parse-as-library "${tmp}/NetDot.swift" -o "${tmp}/NetDot"
pkill -x NetDot || true
cp "${tmp}/NetDot" "${app}/Contents/MacOS/NetDot"
# Signing identity: one line in sign-identity.txt next to config.env, for
# example "Apple Development: you@example.com (TEAMID)". Without the file the
# app is signed ad-hoc: it works, but macOS asks for its permissions again
# after every rebuild.
identity_file="${here}/../sign-identity.txt"
identity="-"
[[ -f "${identity_file}" ]] && identity="$(head -1 "${identity_file}")"
codesign --force --sign "${identity}" --identifier local.branovitskiy.netdot "${app}"
rm -rf "${tmp}"
open "${app}"
echo "NetDot rebuilt and started"
