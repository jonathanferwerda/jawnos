#!/bin/sh
# Fetch the CPAN distributions that the target has no package for, into
# vendor/lib/perl5. The list is deps.json's null entries for that target.
#
#   sh packaging/vendor/fetch.sh deb
#   sh packaging/vendor/fetch.sh arch
#
# --no-deps: every dependency is a declared package in the same manifest, and
# installing it here would shadow the distro's copy. Run this on a host that has
# the declared packages (or the build chroot that just installed them).
set -eu

TARGET=${1:-deb}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

case "$TARGET" in
	deb|arch) ;;
	*) echo "usage: $0 deb|arch" >&2; exit 2 ;;
esac

if ! command -v cpanm >/dev/null 2>&1; then
	echo "fetch.sh: cpanm is required (cpanminus)" >&2
	exit 1
fi

mkdir -p "$ROOT/vendor"

for spec in $(perl "$ROOT/packaging/render_deps.pl" --vendor "$TARGET"); do
	echo "vendor: $spec"
	cpanm --notest --no-deps --local-lib-contained "$ROOT/vendor" "$spec"
done

echo "vendor: $ROOT/vendor/lib/perl5"
