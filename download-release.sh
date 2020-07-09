#!/usr/bin/env bash

set -e

default_source=circleci
default_solidity_version=latest

if [[ $1 == --help ]]; then
    echo "Downloads release binaries, puts them at the right locations in a local"
    echo "checkout of the solc-bin repository and updates the file lists."
    echo
    echo "WARNING: The binaries will be overwritten if they already exist."
    echo
    echo
    echo "Usage:"
    echo "    ./$(basename "$0") --help"
    echo "    ./$(basename "$0") [source] [solidity_version] [solc_bin_dir]"
    echo
    echo "    source           The source to get binaries from. Can be 'circleci' or 'github'."
    echo "                     Default: '${default_source}'."
    echo "    solidity_version Version tag representing the release to download, including"
    echo "                     the leading 'v'. Use 'latest' to get the most recent release."
    echo "                     In case of CircleCI 'latest' is the only supported value."
    echo "                     Default: '${default_solidity_version}'."
    echo "    solc_bin_dir     Location of the solc-bin checkout."
    echo "                     Default: current working directory."
    echo
    echo
    echo "Examples:"
    echo "    ./$(basename "$0") --help"
    echo "    ./$(basename "$0") circleci latest"
    echo "    ./$(basename "$0") github v0.6.9"
    echo "    ./$(basename "$0") github latest ~/solc-bin/"
    exit 0
fi


# GENERAL UTILITIES

query_api() {
    local api_endpoint="$1"

    curl --fail --silent --show-error "$api_endpoint"
}

die() {
    local format="$1"
    local arguments="$1"

    >&2 printf "ERROR: $format\n" "${@:2}"
    exit 1
}


# JOB INFO FROM CIRCLECI API

filter_jobs_by_name() {
    local job_name="$1"
    jq '[ .[] | select (.workflows.job_name == "'"$job_name"'") ]'
}

select_latest_job_info() {
    # ASSUMPTION: Newer jobs always have higher build_num
    jq 'sort_by(.build_num) | last'
}


# ARTIFACT INFO FROM CIRCLECI API

filter_artifacts_by_name()  {
    local artifact_name="$1"

    jq '[ .[] | select (.path == "'"$artifact_name"'") ]'
}

validate_artifact_info() {
    local artifact_info="$1"
    local expected_artifact_name="$2"

    artifact_count=$(echo "$artifact_info" | jq '. | length')
    [[ $artifact_count > 0 ]] || die "Job has no artifacts."
    [[ $artifact_count < 2 ]] || die "Job has multiple artifacts called '%s'." "$expected_artifact_name"
}


# TAG INFO FROM GITHUB API

filter_only_version_tags()  {
    jq '.[] | select (.name | startswith("v"))'
}

filter_tags_by_commit()  {
    local commit_hash="$1"

    jq '[ . | select (.commit.sha == "'"$commit_hash"'") ]'
}

validate_solidity_version() {
    local tag="$1"

    tag_count=$(echo "$tag" | wc --lines)
    [[ $tag_count > 0 ]] || die "No version tags matching the release found."
    [[ $tag_count < 2 ]] || die "Expected one version tag. The commit has %d:\n%s" "$tag_count" "$tag"
}


# RELEASE INFO FROM GITHUB API

select_asset() {
    local binary_name="$1"

    jq '.assets[] | select(.name == "'"${binary_name}"'")'
}


# REPOSITORY STRUCTURE

binary_to_job_name() {
    local binary_name="$1"

    case "$binary_name" in
        solc-static-linux) echo b_ubu ;;
        solc-macos)        echo b_osx ;;
        soljson.js)        echo b_ems ;;
        *) die "Invalid binary name" ;;
    esac
}

binary_to_circleci_artifact_name() {
    local binary_name="$1"

    case "$binary_name" in
        solc-static-linux) echo solc ;;
        solc-macos)        echo solc ;;
        soljson.js)        echo soljson.js ;;
        *) die "Invalid binary name" ;;
    esac
}

format_binary_path() {
    local binary_name="$1"
    local solidity_version="$2"
    local commit_hash="$3"

    short_hash="$(echo "$commit_hash" | head --bytes 8)"
    full_version="${solidity_version}+commit.${short_hash}"

    case "$binary_name" in
        solc-static-linux) echo "linux/${binary_name}-${full_version}" ;;
        solc-macos)        echo "macos/${binary_name}-${full_version}" ;;
        soljson.js)        echo "wasm/soljson-${full_version}.js" ;;
        *) die "Invalid binary name" ;;
    esac
}


# MAIN LOGIC

query_circleci_artifact_url() {
    local binary_name="$1"
    local build_num="$2"

    local artifact_endpoint="https://circleci.com/api/v1.1/project/github/ethereum/solidity/${build_num}/artifacts"
    local artifact_name; artifact_name="$(binary_to_circleci_artifact_name "$binary_name")"
    local artifact_info; artifact_info="$(
        query_api "$artifact_endpoint" |
        filter_artifacts_by_name "$artifact_name"
    )"
    validate_artifact_info "$artifact_info" "$artifact_name"

    echo "$artifact_info" | jq --raw-output '.[].url'
}

download_binary() {
    local target_path="$1"
    local download_url="$2"

    echo "Downloading release binary from ${download_url} into ${target_path}"
    curl "$download_url" --output "${target_path}" --location --no-progress-meter --create-dirs
}

download_binary_from_circleci() {
    local binary_name="$1"
    local successful_jobs="$2"
    local latest_tag_info="$3"
    local solc_bin_dir="$4"

    local job_name; job_name="$(binary_to_job_name "$binary_name")"
    local job_info; job_info="$(
        echo "$successful_jobs" |
        filter_jobs_by_name "$job_name" |
        select_latest_job_info
    )"
    echo "$job_info" | jq '{
        job_name: .workflows.job_name,
        build_url,
        stop_time,
        status,
        subject,
        vcs_revision,
        branch,
        author_date
    }'

    local build_num; build_num="$(echo "$job_info" | jq --raw-output '.build_num')"
    local commit_hash; commit_hash="$(echo "$job_info" | jq --raw-output '.vcs_revision')"

    local solidity_version; solidity_version="$(
        echo "$latest_tag_info" |
        filter_tags_by_commit "$commit_hash" |
        jq --raw-output '.[].name'
    )"
    echo "Solidity version: ${solidity_version}"
    validate_solidity_version "$solidity_version"

    local artifact_url; artifact_url="$(query_circleci_artifact_url "$binary_name" "$build_num")"
    local binary_path; binary_path="$(format_binary_path "$binary_name" "$solidity_version" "$commit_hash")"
    download_binary "${solc_bin_dir}/${binary_path}" "$artifact_url"
}

download_binary_from_github() {
    local binary_name="$1"
    local release_info="$2"
    local solc_bin_dir="$3"

    local solidity_version; solidity_version=$(echo "$release_info" | jq --raw-output '.tag_name')
    local commit_hash; commit_hash=$(echo "$release_info" | jq --raw-output '.target_commitish')

    local artifact_url; artifact_url=$(
        echo "$release_info" |
        select_asset "$binary_name" |
        jq --raw-output '.browser_download_url'
    )
    local binary_path; binary_path="$(format_binary_path "$binary_name" "$solidity_version" "$commit_hash")"
    download_binary "${solc_bin_dir}/${binary_path}" "$artifact_url"
}

download_release() {
    local source="$1"
    local solidity_version="$2"
    local solc_bin_dir="$3"

    local release_binaries=(
        solc-macos
        soljson.js
        solc-static-linux
    )

    echo "===> DOWNLOADING RELEASE ${solidity_version} FROM ${source}"
    echo "solc-bin directory: ${solc_bin_dir}"

    case "$source" in
        circleci)
            [[ $solidity_version == latest ]] || die "Only getting the latest release is supported for CircleCI"

            local job_endpoint="https://circleci.com/api/v1.1/project/github/ethereum/solidity/tree/release"
            local filter="filter=successful&limit=100"
            local successful_jobs; successful_jobs="$(query_api "${job_endpoint}?${filter}")"
            echo "Got $(echo "$successful_jobs" | jq '. | length') recent successful job records from CircleCI"

            # NOTE: The endpoint seems to return tags correctly ordered by semver rather than by date.
            local latest_tag_endpoint="https://api.github.com/repos/ethereum/solidity/tags?per_page=10&page=1"
            echo "Getting latest tag info from ${latest_tag_endpoint}"
            local latest_tag_info; latest_tag_info="$(query_api "$latest_tag_endpoint" | filter_only_version_tags)"

            for binary_name in ${release_binaries[@]}; do
                download_binary_from_circleci "$binary_name" "$successful_jobs" "$latest_tag_info" "$solc_bin_dir"
            done
            ;;

        github)
            if [[ $solidity_version == latest ]]; then
                local release_info_endpoint="https://api.github.com/repos/ethereum/solidity/releases/latest"
            else
                local release_info_endpoint="https://api.github.com/repos/ethereum/solidity/releases/tags/${solidity_version}"
            fi

            echo "Getting ${solidity_version} release info from ${release_info_endpoint}"
            local release_info; release_info="$(query_api "$release_info_endpoint")"

            echo "$release_info" | jq '{
                name,
                author: .author.login,
                tag_name,
                target_commitish,
                draft,
                prerelease,
                created_at,
                published_at,
                assets: [ .assets[].name ]
            }'

            for binary_name in ${release_binaries[@]}; do
                download_binary_from_github "$binary_name" "$release_info" "$solc_bin_dir"
            done
            ;;

        *) die "Invalid source: '${source}'. Must be either 'circleci' or 'github'." ;;
    esac
}

update_lists() {
    echo
    echo "===> UPDATING LISTS"
    npm install
    npm run update
}

main() {
    local source="${1:-"$default_source"}"
    local solidity_version="${2:-"$default_solidity_version"}"
    local solc_bin_dir="${3:-$PWD}"

    [[ $# < 4 ]] || die "Too many arguments"

    download_release "$source" "$solidity_version" "$solc_bin_dir"
    update_lists
}

main "$@"
