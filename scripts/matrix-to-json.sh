#!/usr/bin/env bash
set -euo pipefail

MATRIX_FILE="${1:-matrix.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required" >&2
    exit 1
  fi
}

dispatch_requested() {
  [[ -n "${INPUT_REPOSITORY:-}" || -n "${INPUT_IMAGE:-}" ]]
}

emit_dispatch_items() {
  if [[ -z "${INPUT_REPOSITORY:-}" || -z "${INPUT_IMAGE:-}" ]]; then
    echo "workflow_dispatch requires both upstream_repository and image" >&2
    exit 1
  fi

  jq -cn \
    --arg name "${INPUT_REPOSITORY/\//-}" \
    --arg upstream_repository "${INPUT_REPOSITORY}" \
    --arg image "${INPUT_IMAGE}" \
    --arg tag "${INPUT_TAG:-}" \
    --arg tag_prefix "${INPUT_TAG_PREFIX:-}" \
    --arg tag_regex "${INPUT_TAG_REGEX:-}" \
    --arg context_subdir "${INPUT_CONTEXT_SUBDIR:-}" \
    --arg dockerfile "${INPUT_DOCKERFILE:-Dockerfile}" \
    --arg platforms "${INPUT_PLATFORMS:-linux/amd64}" \
    '{
      name: $name,
      upstream_repository: $upstream_repository,
      image: $image,
      tag: (if $tag == "" then null else $tag end),
      tag_prefix: (if $tag_prefix == "" then null else $tag_prefix end),
      tag_regex: (if $tag_regex == "" then null else $tag_regex end),
      context_subdir: (if $context_subdir == "" then null else $context_subdir end),
      dockerfile: $dockerfile,
      platforms: $platforms
    } | with_entries(select(.value != null)) | [.]'
}

emit_matrix_file_items() {
  jq -c . "${MATRIX_FILE}"
}

# For each item without an explicit `tag`, resolve every matching upstream tag
# and fan out to one matrix entry per tag. The newest tag (first returned by
# the GitHub API) is marked with tag_latest=true so build-image.sh only moves
# the :latest pointer for the most recent release.
expand_items_with_tags() {
  local input_json
  input_json="$(cat)"

  local count
  count="$(jq 'length' <<<"${input_json}")"

  local expanded='[]'
  local i=0
  while (( i < count )); do
    local item
    item="$(jq -c ".[$i]" <<<"${input_json}")"

    local explicit_tag
    explicit_tag="$(jq -r '.tag // ""' <<<"${item}")"

    if [[ -n "${explicit_tag}" ]]; then
      local fanned
      fanned="$(jq -c '. + {tag_latest: "true"}' <<<"${item}")"
      expanded="$(jq -c --argjson item "${fanned}" '. + [$item]' <<<"${expanded}")"
    else
      local upstream tag_prefix tag_regex
      upstream="$(jq -r '.upstream_repository' <<<"${item}")"
      tag_prefix="$(jq -r '.tag_prefix // ""' <<<"${item}")"
      tag_regex="$(jq -r '.tag_regex // ""' <<<"${item}")"

      local tags
      if ! tags="$(
        UPSTREAM_REPOSITORY="${upstream}" \
          TAG_PREFIX="${tag_prefix}" \
          TAG_REGEX="${tag_regex}" \
          LIST_ALL=true \
          bash "${SCRIPT_DIR}/resolve-tag.sh"
      )"; then
        echo "Failed to resolve tags for $(jq -r '.name' <<<"${item}") (${upstream})" >&2
        exit 1
      fi

      if [[ -z "${tags}" ]]; then
        echo "No matching tags found for $(jq -r '.name' <<<"${item}") (${upstream})" >&2
        i=$((i + 1))
        continue
      fi

      local first=true
      while IFS= read -r tag; do
        [[ -z "${tag}" ]] && continue
        local latest="false"
        if [[ "${first}" == "true" ]]; then
          latest="true"
          first=false
        fi

        local base_name
        base_name="$(jq -r '.name' <<<"${item}")"
        local fanned
        fanned="$(jq -c \
          --arg name "${base_name}-${tag}" \
          --arg tag "${tag}" \
          --arg tag_latest "${latest}" \
          '. + {name: $name, tag: $tag, tag_latest: $tag_latest}
             | del(.tag_prefix, .tag_regex)' \
          <<<"${item}")"
        expanded="$(jq -c --argjson item "${fanned}" '. + [$item]' <<<"${expanded}")"
      done <<<"${tags}"
    fi

    i=$((i + 1))
  done

  printf '%s\n' "${expanded}"
}

validate_and_wrap_items() {
  jq -ce '
    def fail($message): error($message);
    def supported_fields:
      [
        "name",
        "upstream_repository",
        "image",
        "tag",
        "tag_prefix",
        "tag_regex",
        "tag_latest",
        "context_subdir",
        "dockerfile",
        "platforms"
      ];
    def required_fields:
      ["name", "upstream_repository", "image"];
    def optional_fields:
      supported_fields - required_fields;
    def non_empty_string:
      type == "string" and (gsub("^\\s+|\\s+$"; "") | length > 0);
    def duplicate_name:
      [.[].name] | group_by(.) | map(select(length > 1) | .[0]) | first;
    def validate_object($index; $item):
      if ($item | type) != "object" then
        fail("matrix[" + $index + "] must be an object")
      else
        .
      end
      | (($item | keys_unsorted) - supported_fields) as $unknown
      | if ($unknown | length) > 0 then
        fail("matrix[" + $index + "]." + $unknown[0] + " is not a supported field")
      else
        .
      end;
    def validate_required_fields($index; $item):
      reduce required_fields[] as $field (.;
        if ($item[$field] | non_empty_string | not) then
          fail("matrix[" + $index + "]." + $field + " is required")
        else
          .
        end
      );
    def validate_optional_fields($index; $item):
      reduce optional_fields[] as $field (.;
        if ($item[$field] != null and ($item[$field] | type) != "string") then
          fail("matrix[" + $index + "]." + $field + " must be a string")
        else
          .
        end
      );
    def validate_repository($index; $item):
      if ($item.upstream_repository | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") | not) then
        fail("matrix[" + $index + "].upstream_repository must be in owner/name form")
      else
        .
      end;
    def validate_image($index; $item):
      if
        ($item.image | test("^[a-z0-9][a-z0-9._/-]*$") | not)
        or ($item.image | contains(".."))
        or ($item.image | contains("//"))
      then
        fail("matrix[" + $index + "].image must be a lowercase image path relative to ghcr.io/relip")
      else
        .
      end;
    def validate_item($entry):
      ($entry.key | tostring) as $index
      | $entry.value as $item
      | validate_object($index; $item)
      | validate_required_fields($index; $item)
      | validate_optional_fields($index; $item)
      | validate_repository($index; $item)
      | validate_image($index; $item);

    if type != "array" or length == 0 then
      fail("matrix must contain a non-empty JSON array")
    else
      .
    end
    | to_entries as $entries
    | reduce $entries[] as $entry (.; validate_item($entry))
    | duplicate_name as $duplicate
    | if $duplicate then
      fail("matrix name must be unique: " + $duplicate)
    else
      {include: .}
    end
  '
}

main() {
  require_jq

  if dispatch_requested; then
    emit_dispatch_items
  else
    emit_matrix_file_items
  fi | expand_items_with_tags | validate_and_wrap_items
}

main "$@"
