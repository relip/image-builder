#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_REPOSITORY="${UPSTREAM_REPOSITORY:?UPSTREAM_REPOSITORY is required}"
TAG="${TAG:-}"
TAG_PREFIX="${TAG_PREFIX:-}"
TAG_REGEX="${TAG_REGEX:-}"
LIST_ALL="${LIST_ALL:-false}"
GITHUB_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required when gh is not available" >&2
    exit 1
  fi
}

github_api() {
  local path="$1"
  local url="https://api.github.com/${path#/}"
  local headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [[ -n "${GITHUB_TOKEN}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl -fsSL "${headers[@]}" "${url}"
}

latest_release_tag() {
  if command -v gh >/dev/null 2>&1; then
    gh api "repos/${UPSTREAM_REPOSITORY}/releases/latest" --jq .tag_name 2>/dev/null || true
    return
  fi

  require_jq
  github_api "repos/${UPSTREAM_REPOSITORY}/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' || true
}

tag_matches_filters() {
  local candidate="$1"

  if [[ -n "${TAG_PREFIX}" && "${candidate}" != "${TAG_PREFIX}"* ]]; then
    return 1
  fi

  if [[ -n "${TAG_REGEX}" && ! "${candidate}" =~ ${TAG_REGEX} ]]; then
    return 1
  fi

  return 0
}

first_matching_tag() {
  while IFS= read -r candidate; do
    if tag_matches_filters "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
}

all_matching_tags() {
  while IFS= read -r candidate; do
    if tag_matches_filters "${candidate}"; then
      printf '%s\n' "${candidate}"
    fi
  done
}

tag_names_with_gh() {
  gh api --paginate "repos/${UPSTREAM_REPOSITORY}/tags?per_page=100" --jq '.[].name'
}

tag_names_with_curl() {
  local page=1
  local names

  require_jq

  while :; do
    names="$(
      github_api "repos/${UPSTREAM_REPOSITORY}/tags?per_page=100&page=${page}" \
        | jq -r '.[].name'
    )"

    if [[ -z "${names}" ]]; then
      break
    fi

    printf '%s\n' "${names}"
    page=$((page + 1))
  done
}

latest_matching_tag() {
  if command -v gh >/dev/null 2>&1; then
    tag_names_with_gh | first_matching_tag
    return
  fi

  tag_names_with_curl | first_matching_tag
}

list_matching_tags() {
  if command -v gh >/dev/null 2>&1; then
    tag_names_with_gh | all_matching_tags
    return
  fi

  tag_names_with_curl | all_matching_tags
}

main() {
  local tag

  if [[ "${LIST_ALL}" == "true" ]]; then
    if [[ -n "${TAG}" ]]; then
      printf '%s\n' "${TAG}"
      return 0
    fi
    list_matching_tags
    return 0
  fi

  if [[ -n "${TAG}" ]]; then
    printf '%s\n' "${TAG}"
    return 0
  fi

  if [[ -z "${TAG_PREFIX}" && -z "${TAG_REGEX}" ]]; then
    tag="$(latest_release_tag)"
    if [[ -n "${tag}" ]]; then
      printf '%s\n' "${tag}"
      return 0
    fi
  fi

  tag="$(latest_matching_tag)"
  if [[ -z "${tag}" ]]; then
    echo "No matching tag found for ${UPSTREAM_REPOSITORY}" >&2
    return 1
  fi

  printf '%s\n' "${tag}"
}

main "$@"
