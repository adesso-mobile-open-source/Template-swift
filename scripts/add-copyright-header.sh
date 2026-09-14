#!/usr/bin/env bash
#
# add-copyright-header.sh
#
# Ensures every Swift source file in this repository carries the required
# adesso SE header: an Xcode-standard banner (filename / package / author)
# followed by the Apache-2.0 license block.
#
# The generated header looks like:
#
#   //
#   //  Filename.swift
#   //  PackageName
#   //
#   //  Created by <Author> on DD.MM.YY for adesso SE.
#   //
#   //  Copyright <YYYY> adesso SE
#   //  Licensed under the Apache License, Version 2.0 (the "License");
#   //  you may not use this file except in compliance with the License.
#   //  You may obtain a copy of the License at
#   //  http://www.apache.org/licenses/LICENSE-2.0
#
# By default the script ADDS the header to any .swift file that is missing it,
# and UPGRADES files that have the Apache license but lack the Xcode banner
# (fully compliant files are left untouched). With --check it only reports
# non-compliant files and exits non-zero, which makes it suitable for CI or a
# pre-commit hook.
#
# Package name is derived from the nearest Package.swift (`name:`). If none is
# found the script fails. The author is taken from an existing "// Created by"
# line when present; otherwise --author is required for files that need one.
#
# Usage:
#   scripts/add-copyright-header.sh --author "Doe, John"   # add/upgrade headers
#   scripts/add-copyright-header.sh Sources Tests          # limit to given paths
#   scripts/add-copyright-header.sh --check                # CI: fail if non-compliant
#
# Exit codes:
#   0  success / all files compliant
#   1  (--check only) one or more files are non-compliant
#   2  usage error (incl. missing Package.swift or missing author)

set -euo pipefail

YEAR="$(date +%Y)"          # 4-digit year for the Copyright line
CREATED_DATE="$(date +%d.%m.%y)"   # 2-digit-year date for new "Created by" lines

# The Apache license lines that get written into files. <YEAR> is substituted
# per-file (preserving an existing Copyright year when upgrading).
license_lines() {
    local year="$1"
    printf '%s\n' \
        "//  Copyright ${year} adesso SE" \
        '//  Licensed under the Apache License, Version 2.0 (the "License");' \
        '//  you may not use this file except in compliance with the License.' \
        '//  You may obtain a copy of the License at' \
        '//  http://www.apache.org/licenses/LICENSE-2.0'
}

usage() {
    cat <<'EOF'
Usage: add-copyright-header.sh [--check] [--author NAME] [-h|--help] [path ...]

Adds the required adesso SE Xcode banner + Apache-2.0 license header to Swift
files, and upgrades files that have the license but lack the banner.

Options:
  --check        Do not modify files. List non-compliant files and exit
                 non-zero if any are found (useful for CI / pre-commit).
  --author NAME  Author to use for the "Created by" line on files that do not
                 already contain one. Ignored when a file already has an
                 existing "// Created by" line (that line is preserved).
  -h, --help     Show this help and exit.

Arguments:
  path ...       Optional files or directories to scan. Defaults to the whole
                 repository. Directories are searched recursively.

Exit codes:
  0  success / all files compliant
  1  (--check only) one or more files are non-compliant
  2  usage error (incl. missing Package.swift or missing author)
EOF
}

# --- parse arguments --------------------------------------------------------
CHECK_ONLY=0
AUTHOR=""
PATHS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --author)
            [[ $# -ge 2 ]] || { echo "error: --author requires a value" >&2; exit 2; }
            AUTHOR="$2"; shift 2 ;;
        --author=*) AUTHOR="${1#--author=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do PATHS+=("$1"); shift; done ;;
        -*) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        *) PATHS+=("$1"); shift ;;
    esac
done

# --- locate repository root -------------------------------------------------
# Resolve the repository being processed from the CURRENT WORKING DIRECTORY,
# not the script's own location. This lets the script live in a shared template
# repo yet operate correctly on whatever repo the user runs it from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$PWD"
fi

# --- package name resolution ------------------------------------------------
# Derive the package/module name from the nearest Package.swift by walking up
# from the file's directory to REPO_ROOT and parsing its `name:` argument. If no
# Package.swift is found the script fails (exit 2), since the banner requires a
# package name. (Kept compatible with the macOS system Bash 3.2 -- no
# associative arrays.)
parse_package_name() {
    # Extract the first `name: "..."` from a Package.swift.
    local pkgfile="$1"
    sed -n -E 's/.*name:[[:space:]]*"([^"]+)".*/\1/p' "$pkgfile" | head -n 1
}

find_package_name() {
    local file="$1"
    local dir
    dir="$(cd "$(dirname "$file")" && pwd)"

    local search="$dir" name=""
    while :; do
        if [[ -f "$search/Package.swift" ]]; then
            name="$(parse_package_name "$search/Package.swift")"
            if [[ -n "$name" ]]; then
                printf '%s' "$name"
                return 0
            fi
        fi
        # Stop once we've checked REPO_ROOT (or reached the filesystem root).
        [[ "$search" == "$REPO_ROOT" || "$search" == "/" ]] && break
        search="$(dirname "$search")"
    done

    echo "error: no Package.swift found for '${file#"$REPO_ROOT"/}'" >&2
    echo "       (package name is required for the header banner)" >&2
    exit 2
}

# --- collect the list of .swift files to process ---------------------------
# Prefer `git ls-files` (respects .gitignore, fast) when in a git repo, and
# fall back to `find` otherwise.
collect_files() {
    local -a scan=()
    [[ $# -gt 0 ]] && scan=("$@")
    local use_git=0

    # Use `git ls-files` only when scanning the whole repository (no explicit
    # paths). Explicit paths may point outside the work tree, in which case git
    # errors out; `find` handles those cases robustly.
    if [[ ${#scan[@]} -eq 0 ]] \
        && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        use_git=1
    fi

    # Package manifests (Package.swift, Package@swift-5.9.swift, ...) are Swift
    # files but not source and must not receive a header banner.
    if [[ $use_git -eq 1 ]]; then
        git -C "$REPO_ROOT" ls-files -z -- \
            '*.swift' ':(exclude)Package.swift' ':(exclude)**/Package.swift' \
            ':(exclude)Package@swift-*.swift' ':(exclude)**/Package@swift-*.swift'
    else
        [[ ${#scan[@]} -eq 0 ]] && scan=("$REPO_ROOT")
        find "${scan[@]}" \
            \( -name .git -o -name .build -o -name Pods -o -name .swiftpm \) -prune -o \
            -type f -name '*.swift' \
            ! -name 'Package.swift' ! -name 'Package@swift-*.swift' -print0
    fi
}

# --- leading comment block --------------------------------------------------
# Emit the contiguous run of leading `//` comment lines at the top of the file.
leading_comment_block() {
    local file="$1"
    awk 'NR==1 && $0 !~ /^\/\// {exit}
         /^\/\// {print; next}
         {exit}' "$file"
}

# --- header detection -------------------------------------------------------
# The Apache license marker. We deliberately do NOT match on a generic
# "Copyright ... adesso SE" line, because Xcode banners like
#   //  Copyright © 2025 adesso SE. All rights reserved.
# also contain that text but are NOT the Apache license header.
has_license() {
    local file="$1"
    head -n 20 "$file" | grep -Eq '//[[:space:]]*Licensed under the Apache License'
}

# True if the leading comment block already contains our Xcode banner, i.e. a
#   //  <basename>.swift
# line matching this file's name.
has_our_banner() {
    local file="$1"
    local base
    base="$(basename "$file")"
    leading_comment_block "$file" \
        | grep -Eq "^//[[:space:]]+$(printf '%s' "$base" | sed 's/[.[\*^$]/\\&/g')[[:space:]]*$"
}

# A file is fully compliant when it has BOTH the license and our banner.
is_compliant() {
    local file="$1"
    has_license "$file" && has_our_banner "$file"
}

# --- third-party detection --------------------------------------------------
# Some vendored source files carry a third-party license (e.g. MIT) that must be
# preserved. We must NOT overwrite these or slap the adesso header on top. A file
# is treated as third-party if its leading comment block looks like a foreign
# license/attribution (MIT "Permission is hereby granted", or a copyright that is
# clearly not adesso SE).
is_third_party() {
    local file="$1"
    local head
    head="$(head -n 30 "$file")"
    # MIT / permissive license text.
    if printf '%s' "$head" | grep -qi 'Permission is hereby granted'; then
        return 0
    fi
    # A non-adesso copyright attribution in the banner.
    if printf '%s' "$head" \
        | grep -Ei '//[[:space:]]*Copyright' \
        | grep -qiv 'adesso'; then
        return 0
    fi
    return 1
}

# --- extraction from an existing leading comment block ----------------------
# Existing "// Created by ..." line (preserved verbatim when present).
existing_created_by() {
    local file="$1"
    leading_comment_block "$file" \
        | grep -Ei '^//[[:space:]]*Created by' | head -n 1 || true
}

# True if a "Created by" line carries no author name, e.g.
#   //  Created by  on 01.01.25 for adesso SE.
#   //  Created by
# In those cases the --author fallback should fill the name in while keeping
# the rest of the line intact.
created_by_missing_author() {
    local line="$1"
    # Strip the "//  Created by" prefix and inspect what remains up to "on"/end.
    local rest
    rest="$(printf '%s' "$line" \
        | sed -E 's#^//[[:space:]]*Created by[[:space:]]*##I')"
    # Author is missing when nothing precedes an "on ..." tail or the line end.
    [[ -z "$rest" || "$rest" =~ ^on[[:space:]] ]]
}

# Existing "// Copyright <year> adesso SE" year (preserved when upgrading).
existing_copyright_year() {
    local file="$1"
    leading_comment_block "$file" \
        | grep -Ei '^//[[:space:]]*Copyright' \
        | grep -i 'adesso' \
        | sed -n -E 's/.*Copyright[^0-9]*([0-9]{4}).*/\1/p' | head -n 1 || true
}

# --- prepend / upgrade header ----------------------------------------------
prepend_header() {
    local file="$1"
    local tmp
    tmp="$(mktemp)"

    local base pkg year created author
    base="$(basename "$file")"
    pkg="$(find_package_name "$file")"

    # Preserve an existing Copyright year, else use the current year.
    year="$(existing_copyright_year "$file")"
    [[ -n "$year" ]] || year="$YEAR"

    # Preserve an existing "Created by" line verbatim -- but only when it
    # actually carries an author name. When there is no line, or the line has
    # an empty author, fall back to --author (without overriding real names).
    created="$(existing_created_by "$file")"
    if [[ -z "$created" ]] || created_by_missing_author "$created"; then
        if [[ -z "$AUTHOR" ]]; then
            rm -f "$tmp"
            echo "error: '${file#"$REPO_ROOT"/}' has no author in its 'Created by' line; pass --author NAME" >&2
            exit 2
        fi
        author="$AUTHOR"
        if [[ -n "$created" ]]; then
            # Splice the author into the existing line, preserving its "on DATE
            # for adesso SE." tail (or the whole standard suffix if absent).
            local tail
            tail="$(printf '%s' "$created" \
                | sed -E 's#^//[[:space:]]*Created by[[:space:]]*##I')"
            if [[ -n "$tail" ]]; then
                created="//  Created by ${author} ${tail}"
            else
                created="//  Created by ${author} on ${CREATED_DATE} for adesso SE."
            fi
        else
            created="//  Created by ${author} on ${CREATED_DATE} for adesso SE."
        fi
    fi

    {
        # Xcode-standard banner.
        printf '//\n'
        printf '//  %s\n' "$base"
        printf '//  %s\n' "$pkg"
        printf '//\n'
        printf '%s\n' "$created"
        printf '//\n'
        # Apache license block.
        license_lines "$year"
        printf '\n'
        # Original file body with any pre-existing leading `//` comment block
        # (and a single trailing blank separator) stripped to avoid duplication.
        awk '
            BEGIN { in_banner = 1 }
            in_banner && /^\/\// { next }             # drop leading // lines
            in_banner && /^[[:space:]]*$/ { in_banner = 0; next }  # drop one blank sep
            { in_banner = 0; print }
        ' "$file"
    } >"$tmp"

    # Preserve original file permissions (BSD/macOS first, then GNU fallback).
    local perm
    perm="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo 644)"
    chmod "$perm" "$tmp" 2>/dev/null || true

    mv "$tmp" "$file"
}

# --- main -------------------------------------------------------------------
added=0
skipped=0
missing=0
thirdparty=0

while IFS= read -r -d '' file; do
    if is_compliant "$file"; then
        skipped=$((skipped + 1))
        continue
    fi

    # Never touch files carrying a third-party license (e.g. vendored MIT code).
    # (Files with our own adesso Apache license are not treated as third-party.)
    if ! has_license "$file" && is_third_party "$file"; then
        echo "skipped (3rd-party license): ${file#"$REPO_ROOT"/}"
        thirdparty=$((thirdparty + 1))
        continue
    fi

    if [[ $CHECK_ONLY -eq 1 ]]; then
        echo "non-compliant:  ${file#"$REPO_ROOT"/}"
        missing=$((missing + 1))
    else
        prepend_header "$file"
        echo "updated header: ${file#"$REPO_ROOT"/}"
        added=$((added + 1))
    fi
done < <(collect_files ${PATHS[@]+"${PATHS[@]}"})

if [[ $CHECK_ONLY -eq 1 ]]; then
    if [[ $missing -gt 0 ]]; then
        echo "---"
        echo "$missing file(s) non-compliant (missing license or banner)."
        [[ $thirdparty -gt 0 ]] \
            && echo "($thirdparty file(s) skipped: third-party license)"
        exit 1
    fi
    echo "All Swift files carry the required header."
    [[ $thirdparty -gt 0 ]] \
        && echo "($thirdparty file(s) skipped: third-party license)"
    exit 0
fi

echo "---"
echo "Done. Updated: $added, already compliant: $skipped, third-party skipped: $thirdparty."
