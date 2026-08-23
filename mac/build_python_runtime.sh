#!/bin/bash
#
# build_python_runtime.sh — stage the server into ClaudeCodeRemoteServer.app.
#
# Run as an Xcode build phase. Produces, inside Contents/Resources:
#
#   python/                  relocatable CPython (python-build-standalone, via uv)
#                            with the server's dependencies installed
#   bot/                     the FastAPI server sources
#   bin/ngrok                the tunnel binary
#   computer_use_mcp.py      uncompiled copy, for bot/paths.py::mcp_sidecar()
#
# The runtime is cached against a stamp of the Python version + requirements, so
# incremental builds skip the expensive pip step.
#
# Every Mach-O staged here is re-signed with the build's identity: files copied
# by a script phase are invisible to Xcode's own signing, and notarization
# rejects a bundle containing unsigned nested code.

set -euo pipefail

PYTHON_VERSION="${CCR_PYTHON_VERSION:-3.12}"

SRCROOT="${SRCROOT:?must run from Xcode (SRCROOT unset)}"
RESOURCES="${BUILT_PRODUCTS_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
BOT_SRC="${SRCROOT}/bot"

log() { echo "[build_python_runtime] $*"; }

mkdir -p "${RESOURCES}"

# ── 1. Server sources ─────────────────────────────────────────────────────────

log "staging server sources"
rm -rf "${RESOURCES}/bot"
mkdir -p "${RESOURCES}/bot"
for f in server.py serve_headless.py claude_session.py claude_runner.py \
         computer_use_mcp.py ngrok_supervisor.py paths.py voice_prompt.py; do
    if [[ -f "${BOT_SRC}/${f}" ]]; then
        cp "${BOT_SRC}/${f}" "${RESOURCES}/bot/${f}"
    else
        echo "error: ${BOT_SRC}/${f} not found" >&2
        exit 1
    fi
done

# paths.mcp_sidecar() looks here first.
cp "${BOT_SRC}/computer_use_mcp.py" "${RESOURCES}/computer_use_mcp.py"

# ── 2. ngrok ──────────────────────────────────────────────────────────────────

mkdir -p "${RESOURCES}/bin"
NGROK_SRC=""
for candidate in "${BOT_SRC}/bin/ngrok" /opt/homebrew/bin/ngrok /usr/local/bin/ngrok; do
    if [[ -x "${candidate}" ]]; then NGROK_SRC="${candidate}"; break; fi
done
if [[ -n "${NGROK_SRC}" ]]; then
    log "bundling ngrok from ${NGROK_SRC}"
    cp "${NGROK_SRC}" "${RESOURCES}/bin/ngrok"
    chmod 755 "${RESOURCES}/bin/ngrok"
else
    log "WARNING: ngrok not found — the app will fall back to PATH at runtime"
fi

# ── 3. Embedded interpreter ───────────────────────────────────────────────────

STAMP="${RESOURCES}/python/.ccr-stamp"
WANT_STAMP="$(
    printf '%s\n' "${PYTHON_VERSION}"
    shasum -a 256 "${BOT_SRC}/requirements-server.txt" | awk '{print $1}'
)"

if [[ -f "${STAMP}" ]] && [[ "$(cat "${STAMP}")" == "${WANT_STAMP}" ]]; then
    log "interpreter cache hit — skipping install"
else
    UV="$(command -v uv || true)"
    if [[ -z "${UV}" ]]; then
        for candidate in "${HOME}/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
            if [[ -x "${candidate}" ]]; then UV="${candidate}"; break; fi
        done
    fi
    if [[ -z "${UV}" ]]; then
        echo "error: uv is required to build the embedded runtime (https://docs.astral.sh/uv/)" >&2
        exit 1
    fi

    log "resolving CPython ${PYTHON_VERSION} via uv"
    "${UV}" python install "${PYTHON_VERSION}" >&2
    PY_BIN="$("${UV}" python find "${PYTHON_VERSION}")"
    # .../cpython-3.12.x-macos-<arch>-none/bin/python3 → the relocatable root
    PY_ROOT="$(cd "$(dirname "${PY_BIN}")/.." && pwd)"
    log "interpreter root: ${PY_ROOT}"

    rm -rf "${RESOURCES}/python"
    mkdir -p "${RESOURCES}/python"
    # -a preserves the symlinks CPython's layout depends on.
    cp -a "${PY_ROOT}/." "${RESOURCES}/python/"

    # python-build-standalone ships PEP 668's EXTERNALLY-MANAGED marker, which
    # exists to stop people installing into a system interpreter. This copy is
    # private to the bundle, so the marker only blocks our own install step.
    rm -f "${RESOURCES}/python/lib/python"*"/EXTERNALLY-MANAGED"

    log "installing server dependencies"
    "${UV}" pip install \
        --python "${RESOURCES}/python/bin/python3" \
        --requirement "${BOT_SRC}/requirements-server.txt" >&2

    # Trim weight that never runs in production.
    rm -rf "${RESOURCES}/python/lib/python"*"/test" \
           "${RESOURCES}/python/lib/python"*"/idlelib" \
           "${RESOURCES}/python/lib/python"*"/tkinter" \
           "${RESOURCES}/python/share" || true
    find "${RESOURCES}/python" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

    printf '%s' "${WANT_STAMP}" > "${STAMP}"
fi

# ── 4. Sign nested code ───────────────────────────────────────────────────────
#
# Xcode signs the app wrapper but never sees these files, so sign them here,
# inside-out, with the hardened runtime. Skipped when signing is off (e.g. a
# plain Debug build with CODE_SIGNING_ALLOWED=NO).

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${EXPANDED_CODE_SIGN_IDENTITY:-}}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${IDENTITY}" ]]; then
    log "signing embedded binaries as '${IDENTITY}'"
    SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:-${IDENTITY}}"

    # Every Mach-O under the staged trees: dylibs, C extensions, executables.
    while IFS= read -r target; do
        codesign --force --timestamp --options runtime \
                 --sign "${SIGN_ID}" "${target}" >/dev/null 2>&1 || {
            echo "warning: failed to sign ${target}" >&2
        }
    done < <(
        find "${RESOURCES}/python" "${RESOURCES}/bin" \
             \( -name '*.dylib' -o -name '*.so' -o -perm -u+x -type f \) 2>/dev/null \
        | while IFS= read -r f; do
            if file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then echo "$f"; fi
          done
    )
else
    log "code signing disabled — leaving embedded binaries unsigned"
fi

log "done"
