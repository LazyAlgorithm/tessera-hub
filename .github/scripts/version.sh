#!/usr/bin/env bash
# The release tag this build is for: the pushed tag, or build-<date>-<commit> for a beta. Written into the Hub
# (src/Data/version.txt) and used as the release's tag, so the Hub knows which release it is.
if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
	echo "$GITHUB_REF_NAME"
else
	# The commit's date, not today's, so jobs that run either side of midnight agree.
	dir="$(cd "$(dirname "$0")/../.." && pwd)"
	echo "build-$(git -C "$dir" log -1 --format=%cd --date=format:%Y%m%d)-$(git -C "$dir" rev-parse --short HEAD)"
fi
