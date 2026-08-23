#!/bin/bash
# Script to automatically fetch the latest SPT version information
# This extracts the download URL from SP-Tushonka/build releases
#
# Upstream moved from the sp-tarkov org to SP-Tushonka (trademark takedown). The
# old org is archived and its mirror (spt-releases.modd.in) is frozen at 4.1.2,
# so only SP-Tushonka/build carries new releases.

set -e

SPT_BUILD_REPO="${SPT_BUILD_REPO:-SP-Tushonka/build}"

# Pull the SPT archive URL out of a release JSON blob.
# Prefers the attached release asset (present since the SP-Tushonka move) and
# falls back to scraping the release notes, which is how it worked pre-move.
extract_download_url() {
    local release_json="$1"

    local asset_url=$(echo "$release_json" | jq -r '.assets[]?.browser_download_url' \
        | grep -E '/SPT-[0-9.]+-[0-9]+-[a-f0-9]+\.7z$' | head -n1)

    if [ -n "$asset_url" ]; then
        echo "$asset_url"
        return 0
    fi

    local release_body=$(echo "$release_json" | jq -r '.body')

    if [ "$release_body" = "null" ] || [ -z "$release_body" ]; then
        return 1
    fi

    # Format: https://mirror.sp-tushonka.com/releases/SPT-4.1.3-40743-ddce41c.7z
    # Legacy: https://spt-releases.modd.in/SPT-4.0.13-40087-2891fd4.7z
    echo "$release_body" | grep -oP 'https://\S+/SPT-[0-9.]+-[0-9]+-[a-f0-9]+\.7z' | head -n1
}

# Extract version string from a download URL, whichever host it points at
# From: https://mirror.sp-tushonka.com/releases/SPT-4.1.3-40743-ddce41c.7z
# To:   4.1.3-40743-ddce41c
parse_version_from_url() {
    echo "$1" | sed -E 's|^.*/SPT-||; s|\.7z$||'
}

# Function to get the latest SPT version from release download URL
get_latest_spt_version() {
    local github_api="https://api.github.com/repos/${SPT_BUILD_REPO}/releases/latest"

    echo "Fetching latest SPT release from GitHub..." >&2

    local release_json=$(curl -s "$github_api")
    local download_url=$(extract_download_url "$release_json")

    if [ -z "$download_url" ]; then
        echo "Error: Could not find download URL in ${SPT_BUILD_REPO} latest release" >&2
        echo "Release body:" >&2
        echo "$release_json" | jq -r '.body' | head -20 >&2
        return 1
    fi

    local full_version=$(parse_version_from_url "$download_url")

    if [ -z "$full_version" ]; then
        echo "Error: Could not parse version from URL: $download_url" >&2
        return 1
    fi

    echo "Found version: $full_version" >&2
    echo "Download URL: $download_url" >&2

    echo "$full_version"
}

# Function to get version from a specific release tag
get_version_from_release() {
    local version_tag="$1"

    local github_api="https://api.github.com/repos/${SPT_BUILD_REPO}/releases/tags/${version_tag}"

    echo "Fetching release info for version ${version_tag}..." >&2

    local release_json=$(curl -s "$github_api")
    local download_url=$(extract_download_url "$release_json")

    if [ -z "$download_url" ]; then
        echo "Error: Could not find download URL in release notes for ${version_tag}" >&2
        return 1
    fi

    local full_version=$(parse_version_from_url "$download_url")

    if [ -z "$full_version" ]; then
        echo "Error: Could not parse version from URL: $download_url" >&2
        return 1
    fi

    echo "$full_version"
}

# Function to extract just the version number from full version string
get_version_number() {
    local full_version="$1"
    echo "$full_version" | cut -d'-' -f1
}

# Main script logic
main() {
    local command="${1:-latest}"

    case "$command" in
        latest)
            # Get the latest full version string from release notes
            get_latest_spt_version
            ;;

        version)
            # Just get the version number (e.g., 4.0.13)
            local full_version=$(get_latest_spt_version)
            if [ $? -ne 0 ]; then
                exit 1
            fi
            get_version_number "$full_version"
            ;;

        specific)
            # Get details for a specific version
            local version="$2"
            if [ -z "$version" ]; then
                echo "Error: Please provide a version (e.g., 4.0.13)" >&2
                exit 1
            fi

            get_version_from_release "$version"
            ;;

        help|--help|-h)
            cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
  latest          Get the latest SPT version string (default)
  version         Get just the version number (e.g., 4.0.13)
  specific <ver>  Get version string for a specific version
  help            Show this help message

Examples:
  $0                    # Get latest full version string
  $0 latest             # Same as above
  $0 version            # Get just version number
  $0 specific 4.0.13    # Get full version string for 4.0.13

Output format: VERSION-BUILD_NUMBER-COMMIT_SHA
Example: 4.0.13-40087-2891fd4

Note: This script extracts the actual download URL from the release notes,
ensuring the version string matches an existing archive.
EOF
            ;;

        *)
            echo "Error: Unknown command '$command'" >&2
            echo "Run '$0 help' for usage information" >&2
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
