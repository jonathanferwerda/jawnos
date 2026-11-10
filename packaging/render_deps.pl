#!/usr/bin/perl

# The one place the packaging dependency lists come from.
#
#   perl packaging/render_deps.pl --target deb      # the Depends: names
#   perl packaging/render_deps.pl --target arch     # the depends=() names
#   perl packaging/render_deps.pl --vendor deb      # CPAN dists to vendor
#   perl packaging/render_deps.pl --vendor arch
#   perl packaging/render_deps.pl --check           # manifests match deps.json
#   perl packaging/render_deps.pl --all-modules     # every module the tree loads
#
# deps.json says, per module, which Debian and Arch package provides it; null
# means no distro package exists and the dist is fetched into vendor/ by
# packaging/vendor/fetch.sh. `--check` is what the suite runs, so the checked-in
# control and PKGBUILD cannot drift from the manifest.
#
# Core Perl modules and the four names CryptX provides are declared but add no
# package. Keep this script core-Perl only: a packaging host has no app modules.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec ();
use FindBin;
use Getopt::Long qw(GetOptions);
use JSON::PP ();

my $root = abs_path("$FindBin::Bin/..");
my $manifest = "$root/packaging/deps.json";

sub read_file {
	my ($file) = @_;
	open(my $fh, '<', $file) or die "cannot read $file: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

my $data = JSON::PP->new->decode(read_file($manifest));
die "packaging/deps.json is not an object\n" unless ref $data eq 'HASH';

my ($target, $vendor, $check, $all_modules, $json);
GetOptions(
	'target=s'    => \$target,
	'vendor=s'    => \$vendor,
	'check'       => \$check,
	'all-modules' => \$all_modules,
	'json'        => \$json,
) or die "bad options\n";

sub wanted {
	my ($row, $which) = @_;
	my $name = $row->{$which};
	return defined $name && length $name ? $name : undef;
}

# Every package name a target needs, modules and command-line tools.
sub package_names {
	my ($which) = @_;
	my %seen;
	for my $kind (qw(modules tools)) {
		for my $name (sort keys %{ $data->{$kind} || {} }) {
			my $pkg = wanted($data->{$kind}{$name}, $which);
			$seen{$pkg} = 1 if defined $pkg;
		}
	}
	return sort keys %seen;
}

# Modules the target has no package for, as cpanm specs. cpanm resolves a
# module name (Mojolicious::Plugin::RenderFile), not a hyphenated dist name
# (Mojolicious-Plugin-RenderFile), so the module name is what we print.
sub vendor_specs {
	my ($which) = @_;
	my @out;
	for my $name (sort keys %{ $data->{modules} || {} }) {
		my $row = $data->{modules}{$name};
		next if $row->{'core'} || $row->{'provided_by'};
		next if defined wanted($row, $which);
		push @out, (defined $row->{'version'} && length $row->{'version'})
			? "$name\@" . $row->{'version'}
			: $name;
	}
	return @out;
}

sub control_depends {
	my ($file) = @_;
	my $text = read_file($file);
	my ($block) = $text =~ /^Depends:\s*(.*?)(?=^[A-Za-z][A-Za-z0-9-]*:|\z)/ms;
	return () unless defined $block;
	$block =~ s/\n\s*/ /g;
	my %seen;
	for my $entry (split /,/, $block) {
		$entry =~ s/^\s+|\s+$//g;
		next unless length $entry;
		next if $entry =~ /^\$\{/;          # ${misc:Depends}, ${perl:Depends}
		$entry =~ s/\s*\(.*$//;             # a version constraint
		$seen{$entry} = 1 if length $entry;
	}
	return sort keys %seen;
}

sub pkgbuild_depends {
	my ($file) = @_;
	my $text = read_file($file);
	my ($block) = $text =~ /^depends=\((.*?)\)/ms;
	return () unless defined $block;
	return sort { $a cmp $b } $block =~ /'([^']+)'/g;
}

sub diff_line {
	my ($label, $expected, $actual) = @_;
	my %e = map { $_ => 1 } @$expected;
	my %a = map { $_ => 1 } @$actual;
	my @missing = grep { !$a{$_} } @$expected;
	my @extra   = grep { !$e{$_} } @$actual;
	return () unless @missing || @extra;
	return ("$label: missing " . join(' ', @missing)) if @missing && !@extra;
	return ("$label: unexpected " . join(' ', @extra)) if @extra && !@missing;
	return ("$label: missing " . join(' ', @missing) . "; unexpected " . join(' ', @extra));
}

if ($check) {
	my @errors;
	push @errors, diff_line('debian Depends', [ package_names('deb') ],
		[ control_depends("$root/packaging/debian/control") ]);
	push @errors, diff_line('PKGBUILD depends', [ package_names('arch') ],
		[ pkgbuild_depends("$root/packaging/aur/PKGBUILD") ]);
	if (@errors) {
		print STDERR "$_\n" for @errors;
		exit 1;
	}
	print "packaging manifests match deps.json\n";
	exit 0;
}

if ($all_modules) {
	print join("\n", sort keys %{ $data->{modules} || {} }), "\n";
	exit 0;
}

if (defined $vendor) {
	die "vendor target must be deb or arch\n" unless $vendor =~ /^(?:deb|arch)$/;
	print join(' ', vendor_specs($vendor)), "\n";
	exit 0;
}

if (defined $target) {
	die "target must be deb or arch\n" unless $target =~ /^(?:deb|arch)$/;
	my @names = package_names($target);
	if ($json) {
		print JSON::PP->new->canonical->encode(\@names), "\n";
	}
	else {
		print join(' ', @names), "\n";
	}
	exit 0;
}

print STDERR "usage: $0 --target deb|arch | --vendor deb|arch | --check | --all-modules [--json]\n";
exit 2;
