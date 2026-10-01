#!/bin/sh
set -eu

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
DEFAULT_APP_DIR=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd -P)
APP_DIR=$DEFAULT_APP_DIR

usage() {
  cat <<EOF
Usage: $PROGRAM [--app-dir DIRECTORY]

Install app-local Java 17, Java 25, Node.js 24 LTS, and npm for macOS 13+
on Intel x86_64 or Apple Silicon arm64. Writes only DIRECTORY/.toolchain
and DIRECTORY/toolchain.properties. No administrator rights are used.
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
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

for required in uname sw_vers id dirname curl tar shasum awk sed mktemp readlink \
  basename cut mkdir mv chmod rm rmdir sleep hostname; do
  command -v "$required" >/dev/null 2>&1 || die "required macOS command '$required' is missing"
done

OS=$(uname -s 2>/dev/null || printf unknown)
[ "$OS" = Darwin ] || die "this bootstrap supports macOS only; detected '$OS'; no files were changed"

MACHINE=$(uname -m 2>/dev/null || printf unknown)
case "$MACHINE" in
  arm64|aarch64)
    VENDOR_ARCH=aarch64
    PLATFORM_ARCH=arm64
    NODE_ARCH=arm64
    ;;
  x86_64|amd64)
    VENDOR_ARCH=x64
    PLATFORM_ARCH=x86_64
    NODE_ARCH=x64
    ;;
  *) die "unsupported macOS architecture '$MACHINE'; supported architectures are Intel x86_64 and Apple Silicon arm64; no files were changed" ;;
esac

MAC_VERSION=$(sw_vers -productVersion 2>/dev/null || printf unknown)
MAC_MAJOR=${MAC_VERSION%%.*}
case "$MAC_MAJOR" in
  ''|*[!0-9]*) die "could not determine macOS version from '$MAC_VERSION'; no files were changed" ;;
esac
[ "$MAC_MAJOR" -ge 13 ] || die "macOS 13 Ventura or newer is required for the official Node.js 24 binary; found $MAC_VERSION; no files were changed"

command -v id >/dev/null 2>&1 || die "required macOS command 'id' is missing"
[ "$(id -u)" -ne 0 ] || die "run as a normal user, not root or with sudo; this installer writes only inside the application directory"

case "$APP_DIR" in
  /*) ;;
  *) APP_DIR=$PWD/$APP_DIR ;;
esac
mkdir -p "$APP_DIR" || die "cannot create application directory: $APP_DIR"
APP_DIR=$(CDPATH= cd "$APP_DIR" && pwd -P) || die "cannot resolve application directory"
TOOL_ROOT=$APP_DIR/.toolchain
mkdir -p "$TOOL_ROOT" || die "cannot create app-local toolchain directory: $TOOL_ROOT"
TOOL_ROOT=$(CDPATH= cd "$TOOL_ROOT" && pwd -P) || die "cannot resolve toolchain directory"
PROPERTIES=$APP_DIR/toolchain.properties
PLATFORM=macos-$PLATFORM_ARCH
HOSTNAME_VALUE=$(hostname 2>/dev/null || printf unknown)
LOCK_DIR=$TOOL_ROOT/.bootstrap.lock
LOCK_HELD=0
STAGE_DIR=
PROPERTIES_TEMP=

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ] && [ -d "$LOCK_DIR" ]; then
    owner_pid=
    owner_host=
    if [ -r "$LOCK_DIR/owner" ]; then
      IFS=' ' read -r owner_pid owner_host < "$LOCK_DIR/owner" || :
    fi
    if [ "$owner_pid" = "$$" ] && [ "$owner_host" = "$HOSTNAME_VALUE" ]; then
      rm -f "$LOCK_DIR/owner"
      rmdir "$LOCK_DIR" 2>/dev/null || :
    fi
  fi
  LOCK_HELD=0
}

cleanup() {
  if [ -n "$PROPERTIES_TEMP" ] && [ -f "$PROPERTIES_TEMP" ]; then
    rm -f "$PROPERTIES_TEMP"
  fi
  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi
  release_lock
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

property() {
  key=$1
  file=$2
  [ -r "$file" ] || return 1
  value=$(sed -n "s/^${key}=//p" "$file" | sed -n '1p')
  [ -n "$value" ] || return 1
  printf '%s\n' "$value" | sed 's/\\=/=/g; s/\\\\/\\/g'
}

resolve_path() {
  candidate=$1
  case "$candidate" in
    /*) ;;
    *) candidate=$PWD/$candidate ;;
  esac
  hops=0
  while :; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    parent=${candidate%/*}
    leaf=${candidate##*/}
    [ -n "$parent" ] || parent=/
    resolved_parent=$(CDPATH= cd "$parent" 2>/dev/null && pwd -P) || return 1
    candidate=$resolved_parent/$leaf
    if [ -L "$candidate" ]; then
      target=$(readlink "$candidate" 2>/dev/null) || return 1
      case "$target" in
        /*) candidate=$target ;;
        *) candidate=$resolved_parent/$target ;;
      esac
    else
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

path_is_app_local() {
  candidate=$1
  [ -n "$candidate" ] || return 1
  case "$candidate" in
    "$TOOL_ROOT"/*) ;;
    *) return 1 ;;
  esac
  resolved=$(resolve_path "$candidate") || return 1
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
  [ "$(property platform "$PROPERTIES" 2>/dev/null || :)" = "$PLATFORM" ] || return 1
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

acquire_lock() {
  waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner_pid=
    owner_host=
    if [ -r "$LOCK_DIR/owner" ]; then
      IFS=' ' read -r owner_pid owner_host < "$LOCK_DIR/owner" || :
    fi
    stale=0
    if [ "$owner_host" = "$HOSTNAME_VALUE" ]; then
      case "$owner_pid" in
        ''|*[!0-9]*) ;;
        *)
          if ! kill -0 "$owner_pid" 2>/dev/null; then stale=1; fi
          ;;
      esac
    elif [ -z "$owner_pid" ] && [ "$waited" -ge 10 ]; then
      stale=1
    fi
    if [ "$stale" -eq 1 ]; then
      stale_dir=$TOOL_ROOT/.bootstrap.stale.$$.${waited}
      if mv "$LOCK_DIR" "$stale_dir" 2>/dev/null; then
        rm -f "$stale_dir/owner"
        rmdir "$stale_dir" 2>/dev/null || :
        continue
      fi
    fi
    [ "$waited" -lt 600 ] || die "timed out waiting for another app-local toolchain install; if its process was killed, remove $LOCK_DIR after confirming no bootstrap is running"
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s %s\n' "$$" "$HOSTNAME_VALUE" > "$LOCK_DIR/owner" || {
    rmdir "$LOCK_DIR" 2>/dev/null || :
    die "cannot record owner of app-local toolchain lock"
  }
  LOCK_HELD=1
}

validate_digest() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

download() {
  url=$1
  output=$2
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
    --connect-timeout 30 --max-time 1800 --output "$output" "$url"
}

manifest_package_field() {
  file=$1
  field=$2
  sed -n '/"package"[[:space:]]*:/,/^[[:space:]]*}/p' "$file" \
    | sed -n "s/^[[:space:]]*\"${field}\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | sed -n '1p'
}

manifest_top_field() {
  file=$1
  field=$2
  sed -n "s/^[[:space:]]*\"${field}\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | sed -n '1p'
}

resolve_temurin() {
  major=$1
  metadata_file=$2
  api_url="https://api.adoptium.net/v3/assets/latest/$major/hotspot?architecture=$VENDOR_ARCH&image_type=jdk&os=mac&vendor=eclipse"
  printf 'Fetching Eclipse Adoptium Java %s release metadata for macOS %s...\n' "$major" "$VENDOR_ARCH" >&2
  download "$api_url" "$metadata_file" || die "could not fetch Java $major metadata from api.adoptium.net"
  checksum=$(manifest_package_field "$metadata_file" checksum)
  checksum_url=$(manifest_package_field "$metadata_file" checksum_link)
  archive_url=$(manifest_package_field "$metadata_file" link)
  release_name=$(manifest_top_field "$metadata_file" release_name)
  validate_digest "$checksum" || die "Adoptium Java $major package metadata did not contain a SHA-256 digest"
  case "$checksum_url" in
    "https://github.com/adoptium/temurin${major}-binaries/releases/download/"*.tar.gz.sha256.txt) ;;
    *) die "Adoptium Java $major checksum URL was outside the official macOS JDK release host" ;;
  esac
  case "$archive_url" in
    "https://github.com/adoptium/temurin${major}-binaries/releases/download/"*"OpenJDK${major}U-jdk_${VENDOR_ARCH}_mac_hotspot_"*.tar.gz) ;;
    *) die "Adoptium returned an unexpected Java $major macOS $VENDOR_ARCH JDK archive URL" ;;
  esac
  case "$release_name" in
    "jdk-${major}."*) ;;
    *) die "Adoptium returned an unexpected Java $major release name" ;;
  esac
  metadata_arch=$(sed -n 's/^[[:space:]]*"architecture":[[:space:]]*"\([^"]*\)".*/\1/p' "$metadata_file" | sed -n '1p')
  metadata_os=$(sed -n 's/^[[:space:]]*"os":[[:space:]]*"\([^"]*\)".*/\1/p' "$metadata_file" | sed -n '1p')
  metadata_type=$(sed -n 's/^[[:space:]]*"image_type":[[:space:]]*"\([^"]*\)".*/\1/p' "$metadata_file" | sed -n '1p')
  [ "$metadata_arch" = "$VENDOR_ARCH" ] && [ "$metadata_os" = mac ] && [ "$metadata_type" = jdk ] \
    || die "Adoptium Java $major metadata did not identify the requested macOS $VENDOR_ARCH JDK"
}

archive_digest() {
  archive=$1
  shasum -a 256 < "$archive" | awk '{print $1}'
}

verify_download() {
  archive=$1
  expected=$2
  actual=$(archive_digest "$archive") || die "could not calculate SHA-256 for $(basename "$archive")"
  [ "$actual" = "$expected" ] || die "SHA-256 mismatch for $(basename "$archive"): expected $expected, got $actual"
}

safe_archive() {
  archive=$1
  expected_root=$2
  listing=$3
  verbose=$4
  tar -tf "$archive" > "$listing" || die "could not list verified archive $(basename "$archive")"
  [ -s "$listing" ] || die "empty archive: $(basename "$archive")"
  while IFS= read -r member || [ -n "$member" ]; do
    case "$member" in
      /*|*\\*|*' '*|*'	'*) die "unsafe or unexpected archive member in $(basename "$archive"): $member" ;;
    esac
    clean=${member%/}
    [ -n "$clean" ] || die "empty archive member in $(basename "$archive")"
    case "/$clean/" in
      *"/../"*|*"/./"*|*"//"*) die "unsafe archive path in $(basename "$archive"): $member" ;;
    esac
    first=${clean%%/*}
    [ "$first" = "$expected_root" ] || die "unexpected archive root in $(basename "$archive"): $member"
  done < "$listing"

  tar -tvf "$archive" > "$verbose" || die "could not inspect links in verified archive $(basename "$archive")"
  awk -v root="$expected_root" '
    function contained(source, target, p, q, i, n, m, depth, stack, parts) {
      if (source == "" || target == "" || source ~ /[[:space:]\\]/ || target ~ /[[:space:]\\]/) return 0
      if (substr(source, 1, 1) == "/" || substr(target, 1, 1) == "/") return 0
      n = split(source, p, "/")
      depth = 0
      for (i = 1; i < n; i++) {
        if (p[i] == "" || p[i] == ".") continue
        if (p[i] == "..") {
          if (depth <= 1) return 0
          depth--
        } else stack[++depth] = p[i]
      }
      if (depth < 1 || stack[1] != root) return 0
      m = split(target, q, "/")
      for (i = 1; i <= m; i++) {
        if (q[i] == "" || q[i] == ".") continue
        if (q[i] == "..") {
          if (depth <= 1) return 0
          depth--
        } else stack[++depth] = q[i]
      }
      return depth >= 1 && stack[1] == root
    }
    function hardlink_contained(target, n, p, i) {
      if (target == "" || target ~ /[[:space:]\\]/ || substr(target, 1, 1) == "/") return 0
      n = split(target, p, "/")
      if (p[1] != root) return 0
      for (i = 1; i <= n; i++) if (p[i] == ".." || p[i] == ".") return 0
      return 1
    }
    {
      mode = substr($1, 1, 1)
      arrow = index($0, " -> ")
      hard = index($0, " link to ")
      if (mode == "l" && arrow > 0) {
        source = $9
        target = substr($0, arrow + 4)
        if (!contained(source, target)) exit 1
      } else if (hard > 0) {
        source = $9
        target = substr($0, hard + 9)
        if (!source || !hardlink_contained(target)) exit 1
      }
    }
  ' "$verbose" || die "archive contains a symbolic or hard link outside its single top-level directory: $(basename "$archive")"
}

acquire_lock
if manifest_is_usable; then
  printf 'App-local Java 17, Java 25, Node.js, and npm are already installed for %s.\n' "$PLATFORM"
  printf 'Tool paths: %s\n' "$PROPERTIES"
  exit 0
fi

printf 'Preparing verified app-local tools for macOS %s (%s).\n' "$MAC_VERSION" "$PLATFORM_ARCH"
printf 'Vendor archives will be fetched over HTTPS and checked against official SHA-256 values before extraction.\n'

STAGE_DIR=$(mktemp -d "$TOOL_ROOT/.bootstrap.XXXXXX") || die "could not create app-local temporary directory"
case "$STAGE_DIR" in
  "$TOOL_ROOT"/.bootstrap.*) ;;
  *) die "temporary directory resolved outside the app-local toolchain" ;;
esac

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
NODE_FILE_KIND=osx-$NODE_ARCH-tar
NODE_INDEX_LINE=$(awk -v file_kind="$NODE_FILE_KIND" 'index($0, "{\"version\":\"v24.") == 1 && index($0, "\"lts\":\"") > 0 && index($0, "\"" file_kind "\"") > 0 { print; exit }' "$STAGE_DIR/node-index.json")
NODE_VERSION=$(printf '%s\n' "$NODE_INDEX_LINE" | sed -n 's/.*"version":"\(v24\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p')
case "$NODE_VERSION" in
  v24.[0-9]*.[0-9]*) ;;
  *) die "nodejs.org did not report a stable Node.js 24 LTS macOS $NODE_ARCH archive" ;;
esac
NODE_ARCHIVE=node-$NODE_VERSION-darwin-$NODE_ARCH.tar.gz
NODE_URL=https://nodejs.org/dist/$NODE_VERSION/$NODE_ARCHIVE
NODE_SUM_URL=https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt
download "$NODE_SUM_URL" "$STAGE_DIR/node-shasums.txt" || die "could not fetch the official Node.js SHA256 manifest"
NODE_SHA=$(awk -v name="$NODE_ARCHIVE" '$2 == name { print $1; exit }' "$STAGE_DIR/node-shasums.txt")
validate_digest "$NODE_SHA" || die "official Node.js SHA256 manifest did not contain the selected archive"

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
  printf '%s\n' "$archive_file"
}

JAVA17_ARCHIVE=$(fetch_temurin 17 "$JAVA17_SHA" "$JAVA17_SUM_URL" "$JAVA17_URL")
JAVA25_ARCHIVE=$(fetch_temurin 25 "$JAVA25_SHA" "$JAVA25_SUM_URL" "$JAVA25_URL")
printf 'Downloading Node.js %s LTS...\n' "$NODE_VERSION"
NODE_ARCHIVE_FILE=$STAGE_DIR/$NODE_ARCHIVE
download "$NODE_URL" "$NODE_ARCHIVE_FILE" || die "could not download the official Node.js archive"
verify_download "$NODE_ARCHIVE_FILE" "$NODE_SHA"

JAVA17_ROOT=${JAVA17_RELEASE#jdk-}
JAVA17_ROOT=jdk-$JAVA17_ROOT
JAVA25_ROOT=${JAVA25_RELEASE#jdk-}
JAVA25_ROOT=jdk-$JAVA25_ROOT
NODE_ROOT=node-$NODE_VERSION-darwin-$NODE_ARCH
safe_archive "$JAVA17_ARCHIVE" "$JAVA17_ROOT" "$STAGE_DIR/java17.list" "$STAGE_DIR/java17.verbose"
safe_archive "$JAVA25_ARCHIVE" "$JAVA25_ROOT" "$STAGE_DIR/java25.list" "$STAGE_DIR/java25.verbose"
safe_archive "$NODE_ARCHIVE_FILE" "$NODE_ROOT" "$STAGE_DIR/node.list" "$STAGE_DIR/node.verbose"

extract_archive() {
  archive=$1
  destination=$2
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination" || die "could not extract $(basename "$archive")"
  set -- "$destination"/*
  [ "$#" -eq 1 ] && [ -d "$1" ] || die "unexpected archive layout in $(basename "$archive")"
  printf '%s\n' "$1"
}

printf 'Checking extracted vendor tools before app-local install...\n'
JAVA17_EXTRACTED=$(extract_archive "$JAVA17_ARCHIVE" "$STAGE_DIR/unpack-java17")
JAVA25_EXTRACTED=$(extract_archive "$JAVA25_ARCHIVE" "$STAGE_DIR/unpack-java25")
NODE_EXTRACTED=$(extract_archive "$NODE_ARCHIVE_FILE" "$STAGE_DIR/unpack-node")

check_jdk() {
  root=$1
  major=$2
  [ -x "$root/Contents/Home/bin/java" ] && [ -x "$root/Contents/Home/bin/javac" ] \
    || die "the macOS Java $major vendor archive lacks Contents/Home/bin/java or javac"
  actual=$(java_major "$root/Contents/Home/bin/java" 2>/dev/null || :)
  [ "$actual" = "$major" ] || die "the extracted Java archive reported major $actual, expected $major"
}
check_jdk "$JAVA17_EXTRACTED" 17
check_jdk "$JAVA25_EXTRACTED" 25
[ -x "$NODE_EXTRACTED/bin/node" ] || die "the Node.js archive lacks bin/node"
[ -f "$NODE_EXTRACTED/lib/node_modules/npm/bin/npm-cli.js" ] || die "the Node.js archive lacks npm-cli.js"
[ "$(node_version "$NODE_EXTRACTED/bin/node" 2>/dev/null || :)" = "$NODE_VERSION" ] \
  || die "the extracted Node.js archive reported an unexpected version"
"$NODE_EXTRACTED/bin/node" "$NODE_EXTRACTED/lib/node_modules/npm/bin/npm-cli.js" --version >/dev/null 2>&1 \
  || die "the extracted npm CLI did not run under the downloaded Node.js"

archive_tag() { printf '%s' "$1" | cut -c1-12; }
java17_safe=$(printf '%s' "$JAVA17_RELEASE" | sed 's/^jdk-//; s/[^A-Za-z0-9.+_-]/_/g')
java25_safe=$(printf '%s' "$JAVA25_RELEASE" | sed 's/^jdk-//; s/[^A-Za-z0-9.+_-]/_/g')
JAVA17_DIR=$TOOL_ROOT/temurin17-${java17_safe}-$(archive_tag "$JAVA17_SHA")
JAVA25_DIR=$TOOL_ROOT/temurin25-${java25_safe}-$(archive_tag "$JAVA25_SHA")
NODE_DIR=$TOOL_ROOT/node-${NODE_VERSION}-darwin-${NODE_ARCH}-$(archive_tag "$NODE_SHA")

install_dir() {
  extracted=$1
  destination=$2
  major=$3
  kind=$4
  if [ -e "$destination" ]; then
    [ -d "$destination" ] || die "managed destination exists and is not a directory: $destination"
    case "$kind" in
      java)
        [ "$(java_major "$destination/Contents/Home/bin/java" 2>/dev/null || :)" = "$major" ] \
          && [ -x "$destination/Contents/Home/bin/javac" ] \
          || die "existing managed Java $major directory is invalid; refusing to overwrite it"
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
    mv "$extracted" "$destination" || die "could not install $kind into the app-local toolchain"
  fi
}

install_dir "$JAVA17_EXTRACTED" "$JAVA17_DIR" 17 java
install_dir "$JAVA25_EXTRACTED" "$JAVA25_DIR" 25 java
install_dir "$NODE_EXTRACTED" "$NODE_DIR" "$NODE_VERSION" node

JAVA17_PATH=$JAVA17_DIR/Contents/Home/bin/java
JAVA25_PATH=$JAVA25_DIR/Contents/Home/bin/java
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
{
  printf 'format=1\nplatform=%s\n' "$PLATFORM"
  printf 'java17=%s\n' "$(escape_property_value "$JAVA17_PATH")"
  printf 'java25=%s\n' "$(escape_property_value "$JAVA25_PATH")"
  printf 'node=%s\n' "$(escape_property_value "$NODE_PATH")"
  printf 'npm=%s\n' "$(escape_property_value "$NPM_PATH")"
  printf 'java17_version=%s\njava17_archive_sha256=%s\n' "${JAVA17_RELEASE#jdk-}" "$JAVA17_SHA"
  printf 'java25_version=%s\njava25_archive_sha256=%s\n' "${JAVA25_RELEASE#jdk-}" "$JAVA25_SHA"
  printf 'node_version=%s\nnode_archive_sha256=%s\n' "$NODE_VERSION" "$NODE_SHA"
} > "$PROPERTIES_TEMP" || die "could not write temporary toolchain manifest"
chmod 600 "$PROPERTIES_TEMP"
mv -f "$PROPERTIES_TEMP" "$PROPERTIES" || die "could not publish toolchain.properties"
PROPERTIES_TEMP=

printf 'App-local toolchain is ready.\n'
printf 'Java 17: %s\nJava 25: %s\nNode.js: %s\nnpm: %s\n' "$JAVA17_PATH" "$JAVA25_PATH" "$NODE_PATH" "$NPM_PATH"
printf 'Tool paths: %s\n' "$PROPERTIES"
