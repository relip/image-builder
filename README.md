# Image Builder

Generic release/tag driven Docker image builder.

It can watch any GitHub repository, resolve the latest release or matching tag,
skip images that already exist in the target registry, and build/push an image
from the upstream Git tag.

## GHCR Permissions

The workflow publishes to `ghcr.io/relip` with the built-in `GITHUB_TOKEN`.
The repository needs `packages: write` permission, which is declared in the
workflow.

## Manual Build

```sh
UPSTREAM_REPOSITORY=slopus/happy \
IMAGE=happy \
TAG=cli-1.1.8 \
bash ./scripts/build-image.sh
```

If `TAG` is empty, the script uses the latest GitHub release. If the repository
does not use GitHub releases, set `TAG_PREFIX` or `TAG_REGEX` to pick from tags.

## GitHub Actions

Manual run:

```sh
gh workflow run build-image.yaml \
  -f upstream_repository=slopus/happy \
  -f image=happy \
  -f tag=cli-1.1.8
```

Push and scheduled builds use `matrix.json`.

## Matrix

`matrix.json` contains the images the workflow checks on push and schedule.

```json
[
  {
    "name": "happy",
    "upstream_repository": "slopus/happy",
    "image": "happy",
    "tag_prefix": "cli-",
    "platforms": "linux/amd64"
  }
]
```

Add another public GitHub project by appending another object to the array:

```json
[
  {
    "name": "happy",
    "upstream_repository": "slopus/happy",
    "image": "happy",
    "tag_prefix": "cli-",
    "platforms": "linux/amd64"
  },
  {
    "name": "another-image",
    "upstream_repository": "owner/repo",
    "image": "another-image",
    "tag_regex": "^v[0-9]+\\.[0-9]+\\.[0-9]+$",
    "platforms": "linux/amd64"
  }
]
```

Supported fields:

- `name`
- `upstream_repository`
- `image`
- `tag`
- `tag_prefix`
- `tag_regex`
- `context_subdir`
- `dockerfile`
- `platforms`

Matrix entries are validated before the build starts. `image` is a lowercase
image path under the hardcoded `ghcr.io/relip/` namespace, `upstream_repository`
must be in `owner/name` form, and unknown fields fail fast to catch typos.
