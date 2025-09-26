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

HOST_OS_RAW="$(uname -s)"
case "$HOST_OS_RAW" in
    Linux*) HOST_OS="linux" ;;
    Darwin*) HOST_OS="darwin" ;;
    MINGW*|MSYS*|CYGWIN*) HOST_OS="windows" ;;
    *) HOST_OS="unknown" ;;
esac

HASH_CMD=""
HASH_USE_SHASUM=0
HASH_USE_CERTUTIL=0
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

has_rsync() {
    command -v rsync >/dev/null 2>&1
}

copy_dir_contents() {
    local source="$1"
    local dest="$2"

    mkdir -p "$dest"
    if has_rsync; then
        rsync -a "$source/" "$dest/"
    else
        (cd "$source" && tar cf - .) | (cd "$dest" && tar xf -)
    fi
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
        darwin)
            case "$arch" in
                amd64) archive="node-v${NODE_VERSION}-darwin-x64.tar.gz" ;;
                arm64) archive="node-v${NODE_VERSION}-darwin-arm64.tar.gz" ;;
                *) abort "Unsupported darwin arch: $arch" ;;
            esac
            ;;
        windows)
            case "$arch" in
                amd64) archive="node-v${NODE_VERSION}-win-x64.zip" ;;
                arm64) archive="node-v${NODE_VERSION}-win-arm64.zip" ;;
                *) abort "Unsupported windows arch: $arch" ;;
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
    local archive="$1"
    local dest_dir="$2"

    mkdir -p "$dest_dir"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local extracted

    case "$archive" in
        *.tar.xz|*.tar.gz)
            tar -xf "$archive" -C "$tmp_dir"
            ;;
        *.zip)
            unzip -q "$archive" -d "$tmp_dir" || {
                rm -rf "$tmp_dir"
                abort "Failed to extract $archive"
            }
            ;;
        *)
            rm -rf "$tmp_dir"
            abort "Unsupported archive format: $archive"
            ;;
    esac

    extracted="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
    if [ -z "$extracted" ]; then
        rm -rf "$tmp_dir"
        abort "Unable to locate extracted Node directory"
    fi

    mkdir -p "$dest_dir"
    copy_dir_contents "$extracted" "$dest_dir"
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
            if [ -d "$ROOT_DIR/$entry" ]; then
                copy_dir_contents "$ROOT_DIR/$entry" "$dest/$entry"
                rm -rf "$dest/$entry/node_modules"
            else
                mkdir -p "$dest"
                cp "$ROOT_DIR/$entry" "$dest/$entry"
            fi
        fi
    done

    mkdir -p "$dest/scripts"
    if [ -e "$ROOT_DIR/scripts/postinstall.js" ]; then
        cp "$ROOT_DIR/scripts/postinstall.js" "$dest/scripts/"
    fi
}

map_npm_platform() {
    local os="$1"
    case "$os" in
        linux) echo "linux" ;;
        darwin) echo "darwin" ;;
        windows) echo "win32" ;;
        *) echo "$os" ;;
    esac
}

map_npm_arch() {
    local arch="$1"
    case "$arch" in
        amd64) echo "x64" ;;
        arm64) echo "arm64" ;;
        *) echo "$arch" ;;
    esac
}

find_node_binary() {
    local runtime_dir="$1"
    if [ -x "$runtime_dir/bin/node" ]; then
        echo "$runtime_dir/bin/node"
        return 0
    fi
    if [ -x "$runtime_dir/node" ]; then
        echo "$runtime_dir/node"
        return 0
    fi
    if [ -x "$runtime_dir/node.exe" ]; then
        echo "$runtime_dir/node.exe"
        return 0
    fi
    return 1
}

find_npm_cli() {
    local runtime_dir="$1"
    if [ -f "$runtime_dir/lib/node_modules/npm/bin/npm-cli.js" ]; then
        echo "$runtime_dir/lib/node_modules/npm/bin/npm-cli.js"
        return 0
    fi
    if [ -f "$runtime_dir/node_modules/npm/bin/npm-cli.js" ]; then
        echo "$runtime_dir/node_modules/npm/bin/npm-cli.js"
        return 0
    fi
    return 1
}

run_npm_ci() {
    local platform="$1"
    local stage_dir="$2"
    local os="${platform%%/*}"
    local arch="${platform##*/}"
    local runtime_dir="$stage_dir/runtime"

    local npm_platform
    npm_platform="$(map_npm_platform "$os")"
    local npm_arch
    npm_arch="$(map_npm_arch "$arch")"

    case "$os" in
        linux)
            local docker_platform="${os}/${arch}"
            local image="node:${NODE_VERSION}-bullseye"
            log_step "Installing npm dependencies for ${platform}"
            docker run --rm \
                --platform "$docker_platform" \
                -v "$stage_dir:/workspace" \
                -w /workspace \
                -e npm_config_platform="$npm_platform" \
                -e npm_config_arch="$npm_arch" \
                "$image" \
                bash -lc "npm ci --omit=dev"
            ;;
        darwin)
            [ "$HOST_OS" = "darwin" ] || abort "Build for ${platform} must run on macOS"
            log_step "Installing npm dependencies for ${platform}"
            local node_bin
            node_bin="$(find_node_binary "$runtime_dir")" || abort "Node binary not found for $platform"
            local npm_cli
            npm_cli="$(find_npm_cli "$runtime_dir")" || abort "npm CLI not found for $platform"

            (cd "$stage_dir" && \
                npm_config_platform="$npm_platform" \
                npm_config_arch="$npm_arch" \
                "$node_bin" "$npm_cli" ci --omit=dev)
            ;;
        windows)
            [ "$HOST_OS" = "windows" ] || abort "Build for ${platform} must run on Windows"
            log_step "Installing npm dependencies for ${platform}"
            local node_bin
            node_bin="$(find_node_binary "$runtime_dir")" || abort "Node binary not found for $platform"
            local npm_cli
            npm_cli="$(find_npm_cli "$runtime_dir")" || abort "npm CLI not found for $platform"

            (cd "$stage_dir" && \
                npm_config_platform="$npm_platform" \
                npm_config_arch="$npm_arch" \
                "$node_bin" "$npm_cli" ci --omit=dev)
            ;;
        *)
            log_warn "npm install for $platform not implemented"
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
        if [ "$HASH_USE_CERTUTIL" -eq 1 ]; then
            local hash_line
            hash_line=$(certutil -hashfile "$file" SHA256 | sed -n '2p' | tr -d '\r' | tr -d ' ')
            printf "%s  %s\n" "$hash_line" "$file" >> SHA256SUMS
        elif [ "$HASH_USE_SHASUM" -eq 1 ]; then
            "$HASH_CMD" -a 256 "$file" >> SHA256SUMS
        else
            "$HASH_CMD" "$file" >> SHA256SUMS
        fi
    done
    popd >/dev/null
}

main() {
    require_cmd curl
    require_cmd tar
    require_cmd gzip

    local needs_docker=0
    local needs_unzip=0
    for platform in "${TARGET_PLATFORMS[@]}"; do
        case "$platform" in
            linux/*) needs_docker=1 ;;
            windows/*) needs_unzip=1 ;;
        esac
    done

    if [ $needs_docker -eq 1 ]; then
        require_cmd docker
    fi

    if [ $needs_unzip -eq 1 ]; then
        require_cmd unzip
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        HASH_CMD="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        HASH_CMD="shasum"
        HASH_USE_SHASUM=1
    elif command -v certutil >/dev/null 2>&1; then
        HASH_CMD="certutil"
        HASH_USE_CERTUTIL=1
    else
        abort "Need sha256sum, shasum, or certutil for checksum generation"
    fi

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
