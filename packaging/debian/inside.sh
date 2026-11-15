#!/bin/sh
# Runs in the container of build.sh: builds the release and the package.
set -eu

export MIX_DEPS_PATH=/cache/deps MIX_BUILD_ROOT=/cache/_build

# The sources, without what a build or git leaves.
rm -rf /build /stage && mkdir -p /build /stage
tar -C /src --exclude=./_build --exclude=./deps --exclude=./.git --exclude=./packaging/debian/dist -cf - . |
  tar -C /build -xf -
cd /build

if [ "$RUN_TESTS" = 1 ]; then
  MIX_ENV=test mix deps.get
  MIX_ENV=test mix test
fi

export MIX_ENV=prod
mix deps.get --only prod
mix release --overwrite --path /stage/opt/aetherion

version="$(sed -n 's/^ *version: "\(.*\)",$/\1/p' mix.exs)"
files=/build/packaging/debian/files

install -D -m 0755 "$files/aetherion" /stage/usr/bin/aetherion
install -D -m 0644 "$files/aetherion-worker.service" /stage/usr/lib/systemd/system/aetherion-worker.service
install -D -m 0640 "$files/worker.env" /stage/etc/aetherion/worker.env
install -D -m 0644 "$files/README.Debian" /stage/usr/share/doc/aetherion/README.Debian
install -D -m 0644 LICENSE /stage/usr/share/doc/aetherion/copyright
install -d /stage/DEBIAN
install -m 0755 "$files/postinst" "$files/prerm" "$files/postrm" /stage/DEBIAN/
install -m 0644 "$files/conffiles" /stage/DEBIAN/

# The shared libraries the release needs, as Debian package names.
mkdir -p /shlibs/debian && printf 'Source: aetherion\n\nPackage: aetherion\nArchitecture: amd64\n' > /shlibs/debian/control
binaries="$(find /stage/opt/aetherion -type f \( -name '*.so' -o -path '*/erts-*/bin/*' \) -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print)"
depends="$(cd /shlibs && dpkg-shlibdeps -O --ignore-missing-info $(printf ' -e%s' $binaries) 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"

size="$(du -sk --exclude=DEBIAN /stage | cut -f1)"
sed -e "s/@VERSION@/$version-1/" -e "s/@DEPENDS@/$depends/" -e "s/@SIZE@/$size/" "$files/control.in" > /stage/DEBIAN/control

deb="/out/aetherion_${version}-1_amd64.deb"
dpkg-deb --build --root-owner-group /stage "$deb"
chown "$HOST_UID:$HOST_GID" "$deb"
echo "built $deb"
