package JawnOS::Packages;

# Metadata parsers for scripts/jawnos_deps.pl --freshness. This module is
# deliberately core-Perl only: it runs before any of the installer's modules
# exist, and it never downloads a package, a tarball or a distribution. The
# callers fetch small JSON/text descriptions; everything here is pure parsing
# and version comparison.

use strict;
use warnings;

use JSON::PP ();
use version ();

# MetaCPAN /v1/module/<name>: {"version":"9.39","release":"Mojolicious-9.39",...}
sub parse_metacpan {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	my $json = eval { JSON::PP::decode_json($text) };
	return undef unless ref $json eq 'HASH';
	my $latest = $json->{'version'};
	return undef unless defined $latest && length $latest;
	return { latest => "$latest", release => $json->{'release'} };
}

# Debian madison?package=<pkg>&table=all:
#   curl | 8.14.1-2+deb13u2 | stable | amd64, arm64
# Returns every line plus the first version seen for each suite. A package that
# is not in any suite produces no lines, which the caller reads as missing.
sub parse_madison {
	my ($text) = @_;
	my (@lines, %suite);
	for my $line (split /\n/, defined $text ? $text : '') {
		next unless $line =~ /\S/;
		my ($pkg, $ver, $s, $archs) = map { s/^\s+|\s+$//gr } split /\|/, $line;
		next unless defined $ver && length $ver;
		push @lines, {
			package => $pkg,
			version => $ver,
			suite   => $s,
			archs   => $archs,
		};
		$suite{$s} //= $ver;
	}
	return { lines => \@lines, suites => \%suite };
}

# The installer targets Debian stable first, then testing, then unstable. A
# package that exists only in unstable is still "offered", but the report says
# which suite answered so a stable install is not assumed to work.
sub debian_latest {
	my ($parsed) = @_;
	return undef unless ref $parsed eq 'HASH';
	my $suites = $parsed->{'suites'} || {};
	for my $suite (qw(stable testing unstable oldstable oldoldstable)) {
		return { version => $suites->{$suite}, suite => $suite }
			if defined $suites->{$suite};
	}
	for my $line (@{ $parsed->{'lines'} || [] }) {
		return { version => $line->{'version'}, suite => $line->{'suite'} };
	}
	return undef;
}

# Arch /packages/search/json/?name=<pkg>:
#   {"results":[{"pkgname":"tmux","repo":"extra","arch":"x86_64",
#               "pkgver":"3.8","pkgrel":"1","epoch":0,...}]}
sub parse_arch {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	my $json = eval { JSON::PP::decode_json($text) };
	return undef unless ref $json eq 'HASH';
	my @results = grep {
		ref $_ eq 'HASH'
			&& (($_->{'arch'} // '') eq 'x86_64' || ($_->{'arch'} // '') eq 'any')
	} @{ $json->{'results'} || [] };
	return undef unless @results;
	my ($best) = sort {
		($b->{'epoch'} // 0) <=> ($a->{'epoch'} // 0)
			|| ($b->{'pkgver'} // '') cmp ($a->{'pkgver'} // '')
	} @results;
	return {
		latest => $best->{'pkgver'},
		rel    => $best->{'pkgrel'},
		epoch  => $best->{'epoch'},
		repo   => $best->{'repo'},
	};
}

# The version string vercmp and a human expect: epoch:pkgver-pkgrel.
sub arch_version {
	my ($arch) = @_;
	return undef unless ref $arch eq 'HASH' && defined $arch->{'latest'};
	my $version = $arch->{'latest'};
	$version = $arch->{'epoch'} . ':' . $version
		if defined $arch->{'epoch'} && $arch->{'epoch'} ne '' && $arch->{'epoch'} ne '0';
	$version .= '-' . $arch->{'rel'} if defined $arch->{'rel'} && $arch->{'rel'} ne '';
	return $version;
}

# Compare two Perl module versions (9.39 vs 9.53, v1.2.3, 0.085, ...).
sub compare_module {
	my ($installed, $latest) = @_;
	return 0 unless defined $installed && defined $latest
		&& length $installed && length $latest;
	my $cmp = eval { version->parse($installed) <=> version->parse($latest) };
	return defined $cmp ? $cmp : 0;
}

# Arch versions compare the way pacman's vercmp does: epoch first, then the
# upstream version in runs of digits and runs of letters (a number beats a
# letter, separators such as . _ + are not part of the order), then pkgrel.
sub _arch_segments {
	my ($version) = @_;
	my @segments;
	while ($version =~ /(\d+|[A-Za-z]+)/g) {
		push @segments, $1;
	}
	return \@segments;
}

sub _compare_segments {
	my ($left, $right) = @_;
	my $count = @$left > @$right ? @$left : @$right;
	for my $i (0 .. $count - 1) {
		my ($a, $b) = ($left->[$i], $right->[$i]);
		next unless defined $a || defined $b;
		# A version that has run out of segments is "nothing": a further
		# number makes the other one newer (1.0.1 > 1.0), a further letter
		# makes it older (1.0rc1 < 1.0).
		return $a =~ /^\d+$/ ? 1 : -1 unless defined $b;
		return $b =~ /^\d+$/ ? -1 : 1 unless defined $a;
		my $numeric = $a =~ /^\d+$/ && $b =~ /^\d+$/;
		my $cmp = $numeric
			? ($a + 0) <=> ($b + 0)
			: ($a =~ /^\d+$/ ? 1 : $b =~ /^\d+$/ ? -1 : $a cmp $b);
		return $cmp if $cmp;
	}
	return 0;
}

sub _split_arch_version {
	my ($version) = @_;
	my ($epoch, $rest) = $version =~ /^(\d+):(.*)$/ ? ($1, $2) : (0, $version);
	my ($pkgver, $pkgrel) = $rest =~ /^(.*)-(\d+)$/ ? ($1, $2) : ($rest, '0');
	return ($epoch + 0, $pkgver, $pkgrel);
}

sub compare_arch {
	my ($installed, $latest) = @_;
	return 0 unless defined $installed && defined $latest
		&& length $installed && length $latest;
	my ($a_epoch, $a_pkgver, $a_pkgrel) = _split_arch_version($installed);
	my ($b_epoch, $b_pkgver, $b_pkgrel) = _split_arch_version($latest);
	return $a_epoch <=> $b_epoch if $a_epoch != $b_epoch;
	my $cmp = _compare_segments(_arch_segments($a_pkgver), _arch_segments($b_pkgver));
	return $cmp if $cmp;
	return _compare_segments(_arch_segments($a_pkgrel), _arch_segments($b_pkgrel));
}

1;
