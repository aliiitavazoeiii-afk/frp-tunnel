#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }

bash "$B/install-iran-final.sh" "$@"
bash "$B/install-autoheal.sh"

echo 'SUCCESS: stable Iran install complete with conservative auto-heal enabled'
