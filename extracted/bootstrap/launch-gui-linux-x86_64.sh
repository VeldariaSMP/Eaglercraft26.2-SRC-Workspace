#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
DEFAULT_APP_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
APP_DIR=$DEFAULT_APP_DIR

if [ "${1:-}" = "--app-dir" ]; then
  [ "$#" -ge 2 ] || { printf 'ERROR: --app-dir requires a directory\n' >&2; exit 2; }
  APP_DIR=$2
  shift 2
fi

APP_DIR=$(CDPATH= cd -- "$APP_DIR" && pwd -P) || {
  printf 'ERROR: application directory does not exist: %s\n' "$APP_DIR" >&2
  exit 2
}
BOOTSTRAP=$SCRIPT_DIR/bootstrap-linux-x86_64.sh
GUI_JAR=$APP_DIR/eaglercraft-26.2-u1-patcher-gui.jar
PROPERTIES=$APP_DIR/toolchain.properties

[ -f "$GUI_JAR" ] || { printf 'ERROR: GUI JAR is missing: %s\n' "$GUI_JAR" >&2; exit 2; }
[ -x "$BOOTSTRAP" ] || { printf 'ERROR: Linux bootstrap is missing or not executable: %s\n' "$BOOTSTRAP" >&2; exit 2; }

"$BOOTSTRAP" --app-dir "$APP_DIR"

property() {
  key=$1
  value=$(sed -n "s/^${key}=//p" "$PROPERTIES" | sed -n '1p')
  printf '%s\n' "$value" | sed 's/\\=/=/g; s/\\\\/\\/g'
}

JAVA17=$(property java17)
[ -x "$JAVA17" ] || { printf 'ERROR: app-local Java 17 was not installed correctly\n' >&2; exit 2; }
exec "$JAVA17" -jar "$GUI_JAR" "$@"
