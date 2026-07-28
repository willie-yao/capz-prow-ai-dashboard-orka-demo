#!/usr/bin/env bash
# Maintainer-only packaging for the pinned unreleased Orka source chart.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/orka/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: package-source.sh --source-dir DIR [--output-dir DIR]

DIR must be a clean Orka checkout at the exact commit in versions.env. This
packages only the chart. It does not build or publish runtime images.
EOF
}

source_dir=
output_dir=${PWD}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      source_dir=${2:-}
      shift 2
      ;;
    --output-dir)
      output_dir=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

load_orka_versions
require_commands git helm

if [[ -z "${source_dir}" ]]; then
  usage
  exit 2
fi
source_dir=$(cd "${source_dir}" && pwd)
output_dir=$(mkdir -p "${output_dir}" && cd "${output_dir}" && pwd)

actual_commit=$(git -C "${source_dir}" rev-parse HEAD)
if [[ "${actual_commit}" != "${ORKA_MINIMUM_COMMIT}" ]]; then
  echo "Orka source must be checked out at ${ORKA_MINIMUM_COMMIT}; found ${actual_commit}" >&2
  exit 1
fi
if [[ -n "$(git -C "${source_dir}" status --porcelain -- charts/orka)" ]]; then
  echo "Orka chart source has local modifications" >&2
  exit 1
fi

chart_dir="${source_dir}/charts/orka"
chart_version=$(helm show chart "${chart_dir}" | awk '$1 == "version:" {print $2; exit}')
if [[ -z "${chart_version}" ]]; then
  echo "could not read chart version from ${chart_dir}" >&2
  exit 1
fi

package_output=$(helm package "${chart_dir}" --destination "${output_dir}")
package_path=${package_output##*: }
if [[ ! -f "${package_path}" ]]; then
  package_path="${output_dir}/orka-${chart_version}.tgz"
fi

echo "Packaged maintainer-only source chart: ${package_path}"
echo "Source commit: ${actual_commit}"
echo "Chart version: ${chart_version}"
echo "Local package digest: $(sha256_file "${package_path}")"
echo "No runtime images were built or published."
