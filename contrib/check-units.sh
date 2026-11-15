#!/bin/bash
# -----------------------------------------------------------------------------
# contrib/check-units.sh — the systemd units in contrib/ are reference copies of
# what 'uhc.sh --install-timer' writes (monthly), with placeholders instead of
# the paths and user name. Their only source is lib/install.sh (unit_text_*).
# This script checks that the copies match it; with --update, it rewrites them.
#
#   bash contrib/check-units.sh            # exit 1 and a diff if a copy is stale
#   bash contrib/check-units.sh --update   # regenerate the copies
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

# Globals read by the generators (same value as in uhc.sh).
ROOT_INSTALL_DIR="/opt/ubuntu-health-check"
# shellcheck source=lib/install.sh
source lib/install.sh

rc=0
# unit FILE TEXT — compare (or, with --update, write) one reference copy.
unit() {
    if [[ "$UPDATE" == 1 ]]; then
        printf '%s\n' "$2" >"$1" && echo "written: $1"
    elif ! diff -u --label "$1" --label "generated" "$1" <(printf '%s\n' "$2"); then
        echo "check-units: $1 differs from lib/install.sh (run: bash contrib/check-units.sh --update)" >&2
        rc=1
    fi
}
UPDATE=0
[[ "${1:-}" == --update ]] && UPDATE=1

unit contrib/uhc.service      "$(unit_text_user_service '@UHC_DIR@' '')"
unit contrib/uhc.timer        "$(unit_text_timer user monthly)"
unit contrib/uhc-root.service "$(unit_text_root_service '@DATA_DIR@' '@USER@')"
unit contrib/uhc-root.timer   "$(unit_text_timer root monthly)"
(( rc == 0 && UPDATE == 0 )) && echo "check-units: the reference units match lib/install.sh"
exit "$rc"
