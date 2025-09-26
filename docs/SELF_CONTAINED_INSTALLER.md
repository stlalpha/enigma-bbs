# Self-Contained Installer Workflow

This branch adds tooling to package ENiGMA½ with a bundled Node.js runtime and dependencies for distribution as single-file installers.

## Prerequisites
- Docker (with binfmt/qemu for cross-platform builds)
- Go 1.22+
- `curl`, `rsync`, `tar`, `gzip`, `sha256sum`
- `unzip` (only when packaging Windows installers)
- A local Node.js matching `NODE_VERSION` when building Windows bundles on non-Windows hosts (used to drive npm)
- Python 3 with `distutils` available for native module builds (Xcode’s `/usr/bin/python3` works)
- On macOS hosts: Rosetta 2 for building `darwin/amd64` and `brew install vips pkg-config`

## Build Steps
1. From the repository root run `./build.sh`. By default it produces Linux `amd64` and `arm64` installers under `dist/`.
2. Set `NODE_VERSION` (e.g. `22.2.0`) to target a specific Node release.
3. Override `TARGET_PLATFORMS="linux/amd64 linux/arm64 darwin/arm64 darwin/amd64 windows/amd64"` (or any subset) to build additional bundles.
4. Linux targets run inside Docker and can be built anywhere with Docker/QEMU support. macOS bundles must be built on macOS (with the prerequisites above). Windows bundles can be produced on other hosts when `node` v`NODE_VERSION` is available locally.

The script downloads platform runtimes, runs `npm ci --omit=dev` (via Docker for Linux targets, locally otherwise) to produce platform-specific `node_modules`, assembles the payload, and cross-builds the Go installer (`cmd/installer`).

## Installer Behavior
- Prompts for a destination, extracts runtime + application files, and writes launch scripts (`bin/start-enigma.*`).
- Invokes `scripts/postinstall.js` to generate a fresh `config/config.hjson` and default menu files on first run.
- Leaves additional setup (SSH keys, TLS certs, etc.) to the operator.

## Extending the Build
- To support macOS/Windows, add runtime download handlers and native `npm ci` execution paths (e.g. macOS runners, Windows containers or cross-compilers).
- Consider re-introducing signing once release keys are ready. `build-dist.sh` already centralises payload generation so signature steps can be inserted near the archive creation phase.
