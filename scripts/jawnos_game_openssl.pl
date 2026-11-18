#!/usr/bin/perl
# Give RetroArch the OpenSSL it was linked against without disturbing the one
# the rest of the image runs on.
#
#   perl scripts/jawnos_game_openssl.pl
#
# It runs as root after the emulator packages are installed. One JSON object
# goes to stdout; progress meant for a person goes to stderr. Running it twice
# is safe: the second run finds the layer already staged and verifies it.
#
# The GOU's packaged RetroArch is built against OpenSSL 4 and asks the loader
# for libssl.so.4 / libcrypto.so.4, while the image's openssl package is 3.6 and
# carries only .so.3. Installing the OpenSSL 4 package would replace the system
# library under half the machine, so the repository package is downloaded and
# NOT installed: only the two versioned libraries are lifted out of it.
#
# The layout is the one the Packages app reads:
#
#   /opt/openssl<N>/usr/lib/libssl.so.<N>
#   /opt/openssl<N>/usr/lib/libcrypto.so.<N>
#   /opt/openssl<N>/jawnos-compat.json
#   /etc/ld.so.conf.d/openssl<N>.conf
#
# with a manifest naming the sonames, the package they came from, the binary
# they were staged for and when. The system's own /usr/lib/libssl.so.3 and
# every other system file are left alone.
#
# Tests replace each tool and path through the environment:
#   JAWNOS_OPENSSL_COMPAT_DIR  /opt/openssl<N>
#   JAWNOS_OPENSSL_LDCONF      /etc/ld.so.conf.d/openssl<N>.conf
#   JAWNOS_OPENSSL_PACMAN      pacman
#   JAWNOS_OPENSSL_LDCONFIG    ldconfig
#   JAWNOS_OPENSSL_LDD         ldd
#   JAWNOS_OPENSSL_BINARY      the RetroArch to check
#   JAWNOS_OPENSSL_CACHE       /var/cache/pacman/pkg
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use JSON::PP ();
use JawnOS::Games ();

my $JSON = JSON::PP->new->canonical(1);

# Filled in before any helper runs; the subs below close over it.
my $retroarch;

sub progress {
	print STDERR 'openssl: ' . join('', @_) . "\n";
}

sub output {
	my ($data) = @_;
	print $JSON->encode($data), "\n";
	exit($data->{'ok'} ? 0 : 1);
}

sub refuse {
	my ($error) = @_;
	output({ ok => 0, error => $error });
}

# One command's stdout, so the JSON channel stays clean. A command that is not
# installed reads as exit 127 rather than an exception.
sub capture {
	my (@command) = @_;
	open(my $pipe, '-|', @command) or return (127, '');
	local $/;
	my $out = <$pipe>;
	$out = '' unless defined $out;
	close $pipe;
	my $status = $?;
	my $code = $status == -1 ? 127 : $status >> 8;
	return ($code, $out);
}

sub tail {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	$text = substr($text, -300) if length($text) > 300;
	return $text;
}

sub read_json {
	my ($path) = @_;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	$text = '' unless defined $text;
	my $data = eval { $JSON->decode($text) };
	return ref $data eq 'HASH' ? $data : undef;
}

sub write_json {
	my ($path, $data) = @_;
	open(my $fh, '>', "$path.tmp") or return 0;
	print $fh $JSON->encode($data);
	close $fh or return 0;
	rename "$path.tmp", $path or return 0;
	chmod 0644, $path;
	return 1;
}

sub retroarch_binary {
	my $override = $ENV{'JAWNOS_OPENSSL_BINARY'};
	return $override if defined $override && length $override;
	my $found = JawnOS::Games::retroarch_binary();
	return defined $found ? $found : '/usr/bin/retroarch';
}

sub ldd_report {
	my ($binary) = @_;
	my ($code, $out) = capture($ENV{'JAWNOS_OPENSSL_LDD'} || 'ldd', $binary);
	my @missing;
	while ($out =~ /^[ \t]*(\S+)[ \t]+=>[ \t]+not[ \t]+found/mg) {
		push @missing, $1;
	}
	return ($code, \@missing);
}

# The OpenSSL sonames among the missing ones, and any whose version suffix is
# not a plain number. Refusing the odd shape keeps a crafted ldd line from
# naming a path the tar step would follow.
sub openssl_majors {
	my (@names) = @_;
	my (%seen, @unsafe);
	for my $name (@names) {
		my ($rest) = $name =~ /^lib(?:ssl|crypto)\.so\.(.*)$/;
		next unless defined $rest;
		if ($rest !~ /^\d{1,3}$/) {
			push @unsafe, $name;
			next;
		}
		$seen{$rest} = 1;
	}
	return (\@unsafe, [ sort { $a <=> $b } keys %seen ]);
}

sub compat_dir {
	my ($major) = @_;
	my $override = $ENV{'JAWNOS_OPENSSL_COMPAT_DIR'};
	return $override if defined $override && length $override;
	return "/opt/openssl$major";
}

sub ldconf_path {
	my ($major) = @_;
	my $override = $ENV{'JAWNOS_OPENSSL_LDCONF'};
	return $override if defined $override && length $override;
	return "/etc/ld.so.conf.d/openssl$major.conf";
}

# A layer already staged by an earlier run. With the compat dir pinned by the
# environment there is one place to read; otherwise every /opt/openssl<N>.
sub installed_manifest {
	my @dirs;
	if (defined $ENV{'JAWNOS_OPENSSL_COMPAT_DIR'} && length $ENV{'JAWNOS_OPENSSL_COMPAT_DIR'}) {
		push @dirs, $ENV{'JAWNOS_OPENSSL_COMPAT_DIR'};
	}
	else {
		push @dirs, sort glob('/opt/openssl*');
	}
	for my $dir (@dirs) {
		next unless -d $dir;
		my $data = read_json("$dir/jawnos-compat.json");
		next unless defined $data;
		my $list = ref $data->{'sonames'} eq 'ARRAY' ? $data->{'sonames'} : [];
		my @sonames = map { '' . $_ } @$list;
		my ($major) = map { /^libssl\.so\.(\d+)$/ ? $1 : () } @sonames;
		next unless defined $major && $major =~ /^\d{1,3}$/;
		return { dir => $dir, major => $major, sonames => \@sonames, data => $data };
	}
	return undef;
}

sub stage_complete {
	my ($dir, $major) = @_;
	return 0 unless -f "$dir/usr/lib/libssl.so.$major";
	return 0 unless -f "$dir/usr/lib/libcrypto.so.$major";
	return 0 unless -f "$dir/jawnos-compat.json";
	return 1;
}

# The loader conf is one line. Writing it only when it is absent or lacks that
# line is what makes a second run leave the file alone.
sub ensure_conf {
	my ($path, $libdir) = @_;
	my $dir = dirname($path);
	if (!-d $dir) {
		eval { make_path($dir) };
		return (0, 0, "Cannot create $dir: $@") unless -d $dir;
	}
	if (-f $path) {
		open(my $fh, '<', $path) or return (0, 0, "Cannot read $path: $!");
		local $/;
		my $text = <$fh>;
		close $fh;
		$text = '' unless defined $text;
		return (1, 0, undef) if grep { $_ eq $libdir } split /\n/, $text;
		open(my $out, '>>', $path) or return (0, 0, "Cannot write $path: $!");
		print $out "$libdir\n";
		close $out or return (0, 0, "Cannot write $path: $!");
		return (1, 1, undef);
	}
	open(my $out, '>', $path) or return (0, 0, "Cannot write $path: $!");
	print $out "$libdir\n";
	close $out or return (0, 0, "Cannot write $path: $!");
	return (1, 1, undef);
}

sub candidates {
	my ($dir) = @_;
	my @files = grep { -f $_ && m{\.pkg\.tar\.(?:xz|zst|gz|bz2)$} } glob("$dir/openssl-*.pkg.tar.*");
	my %at = map { $_ => (stat($_))[9] // 0 } @files;
	return sort { $at{$b} <=> $at{$a} || $b cmp $a } @files;
}

sub present {
	my ($major, $dir, $conf, $sonames, $manifest) = @_;
	progress("OpenSSL $major is already staged under $dir.");
	my ($ok, undef, $error) = ensure_conf($conf, "$dir/usr/lib");
	refuse($error) unless $ok;

	my ($code, $missing) = ldd_report($retroarch);
	refuse("ldd could not check $retroarch (exit $code).") if $code != 0;
	my %now = map { $_ => 1 } @$missing;
	my @still = grep { $now{$_} } @$sonames;
	if (@still) {
		progress('The loader cache does not know the layer yet; refreshing it.');
		my ($lc_code, $lc_out) = capture($ENV{'JAWNOS_OPENSSL_LDCONFIG'} || 'ldconfig');
		refuse('ldconfig failed: ' . tail($lc_out)) if $lc_code != 0;
		($code, $missing) = ldd_report($retroarch);
		refuse("ldd could not check $retroarch (exit $code).") if $code != 0;
		%now = map { $_ => 1 } @$missing;
		@still = grep { $now{$_} } @$sonames;
	}
	refuse('RetroArch still cannot load ' . join(', ', @still)) if @still;

	my $data = defined $manifest ? $manifest->{'data'} : {};
	output({
		ok => 1,
		state => 'present',
		major => $major,
		sonames => [ sort @$sonames ],
		source => defined $data->{'source'} ? $data->{'source'} : '',
		compat => $dir,
		binary => $retroarch,
	});
}

sub stage {
	my ($major, $dir, $conf, $sonames) = @_;
	progress("RetroArch needs OpenSSL $major; staging it under $dir.");
	my $pacman = $ENV{'JAWNOS_OPENSSL_PACMAN'} || 'pacman';
	my $cache = $ENV{'JAWNOS_OPENSSL_CACHE'} || '/var/cache/pacman/pkg';

	# -Sddw downloads the package and its dependencies and stops there: the
	# package is never installed, so the system's OpenSSL stays what it is.
	my ($pac_code, $pac_out) = capture($pacman, '-Sddw', '--noconfirm', 'openssl');
	refuse('The OpenSSL package could not be downloaded: ' . tail($pac_out)) if $pac_code != 0;

	my @members = map { "usr/lib/$_" } @$sonames;
	# Newest first, and the first one that really carries both sonames wins: a
	# cache may also hold an older OpenSSL that does not.
	my ($package);
	my @candidates = candidates($cache);
	for my $candidate (@candidates) {
		my ($code, $out) = capture('tar', '-tf', $candidate);
		next if $code != 0;
		my %member;
		for my $line (split /\n/, $out) {
			(my $name = $line) =~ s{^\./}{};
			$member{$name} = 1;
		}
		next if grep { !$member{$_} } @members;
		$package = $candidate;
		last;
	}
	refuse("No cached openssl package in $cache carries " . join(', ', @$sonames) . '.')
		unless defined $package;
	progress('Using ' . basename($package) . '.');

	my $libdir = "$dir/usr/lib";
	make_path($libdir);
	my ($untar_code, $untar_out) = capture('tar', '-xf', $package, '-C', $dir, @members);
	refuse('The OpenSSL libraries could not be extracted: ' . tail($untar_out)) if $untar_code != 0;

	my @files;
	for my $name (@members) {
		my $file = "$dir/$name";
		refuse("Extracting " . basename($package) . " did not produce $name.") unless -f $file;
		chmod 0755, $file;
		push @files, $file;
	}
	# Only root may own root's libraries; a test run as a person skips this.
	if ($> == 0) {
		chown(0, 0, @files) or progress('Could not hand the libraries to root: ' . $!);
	}

	refuse('The compat manifest could not be written.')
		unless write_json("$dir/jawnos-compat.json", {
			sonames => [ sort @$sonames ],
			source => basename($package),
			binary => $retroarch,
			created => time,
		});

	my ($ok, undef, $error) = ensure_conf($conf, $libdir);
	refuse($error) unless $ok;

	my ($lc_code, $lc_out) = capture($ENV{'JAWNOS_OPENSSL_LDCONFIG'} || 'ldconfig');
	refuse('ldconfig failed: ' . tail($lc_out)) if $lc_code != 0;

	my ($code, $missing) = ldd_report($retroarch);
	refuse("ldd could not check $retroarch (exit $code).") if $code != 0;
	my %now = map { $_ => 1 } @$missing;
	my @still = grep { $now{$_} } @$sonames;
	refuse('RetroArch still cannot load ' . join(', ', @still)) if @still;

	progress("OpenSSL $major is staged for RetroArch.");
	output({
		ok => 1,
		state => 'staged',
		major => $major,
		sonames => [ sort @$sonames ],
		source => basename($package),
		compat => $dir,
		binary => $retroarch,
	});
}

$retroarch = retroarch_binary();
refuse("RetroArch is not installed at $retroarch.") unless -x $retroarch;

my ($ldd_code, $missing) = ldd_report($retroarch);
refuse("ldd could not check $retroarch (exit $ldd_code).") if $ldd_code != 0;

my ($unsafe, $majors) = openssl_majors(@$missing);
if (@$unsafe) {
	refuse('The loader names an OpenSSL soname this helper will not use: ' . join(', ', @$unsafe));
}
if (@$majors > 1) {
	refuse('RetroArch asks for two OpenSSL majors at once: ' . join(', ', @$majors));
}

my $known = installed_manifest();

if (!@$majors) {
	# Nothing is missing. A layer staged by an earlier run is still reported,
	# so a second install pass says what is in place rather than "none".
	if (defined $known && stage_complete($known->{'dir'}, $known->{'major'})) {
		present($known->{'major'}, $known->{'dir'}, ldconf_path($known->{'major'}),
			$known->{'sonames'}, $known);
	}
	output({ ok => 1, state => 'none' });
}

my $major = $majors->[0];
my @wanted = ("libssl.so.$major", "libcrypto.so.$major");
my $dir = compat_dir($major);
my $conf = ldconf_path($major);
my $manifest = defined $known && $known->{'major'} eq $major ? $known : undef;

if (stage_complete($dir, $major)) {
	present($major, $dir, $conf, \@wanted, $manifest);
}
stage($major, $dir, $conf, \@wanted);
