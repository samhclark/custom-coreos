#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-quay.io/fedora/fedora-coreos:stable}"
CONTAINER_CLI="${CONTAINER_CLI:-}"
skopeo_bin="${SKOPEO_BIN:-skopeo}"
jq_bin="${JQ_BIN:-jq}"

if [[ -z "${CONTAINER_CLI}" ]]; then
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI="podman"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CLI="docker"
  else
    CONTAINER_CLI=""
  fi
fi

INSPECT_OUTPUT=$("${skopeo_bin}" inspect "docker://${IMAGE}")
DIGEST=$("${jq_bin}" -r '.Digest' <<<"${INSPECT_OUTPUT}")
if [[ -n "${DIGEST}" && "${DIGEST}" != "null" ]]; then
  IMAGE_WITH_DIGEST="${IMAGE}@${DIGEST}"
else
  IMAGE_WITH_DIGEST="${IMAGE}"
fi

KERNEL_VERSION=$("${jq_bin}" -r '.Labels["ostree.linux"]' <<<"${INSPECT_OUTPUT}")

if [[ -z "${KERNEL_VERSION}" || "${KERNEL_VERSION}" == "null" ]]; then
  if [[ -z "${CONTAINER_CLI}" ]]; then
    echo "Failed to determine kernel version from ${IMAGE} and no container runtime available for fallback" >&2
    exit 1
  fi

  if ! RPM_QUERY_OUTPUT=$("${CONTAINER_CLI}" run --rm --entrypoint rpm "${IMAGE_WITH_DIGEST}" \
    -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n'); then
    echo "Failed to run rpm fallback inside ${IMAGE}" >&2
    exit 1
  fi

  KERNEL_VERSION=$(head -n1 <<<"${RPM_QUERY_OUTPUT}" | tr -d '\r')
fi

echo "${KERNEL_VERSION}"
