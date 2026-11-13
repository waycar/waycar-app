#!/bin/sh
# Give the archive a dSYM for each code-free framework stub Xcode embeds.
#
#   scripts/archive-stub-dsyms.sh build/Waycar.xcarchive   (`make archive` runs it)
#
# Why: CLibSSH2 and COpenSSL (Packages/WaycarSSH) are static frameworks. Xcode
# links their code into the app binary, so Waycar.app.dSYM already symbolicates
# it, and embeds the bundles anyway with an empty stub dylib in place of the
# archive ("Injecting stub binary into codeless framework" in the build log).
# The stub has a UUID but no dSYM, so every upload warned "Upload Symbols
# Failed. The archive did not include a dSYM for the CLibSSH2.framework". A
# dSYM of the stub itself matches that UUID. Frameworks whose binary has
# symbols are real dylibs and are left to their own dSYMs.
set -eu

archive="${1:?usage: $0 <archive.xcarchive>}"

for framework in "${archive}"/Products/Applications/*.app/Frameworks/*.framework; do
    [ -d "${framework}" ] || continue
    name="$(basename "${framework}" .framework)"
    binary="${framework}/${name}"
    dsym="${archive}/dSYMs/${name}.framework.dSYM"
    [ -f "${binary}" ] && [ ! -e "${dsym}" ] || continue
    xcrun nm "${binary}" 2>&1 | grep -q 'no symbols' || continue
    if xcrun dsymutil "${binary}" -o "${dsym}" 2>/dev/null; then
        echo "Stub dSYM: ${name}.framework"
    else
        echo "warning: no stub dSYM for ${name}.framework; the upload will warn about it" >&2
    fi
done
