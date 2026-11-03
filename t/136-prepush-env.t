# tests-for: .githooks/pre-push scripts/perl_env.sh
# covers:    the pre-push hook runs the guard through scripts/perl_env.sh - the
#            interpreter ./jawn's shebang names and the app's local::lib on
#            PERL5LIB - so a module the app can load is not reported missing;
#            it still blocks a syntax error or a genuinely absent module, and it
#            blocks loudly instead of passing when it cannot run perl at all.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Slurp qw(read_file);

# A laptop push was refused for 'Can't locate Text/Unidecode.pm' because the hook
# ran bare `perl` from PATH with the system @INC, while ./jawn seeds local::lib in
# its BEGIN block - so the same commit passed the restart guard. The hook now
# sources scripts/perl_env.sh, and these subtests run the real hook against a
# throwaway repo: a module that only local::lib supplies must be found, an
# existing PERL5LIB kept, broken code still blocked, and a machine with no perl
# blocked with a line that says so.

my $root = "$FindBin::Bin/..";
my $hook = "$root/.githooks/pre-push";
my $helper = "$root/scripts/perl_env.sh";
my $guard = "$root/scripts/verify_change.pl";

my $hook_text = read_file($hook);
my $helper_text = read_file($helper);

# --- the hook's shape ---------------------------------------------------------
like($hook_text, qr/^\.\s+\.\/scripts\/perl_env\.sh$/m,
	'the hook sources scripts/perl_env.sh');
my $source_at = index($hook_text, 'scripts/perl_env.sh');
my $guard_at = index($hook_text, 'scripts/verify_change.pl');
ok($source_at >= 0 && $guard_at > $source_at,
	'the helper is sourced before the guard is called');
like($hook_text, qr/"\$PERL" scripts\/verify_change\.pl/,
	'the guard runs on the interpreter the helper chose');
like($hook_text, qr/"\$PERL" scripts\/help_audit\.pl/, 'so does the help audit');
like($hook_text, qr/"\$PERL" scripts\/run_tests\.pl/, 'and the test suite');
unlike($hook_text, qr/^[^#\n]*[^"\w]perl scripts\/verify_change\.pl/m,
	'no call to the guard falls back to PATH perl');
like($hook_text, qr/PERL_ENV_OK/, 'the hook checks whether the helper could run');
like($hook_text, qr/perl_env\.sh is missing/, 'and blocks loudly when the helper is missing');
like($hook_text, qr/blocking \(not passing\)/, 'a guard it cannot run blocks the push');

# --- the helper's shape -------------------------------------------------------
like($helper_text, qr/perl5\/lib\/perl5/, 'the helper seeds the app local::lib tree');
like($helper_text, qr/\*-linux-\*/, 'including the arch subdirs');
like($helper_text, qr/\[0-9\]\*\.\[0-9\]\*/, 'including the version subdirs');
like($helper_text, qr/export PERL5LIB/, 'and exports PERL5LIB for every child perl');
like($helper_text, qr/sed -n '1s\/\^#!/, 'the helper reads ./jawn for the app\'s interpreter');
like($helper_text, qr/PERL_ENV_OK/, 'it reports whether an interpreter was found');

for my $file ($hook, $helper) {
	my $text = read_file($file);
	unlike($text, qr/\[\[[[:space:]]/, "$file stays POSIX sh (no [[ ]] test)");
	unlike($text, qr/\bfunction\s+\w+\s*\(\)/, "$file stays POSIX sh (no bash function)");
	unlike($text, qr/^\s*local\s+\w+=/m, "$file stays POSIX sh (no local)");
	my $out = `sh -n "$file" 2>&1`;
	is($? >> 8, 0, "$file parses under sh") or diag($out);
}

# --- run the real hook --------------------------------------------------------
sub sq { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }

sub git {
	my ($repo, @cmd) = @_;
	my $out = `cd @{[ &sq($repo) ]} && @cmd 2>&1`;
	die "git @cmd: $out" if $? != 0;
	return $out;
}

sub write_text {
	my ($path, $text) = @_;
	make_path(dirname($path));
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $text;
	close $fh;
}

# A module only local::lib (or PERL5LIB) supplies, so a pass proves the hook put
# it on @INC instead of finding it on the system.
sub install_module {
	my ($dir, $module) = @_;
	my $package = $module =~ s{/}{::}gr;
	&write_text("$dir/$module.pm", "package $package;\n1;\n");
}

# Run the hook as git would: a base commit, a tip that changes probe.pl, and the
# pre-push line on stdin. HOME is a fixture, so the real local::lib is never seen.
sub run_hook {
	my (%opt) = @_;
	my $repo = tempdir(CLEANUP => 1);
	make_path("$repo/scripts", "$repo/.githooks");
	copy($guard, "$repo/scripts/verify_change.pl") or die "copy: $!";
	copy($hook, "$repo/.githooks/pre-push") or die "copy: $!";
	copy($helper, "$repo/scripts/perl_env.sh") or die "copy: $!" unless $opt{no_helper};

	&git($repo, 'git init -q');
	&git($repo, 'git config user.email test@example.invalid');
	&git($repo, 'git config user.name Test');
	&git($repo, 'git config commit.gpgsign false');

	&write_text("$repo/probe.pl", "1;\n");
	&git($repo, 'git add -A');
	&git($repo, 'git commit -qm base');
	my $base = &git($repo, 'git rev-parse HEAD');
	$base =~ s/\s+$//;

	&write_text("$repo/probe.pl", $opt{probe} . "\n");
	&git($repo, 'git add -A');
	&git($repo, 'git commit -qm tip');
	my $tip = &git($repo, 'git rev-parse HEAD');
	$tip =~ s/\s+$//;

	# A PATH with no perl at all (the hook still needs git to find the top level).
	my $path = $opt{no_perl} ? do {
		my $bin = tempdir(CLEANUP => 1);
		&write_text("$bin/git", "#!/bin/sh\npwd\n");
		chmod 0755, "$bin/git" or die "chmod: $!";
		$bin;
	} : undef;

	my @env = ("HOME=" . &sq($opt{home}));
	push @env, defined $opt{perl5lib} ? "PERL5LIB=" . &sq($opt{perl5lib}) : 'env -u PERL5LIB';
	push @env, 'PATH=' . &sq($path) if defined $path;

	my $line = qq{"refs/heads/main $tip refs/heads/main $base"};
	my $out = `cd @{[ &sq($repo) ]} && printf '%s\\n' $line | @env /bin/sh .githooks/pre-push origin https://example.invalid/repo.git 2>&1`;
	return ($? >> 8, $out);
}

# 1. no PERL5LIB: the hook seeds local::lib, version subdir included
my $home = tempdir(CLEANUP => 1);
&install_module("$home/perl5/lib/perl5/5.99.0", 'JawnProbe/Locallib');
my ($code, $out) = &run_hook(
	home => $home,
	probe => "use JawnProbe::Locallib;\n1;\n",
);
is($code, 0, 'a module in local::lib is found when PERL5LIB is absent') or diag($out);

# 2. a supplied PERL5LIB is kept
my $lib = tempdir(CLEANUP => 1);
&install_module($lib, 'JawnProbe/Locallib');
($code, $out) = &run_hook(
	home => tempdir(CLEANUP => 1),
	perl5lib => $lib,
	probe => "use JawnProbe::Locallib;\n1;\n",
);
is($code, 0, 'a supplied PERL5LIB is still used') or diag($out);

# 3. local::lib leads a supplied PERL5LIB, as it does in ./jawn's BEGIN block
($code, $out) = &run_hook(
	home => $home,
	perl5lib => tempdir(CLEANUP => 1),
	probe => "use JawnProbe::Locallib;\n1;\n",
);
is($code, 0, 'local::lib is prepended to an existing PERL5LIB, not dropped') or diag($out);

# 4. a genuine syntax error is still the block it always was
($code, $out) = &run_hook(
	home => tempdir(CLEANUP => 1),
	probe => "use strict;\nthis is not perl(;\n1;\n",
);
isnt($code, 0, 'a syntax error still blocks the push');
like($out, qr/syntax error/i, 'and the failure says syntax');

# 5. a module the machine does not have still blocks
($code, $out) = &run_hook(
	home => tempdir(CLEANUP => 1),
	probe => "use JawnProbe::Absent;\n1;\n",
);
isnt($code, 0, 'a genuinely missing module still blocks the push');
like($out, qr/JawnProbe/, 'and the report names it');

# 6. no perl: say so and block, never pass quietly
($code, $out) = &run_hook(
	home => tempdir(CLEANUP => 1),
	no_perl => 1,
	probe => "1;\n",
);
isnt($code, 0, 'a push on a machine with no perl is blocked');
like($out, qr/no perl interpreter found/, 'the line names the missing interpreter');
like($out, qr/blocking \(not passing\)/, 'and says it is a block, not a pass');

# 7. no helper: likewise loud
($code, $out) = &run_hook(
	home => tempdir(CLEANUP => 1),
	no_helper => 1,
	probe => "1;\n",
);
isnt($code, 0, 'a push without scripts/perl_env.sh is blocked');
like($out, qr/perl_env\.sh is missing/, 'the line names the missing helper');

done_testing();
