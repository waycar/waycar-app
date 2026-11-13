# Shared by build-native.sh, verify-native.sh and test-libssh2-patches.sh.
# Callers set PACKAGE_DIR and source Sources.lock first; download_and_verify
# also needs WORK_DIR.
# shellcheck shell=bash

LIBSSH2_PATCH_DIR="${PACKAGE_DIR}/Patches/libssh2"

download_and_verify() {
    local name="$1"
    local url="$2"
    local expected_sha256="$3"
    local archive="${WORK_DIR}/${name}.tar.gz"

    curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 --retry-all-errors \
        "${url}" --output "${archive}"

    local actual_sha256
    actual_sha256="$(shasum -a 256 "${archive}" | awk '{print $1}')"
    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
        echo "error: ${name} source hash mismatch" >&2
        echo "expected: ${expected_sha256}" >&2
        echo "actual:   ${actual_sha256}" >&2
        exit 1
    fi

    tar -xzf "${archive}" -C "${WORK_DIR}"
}

# Every *.patch in Patches/libssh2 must be listed in LIBSSH2_PATCHES with its
# reviewed SHA-256, and every listed patch must exist with that hash, so an
# unreviewed or edited patch can never reach a build.
verify_libssh2_patches() {
    local entry name expected actual listed=""

    for entry in "${LIBSSH2_PATCHES[@]}"; do
        name="${entry%% *}"
        expected="${entry##* }"
        [[ -f "${LIBSSH2_PATCH_DIR}/${name}" ]] || {
            echo "error: locked libssh2 patch is missing: ${name}" >&2
            exit 1
        }
        actual="$(shasum -a 256 "${LIBSSH2_PATCH_DIR}/${name}" | awk '{print $1}')"
        [[ "${actual}" == "${expected}" ]] || {
            echo "error: libssh2 patch hash mismatch: ${name}" >&2
            echo "expected: ${expected}" >&2
            echo "actual:   ${actual}" >&2
            exit 1
        }
        listed="${listed}${name}"$'\n'
    done

    local present
    present="$(cd "${LIBSSH2_PATCH_DIR}" && find . -maxdepth 1 -type f -name '*.patch' \
        | sed 's|^\./||' | LC_ALL=C sort)"
    [[ "${present}" == "$(printf '%s' "${listed}" | LC_ALL=C sort)" ]] || {
        echo "error: Patches/libssh2 does not match LIBSSH2_PATCHES in Sources.lock" >&2
        echo "present:" >&2
        echo "${present}" >&2
        exit 1
    }
}

# Applies the locked patches in lock order with no fuzz; any rejected hunk is
# fatal.
apply_libssh2_patches() {
    local source_dir="$1"
    local entry name

    for entry in "${LIBSSH2_PATCHES[@]}"; do
        name="${entry%% *}"
        patch --batch --forward --fuzz=0 -p1 -d "${source_dir}" \
            < "${LIBSSH2_PATCH_DIR}/${name}" >/dev/null || {
            echo "error: libssh2 patch does not apply cleanly: ${name}" >&2
            exit 1
        }
    done
}

# One provenance line per locked patch, in lock order.
libssh2_patch_provenance() {
    local entry
    for entry in "${LIBSSH2_PATCHES[@]}"; do
        echo "- libssh2 patch: ${entry%% *} sha256 ${entry##* }"
    done
}
