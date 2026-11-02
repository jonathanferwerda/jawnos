#!/usr/bin/perl

# Where does a name live? One line, instead of reading Index.pm (611 lines of
# names) or grepping nine part files to find one function.
#
#   perl scripts/where.pl app_release_sync
#   perl scripts/where.pl subs::path_name manager_misc10 action_7408
#   perl scripts/where.pl /js/manager/app.js
#   perl scripts/where.pl --context 6 guide_find_target
#   perl scripts/where.pl --terse path_name
#
# The maps are read, never loaded: lib/JawnOS/Manager/Index.pm is %SUB (helper
# -> part) and lib/JawnOS/Domain/Loader.pm is %DOMAIN_MODULE (sub -> module).
# A name neither map knows is searched for as a sub across the parts and the
# domain modules, then as a bare reference (capped by --limit). When a map names
# a file that does not define the sub, the hit prints where it really is and
# says the map drifted - that is the audit, for free.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin ();
use Getopt::Long qw(GetOptions);

my $root    = abs_path("$FindBin::Bin/..");
my $context = 0;
my $limit   = 8;
my $terse   = 0;
my $help    = 0;

GetOptions(
	'context=i' => \$context,
	'limit=i'   => \$limit,
	'terse'     => \$terse,
	'root=s'    => \$root,
	'help'      => \$help,
) or usage(2);

usage(0) if $help;
usage(2) unless @ARGV;
usage(2) unless defined $root && length $root && -d $root;

my @manager_files = grep { -f $_ } map { glob "$root/lib/JawnOS/Manager/$_" }
	qw(Manager.pm Core1_tables_hooks.pm Core2_worker_boot.pm Part*.pm);
my @domain_files     = grep { -f $_ } glob "$root/lib/JawnOS/Domain/*.pm";
my @controller_files = grep { -f $_ } glob "$root/lib/JawnOS/Controller/*.pm";
my @route_files      = grep { -f $_ } glob "$root/lib/JawnOS/Routes/*.pm";

# --- the two name maps ------------------------------------------------------

my %helper_part;
{
	my $text = slurp("$root/lib/JawnOS/Manager/Index.pm");
	while ($text =~ /'([A-Za-z_][A-Za-z0-9_]*)'\s*=>\s*'(JawnOS\/Manager\/[^']+)'/g) {
		$helper_part{$1} = "$root/lib/$2";
	}
}

my %domain_file;
{
	my $text = slurp("$root/lib/JawnOS/Domain/Loader.pm");
	while ($text =~ /'(JawnOS::Domain::[A-Za-z0-9_]+)'\s*for\s+qw\(([^)]*)\)/g) {
		my ($module, $names) = ($1, $2);
		my $file = join('/', "$root/lib", split /::/, $module) . '.pm';
		next unless -f $file;
		$domain_file{$_} = $file for split ' ', $names;
	}
}

# --- the lookup -------------------------------------------------------------

my $found = 0;
for my $raw (@ARGV) {
	my ($name, $hint) = normalize($raw);
	unless (defined $name && length $name) {
		warn "where: '$raw' is not a name\n";
		next;
	}
	$found += lookup($raw, $name, $hint);
}
exit($found ? 0 : 1);

# --- subs -------------------------------------------------------------------

sub lookup {
	my ($raw, $name, $hint) = @_;

	return route_path($raw) if $raw =~ m{^/};
	return route_action($name) if $name =~ /^action_\d+$/;

	my @order = $hint && $hint eq 'domain' ? qw(domain manager) : qw(manager domain);
	for my $which (@order) {
		if ($which eq 'manager' && exists $helper_part{$name}) {
			return emit($name, 'Manager', $helper_part{$name});
		}
		if ($which eq 'domain' && exists $domain_file{$name}) {
			return emit($name, 'subs', $domain_file{$name});
		}
	}

	# Neither map knows it: look for the sub itself, then for a mention.
	for my $file (@manager_files, @domain_files) {
		my $line = find_sub($file, $name);
		return emit($name, undef, $file, $line) if $line;
	}

	my $hits = 0;
	for my $file (@manager_files, @domain_files, @controller_files, @route_files) {
		my $text = slurp($file) // next;
		my $n    = 0;
		for my $line (split /\n/, $text, -1) {
			$n++;
			next unless $line =~ /(?<![\w:])\Q$name\E(?!\w)/;
			print '  ', rel($file), ":$n\n";
			last if ++$hits >= $limit;
		}
		last if $hits >= $limit;
	}
	warn "where: no $name in the tree (maps, subs, references)\n" unless $hits;
	return $hits;
}

# Print a located sub. $map_file is what the name map claimed, when it claimed
# anything; a map file that does not define the sub is drift, and the real
# location is what gets printed.
sub emit {
	my ($name, $package, $map_file, $line) = @_;
	my $label = $package ? "$package\::$name" : $name;

	$line //= find_sub($map_file, $name);
	if ($line) {
		print $terse ? rel($map_file) . ":$line\n" : "$label\t" . rel($map_file) . ":$line\n";
		print_context($map_file, $line) if $context && !$terse;
		return 1;
	}

	for my $other (@manager_files, @domain_files) {
		next if $other eq $map_file;
		my $at = find_sub($other, $name) or next;
		print $terse ? rel($other) . ":$at\n" : "$label\t" . rel($other) . ":$at\n";
		print '  map drift: ', rel($map_file), " does not define $name\n" unless $terse;
		print_context($other, $at) if $context && !$terse;
		return 1;
	}

	print "$label\t", rel($map_file), " (no sub there)\n";
	return 0;
}

sub route_action {
	my ($action) = @_;
	my $hits = 0;

	for my $file (@controller_files) {
		my $line = find_sub($file, $action) or next;
		print $terse ? rel($file) . ":$line\n" : "Manager\::$action\t" . rel($file) . ":$line\n";
		$hits++;
		last;
	}

	for my $file (@route_files) {
		my $text = slurp($file) // next;
		my $n    = 0;
		for my $row (split /\n/, $text, -1) {
			$n++;
			next unless $row =~ /\b\Q$action\E\b/ && $row =~ /^\s*\[\s*\d+\s*,/;
			print '  route	', rel($file), ":$n	", route_row($row), "\n";
			$hits++;
		}
	}

	warn "where: no route action $action\n" unless $hits;
	return $hits;
}

sub route_path {
	my ($path) = @_;
	my $hits = 0;

	for my $file (@route_files) {
		my $text = slurp($file) // next;
		my $n    = 0;
		for my $row (split /\n/, $text, -1) {
			$n++;
			my ($method, $p, $action) =
				$row =~ /\[\s*\d+\s*,\s*'(\w+)'\s*,\s*'([^']*)'\s*,\s*'(\w+)'\s*\]/ or next;
			next unless $p eq $path;
			print 'route	', rel($file), ":$n	$method $p -> $action\n";
			$hits++;

			for my $controller (@controller_files) {
				my $line = find_sub($controller, $action) or next;
				print '  action	', rel($controller), ":$line\n";
				last;
			}
		}
	}

	warn "where: no route for $path\n" unless $hits;
	return $hits;
}

sub route_row {
	my ($row) = @_;
	return "$1 $2 -> $3"
		if $row =~ /\[\s*\d+\s*,\s*'(\w+)'\s*,\s*'([^']*)'\s*,\s*'(\w+)'\s*\]/;
	my $trimmed = $row;
	$trimmed =~ s/^\s+|\s+$//g;
	return $trimmed;
}

# 'subs::path_name', 'Manager::foo' and a bare name all reach the same lookup;
# the prefix only decides which map is asked first.
sub normalize {
	my ($raw) = @_;
	my $name = $raw;
	$name =~ s/^\s+|\s+$//g;
	$name =~ s/\(\s*\)$//;
	$name =~ s/^sub\s+//;
	$name =~ s/\s.*$//s;
	my $hint;
	if    ($name =~ /^subs::(.+)$/)            { $name = $1; $hint = 'domain' }
	elsif ($name =~ /^(?:Manager|main)::(.+)$/) { $name = $1; $hint = 'manager' }
	return ($name, $hint);
}

sub find_sub {
	my ($file, $name) = @_;
	my $text = slurp($file) or return;
	my $n    = 0;
	for my $line (split /\n/, $text, -1) {
		$n++;
		return $n if $line =~ /^\s*sub\s+\Q$name\E\b/;
	}
	return;
}

sub print_context {
	my ($file, $line) = @_;
	my $text = slurp($file) or return;
	my @lines = split /\n/, $text, -1;
	for my $i ($line + 1 .. $line + $context) {
		last unless defined $lines[$i];
		print "  $lines[$i]\n";
	}
}

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or return;
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

sub rel {
	my ($path) = @_;
	my $prefix = $root;
	$prefix =~ s{/+$}{};
	$path =~ s{^\Q$prefix\E/+}{};
	return $path;
}

sub usage {
	my ($code) = @_;
	my $fh = $code ? \*STDERR : \*STDOUT;
	print $fh <<'TXT';
usage: perl scripts/where.pl [--context N] [--limit N] [--terse] [--root DIR] NAME...

  NAME   a Manager helper (app_release_sync), a domain sub (subs::path_name or
         path_name), a route action (action_7408), or a route path
         (/manager/pen). Several names may be given.

Prints file:line for each. A name the maps do not know is searched for as a
sub, then as a mention (at most --limit lines). --context N adds N lines after
a located sub, --terse prints only file:line. Exits 0 if anything was found.
TXT
	exit $code;
}
