#!/bin/bash
# ENiGMA½ distribution builder – creates self-contained installers per platform

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DIST_ROOT="$ROOT_DIR/dist"
CACHE_DIR="${DIST_CACHE:-$ROOT_DIR/.cache/build}"
WORK_ROOT="$ROOT_DIR/.tmp/build"

NODE_VERSION="${NODE_VERSION:-22.2.0}"
TARGET_PLATFORMS_DEFAULT="linux/amd64 linux/arm64"
if [ -n "${TARGET_PLATFORMS:-}" ]; then
    read -r -a TARGET_PLATFORMS <<< "${TARGET_PLATFORMS}"
else
    read -r -a TARGET_PLATFORMS <<< "$TARGET_PLATFORMS_DEFAULT"
fi
LDFLAGS_BASE="-s -w"

log_step() {
    echo -e "\033[1;34m[STEP]\033[0m $1"
}

log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[WARN]\033[0m $1"
}

abort() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || abort "Missing required command: $1"
}

clean_previous() {
    rm -rf "$WORK_ROOT"
    mkdir -p "$WORK_ROOT"
    mkdir -p "$CACHE_DIR"
    mkdir -p "$DIST_ROOT"
}

download_node_runtime() {
    local platform="$1"
    local os="${platform%%/*}"
    local arch="${platform##*/}"
    local archive=""
    local url=""

    case "$os" in
        linux)
            case "$arch" in
                amd64) archive="node-v${NODE_VERSION}-linux-x64.tar.xz" ;;
                arm64) archive="node-v${NODE_VERSION}-linux-arm64.tar.xz" ;;
                *) abort "Unsupported linux arch: $arch" ;;
            esac
            ;;
        *)
            abort "download_node_runtime: unsupported platform $platform"
            ;;
    esac

    url="https://nodejs.org/dist/v${NODE_VERSION}/${archive}"
    local dest="${CACHE_DIR}/${archive}"

    if [ ! -f "$dest" ]; then
        log_step "Downloading Node.js v${NODE_VERSION} for ${platform}"
        curl -fsSL "$url" -o "$dest" || abort "Failed to download Node runtime"
    else
        log_info "Using cached Node runtime: ${archive}"
    fi

    echo "$dest"
}

extract_node_runtime() {
    local tarball="$1"
    local dest_dir="$2"

    mkdir -p "$dest_dir"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    tar -xf "$tarball" -C "$tmp_dir"

    local extracted
    extracted="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d)"
    if [ -z "$extracted" ]; then
        rm -rf "$tmp_dir"
        abort "Unable to locate extracted Node directory"
    fi

    # Move contents into runtime dest
    mkdir -p "$dest_dir"
    rsync -a "$extracted"/ "$dest_dir"/
    rm -rf "$tmp_dir"
}

copy_project_sources() {
    local dest="$1"

    mkdir -p "$dest"
    local paths=(
        art
        config
        core
        docs
        gopher
        misc
        mods
        util
        www
        autoexec.sh
        LICENSE.TXT
        CONTRIBUTING.md
        UPGRADE.md
        main.js
        oputil.js
        package.json
        package-lock.json
        README.md
        TROUBLESHOOTING.md
        WHATSNEW.md
    )

    for entry in "${paths[@]}"; do
        if [ -e "$ROOT_DIR/$entry" ]; then
            rsync -a --exclude '.git' --exclude 'node_modules' "$ROOT_DIR/$entry" "$dest/"
        fi
    done

    mkdir -p "$dest/scripts"
    if [ -e "$ROOT_DIR/scripts/postinstall.js" ]; then
        cp "$ROOT_DIR/scripts/postinstall.js" "$dest/scripts/"
    fi
}

run_npm_ci() {
    local platform="$1"
    local stage_dir="$2"
    local os="${platform%%/*}"
    local arch="${platform##*/}"

    case "$os" in
        linux)
            local docker_platform="${os}/${arch}"
            local image="node:${NODE_VERSION}-bullseye"
            log_step "Installing npm dependencies for ${platform}"
            docker run --rm \
                --platform "$docker_platform" \
                -v "$stage_dir:/workspace" \
                -w /workspace \
                -e npm_config_platform="$os" \
                -e npm_config_arch="$arch" \
                "$image" \
                bash -lc "npm ci --omit=dev"
            ;;
        *)
            log_warn "npm install for $platform not automated; run on target host"
            ;;
    esac
}

create_release_archive() {
    local stage_dir="$1"
    local out_file="$2"

    log_step "Creating payload archive: $(basename "$out_file")"
    tar -czf "$out_file" -C "$stage_dir" .
}

build_installer_binary() {
    local platform="$1"
    local payload="$2"
    local os="${platform%%/*}"
    local arch="${platform##*/}"
    local output_name="enigma-installer-${os}-${arch}"

    if [ "$os" = "windows" ]; then
        output_name+=".exe"
    fi

    local installer_dir="$ROOT_DIR/cmd/installer"
    cp "$payload" "$installer_dir/release-data.tar.gz"

    pushd "$installer_dir" >/dev/null
    env GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 \
        go build -ldflags="$LDFLAGS_BASE -X main.version=${VERSION_LABEL} -X main.buildDate=${BUILD_DATE} -X main.gitCommit=${GIT_COMMIT}" \
        -o "$DIST_ROOT/${output_name}"
    popd >/dev/null

    rm -f "$installer_dir/release-data.tar.gz"
}

create_checksums() {
    local target_dir="$1"
    pushd "$target_dir" >/dev/null
    rm -f SHA256SUMS
    for file in enigma-installer-*; do
        [ -f "$file" ] || continue
        sha256sum "$file" >> SHA256SUMS
    done
    popd >/dev/null
}

main() {
    require_cmd curl
    require_cmd rsync
    require_cmd tar
    require_cmd gzip
    require_cmd docker
    require_cmd sha256sum

    BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if git describe --exact-match --tags >/dev/null 2>&1; then
        VERSION_LABEL="$(git describe --tags)"
    else
        VERSION_LABEL="$(git rev-parse --abbrev-ref HEAD)-$(git rev-parse --short HEAD)"
    fi
    GIT_COMMIT="$(git rev-parse --short HEAD)"

    clean_previous

    for platform in "${TARGET_PLATFORMS[@]}"; do
        log_step "Preparing payload for ${platform}"
        stage_dir="$WORK_ROOT/release-${platform//\//-}"
        rm -rf "$stage_dir"
        mkdir -p "$stage_dir"

        copy_project_sources "$stage_dir"

        case "$platform" in
            linux/*)
                tarball="$(download_node_runtime "$platform")"
                extract_node_runtime "$tarball" "$stage_dir/runtime"
                run_npm_ci "$platform" "$stage_dir"
                ;;
            *)
                log_warn "Runtime bundling for $platform not yet implemented"
                ;;
        esac

        payload="$WORK_ROOT/release-data-${platform//\//-}.tar.gz"
        create_release_archive "$stage_dir" "$payload"
        build_installer_binary "$platform" "$payload"
    done

    create_checksums "$DIST_ROOT"

    log_info "Installers ready in $DIST_ROOT"
}

main "$@"
