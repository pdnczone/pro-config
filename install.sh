#!/usr/bin/env bash
# =============================================================================
#  pro-config  —  https://github.com/pdnczone/pro-config
#
#  One link for every supported panel. It looks at this server, finds which
#  panel is installed (Rebecca or 3x-ui) and runs the matching installer with
#  all the arguments you gave.
#
#    bash <(curl -Ls https://raw.githubusercontent.com/pdnczone/pro-config/main/install.sh)
#
#  Options (everything else is passed on to the panel installer):
#    --panel-type rebecca|3x-ui   skip the detection (or pick one when both are installed)
# =============================================================================
set -euo pipefail
RAW="https://raw.githubusercontent.com/pdnczone/pro-config/main"

# --panel-type is ours; every other argument goes to the installer untouched
TYPE="${PRO_PANEL:-}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --panel-type)   TYPE="${2:-}"; shift 2 ;;
    --panel-type=*) TYPE="${1#*=}"; shift ;;
    *)              ARGS+=("$1"); shift ;;
  esac
done

have_rebecca() { [ -f /opt/rebecca/.env ] || command -v rebecca >/dev/null 2>&1; }
have_3xui()    { command -v x-ui >/dev/null 2>&1 || [ -d /etc/x-ui ] || [ -x /usr/local/x-ui/x-ui ]; }

case "$TYPE" in
  "") ;;
  rebecca) ;;
  3x-ui|3xui|xui) TYPE="3x-ui" ;;
  *) echo "Unknown --panel-type '$TYPE' (use rebecca or 3x-ui)."; exit 1 ;;
esac

if [ -z "$TYPE" ]; then
  R=0; X=0
  have_rebecca && R=1
  have_3xui && X=1
  if [ "$R$X" = "10" ]; then TYPE="rebecca"
  elif [ "$R$X" = "01" ]; then TYPE="3x-ui"
  elif [ "$R$X" = "11" ]; then
    echo "Both Rebecca and 3x-ui are installed on this server."
    if [ -r /dev/tty ]; then
      printf "Which one do you want to add the configs to?  1) Rebecca   2) 3x-ui  [1]: " > /dev/tty
      read -r a < /dev/tty || a=""
      [ "$a" = "2" ] && TYPE="3x-ui" || TYPE="rebecca"
    else
      echo "Run again with --panel-type rebecca  or  --panel-type 3x-ui"; exit 1
    fi
  else
    echo "No supported panel found on this server (looked for Rebecca in /opt/rebecca and for 3x-ui)."
    echo "Install the panel first, or force one with --panel-type rebecca|3x-ui."
    exit 1
  fi
  echo "Detected panel: $TYPE"
fi

[ "$TYPE" = "rebecca" ] && FILE="install-rebecca.sh" || FILE="install-3xui.sh"

# use the file next to this script when it is there, otherwise download it
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -n "$DIR" ] && [ -f "$DIR/$FILE" ]; then
  exec bash "$DIR/$FILE" ${ARGS[@]+"${ARGS[@]}"}
fi
TMP=$(mktemp /tmp/pro-config.XXXXXX.sh)
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$RAW/$FILE" -o "$TMP" || { echo "Could not download $FILE"; exit 1; }
bash "$TMP" ${ARGS[@]+"${ARGS[@]}"}
