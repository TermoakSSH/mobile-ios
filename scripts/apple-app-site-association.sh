#!/usr/bin/env bash
# Writes the apple-app-site-association that a server publishes at
# /.well-known/apple-app-site-association (served as application/json) so
# its https://<server>/join/<token> links open the app (Universal Links).
# The Team ID comes from Signing.xcconfig (DEVELOPMENT_TEAM), the bundle id
# from project.yml.
#
#   scripts/apple-app-site-association.sh                 # → stdout
#   scripts/apple-app-site-association.sh ../public-web/site/.well-known/apple-app-site-association
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
team="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' "$root/Signing.xcconfig" | head -1)"
bundle="$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: *com\.termoak *$/com.termoak/p' "$root/project.yml" | head -1)"
if [ -z "$team" ]; then
  echo "Signing.xcconfig: fill in DEVELOPMENT_TEAM (the Apple Team ID) first" >&2
  exit 1
fi
bundle="${bundle:-com.termoak}"
json=$(cat <<JSON
{
  "applinks": {
    "details": [
      {
        "appIDs": ["$team.$bundle"],
        "components": [
          { "/": "/join/*", "comment": "Invitation to a shared session" },
          { "/": "/*/join/*", "comment": "Same, under a language (/es/join/…) or a server path" }
        ]
      }
    ]
  }
}
JSON
)
if [ $# -ge 1 ]; then
  printf '%s\n' "$json" > "$1"
  echo "wrote $1 ($team.$bundle)"
else
  printf '%s\n' "$json"
fi
