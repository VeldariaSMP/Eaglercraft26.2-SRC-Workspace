#!/usr/bin/env sh
set -eu

PROGRAM=${0##*/}
command -v dirname >/dev/null 2>&1 || { printf 'ERROR: required system command dirname is missing\n' >&2; exit 2; }
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
DEFAULT_APP_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
APP_DIR=$DEFAULT_APP_DIR

usage() {
  cat <<EOF
Usage: $PROGRAM [--app-dir DIRECTORY]

Install app-local Java 17, Java 25, Node.js 24 LTS, and npm for Linux x86_64.
The only write location is DIRECTORY/.toolchain plus DIRECTORY/toolchain.properties.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-dir)
      [ "$#" -ge 2 ] || die "--app-dir requires a directory"
      APP_DIR=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (use --help)"
      ;;
  esac
done

command -v uname >/dev/null 2>&1 || die "required system command 'uname' is missing"
OS=$(uname -s 2>/dev/null || printf unknown)
ARCH=$(uname -m 2>/dev/null || printf unknown)
case "$OS/$ARCH" in
  Linux/x86_64|Linux/amd64) ;;
  Linux/*)
    die "unsupported Linux architecture '$ARCH'; this bootstrap supports Linux x86_64 only; no files were changed"
    ;;
  Darwin/*)
    die "macOS bootstrap is not implemented; no files were changed"
    ;;
  MINGW*/*|MSYS*/*|CYGWIN*/*)
    die "Windows bootstrap is not implemented; no files were changed"
    ;;
  *)
    die "unsupported platform '$OS/$ARCH'; this bootstrap supports Linux x86_64 only; no files were changed"
    ;;
esac

command -v id >/dev/null 2>&1 || die "required system command 'id' is missing"
if [ "$(id -u)" -eq 0 ]; then
  die "run as a normal user, not root or with sudo; this installer writes only inside the app directory"
fi

for required in curl tar sha256sum awk sed mktemp readlink cut basename rm mkdir mv chmod getconf flock; do
  command -v "$required" >/dev/null 2>&1 || die "required system command '$required' is missing"
done

LIBC_INFO=$(getconf GNU_LIBC_VERSION 2>/dev/null || :)
case "$LIBC_INFO" in
  glibc\ *) ;;
  *) die "glibc-based Linux is required by the vendor JDK/Node archives; no files were changed" ;;
esac

mkdir -p -- "$APP_DIR" || die "cannot create application directory: $APP_DIR"
APP_DIR=$(CDPATH= cd -- "$APP_DIR" && pwd -P) || die "cannot resolve application directory"
TOOL_ROOT=$APP_DIR/.toolchain
mkdir -p -- "$TOOL_ROOT" || die "cannot create app-local toolchain directory: $TOOL_ROOT"
TOOL_ROOT=$(CDPATH= cd -- "$TOOL_ROOT" && pwd -P) || die "cannot resolve toolchain directory"
PROPERTIES=$APP_DIR/toolchain.properties
exec 9>"$TOOL_ROOT/.bootstrap.lock" || die "cannot open app-local bootstrap lock"
flock -x 9 || die "cannot lock app-local toolchain"

property() {
  key=$1
  file=$2
  [ -r "$file" ] || return 1
  value=$(sed -n "s/^${key}=//p" "$file" | sed -n '1p')
  [ -n "$value" ] || return 1
  # Decode the Java Properties escapes emitted below. Do not source this file.
  printf '%s\n' "$value" | sed 's/\\=/=/g; s/\\\\/\\/g'
}

path_is_app_local() {
  candidate=$1
  [ -n "$candidate" ] || return 1
  case "$candidate" in
    "$TOOL_ROOT"/*) ;;
    *) return 1 ;;
  esac
  resolved=$(readlink -f -- "$candidate" 2>/dev/null) || return 1
  case "$resolved" in
    "$TOOL_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

java_major() {
  candidate=$1
  [ -x "$candidate" ] || return 1
  "$candidate" -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\)\..*/\1/p'
}

node_version() {
  candidate=$1
  [ -x "$candidate" ] || return 1
  "$candidate" --version 2>/dev/null
}

manifest_is_usable() {
  [ -f "$PROPERTIES" ] || return 1
  [ "$(property format "$PROPERTIES" 2>/dev/null || :)" = 1 ] || return 1
  [ "$(property platform "$PROPERTIES" 2>/dev/null || :)" = linux-x86_64 ] || return 1
  java17=$(property java17 "$PROPERTIES" 2>/dev/null || :)
  java25=$(property java25 "$PROPERTIES" 2>/dev/null || :)
  node=$(property node "$PROPERTIES" 2>/dev/null || :)
  npm=$(property npm "$PROPERTIES" 2>/dev/null || :)
  path_is_app_local "$java17" || return 1
  path_is_app_local "$java25" || return 1
  path_is_app_local "$node" || return 1
  path_is_app_local "$npm" || return 1
  [ "$(java_major "$java17" 2>/dev/null || :)" = 17 ] || return 1
  [ "$(java_major "$java25" 2>/dev/null || :)" = 25 ] || return 1
  case "$(node_version "$node" 2>/dev/null || :)" in
    v24.*) ;;
    *) return 1 ;;
  esac
  "$node" "$npm" --version >/dev/null 2>&1 || return 1
}

if manifest_is_usable; then
  printf 'App-local Java 17, Java 25, Node.js, and npm are already installed.\n'
  printf 'Tool paths: %s\n' "$PROPERTIES"
  exit 0
fi

printf 'Preparing verified app-local tools for Linux x86_64.\n'
printf 'Vendor archives will be checked against HTTPS checksums before extraction.\n'

download() {
  url=$1
  output=$2
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
    --connect-timeout 30 --max-time 1800 --output "$output" "$url"
}

manifest_field() {
  file=$1
  field=$2
  sed -n "s/^[[:space:]]*\"${field}\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | sed -n '1p'
}

validate_digest() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

resolve_temurin() {
  major=$1
  metadata_file=$2
  api_url="https://api.adoptium.net/v3/assets/latest/$major/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse"
  printf 'Fetching Eclipse Adoptium Java %s release metadata...\n' "$major" >&2
  download "$api_url" "$metadata_file" || die "could not fetch Java $major metadata from api.adoptium.net"
  checksum=$(manifest_field "$metadata_file" checksum)
  checksum_url=$(manifest_field "$metadata_file" checksum_link)
  archive_url=$(manifest_field "$metadata_file" link)
  release_name=$(manifest_field "$metadata_file" release_name)
  validate_digest "$checksum" || die "Adoptium Java $major metadata did not contain a SHA-256 digest"
  case "$checksum_url" in
    "https://github.com/adoptium/temurin${major}-binaries/releases/download/"*.tar.gz.sha256.txt) ;;
    *) die "Adoptium Java $major checksum URL was outside the official release host" ;;
  esac
  case "$archive_url" in
    "https://github.com/adoptium/temurin${major}-binaries/releases/download/"*OpenJDK${major}U-jdk_x64_linux_hotspot_*.tar.gz) ;;
    *) die "Adoptium Java $major archive URL was outside the expected official Linux x64 JDK release" ;;
  esac
  case "$release_name" in
    "jdk-${major}."*) ;;
    *) die "Adoptium returned an unexpected Java $major release name" ;;
  esac
}

STAGE_DIR=$(mktemp -d "$TOOL_ROOT/.bootstrap.XXXXXXXX") || die "could not create app-local temporary directory"
case "$STAGE_DIR" in
  "$TOOL_ROOT"/.bootstrap.*) ;;
  *) die "temporary directory resolved outside the app-local toolchain" ;;
esac
cleanup() {
  if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf -- "$STAGE_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

resolve_temurin 17 "$STAGE_DIR/temurin17.json"
JAVA17_SHA=$checksum
JAVA17_SUM_URL=$checksum_url
JAVA17_URL=$archive_url
JAVA17_RELEASE=$release_name
resolve_temurin 25 "$STAGE_DIR/temurin25.json"
JAVA25_SHA=$checksum
JAVA25_SUM_URL=$checksum_url
JAVA25_URL=$archive_url
JAVA25_RELEASE=$release_name

printf 'Fetching official Node.js 24 LTS release index...\n'
download 'https://nodejs.org/dist/index.json' "$STAGE_DIR/node-index.json" || die "could not fetch Node.js release index from nodejs.org"
NODE_INDEX_LINE=$(awk 'index($0, "{\"version\":\"v24.") == 1 && index($0, "\"lts\":false") == 0 && index($0, ",\"linux-x64\",") > 0 { print; exit }' "$STAGE_DIR/node-index.json")
NODE_VERSION=$(printf '%s\n' "$NODE_INDEX_LINE" | sed -n 's/.*"version":"\(v24\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p')
case "$NODE_VERSION" in
  v24.[0-9]*.[0-9]*) ;;
  *) die "nodejs.org did not report a stable Node.js 24 LTS Linux x64 release" ;;
esac
NODE_ARCHIVE="node-${NODE_VERSION}-linux-x64.tar.xz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_ARCHIVE}"
NODE_SUM_URL="https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt"
download "$NODE_SUM_URL" "$STAGE_DIR/node-shasums.txt" || die "could not fetch the official Node.js SHA256 manifest"
NODE_SHA=$(awk -v name="$NODE_ARCHIVE" '$2 == name { print $1; exit }' "$STAGE_DIR/node-shasums.txt")
validate_digest "$NODE_SHA" || die "official Node.js SHA256 manifest did not contain the selected archive"

verify_download() {
  archive=$1
  expected=$2
  archive_dir=${archive%/*}
  archive_base=${archive##*/}
  actual=$(CDPATH= cd -- "$archive_dir" && sha256sum -- "$archive_base" | awk '{print $1}')
  [ "$actual" = "$expected" ] || die "SHA-256 mismatch for $(basename -- "$archive"): expected $expected, got $actual"
}

fetch_temurin() {
  major=$1
  checksum=$2
  checksum_url=$3
  archive_url=$4
  archive_name=${archive_url##*/}
  checksum_name=${checksum_url##*/}
  checksum_file=$STAGE_DIR/$checksum_name
  archive_file=$STAGE_DIR/$archive_name
  printf 'Verifying Eclipse Adoptium Java %s vendor checksum...\n' "$major" >&2
  download "$checksum_url" "$checksum_file" || die "could not fetch Java $major checksum sidecar"
  sidecar_hash=$(awk 'NF { print $1; exit }' "$checksum_file")
  [ "$sidecar_hash" = "$checksum" ] || die "Java $major API digest and release checksum sidecar disagree"
  printf 'Downloading Temurin Java %s JDK...\n' "$major" >&2
  download "$archive_url" "$archive_file" || die "could not download the Java $major archive"
  verify_download "$archive_file" "$checksum"
}

fetch_temurin 17 "$JAVA17_SHA" "$JAVA17_SUM_URL" "$JAVA17_URL"
JAVA17_ARCHIVE=$archive_file
JAVA17_ARCHIVE_SHA=$checksum
JAVA17_ARCHIVE_NAME=$archive_name
fetch_temurin 25 "$JAVA25_SHA" "$JAVA25_SUM_URL" "$JAVA25_URL"
JAVA25_ARCHIVE=$archive_file
JAVA25_ARCHIVE_SHA=$checksum
JAVA25_ARCHIVE_NAME=$archive_name

printf 'Downloading Node.js %s LTS...\n' "$NODE_VERSION"
NODE_ARCHIVE_FILE=$STAGE_DIR/$NODE_ARCHIVE
download "$NODE_URL" "$NODE_ARCHIVE_FILE" || die "could not download the official Node.js archive"
verify_download "$NODE_ARCHIVE_FILE" "$NODE_SHA"

extract_archive() {
  archive=$1
  destination=$2
  mkdir -p -- "$destination"
  tar --no-same-owner --no-same-permissions -xf "$archive" -C "$destination" || die "could not extract $(basename -- "$archive")"
  set -- "$destination"/*
  [ "$#" -eq 1 ] && [ -d "$1" ] || die "unexpected archive layout in $(basename -- "$archive")"
  printf '%s\n' "$1"
}

printf 'Checking extracted vendor tools before app-local install...\n'
JAVA17_EXTRACTED=$(extract_archive "$JAVA17_ARCHIVE" "$STAGE_DIR/unpack-java17")
JAVA25_EXTRACTED=$(extract_archive "$JAVA25_ARCHIVE" "$STAGE_DIR/unpack-java25")
NODE_EXTRACTED=$(extract_archive "$NODE_ARCHIVE_FILE" "$STAGE_DIR/unpack-node")

check_jdk() {
  root=$1
  major=$2
  [ -x "$root/bin/java" ] && [ -x "$root/bin/javac" ] || die "the Java $major vendor archive lacks java or javac"
  actual=$(java_major "$root/bin/java" 2>/dev/null || :)
  [ "$actual" = "$major" ] || die "the extracted Java archive reported major $actual, expected $major"
}
check_jdk "$JAVA17_EXTRACTED" 17
check_jdk "$JAVA25_EXTRACTED" 25
[ -x "$NODE_EXTRACTED/bin/node" ] || die "the Node.js archive lacks bin/node"
[ -f "$NODE_EXTRACTED/lib/node_modules/npm/bin/npm-cli.js" ] || die "the Node.js archive lacks npm-cli.js"
[ "$(node_version "$NODE_EXTRACTED/bin/node" 2>/dev/null || :)" = "$NODE_VERSION" ] || die "the extracted Node.js archive reported an unexpected version"
"$NODE_EXTRACTED/bin/node" "$NODE_EXTRACTED/lib/node_modules/npm/bin/npm-cli.js" --version >/dev/null 2>&1 || die "the extracted npm CLI did not run under the downloaded Node.js"

archive_tag() {
  printf '%s' "$1" | cut -c1-12
}
java17_safe=$(printf '%s' "$JAVA17_RELEASE" | sed 's/^jdk-//; s/[^A-Za-z0-9.+_-]/_/g')
java25_safe=$(printf '%s' "$JAVA25_RELEASE" | sed 's/^jdk-//; s/[^A-Za-z0-9.+_-]/_/g')
JAVA17_DIR=$TOOL_ROOT/temurin17-${java17_safe}-$(archive_tag "$JAVA17_ARCHIVE_SHA")
JAVA25_DIR=$TOOL_ROOT/temurin25-${java25_safe}-$(archive_tag "$JAVA25_ARCHIVE_SHA")
NODE_DIR=$TOOL_ROOT/node-${NODE_VERSION}-linux-x64-$(archive_tag "$NODE_SHA")

install_dir() {
  extracted=$1
  destination=$2
  major=$3
  kind=$4
  if [ -e "$destination" ]; then
    [ -d "$destination" ] || die "managed destination exists and is not a directory: $destination"
    case "$kind" in
      java)
        [ "$(java_major "$destination/bin/java" 2>/dev/null || :)" = "$major" ] \
          && [ -x "$destination/bin/javac" ] || die "existing managed Java $major directory is invalid; refusing to overwrite it"
        ;;
      node)
        [ "$(node_version "$destination/bin/node" 2>/dev/null || :)" = "$major" ] \
          && [ -f "$destination/lib/node_modules/npm/bin/npm-cli.js" ] \
          && "$destination/bin/node" "$destination/lib/node_modules/npm/bin/npm-cli.js" --version >/dev/null 2>&1 \
          || die "existing managed Node.js directory is invalid; refusing to overwrite it"
        ;;
    esac
    printf 'Reusing verified app-local %s directory.\n' "$kind"
  else
    mv -- "$extracted" "$destination" || die "could not install $kind into the app-local toolchain"
  fi
}

install_dir "$JAVA17_EXTRACTED" "$JAVA17_DIR" 17 java
install_dir "$JAVA25_EXTRACTED" "$JAVA25_DIR" 25 java
install_dir "$NODE_EXTRACTED" "$NODE_DIR" "$NODE_VERSION" node

JAVA17_PATH=$JAVA17_DIR/bin/java
JAVA25_PATH=$JAVA25_DIR/bin/java
NODE_PATH=$NODE_DIR/bin/node
NPM_PATH=$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js

for candidate in "$JAVA17_PATH" "$JAVA25_PATH" "$NODE_PATH" "$NPM_PATH"; do
  path_is_app_local "$candidate" || die "installed tool resolved outside $TOOL_ROOT: $candidate"
done
[ "$(java_major "$JAVA17_PATH" 2>/dev/null || :)" = 17 ] || die "installed Java 17 validation failed"
[ "$(java_major "$JAVA25_PATH" 2>/dev/null || :)" = 25 ] || die "installed Java 25 validation failed"
[ "$(node_version "$NODE_PATH" 2>/dev/null || :)" = "$NODE_VERSION" ] || die "installed Node.js validation failed"
"$NODE_PATH" "$NPM_PATH" --version >/dev/null 2>&1 || die "installed npm validation failed"

escape_property_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/=/\\=/g'
}

PROPERTIES_TEMP=$APP_DIR/.toolchain.properties.tmp.$$
trap 'rm -f -- "$PROPERTIES_TEMP"; cleanup' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
{
  printf 'format=1\nplatform=linux-x86_64\n'
  printf 'java17=%s\n' "$(escape_property_value "$JAVA17_PATH")"
  printf 'java25=%s\n' "$(escape_property_value "$JAVA25_PATH")"
  printf 'node=%s\n' "$(escape_property_value "$NODE_PATH")"
  printf 'npm=%s\n' "$(escape_property_value "$NPM_PATH")"
  printf 'java17_version=%s\njava17_archive_sha256=%s\n' "${JAVA17_RELEASE#jdk-}" "$JAVA17_ARCHIVE_SHA"
  printf 'java25_version=%s\njava25_archive_sha256=%s\n' "${JAVA25_RELEASE#jdk-}" "$JAVA25_ARCHIVE_SHA"
  printf 'node_version=%s\nnode_archive_sha256=%s\n' "$NODE_VERSION" "$NODE_SHA"
} > "$PROPERTIES_TEMP" || die "could not write temporary toolchain manifest"
chmod 600 "$PROPERTIES_TEMP"
mv -f -- "$PROPERTIES_TEMP" "$PROPERTIES" || die "could not publish toolchain.properties"

printf 'App-local toolchain is ready.\n'
printf 'Java 17: %s\nJava 25: %s\nNode.js: %s\nnpm: %s\n' "$JAVA17_PATH" "$JAVA25_PATH" "$NODE_PATH" "$NPM_PATH"
printf 'Tool paths: %s\n' "$PROPERTIES"
