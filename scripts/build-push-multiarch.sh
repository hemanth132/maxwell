#!/usr/bin/env bash
#
# build-push-multiarch.sh
# ---------------------------------------------------------------------------
# Builds a multi-architecture (linux/amd64 + linux/arm64) image and pushes it
# to the registry.
#
#   Image: harbor.razorpay.com/razorpay/maxwell:v1.44.1
#
# The script is idempotent and self-bootstrapping: it verifies the environment
# and installs the tools required for cross-arch builds (docker buildx + QEMU
# binfmt emulators) if they are missing, then creates a dedicated buildx
# builder and runs the build.
#
# PREREQUISITE: you must already be logged in to the registry, e.g.
#   docker login harbor.razorpay.com
#
# Usage:
#   ./scripts/build-push-multiarch.sh
#
# Override any default via environment variables:
#   IMAGE=harbor.razorpay.com/razorpay/maxwell:v1.44.2 ./scripts/build-push-multiarch.sh
#   PLATFORMS=linux/amd64,linux/arm64,linux/arm/v7 ./scripts/build-push-multiarch.sh
#   PUSH=false ./scripts/build-push-multiarch.sh        # build only, do not push
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Configuration (override via env) ────────────────────────────────────────
IMAGE="${IMAGE:-harbor.razorpay.com/razorpay/maxwell:v1.44.1}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="${BUILDER_NAME:-rzp-multiarch}"
BUILDX_VERSION="${BUILDX_VERSION:-v0.34.1}"   # used only if buildx must be installed
PUSH="${PUSH:-true}"

# Build context = repo root (this script lives in <repo>/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_DIR="${CONTEXT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
DOCKERFILE="${DOCKERFILE:-${CONTEXT_DIR}/Dockerfile}"

# ── Logging helpers ─────────────────────────────────────────────────────────
log()  { printf '\033[0;36m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[err ]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Detect OS / arch (for tool installation) ────────────────────────────────
detect_platform() {
    case "$(uname -s)" in
        Darwin) HOST_OS="darwin" ;;
        Linux)  HOST_OS="linux" ;;
        *)      err "Unsupported OS: $(uname -s). This script supports macOS and Linux." ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)        HOST_ARCH="amd64" ;;
        arm64|aarch64)       HOST_ARCH="arm64" ;;
        *)                   err "Unsupported CPU arch: $(uname -m)." ;;
    esac
}

# ── 1. Docker present and daemon reachable ──────────────────────────────────
check_docker() {
    command -v docker >/dev/null 2>&1 || err "docker not found on PATH. Install Docker (or Colima) first."
    docker info >/dev/null 2>&1 || err "Cannot reach the Docker daemon. Is Docker/Colima running?"
    ok "Docker daemon reachable"
}

# ── 2. Ensure 'docker buildx' is available, installing it if needed ─────────
ensure_buildx() {
    if docker buildx version >/dev/null 2>&1; then
        ok "docker buildx present ($(docker buildx version | awk '{print $2}'))"
        return
    fi

    warn "docker buildx not found — attempting to install it"
    local plugin_dir="${HOME}/.docker/cli-plugins"
    mkdir -p "${plugin_dir}"

    if [[ "${HOST_OS}" == "darwin" ]] && command -v brew >/dev/null 2>&1; then
        log "Installing docker-buildx via Homebrew"
        brew install docker-buildx
        # Link the brew-installed plugin into Docker's plugin dir so the CLI finds it.
        local brew_plugin="$(brew --prefix)/lib/docker/cli-plugins/docker-buildx"
        [[ -f "${brew_plugin}" ]] && ln -sf "${brew_plugin}" "${plugin_dir}/docker-buildx"
    else
        # Download the official buildx plugin binary from GitHub releases.
        local url="https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.${HOST_OS}-${HOST_ARCH}"
        log "Downloading buildx ${BUILDX_VERSION} from ${url}"
        curl -fsSL "${url}" -o "${plugin_dir}/docker-buildx" \
            || err "Failed to download buildx. Install it manually: https://github.com/docker/buildx#installing"
        chmod +x "${plugin_dir}/docker-buildx"
    fi

    docker buildx version >/dev/null 2>&1 || err "buildx still not available after install attempt."
    ok "docker buildx installed"
}

# ── 3. Ensure QEMU binfmt emulators for cross-arch builds ───────────────────
# Building a foreign architecture (e.g. amd64 on an arm64 host) needs QEMU
# emulation registered in the kernel. Docker Desktop bundles this; bare Linux
# and Colima may not. The tonistiigi/binfmt installer is idempotent.
ensure_binfmt() {
    log "Registering QEMU binfmt emulators (idempotent)"
    if docker run --rm --privileged tonistiigi/binfmt:latest --install all >/dev/null 2>&1; then
        ok "QEMU binfmt emulators registered"
    else
        warn "Could not register binfmt emulators (privileged run failed)."
        warn "If your host already supports the target platforms this is fine; otherwise the build will fail."
    fi
}

# ── 4. Ensure a docker-container buildx builder exists ──────────────────────
# The default 'docker' driver cannot do multi-platform builds; we need a
# 'docker-container' (BuildKit) builder.
ensure_builder() {
    if docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
        log "Reusing existing builder '${BUILDER_NAME}'"
        docker buildx use "${BUILDER_NAME}"
    else
        log "Creating buildx builder '${BUILDER_NAME}' (docker-container driver)"
        docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use >/dev/null
    fi
    docker buildx inspect --bootstrap "${BUILDER_NAME}" >/dev/null
    ok "Builder '${BUILDER_NAME}' ready"
}

# ── 5. Verify the builder can build every requested platform ────────────────
check_platforms() {
    local supported missing=()
    supported="$(docker buildx inspect "${BUILDER_NAME}" | grep -i '^Platforms:' | cut -d: -f2-)"
    IFS=',' read -ra wanted <<< "${PLATFORMS}"
    for p in "${wanted[@]}"; do
        p="$(echo "$p" | xargs)"  # trim
        echo "${supported}" | grep -q "${p}" || missing+=("${p}")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Builder cannot build: ${missing[*]}. Ensure QEMU binfmt is installed (step 3)."
    fi
    ok "All requested platforms supported: ${PLATFORMS}"
}

# ── 6. Sanity-check build context and Dockerfile ────────────────────────────
check_context() {
    [[ -f "${DOCKERFILE}" ]] || err "Dockerfile not found at ${DOCKERFILE}"
    [[ -d "${CONTEXT_DIR}" ]] || err "Build context not found at ${CONTEXT_DIR}"
    ok "Build context: ${CONTEXT_DIR} (Dockerfile: ${DOCKERFILE})"
}

# ── 7. Warn if not logged in to the target registry (non-fatal) ─────────────
# The script assumes you are already logged in; this is only a friendly heads-up.
check_login() {
    local registry="${IMAGE%%/*}"
    local cfg="${HOME}/.docker/config.json"
    if [[ -f "${cfg}" ]] && grep -q "${registry}" "${cfg}" 2>/dev/null; then
        ok "Found credentials for ${registry} in docker config"
    else
        warn "No stored credential entry for ${registry} found."
        warn "If the push fails with an auth error, run: docker login ${registry}"
    fi
}

# ── 8. Build and push ───────────────────────────────────────────────────────
build_and_push() {
    local output_flag="--push"
    if [[ "${PUSH}" != "true" ]]; then
        warn "PUSH=${PUSH} — building only, image will NOT be pushed."
        output_flag=""
    fi

    log "Building ${IMAGE}"
    log "  platforms : ${PLATFORMS}"
    log "  builder   : ${BUILDER_NAME}"
    log "  context   : ${CONTEXT_DIR}"

    docker buildx build \
        --builder "${BUILDER_NAME}" \
        --platform "${PLATFORMS}" \
        --file "${DOCKERFILE}" \
        --tag "${IMAGE}" \
        ${output_flag} \
        "${CONTEXT_DIR}"

    ok "Build complete"
}

# ── 9. Verify the pushed multi-arch manifest ────────────────────────────────
verify_manifest() {
    [[ "${PUSH}" == "true" ]] || return 0
    log "Verifying pushed manifest"
    docker buildx imagetools inspect "${IMAGE}"
    ok "Multi-arch image available: ${IMAGE}"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log "Multi-arch build for: ${IMAGE}"
    detect_platform
    check_docker
    ensure_buildx
    ensure_binfmt
    ensure_builder
    check_platforms
    check_context
    check_login
    build_and_push
    verify_manifest
    ok "Done."
}

main "$@"
