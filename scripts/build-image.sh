#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAMESPACE="ghcr.io/relip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UPSTREAM_REPOSITORY="${UPSTREAM_REPOSITORY:?UPSTREAM_REPOSITORY is required}"
IMAGE="${IMAGE:?IMAGE is required}"
TAG="${TAG:-}"
TAG_PREFIX="${TAG_PREFIX:-}"
TAG_REGEX="${TAG_REGEX:-}"
CONTEXT_SUBDIR="${CONTEXT_SUBDIR:-}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
PUSH="${PUSH:-true}"
TAG_LATEST="${TAG_LATEST:-true}"
SKIP_EXISTING="${SKIP_EXISTING:-true}"

full_image_name() {
  if [[ "${IMAGE}" == "${IMAGE_NAMESPACE}/"* ]]; then
    printf '%s\n' "${IMAGE}"
  else
    printf '%s/%s\n' "${IMAGE_NAMESPACE}" "${IMAGE}"
  fi
}

resolve_tag() {
  if [[ -n "${TAG}" ]]; then
    printf '%s\n' "${TAG}"
    return 0
  fi

  UPSTREAM_REPOSITORY="${UPSTREAM_REPOSITORY}" \
    TAG_PREFIX="${TAG_PREFIX}" \
    TAG_REGEX="${TAG_REGEX}" \
    bash "${SCRIPT_DIR}/resolve-tag.sh"
}

image_already_exists() {
  local image="$1"
  local tag="$2"
  local status

  set +e
  IMAGE="${image}" TAG="${tag}" bash "${SCRIPT_DIR}/image-exists.sh"
  status="$?"
  set -e

  case "${status}" in
    0)
      return 0
      ;;
    1)
      return 1
      ;;
    *)
      exit "${status}"
      ;;
  esac
}

build_context_url() {
  local tag="$1"
  local context_url="https://github.com/${UPSTREAM_REPOSITORY}.git#refs/tags/${tag}"

  if [[ -n "${CONTEXT_SUBDIR}" ]]; then
    context_url="${context_url}:${CONTEXT_SUBDIR}"
  fi

  printf '%s\n' "${context_url}"
}

main() {
  local image
  local tag
  local context_url
  local push_args=()
  local tag_args=()

  image="$(full_image_name)"
  tag="$(resolve_tag)"

  if [[ "${SKIP_EXISTING}" == "true" ]] && image_already_exists "${image}" "${tag}"; then
    echo "Image already exists: ${image}:${tag}"
    return 0
  fi

  context_url="$(build_context_url "${tag}")"

  if [[ "${PUSH}" == "true" ]]; then
    push_args=(--push)
  else
    push_args=(--load)
  fi

  tag_args=(--tag "${image}:${tag}")
  if [[ "${TAG_LATEST}" == "true" ]]; then
    tag_args+=(--tag "${image}:latest")
  fi

  docker buildx build \
    "${push_args[@]}" \
    --platform "${PLATFORMS}" \
    --file "${DOCKERFILE}" \
    --label "org.opencontainers.image.source=https://github.com/${UPSTREAM_REPOSITORY}" \
    --label "org.opencontainers.image.version=${tag}" \
    "${tag_args[@]}" \
    "${context_url}"
}

main "$@"
