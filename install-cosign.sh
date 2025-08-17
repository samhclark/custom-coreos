#!/usr/bin/env bash

# Cosign install script

runner_arch="$1"
workdir="$2" # Should be $RUNNER_TEMP
toolsdir="${HOME}/tools"

tag="v2.4.3"
commit="6a7abbf3ae7eb6949883a80c8f6007cc065d2dfb"

log_info() {
    1>&2 echo "[INFO]: $*"
}

log_fatal_die() {
    1>&2 echo "[FATAL]: $*"
    exit 1
}

# Setup
set -e
trap "popd >/dev/null" EXIT
pushd "${workdir}" > /dev/null
mkdir -p "${toolsdir}"
export PATH="$PATH:${toolsdir}" # makes it available in this step
echo "${toolsdir}" >> $GITHUB_PATH # makes it availabe in later steps

# Clone the repo
git clone -b "${tag}" https://github.com/sigstore/cosign.git
cd cosign

# Verify the tag and commit
current_commit=$(git rev-parse HEAD)
if [ "${current_commit}" = "${commit}" ]; then
    log_info "Commit hash verified: ${current_commit}"
else
    log_fatal_die "Commmit hash mismatch!"
fi

# Build and install cosign
go install ./cmd/cosign
cp "$(go env GOPATH)/bin/cosign" "${HOME}/tools/cosign"
log_info "Installed cosign from commit $(cosign version --json | jq -r '.gitCommit')"

exit 0
