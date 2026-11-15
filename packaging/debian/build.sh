#!/bin/sh
# Builds the Debian 13 package, packaging/debian/dist/aetherion_<version>-1_amd64.deb,
# in a Debian 13 container, so it links against the libraries of Debian 13.
#
#   packaging/debian/build.sh              # build the package
#   RUN_TESTS=1 packaging/debian/build.sh  # run the tests there first, on Debian's Elixir
#
# Needs Docker. Dependencies are cached in the volume aetherion-deb-cache, so a
# second build does not compile quicer again.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
mkdir -p "$here/dist"

docker build -t aetherion-deb-build "$here"
docker run --rm \
  -v "$root":/src:ro \
  -v "$here/dist":/out \
  -v aetherion-deb-cache:/cache \
  -e RUN_TESTS="${RUN_TESTS:-0}" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  aetherion-deb-build sh /src/packaging/debian/inside.sh
