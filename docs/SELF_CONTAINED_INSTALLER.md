# Self-Contained Installer Workflow

Packages ENiGMA½ with a pinned Node.js runtime to create single-file installers per platform.

## Prerequisites

### Core Requirements
- **Go 1.22+** (required for build-dist.sh)
- **curl, tar, gzip** (standard archive tools)
- **shasum** or **sha256sum** (for checksums)
- **Python 3** with distutils (for native module rebuilds)
- **Docker** with binfmt/QEMU (for Linux cross-compilation)
- **unzip** (for Windows builds)

### Platform-Specific Requirements

#### macOS
- Homebrew **vips**
- **pkg-config**
- **Rosetta** (for darwin/amd64 cross-compilation)

#### FreeBSD
- `/usr/local/bin/bash`
- `/usr/local/bin/node`
- `/usr/local/lib/node_modules`

### Optional
- **rsync** (falls back to tar if unavailable)

## Build Instructions

Run from the repository root:
```bash
./build.sh
```

### Default Target Platforms
- `linux/amd64`
- `linux/arm64`
- `linux/armv7`
- `freebsd/amd64` (requires FreeBSD host)
- `darwin/amd64`
- `darwin/arm64`

### Platform Limitations
- **FreeBSD builds:** Must run on FreeBSD hosts
- **macOS builds:** Must run on macOS hosts
- **Linux builds:** Can be built from macOS with Docker

### Configuration Options

| Variable | Description | Default |
|----------|-------------|---------|
| `TARGET_PLATFORMS` | Override platform list | All supported platforms |
| `NODE_VERSION` | Specify Node.js version | Latest stable |
| `SKIP_COMPLETED` | Skip existing installers | `1` |
| `FORCE_REBUILD` | Force overwrite artifacts | `0` |

#### Examples
```bash
# Build only Linux platforms
TARGET_PLATFORMS="linux/amd64 linux/arm64" ./build.sh

# Rebuild all platforms
SKIP_COMPLETED=0 ./build.sh

# Force rebuild with specific Node version
FORCE_REBUILD=1 NODE_VERSION=20.11.0 ./build.sh
```

### Output Locations
- **Build workspace:** `.tmp/`
- **Downloads cache:** `.cache/`
- **Installers:** `dist/enigma-installer-<os>-<arch>`

## Installer Behavior

The generated installer performs the following steps:

1. **Platform Detection**  
   Detects the target platform and extracts the embedded payload

2. **Runtime Setup**  
   Creates `runtime/` directory containing:
   - Node.js binary
   - Platform-specific node_modules
   - Helper scripts (uses `/usr/local/bin/bash` on FreeBSD, `/bin/bash` elsewhere)

3. **Post-Installation**  
   Executes `scripts/postinstall.js --install-dir <path>` to:
   - Generate `config/config.hjson`
   - Create starter assets

4. **Completion**  
   Displays launch command and configuration instructions

## Notes

- FreeBSD builds use the system Node.js from `/usr/local` instead of downloading archives