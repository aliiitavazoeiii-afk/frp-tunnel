#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-status}" in
  status) shift || true; exec /usr/local/sbin/dual-manager "$@" ;;
  health) shift || true; exec /usr/local/sbin/dual-health "${1:---quick}" "${2:-all}" ;;
  optimize) shift || true; exec /usr/local/sbin/dual-optimizer "$@" ;;
  *) echo 'usage: dual [status|health [--quick|--full] [all|trust|mieru|naive]|optimize]' >&2; exit 2 ;;
esac
