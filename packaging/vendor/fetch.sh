#!/bin/sh
# Fetch the CPAN distributions that the target has no package for, into
# vendor/lib/perl5. The list is deps.json's null entries for that target.
#
#   sh packaging/vendor/fetch.sh deb
#   sh packaging/vendor/fetch.sh arch
#
# Each dist is built through cpanm in a throwaway local lib, then ONLY that
# dist's own blib is copied into vendor/. Its dependencies are never copied:
# they are the declared distro packages, and a CPAN copy here would shadow them
# (and silently replace the tested Mojolicious 9.39 with a newer one).
#
# Run this on a host that can reach CPAN. It needs cpanm (cpanminus).
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

CPANM_HOME=${PERL_CPANM_HOME:-${HOME}/.cpanm}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$ROOT/vendor/lib/perl5"

for spec in $(perl "$ROOT/packaging/render_deps.pl" --vendor "$TARGET"); do
	echo "vendor: $spec"
	if ! cpanm --notest --reinstall --local-lib "$TMP/lib" "$spec" >"$TMP/cpanm.log" 2>&1; then
		tail -30 "$TMP/cpanm.log" >&2
		exit 1
	fi
	# cpanm resolves a module name to AUTHOR/Dist-version.tar.gz; the build tree
	# it leaves behind is named after the dist, not the module.
	info=$(cpanm --info "$spec" 2>/dev/null | grep -E '/[^/]+\.tar\.gz$' | tail -n 1 || true)
	case "$info" in
		*/*.tar.gz) ;;
		*) echo "fetch.sh: cpanm --info did not resolve $spec" >&2; exit 1 ;;
	esac
	base=${info##*/}
	base=${base%.tar.gz}
	build=$(ls -1dt "$CPANM_HOME"/work/*/"$base"* 2>/dev/null | head -n 1 || true)
	if [ -z "$build" ] || [ ! -d "$build/blib/lib" ]; then
		echo "fetch.sh: no blib for $base under $CPANM_HOME/work" >&2
		exit 1
	fi
	cp -a "$build/blib/lib/." "$ROOT/vendor/lib/perl5/"
	# Pure-Perl set today; copy arch too if a future vendor dist has XS.
	if [ -d "$build/blib/arch" ]; then
		cp -a "$build/blib/arch/." "$ROOT/vendor/lib/perl5/"
	fi
done

echo "vendor: $ROOT/vendor/lib/perl5"
