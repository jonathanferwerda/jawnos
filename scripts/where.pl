#!/usr/bin/perl

# Where does a name live? One line, instead of reading Index.pm (611 lines of
# names) or grepping nine part files to find one function.
#
#   perl scripts/where.pl app_release_sync
#   perl scripts/where.pl subs::path_name manager_misc10 action_7408
#   perl scripts/where.pl /js/manager/app.js
#   perl scripts/where.pl budget                     # a help topic
#   perl scripts/where.pl templates/apps/gallery.html.ep   # which topic covers it
#   perl scripts/where.pl --topics                   # the whole help registry
#   perl scripts/where.pl --context 6 guide_find_target
#   perl scripts/where.pl --terse path_name
#
# The maps are read, never loaded: lib/JawnOS/Manager/Index.pm is %SUB (helper
# -> part) and lib/JawnOS/Domain/Loader.pm is %DOMAIN_MODULE (sub -> module).
# Routes are read from lib/JawnOS/Routes/*.pm and help topics from
# perl/help/topics_*.pl, so nothing boots the app. A name neither map knows is
# searched for as a sub across the parts and the domain modules, then as a help
# topic, then as a bare reference (capped by --limit). When a map names a file
# that does not define the sub, the hit prints where it really is and says the
# map drifted - that is the audit, for free.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin ();
use Getopt::Long qw(GetOptions);

my $root       = abs_path("$FindBin::Bin/..");
my $context    = 0;
my $limit      = 8;
my $terse      = 0;
my $list_topics = 0;
my $help       = 0;

GetOptions(
	'context=i' => \$context,
	'limit=i'   => \$limit,
	'terse'     => \$terse,
	'topics'    => \$list_topics,
	'root=s'    => \$root,
	'help'      => \$help,
) or usage(2);

usage(0) if $help;
usage(2) unless defined $root && length $root && -d $root;
usage(2) unless $list_topics || @ARGV;

my @manager_files = grep { -f $_ } map { glob "$root/lib/JawnOS/Manager/$_" }
	qw(Manager.pm Core1_tables_hooks.pm Core2_worker_boot.pm Part*.pm);
my @domain_files     = grep { -f $_ } glob "$root/lib/JawnOS/Domain/*.pm";
my @controller_files = grep { -f $_ } glob "$root/lib/JawnOS/Controller/*.pm";
my @route_files      = grep { -f $_ } glob "$root/lib/JawnOS/Routes/*.pm";

my $topics_cache;

if ($list_topics) {
	for my $t (@{ topics() }) {
		print 'help::', $t->{'id'}, "\t", rel($t->{'file'}), ':', $t->{'line'}, "\n";
	}
	exit 0;
}

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

	# A file is looked up before a route path, so an absolute path to a template
	# is not mistaken for the route that serves it. A route path that is also a
	# real file under the root would win, which the route table does not do.
	my $candidate = $raw =~ m{^/} ? $raw : "$root/$raw";
	if ($raw =~ m{/} && -f $candidate) {
		my $hits = file_lookup($raw);
		return $hits if $hits;
		# A real file with no topic is a coverage gap, not a miss: say so.
		my $rel = $raw;
		my $prefix = $root;
		$prefix =~ s{/+$}{};
		$rel =~ s{^\Q$prefix\E/+}{};
		print "$rel\t(no help topic names this file)\n";
		return 1;
	}

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

	# Neither map knows it: look for the sub itself, then for a help topic that
	# answers to the name, then for a mention.
	for my $file (@manager_files, @domain_files) {
		my $line = find_sub($file, $name);
		return emit($name, undef, $file, $line) if $line;
	}

	my $topic = topic_lookup($name);
	return $topic if $topic;

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

# --- the help registry ------------------------------------------------------
#
# perl/help/topics_*.pl holds one `$topic{'id'} = { ... }` per topic. The registry
# is not loaded here (that would boot the app's help code); the entries are read
# the same way Index.pm is, so a lookup costs one file read and no boot.

sub topics {
	return $topics_cache if $topics_cache;
	my @out;
	for my $file (sort grep { -f $_ } glob "$root/perl/help/topics_*.pl") {
		my $text = slurp($file) // next;
		my @lines = split /\n/, $text, -1;
		my @starts;
		for my $i (0 .. $#lines) {
			push @starts, $i if $lines[$i] =~ /^\$topic\{'([A-Za-z0-9_]+)'\}\s*=\s*\{/;
		}
		for my $s (0 .. $#starts) {
			my $from = $starts[$s];
			my $to   = $s < $#starts ? $starts[ $s + 1 ] - 1 : $#lines;
			my ($id) = $lines[$from] =~ /^\$topic\{'([A-Za-z0-9_]+)'\}/;
			my $chunk = join "\n", @lines[ $from .. $to ];
			my ($app) = $chunk =~ /\bapp\s*=>\s*'([^']+)'/;
			my ($list) = $chunk =~ /\btemplates\s*=>\s*\[(.*?)\]/s;
			my @templates = defined $list ? ($list =~ /'([^']+)'/g) : ();
			push @out, {
				'id' => $id, 'file' => $file, 'line' => $from + 1,
				'app' => $app, 'templates' => \@templates,
			};
		}
	}
	$topics_cache = \@out;
	return $topics_cache;
}

# A topic answers to its id the way help() answers: case-insensitive, with
# spaces or hyphens where the id has underscores.
sub topic_lookup {
	my ($name) = @_;
	my $want = lc $name;
	$want =~ s/[-\s]+/_/g;

	my @hits = grep { lc($_->{'id'}) eq $want } @{ topics() };
	@hits = grep { lc($_->{'id'}) =~ /\Q$want\E/ } @{ topics() } unless @hits;
	return 0 unless @hits;

	for my $t (@hits) {
		print 'help::', $t->{'id'}, "\t", rel($t->{'file'}), ':', $t->{'line'}, "\n";
		next if $terse;
		print "  app: $t->{'app'}\n" if defined $t->{'app'};
		for my $template (@{ $t->{'templates'} }) {
			print "  template: $template\n";
		}
	}
	return scalar @hits;
}

# A file's place in the tree: the help topics that name it, plus the topic that
# explains its app. The convention is help::inventory's - an app's page is
# templates/apps/<app>.html.ep, its script public/js/manager/<app>.js - so this
# answers for the 18 pages no topic lists by hand as well as the ones it does.
sub file_lookup {
	my ($raw) = @_;
	my $rel = $raw;
	my $prefix = $root;
	$prefix =~ s{/+$}{};
	$rel =~ s{^\Q$prefix\E/+}{};

	my @hits;
	for my $t (@{ topics() }) {
		next unless grep { $_ eq $rel } @{ $t->{'templates'} };
		push @hits, [ 'named by', $t ];
	}

	my ($app) = $rel =~ m{^templates/apps/([A-Za-z0-9_]+)\.html\.ep$};
	($app) = $rel =~ m{^public/js/manager/([A-Za-z0-9_]+)\.js$} unless defined $app;
	if (defined $app) {
		for my $t (@{ topics() }) {
			next unless defined $t->{'app'} && $t->{'app'} eq $app;
			push @hits, [ 'app', $t ];
		}
	}

	return 0 unless @hits;
	my %seen;
	for my $hit (@hits) {
		my ($kind, $t) = @$hit;
		next if $seen{ $t->{'id'} }++;
		print $kind eq 'named by' ? 'named by ' : 'app ',
			'help::', $t->{'id'}, "\t", rel($t->{'file'}), ':', $t->{'line'}, "\n";
	}
	return scalar @hits;
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
usage: perl scripts/where.pl [--context N] [--limit N] [--terse] [--topics] [--root DIR] NAME...

  NAME   a Manager helper (app_release_sync), a domain sub (subs::path_name or
         path_name), a route action (action_7408), a route path (/manager/pen),
         a help topic (budget), or a file (templates/apps/gallery.html.ep, which
         reports the help topics covering it). Several names may be given.

Prints file:line for each. A name the maps do not know is searched for as a
sub, then as a help topic, then as a mention (at most --limit lines).
--context N adds N lines after a located sub, --terse prints only file:line,
--topics lists every help topic with the line it is defined on. Exits 0 if
anything was found.
TXT
	exit $code;
}
