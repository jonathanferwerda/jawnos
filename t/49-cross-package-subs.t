use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Basename qw(basename);

# Cross-package sub calls and the require graph.
#
# This tree has no modules: `package Foo;` lives inside a .pl that another .pl
# `require`s by relative path, and a few files declare no package at all and
# silently join the package of whoever loaded them (Music.pl, hooks.pl and
# junderground.pl are `Manager::*` because Manager.pl requires them). A rename
# in one file is then invisible: `perl -c` cannot see a call to a sub that does
# not exist, and the suite's harness only loads subroutines.pl.
#
# The case that motivated this file: watch.pl and teletype.pl load Manager.pl
# for `package Manager`'s subs (subroutines.pl calls 78 `Manager::*`), and
# nothing verified that contract. The subtests here do:
#
#   1. every `Pkg::name` call names a sub (or explicit import) that exists;
#   2. each server entry point loads the file that defines every package it
#      calls into, so a call cannot wait for a file that never arrives;
#   3. a file with no `package` line is loaded from exactly one package, so it
#      cannot quietly define subs under two names;
#   4. the require graph has no cycle beyond the two known ones (a `use`
#      conversion turns any new cycle into a compile error).
#
# It is static: no app, no database, no config, no network.

my $root = abs_path("$FindBin::Bin/..");

my @rel;
push @rel, map { basename($_) } glob("$root/*.pl");
push @rel, map { 'scripts/' . basename($_) } glob("$root/scripts/*.pl");

# The code part of a line: comments removed, quoted spans blanked.
# Heredoc bodies and POD are skipped by the caller.
sub line_parts {
	my $line = shift;
	my ($code, $text) = ('', '');
	my ($sq, $dq, $bt) = (0, 0, 0);
	for (my $i = 0; $i < length $line; $i++) {
		my $ch = substr($line, $i, 1);
		if ($ch eq '\\' && ($sq || $dq || $bt) && $i + 1 < length $line) {
			$text .= substr($line, $i, 2);
			$i++;
			next;
		}
		if ($sq) { $sq = 0 if $ch eq "'"; $text .= $ch; next }
		if ($dq) { $dq = 0 if $ch eq '"'; $text .= $ch; next }
		if ($bt) { $bt = 0 if $ch eq '`'; $text .= $ch; next }
		if ($ch eq "'") { $sq = 1; $text .= $ch; next }
		if ($ch eq '"') { $dq = 1; $text .= $ch; next }
		if ($ch eq '`') { $bt = 1; $text .= $ch; next }
		last if $ch eq '#';    # a comment runs to the end of the line
		$code .= $ch;
		$text .= $ch;
	}
	return ($code, $text);
}

my %scan;    # './Foo.pl' => { subs, pkg_at, requires, refs, imports, lite }

for my $name (@rel) {
	my $path = "$root/$name";
	open(my $fh, '<', $path) or die "$path: $!";
	local $/;
	my $src = <$fh>;
	close $fh;

	my (%subs, @pkg_at, @requires, @refs, %imports);
	my $cur_pkg;
	my $in_pod = 0;
	my $heredoc;

	my @lines = split /\n/, $src, -1;
	for my $i (0 .. $#lines) {
		my $ln  = $i + 1;
		my $raw = $lines[$i];

		if (defined $heredoc) {
			my $end = $heredoc->{'indent'} ? qr/^\s*\Q$heredoc->{'term'}\E$/ : qr/^\Q$heredoc->{'term'}\E$/;
			undef $heredoc if $raw =~ $end;
			next;
		}
		if ($in_pod) { $in_pod = 0 if $raw =~ /^=cut\b/; next }
		if ($raw =~ /^=(\w+)/ && $1 ne 'cut') { $in_pod = 1; next }
		last if $raw =~ /^__(END|DATA)__\s*$/;

		my ($code, $text) = line_parts($raw);

		# The terminator may be quoted (<<'TXT'), so look at the version that
		# still has its quotes; $code has them blanked.
		if ($text =~ /<<(~?)['"]?([A-Za-z_]\w*)['"]?/) {
			$heredoc = { term => $2, indent => ($1 ? 1 : 0) };
		}
		if ($code =~ /^\s*package\s+([A-Za-z_]\w*)\s*[;{]/) {
			$cur_pkg = $1;
			push @pkg_at, [ $ln, $cur_pkg ];
		}
		if ($code =~ /^\s*sub\s+([A-Za-z_]\w*)/) {
			push @{ $subs{$1} }, [ $ln, $cur_pkg ];
		}
		# `use Module qw(name ...)` installs name() in the importing package;
		# subroutines.pl exports md5_sum/encode_json/encode_sereal that way.
		if ($text =~ /^\s*use\s+[A-Za-z_]\w*(?:::\w+)*\s+(.*)$/) {
			my $list = $1;
			$list =~ s/^qw\b//;
			$list =~ s/;.*$//;
			while ($list =~ /\b([a-z_][A-Za-z0-9_]*)\b/g) {
				$imports{ $cur_pkg // '<inherit>' }{ $1 } = $ln;
			}
		}
		if ($code =~ /\brequire\b/ && $text =~ /require\s*\(?\s*["']([^"']+\.pl)["']/) {
			push @requires, [ $ln, $1 ];
		}
		# A package-qualified call. `$gb::secret_maker` and friends are
		# variables; `Tunnel::Hub->new` is a class name, not a sub.
		while ($code =~ /(?<![\$\@%*])\b([A-Za-z_]\w*)::([A-Za-z_]\w*)\b(?!\s*::)(\s*->)?/g) {
			next if $3 && $2 =~ /^[A-Z]/;
			push @refs, [ $ln, $1, $2 ];
		}
	}

	$scan{"./$name"} = {
		subs     => \%subs,
		pkg_at   => \@pkg_at,
		requires => \@requires,
		refs     => \@refs,
		imports  => \%imports,
		lite     => ($src =~ /^\s*use\s+Mojolicious::Lite\b/m ? 1 : 0),
	};
}

# A required path is matched by basename: `./Manager.pl`, `"$repo/x.pl"` and
# `"$RealBin/../subroutines.pl"` all name a file in this scan.
sub target_of {
	my $raw  = shift;
	my $base = basename($raw);
	for my $candidate ("./$base", "./scripts/$base") {
		return $candidate if $scan{$candidate};
	}
	return undef;
}

# The package a file's code joins before its own `package` line: whoever loads
# it, provided every loader agrees.
my %loaders;
for my $path (keys %scan) {
	for my $req (@{ $scan{$path}{requires} }) {
		my $target = target_of($req->[1]) or next;
		my $loader_pkg = @{ $scan{$path}{pkg_at} }
			? $scan{$path}{pkg_at}[0][1]
			: undef;
		$loaders{$target}{ $loader_pkg // '<inherit>' } = 1 if defined $loader_pkg;
	}
}

my %effective;
for my $path (keys %scan) {
	my @declared = map { $_->[1] } @{ $scan{$path}{pkg_at} };
	if (@declared) { $effective{$path} = $declared[0]; next }
	my @loaded_from = sort keys %{ $loaders{$path} || {} };
	$effective{$path} = @loaded_from == 0 ? '<entry>'
		: @loaded_from == 1 ? $loaded_from[0]
		: '<unresolved>';
}

my %known_pkg;
for my $path (keys %scan) {
	$known_pkg{ $effective{$path} } = 1 unless $effective{$path} =~ /^</;
	$known_pkg{ $_->[1] } = 1 for @{ $scan{$path}{pkg_at} };
}
my %lite_pkg;
for my $path (keys %scan) {
	next unless $scan{$path}{lite};
	$lite_pkg{ $effective{$path} } = 1 unless $effective{$path} =~ /^</;
	$lite_pkg{ $_->[1] } = 1 for @{ $scan{$path}{pkg_at} };
}

# "Pkg::name" => [ "file:line", ... ] for subs and explicit imports
my %defined;
for my $path (keys %scan) {
	my $eff = $effective{$path};
	for my $name (keys %{ $scan{$path}{subs} }) {
		for my $def (@{ $scan{$path}{subs}{$name} }) {
			my ($ln, $pkg) = @$def;
			my $where = $pkg // $eff;
			push @{ $defined{"$where\::$name"} }, "$path:$ln";
		}
	}
	for my $pkg (keys %{ $scan{$path}{imports} }) {
		my $where = $pkg eq '<inherit>' ? $eff : $pkg;
		for my $name (keys %{ $scan{$path}{imports}{$pkg} }) {
			push @{ $defined{"$where\::$name"} }, "$path:$scan{$path}{imports}{$pkg}{$name} (import)";
		}
	}
}

sub closure_of {
	my $start = shift;
	my %seen;
	my @stack = ($start);
	while (my $path = pop @stack) {
		next if $seen{$path}++;
		next unless $scan{$path};
		for my $req (@{ $scan{$path}{requires} }) {
			my $target = target_of($req->[1]) or next;
			push @stack, $target;
		}
	}
	return \%seen;
}

sub is_defined {
	my ($pkg, $name) = @_;
	return 1 if $defined{"$pkg\::$name"};
	return 1 if ($name eq 'app' || $name eq 'new') && $lite_pkg{$pkg};
	return 0;
}

# The scan must actually have found the tree; a regex gone quiet would
# otherwise pass every assertion below.
cmp_ok(scalar keys %known_pkg, '>=', 15, 'found the tree\'s packages');
cmp_ok(scalar keys %defined,   '>=', 2000, 'found the tree\'s subs');
my $ref_count = 0;
$ref_count += scalar @{ $scan{$_}{refs} } for keys %scan;
cmp_ok($ref_count, '>=', 5000, 'found package-qualified calls');

subtest 'every package-qualified call names something that exists' => sub {
	my @bad;
	for my $path (sort keys %scan) {
		for my $ref (@{ $scan{$path}{refs} }) {
			my ($ln, $pkg, $name) = @$ref;
			next unless $known_pkg{$pkg};
			next if is_defined($pkg, $name);
			push @bad, "$path:$ln calls $pkg\::$name";
		}
	}
	is(scalar @bad, 0, 'no call to an undefined sub')
		or diag(join "\n", @bad[0 .. ($#bad > 9 ? 9 : $#bad)]);
};

subtest 'each server entry point loads what it calls into' => sub {
	# The entry points a President worker starts with load_app.
	my @entries = ('./President.pl', './Manager.pl', './watch.pl', './teletype.pl', './Alarm.pl');
	for my $entry (@entries) {
		ok($scan{$entry}, "$entry exists") or next;
		my $closure = closure_of($entry);
		my @outside;
		for my $path (sort keys %$closure) {
			for my $ref (@{ $scan{$path}{refs} }) {
				my ($ln, $pkg, $name) = @$ref;
				next unless $known_pkg{$pkg};
				next if ($name eq 'app' || $name eq 'new') && $lite_pkg{$pkg};
				my @defs = @{ $defined{"$pkg\::$name"} || [] };
				next unless @defs;
				my $inside = grep { (my $p = $_) =~ s/:\d+.*$//; $closure->{$p} } @defs;
				next if $inside;
				push @outside, "$path:$ln calls $pkg\::$name (defined at $defs[0])";
			}
		}
		is(scalar @outside, 0, "$entry reaches every definition it calls")
			or diag(join "\n", @outside[0 .. ($#outside > 9 ? 9 : $#outside)]);
	}
};

subtest 'a file with no package line is loaded from one package' => sub {
	my @ambiguous = grep { $effective{$_} eq '<unresolved>' } sort keys %scan;
	is(scalar @ambiguous, 0, 'no file is loaded from two packages')
		or diag(join "\n", @ambiguous);
	# Name the files that currently inherit, so the next reader sees them.
	my @inherited = grep { !@{ $scan{$_}{pkg_at} } && $effective{$_} !~ /^</ } sort keys %scan;
	diag("inherits its package from its loader: $_ => $effective{$_}") for @inherited;
	pass('inheriting files are unambiguous');
};

subtest 'no new require cycles' => sub {
	my %reach;
	for my $path (keys %scan) {
		my $closure = closure_of($path);
		$reach{$path} = $closure;
	}
	# Group files that reach each other: one strongly connected component.
	my %scc;
	for my $path (sort keys %scan) {
		next if $scc{$path};
		my @members = grep { $reach{$_}{$path} && $reach{$path}{$_} } keys %{ $reach{$path} };
		$scc{$_} = \@members for @members;
	}
	my %allowed = (
		'./Websocket.pl|./gb.pl|./subroutines.pl' => 1,
		'./teletype.pl|./watch.pl'               => 1,
	);
	my (@new, %seen);
	for my $members (values %scc) {
		next if @$members < 2;
		my $key = join '|', sort @$members;
		next if $seen{$key}++;
		next if $allowed{$key};
		push @new, join(', ', sort @$members);
	}
	is(scalar @new, 0, 'cycles are only gb/subs and watch/teletype')
		or diag(join "\n", @new);
};

subtest 'scripts load the packages they call into' => sub {
	# TODO: subroutines.pl calls 78 `Manager::*` subs, so every script that
	# loads only ./subroutines.pl has calls it cannot resolve in that process.
	# Extract those subs into the domain layer and this passes; until then it
	# records the size of the gap.
	local $TODO = 'subroutines.pl -> Manager:: calls are unresolved when only subroutines.pl is loaded';
	my (@affected, %missing);
	for my $script (sort glob('./scripts/*.pl')) {
		$script =~ s{^\./}{./};
		next unless $scan{$script};
		my $closure = closure_of($script);
		my $hit = 0;
		for my $path (sort keys %$closure) {
			for my $ref (@{ $scan{$path}{refs} }) {
				my ($ln, $pkg, $name) = @$ref;
				next unless $known_pkg{$pkg};
				next if ($name eq 'app' || $name eq 'new') && $lite_pkg{$pkg};
				my @defs = @{ $defined{"$pkg\::$name"} || [] };
				next unless @defs;
				my $inside = grep { (my $p = $_) =~ s/:\d+.*$//; $closure->{$p} } @defs;
				next if $inside;
				$missing{"$pkg\::$name"} = 1;
				$hit++;
			}
		}
		push @affected, "$script ($hit)" if $hit;
	}
	diag(sprintf 'scripts with unresolved calls: %d', scalar @affected);
	diag(sprintf 'distinct missing subs: %d', scalar keys %missing);
	is(scalar @affected, 0, 'every script can resolve every call it makes');
};

done_testing;
