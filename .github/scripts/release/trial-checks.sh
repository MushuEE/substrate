#!/usr/bin/env bash
# TRIAL ONLY. Exercises the #3199 attestations against the job's registry.
set -o errexit -o nounset -o pipefail

signer="${GITHUB_REPOSITORY}/.github/workflows/release.yaml"
repo="${KO_DOCKER_REPO}"
crane() { go run github.com/google/go-containerregistry/cmd/crane@v0.21.7 "$@"; }

echo "::group::1. Digests file"
cat bin/release-images.txt
echo "lines: $(wc -l <bin/release-images.txt)"
grep -q ' localhost:5000/substrate/envoy-dataplane$' bin/release-images.txt
echo "::endgroup::"

echo "::group::2. gh attestation verify by tag"
for img in envoy-dataplane ateapi; do
  gh attestation verify "oci://${repo}/${img}:${VERSION}" --repo "${GITHUB_REPOSITORY}" --signer-workflow "${signer}"
done
echo "::endgroup::"

echo "::group::3. Rerun builds nothing, verify script passes"
cp bin/release-images.txt "${RUNNER_TEMP}/first-run.txt"
ATE_PUBLISH_DIGESTS_FILE="${RUNNER_TEMP}/rerun.txt" go run ./cmd/ate-setup publish release-images
test ! -e "${RUNNER_TEMP}/rerun.txt"
DIGESTS_FILE="${RUNNER_TEMP}/verify.txt" .github/scripts/release/verify-image-attestations.sh
diff "${RUNNER_TEMP}/first-run.txt" "${RUNNER_TEMP}/verify.txt"
echo "PASS: rerun built nothing and every image verified"
echo "::endgroup::"

echo "::group::4. Negative: attested ateapi digest pushed over the atelet tag"
ateapi="$(crane digest "${repo}/ateapi:${VERSION}")"
crane copy "${repo}/ateapi@${ateapi}" "${repo}/atelet:${VERSION}"
if DIGESTS_FILE="${RUNNER_TEMP}/verify-neg.txt" .github/scripts/release/verify-image-attestations.sh; then
  echo "::error::FAIL: verify passed with a swapped image"
  exit 1
fi
echo "PASS: verify refused the swapped image"
echo "::endgroup::"
