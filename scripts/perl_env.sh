# perl_env.sh - run Perl with the interpreter and @INC the app itself runs with.
#
# Sourced, never executed:  . ./scripts/perl_env.sh   (from the repo root)
#
# Git launches .githooks/pre-push from whatever shell started the push, so a GUI
# or bare-shell push gets only the system @INC. The guard then fails a file for
# "Can't locate Text/Unidecode.pm" while the same commit passes the restart
# guard, which ./jawn runs with its own local::lib BEGIN block. This mirrors
# ./jawn and scripts/manager_killer.pl: run the interpreter ./jawn's shebang
# names, and put $HOME/perl5/lib/perl5 plus its version/arch subdirs ahead of
# any PERL5LIB already set. PERL5LIB is exported so verify_change.pl, the help
# audit and the test suite - and their child perls - inherit it.
#
# A machine with no local::lib at all is not an error: nothing is added and the
# system perl answers, which is how a clean box has always pushed.
#
# On return:
#   PERL            the interpreter to run scripts with (not exported; callers
#                   use "$PERL", whose children inherit it as $^X anyway)
#   PERL5LIB        the app's library path, exported when local::lib exists
#   PERL_ENV_OK     0 when an interpreter was found, 1 when this machine cannot
#                   run the guard at all; PERL_ENV_ERROR then names what is
#                   missing. A caller that cannot run the guard must say so and
#                   block - never let a push pass by default.

perl_env_root=${perl_env_root:-.}
PERL=
PERL_ENV_ERROR=

# The app's own interpreter: ./jawn's shebang, not whatever PATH offers. A
# perlbrew/system-perl mismatch is exactly what made a laptop refuse a clean
# commit, so the shebang wins and PATH is only the fallback.
perl_env_shebang=$(sed -n '1s/^#![[:space:]]*//p' "$perl_env_root/jawn" 2>/dev/null)
case $perl_env_shebang in
	*"/env "*) perl_env_shebang=${perl_env_shebang##*"/env "} ;;
esac
perl_env_shebang=${perl_env_shebang%% *}

if [ -n "$perl_env_shebang" ] && [ -x "$perl_env_shebang" ]; then
	PERL=$perl_env_shebang
elif command -v perl >/dev/null 2>&1; then
	PERL=$(command -v perl)
fi

# $HOME can be absent under a launcher; /etc/passwd has the same answer.
perl_env_home=${HOME:-}
if [ -z "$perl_env_home" ] && command -v getent >/dev/null 2>&1 && command -v id >/dev/null 2>&1; then
	perl_env_home=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)
fi

if [ -n "$perl_env_home" ] && [ -d "$perl_env_home/perl5/lib/perl5" ]; then
	perl_env_lib=$perl_env_home/perl5/lib/perl5
	for perl_env_dir in "$perl_env_lib"/*; do
		[ -d "$perl_env_dir" ] || continue
		case ${perl_env_dir##*/} in
			*-linux-*|[0-9]*.[0-9]*) perl_env_lib=$perl_env_lib:$perl_env_dir ;;
		esac
	done
	if [ -n "${PERL5LIB:-}" ]; then
		PERL5LIB=$perl_env_lib:$PERL5LIB
	else
		PERL5LIB=$perl_env_lib
	fi
	export PERL5LIB
fi

if [ -n "$PERL" ]; then
	PERL_ENV_OK=0
else
	PERL_ENV_OK=1
	PERL_ENV_ERROR="no perl interpreter found (./jawn names '${perl_env_shebang}', PATH has no perl)"
fi
