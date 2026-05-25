#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAMESPACE="ghcr.io/relip"

IMAGE="${IMAGE:?IMAGE is required}"
TAG="${TAG:?TAG is required}"
IMAGE_EXISTS_RETRIES="${IMAGE_EXISTS_RETRIES:-3}"
IMAGE_EXISTS_RETRY_DELAY="${IMAGE_EXISTS_RETRY_DELAY:-2}"

full_image_name() {
  if [[ "${IMAGE}" == "${IMAGE_NAMESPACE}/"* ]]; then
    printf '%s\n' "${IMAGE}"
  else
    printf '%s/%s\n' "${IMAGE_NAMESPACE}" "${IMAGE}"
  fi
}

is_missing_image_error() {
  local error_file="$1"

  grep -Eiq \
    '(^|[^[:alpha:]])(404|manifest unknown|name_unknown|not found|no such manifest)([^[:alpha:]]|$)' \
    "${error_file}"
}

inspect_image() {
  local image_ref="$1"
  local error_file="$2"

  docker buildx imagetools inspect "${image_ref}" >/dev/null 2>"${error_file}"
}

main() {
  local image
  local image_ref
  local error_file
  local attempt=1

  image="$(full_image_name)"
  image_ref="${image}:${TAG}"
  error_file="$(mktemp "${TMPDIR:-/tmp}/image-exists.XXXXXX")"
  trap 'rm -f "${error_file}"' EXIT

  while :; do
    if inspect_image "${image_ref}" "${error_file}"; then
      return 0
    fi

    if is_missing_image_error "${error_file}"; then
      return 1
    fi

    if (( attempt >= IMAGE_EXISTS_RETRIES )); then
      echo "Could not verify whether image exists: ${image_ref}" >&2
      sed 's/^/  /' "${error_file}" >&2
      return 2
    fi

    sleep "${IMAGE_EXISTS_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done
}

main "$@"
