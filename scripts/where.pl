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
#   perl scripts/where.pl --outline lib/JawnOS/Domain/Coding.pm   # its symbols
#
# The maps are read, never loaded: lib/JawnOS/Manager/Index.pm is %SUB (helper
# -> part) and lib/JawnOS/Domain/Loader.pm is %DOMAIN_MODULE (sub -> module).
# Routes are read from lib/JawnOS/Routes/*.pm and help topics from
# perl/help/topics_*.pl, so nothing boots the app. A name neither map knows is
# searched for as a sub across the parts, the domain modules, perl/ and scripts/,
# then as a help topic, then as a declaration in a controller, a JavaScript file
# or a firmware sketch (jp/, jw/, jt/), then as a mention that prints the matching
# line itself (capped by --limit). A single JavaScript or firmware declaration
# arrives with its body (--body), because a location still costs a second read.
# When a map names a file that does not define the sub, the hit prints where it
# really is and says the map drifted - that is the audit, for free.
#
# Every lookup is recorded in the where_calls table (a hit or a miss, the minute
# and the machine), so Configure -> System can show the locator's hit rate beside
# the cost ledger. --no-log skips the row.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Find qw(find);
use FindBin ();
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);
use Sys::Hostname qw(hostname);

my $real_root  = abs_path("$FindBin::Bin/..");
my $root       = $real_root;
my $context    = 0;
my $limit      = 8;
my $terse      = 0;
my $body_flag;
my $body_lines;
my $body_chars;
my $outline    = 0;
my $log_flag;
my $report_name;
my $report_at;
my $report_found;
my $report_note;
my $tech_name;
my $list_topics = 0;
my $help       = 0;

GetOptions(
	'context=i'    => \$context,
	'limit=i'      => \$limit,
	'terse'        => \$terse,
	'body!'        => \$body_flag,
	'body-lines=i' => \$body_lines,
	'body-chars=i' => \$body_chars,
	'outline'      => \$outline,
	'log!'         => \$log_flag,
	'report=s'     => \$report_name,
	'at=s'         => \$report_at,
	'found=s'      => \$report_found,
	'note=s'       => \$report_note,
	'tech=s'       => \$tech_name,
	'topics'       => \$list_topics,
	'root=s'       => \$root,
	'help'         => \$help,
) or usage(2);

$body_flag = 1 if defined $body_lines && !defined $body_flag;
$body_lines = 16 unless defined $body_lines;
$body_lines = 0 if $body_lines < 0;
$body_chars = 2000 unless defined $body_chars;
$body_chars = 0 if $body_chars < 0;

# Every lookup is evidence: a hit says the locator answered without a read, a
# miss says the agent is about to grep. The row rides the same sync as the cost
# ledger, so Configure -> System can show both. A fixture tree (--root) never
# writes to the real database, and --no-log turns it off for a curious call.
my $log_enabled = (!defined $log_flag || $log_flag)
	&& $root eq $real_root
	&& !$ENV{'JAWNOS_WHERE_LOG_OFF'};

usage(0) if $help;
usage(2) unless defined $root && length $root && -d $root;

# An agent that acted on a hit can tell us whether it was the right one. This is
# a write, not a lookup: it records the verdict against the latest call for the
# same name and exits, so a report never grows the lookup counts.
if (defined $report_name) {
	usage(2) unless length $report_name;
	my $verdict = shift @ARGV // '';
	$verdict = lc $verdict;
	usage(2) unless $verdict eq 'right' || $verdict eq 'wrong';
	exit(report_feedback($report_name, $verdict, $report_at, $report_found, $report_note) ? 0 : 2);
}

# The second tier of help is a whole brief, not a location: hand it to the script
# that generates it rather than growing a second copy of that logic here.
if (defined $tech_name) {
	usage(2) unless length $tech_name;
	exec($^X, "$root/scripts/agent_help.pl", $tech_name)
		or die "where: cannot run scripts/agent_help.pl: $!\n";
}

usage(2) unless $list_topics || @ARGV;

my @manager_files = grep { -f $_ } map { glob "$root/lib/JawnOS/Manager/$_" }
	qw(Manager.pm Core1_tables_hooks.pm Core2_worker_boot.pm Part*.pm);
my @domain_files     = grep { -f $_ } glob "$root/lib/JawnOS/Domain/*.pm";
my @controller_files = grep { -f $_ } glob "$root/lib/JawnOS/Controller/*.pm";
my @route_files      = grep { -f $_ } glob "$root/lib/JawnOS/Routes/*.pm";

# --- source groups the locator can search -----------------------------------
#
# The name maps cover lib/ only. The app's JavaScript, the templates and the
# three firmware trees (jp alarm clock, jw watch, jt panel) are scanned here so
# a name that lives outside lib/ is still one command away. Generated trees are
# pruned, never read: .pio/build and __pycache__ are build output, and the
# firmware's generated model/font headers are bigger than any hand-written
# source, so a size cap keeps them out without a name blacklist to maintain.
my @js_files = source_files(
	dirs       => ['public/js'],
	ext        => [qw(js)],
	skip_names => qr/^(?:jquery|jquery-ui|moment)\.js$/,
);
my @template_files = source_files(
	dirs => ['templates'],
	ext  => [qw(ep)],
);
my @embedded_files = source_files(
	dirs      => [qw(jp jw jt)],
	ext       => [qw(ino cpp cc c h hpp py)],
	max_bytes => 131072,
);

# perl/ and scripts/ sit outside every name map, so a name defined in help.pl or
# a CLI script used to fall through to "no X in the tree". Tests belong here too:
# a helper that only exists in t/ is still a real location.
my %mapped = map { $_ => 1 } (@manager_files, @domain_files, @controller_files, @route_files);
my @perl_extra_files = sort grep { !$mapped{$_} } (
	source_files(dirs => [qw(perl scripts t)], ext => [qw(pl pm t)]),
	grep { -f $_ } ("$root/lib/JawnOS.pm", glob("$root/lib/JawnOS/*.pm")),
);
# A test file is a place a sub can be declared, but its fixture strings are not
# evidence a name exists: mention-search would find the test's own 'no such name'
# probe and call it a hit. Definitions in t/ stay in scope.
my @perl_extra_mention = grep { $_ !~ m{/t/[^/]+\.t\z} } @perl_extra_files;

sub source_files {
	my (%spec) = @_;
	my %ext    = map { $_ => 1 } @{ $spec{'ext'} };
	my $skip   = $spec{'skip_names'};
	my $max    = $spec{'max_bytes'};
	my @out;

	for my $dir (@{ $spec{'dirs'} }) {
		my $base = "$root/$dir";
		next unless -d $base;
		find({
			no_chdir => 1,
			wanted   => sub {
				my $path = $File::Find::name;
				if (-d $path) {
					$File::Find::prune = 1
						if $path =~ m{/(?:\.pio|build|__pycache__|node_modules)(?:/|\z)};
					return;
				}
				return unless -f $path;
				my ($name) = $path =~ m{([^/]+)\z};
				return if $skip && $name =~ $skip;
				my ($ext) = $name =~ /\.([^.]+)\z/ or return;
				return unless $ext{ lc $ext };
				return if $max && -s $path > $max;
				push @out, $path;
			},
		}, $base);
	}

	return sort @out;
}

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

if ($outline) {
	my $ok = 0;
	for my $raw (@ARGV) {
		my $abs = $raw =~ m{^/} ? $raw : "$root/$raw";
		unless (-f $abs) {
			warn "where: no file $raw\n";
			next;
		}
		print "$raw\n" if @ARGV > 1;
		for my $symbol ( outline_symbols($abs) ) {
			print $symbol->[0], "\t", $symbol->[1], ' ', $symbol->[2], "\n";
		}
		$ok = 1;
	}
	exit($ok ? 0 : 1);
}

my $found = 0;
for my $raw (@ARGV) {
	my ($name, $hint) = normalize($raw);
	unless (defined $name && length $name) {
		warn "where: '$raw' is not a name\n";
		next;
	}
	my $hits = lookup($raw, $name, $hint);
	where_log($name, $hits);
	$found += $hits;
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

	# Neither map knows it: look for the declaration itself, then for a help
	# topic that answers to the name, then for a mention.
	#
	# Perl first, because the two maps only cover lib/ and a part is still the
	# most likely home. A help topic keeps its priority over a same-named JS
	# function, the way help() resolves it. Then the declaration in a controller,
	# the app's JavaScript or a firmware sketch.
	for my $file (@manager_files, @domain_files) {
		my $line = find_sub($file, $name);
		return emit($name, undef, $file, $line) if $line;
	}

	my $topic = topic_lookup($name);
	return $topic if $topic;

	my @decl;
	for my $file (@controller_files, @perl_extra_files, @js_files, @embedded_files) {
		my $line = find_definition($file, $name) or next;
		push @decl, [ $file, $line ];
		last if @decl >= $limit;
	}

	# A plain `const NAME = value` is a declaration, but a local variable of a
	# name that a real function also has is not the answer, so weak hits wait
	# until nothing stronger matched.
	if (!@decl) {
		for my $file (@js_files) {
			my $line = find_definition($file, $name, 'weak') or next;
			push @decl, [ $file, $line ];
			last if @decl >= $limit;
		}
	}

	if (@decl) {
		# One declaration in a language with no package is the common case, and
		# its body is the answer: print it without a second read. Several hits
		# are a choice, so locations alone keep the output small.
		my $auto = @decl == 1 && !is_perl($decl[0][0]);
		print_declaration($name, $_->[0], $_->[1], $auto) for @decl;
		return scalar @decl;
	}

	# Nothing declares it: show the lines that mention it, with their text. A
	# bare file:line cannot be judged without opening the file - the cost this
	# script exists to avoid - so a mention prints grep's matching line too.
	my $hits = 0;
	for my $file (@manager_files, @domain_files, @controller_files, @route_files,
		@perl_extra_mention, @js_files, @template_files, @embedded_files)
	{
		my $text = slurp($file) // next;
		my $n    = 0;
		for my $line (split /\n/, $text, -1) {
			$n++;
			next unless $line =~ /(?<![\w:])\Q$name\E(?!\w)/;
			print '  ', rel($file), ":$n:", mention_text($line), "\n";
			last if ++$hits >= $limit;
		}
		last if $hits >= $limit;
	}
	warn "where: no $name in the tree (maps, subs, declarations, references)\n" unless $hits;
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
		print_extra($map_file, $line);
		return 1;
	}

	for my $other (@manager_files, @domain_files) {
		next if $other eq $map_file;
		my $at = find_sub($other, $name) or next;
		print $terse ? rel($other) . ":$at\n" : "$label\t" . rel($other) . ":$at\n";
		print '  map drift: ', rel($map_file), " does not define $name\n" unless $terse;
		print_extra($other, $at);
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

# A declaration, not a mention. Each language answers in its own syntax, so a
# JS function, an Arduino sketch function and a Perl sub are all findable. The
# extension decides how the line is read.
sub find_definition {
	my ($file, $name, $weak) = @_;
	my $text = slurp($file) or return;
	my $n    = 0;
	for my $line (split /\n/, $text, -1) {
		$n++;
		return $n if $weak
			? is_weak_definition($file, $line, $name)
			: is_definition($file, $line, $name);
	}
	return;
}

sub is_definition {
	my ($file, $line, $name) = @_;
	my ($ext) = $file =~ /\.([^.]+)\z/;
	$ext = lc($ext // '');
	my $n = quotemeta $name;

	if ($ext eq 'pm' || $ext eq 'pl' || $ext eq 't') {
		return $line =~ /^\s*sub\s+$n\b/;
	}
	if ($ext eq 'js') {
		return 1 if $line =~ /\bfunction\s+$n\s*\(/;
		return 1 if $line =~ /\bclass\s+$n\b/;
		# A value assigned a function is a definition; a plain value is weak.
		return 1 if $line =~ /\b(?:const|let|var)\s+$n\s*=\s*(?:async\s+)?(?:function\b|\()/;
		return $line =~ /^\s*$n\s*[:=]\s*(?:async\s+)?(?:function\b|\()/;
	}
	if ($ext eq 'py') {
		return $line =~ /^\s*(?:def|class)\s+$n\b/;
	}
	if ($ext eq 'ino' || $ext eq 'c' || $ext eq 'cpp' || $ext eq 'cc'
		|| $ext eq 'h' || $ext eq 'hpp')
	{
		return 1 if $line =~ /^\s*#\s*define\s+$n\b/;
		return 1 if $line =~ /^\s*(?:class|struct|enum|namespace)\s+$n\b/;
		# A definition starts with a return type. The keywords are excluded
		# because "return foo(" and "if (foo(" fit the shape; a prototype ends
		# in ';' and is not a definition.
		return $line =~ /^\s*(?!if\b|for\b|while\b|switch\b|return\b|else\b|case\b|do\b)
			(?:[\w:<>*&\[\]]+\s+)+[*&]?\s*$n\s*\([^;]*\)\s*(?:const\s*)?(?:\{|\z)/x;
	}
	return 0;
}

# Print one located declaration. The package label is omitted for a language
# with no package; --context wins over --body, and --terse prints no code.
sub print_declaration {
	my ($name, $file, $line, $auto) = @_;
	print $terse ? rel($file) . ":$line\n" : "$name\t" . rel($file) . ":$line\n";
	return if $terse;
	if ($context) {
		print_context($file, $line);
		return;
	}
	my $want = defined $body_flag ? $body_flag : $auto;
	print_body($file, $line, $body_lines) if $want;
}

# A map hit is Perl: its body is opt-in, because reading a part is exactly what
# the map exists to avoid. --body still asks for it explicitly.
sub print_extra {
	my ($file, $line) = @_;
	return if $terse;
	if ($context) {
		print_context($file, $line);
		return;
	}
	print_body($file, $line, $body_lines) if $body_flag;
}

sub is_perl {
	my ($file) = @_;
	return $file =~ /\.(?:p[lm]|t)\z/;
}

# Print the declaration's body, stopping at its closing brace (or the dedent
# that ends a Python def) and capped at $max following lines. A short function
# arrives whole, so a second read is not needed.
sub print_body {
	my ($file, $line, $max) = @_;
	return unless $max && $max > 0;
	my $text = slurp($file) or return;
	my @lines = split /\n/, $text, -1;
	return unless $line >= 1 && $line <= @lines;

	my ($ext) = $file =~ /\.([^.]+)\z/;
	$ext = lc($ext // '');
	my ($after, $more) = $ext eq 'py'
		? python_body(\@lines, $line, $max)
		: brace_body(\@lines, $line, $max);

	# Blank lines and shared indentation are tokens that buy nothing, and a body
	# of long string literals can pass a line cap without passing a useful size.
	# Strip both, then stop at the character budget as well as the line cap.
	my @body = grep { defined && /\S/ } @lines[ $line .. $line + $after - 1 ];
	my $cut;
	for my $text (@body) {
		my $w = indent_width($text);
		$cut = $w if !defined $cut || $w < $cut;
	}
	$cut = 0 unless defined $cut;

	my $spent = 0;
	for my $text (@body) {
		my $shown = $cut ? substr($text, $cut) : $text;
		$shown =~ s/\s+\z//;
		if ($body_chars && $spent + length($shown) + 1 > $body_chars) {
			$more = 1;
			last;
		}
		print "  $shown\n";
		$spent += length($shown) + 1;
	}
	print "  ...\n" if $more;
}

# Braces, not a parser: depth returns to zero at the closing line, and the cap
# bounds a miscount. A declaration that never opens a brace (a #define, a
# one-line arrow) has no body to print.
sub brace_body {
	my ($lines, $line, $max) = @_;
	my $first = $lines->[ $line - 1 ] // '';
	return (0, 0) if $first =~ /^\s*#/;
	return (0, 0) if $first =~ /;\s*\z/ && $first !~ /\{/;

	my $depth  = 0;
	my $opened = 0;
	my $count  = 0;

	for my $i ($line - 1 .. $#{$lines}) {
		my $delta = brace_delta($lines->[$i]);
		$depth += $delta;
		$opened = 1 if $delta > 0;

		if ($i == $line - 1) {
			return (0, 0) if $opened && $depth <= 0;
			next;
		}

		$count++;
		return ($count, 0) if $opened && $depth <= 0;
		return ($count, 1) if $count >= $max;
		return ($count, 0) if !$opened && $count >= 5;
	}

	return ($count, 0);
}

sub python_body {
	my ($lines, $line, $max) = @_;
	my $indent = indent_width($lines->[ $line - 1 ] // '');
	my $count  = 0;

	for my $i ($line .. $#{$lines}) {
		my $text = $lines->[$i];
		next if $text =~ /^\s*\z/;
		last if indent_width($text) <= $indent;
		$count++;
		next if $count < $max;

		# Only say "more" when the body really continues past the cap.
		for my $j ($i + 1 .. $#{$lines}) {
			next if $lines->[$j] =~ /^\s*\z/;
			return ($count, indent_width($lines->[$j]) > $indent ? 1 : 0);
		}
		return ($count, 0);
	}

	return ($count, 0);
}

sub indent_width {
	my ($text) = @_;
	my ($ws) = $text =~ /^([ \t]*)/;
	return length $ws;
}

# The braces on one line, ignoring those inside a string, a line comment or a
# single-line block comment. Block comments that span lines are not tracked; a
# brace inside one is rare, and the cap stops a miscount from printing the
# whole file.
sub brace_delta {
	my ($line) = @_;
	return 0 if $line =~ /^\s*#/;
	$line =~ s{/\*.*?\*/}{}g;

	my $delta = 0;
	my $quote;
	for (my $i = 0; $i < length $line; $i++) {
		my $c = substr($line, $i, 1);
		if (defined $quote) {
			if ($c eq '\\') { $i++; next }
			$quote = undef if $c eq $quote;
			next;
		}
		last if $c eq '/' && substr($line, $i + 1, 1) eq '/';
		if ($c eq q{"} || $c eq q{'} || $c eq q{`}) { $quote = $c; next }
		$delta++ if $c eq '{';
		$delta-- if $c eq '}';
	}
	return $delta;
}

# Weak declarations: `const NAME = value`. Reported only when no function,
# class, sub or sketch symbol of that name exists.
sub is_weak_definition {
	my ($file, $line, $name) = @_;
	my ($ext) = $file =~ /\.([^.]+)\z/;
	return 0 unless lc($ext // '') eq 'js';
	my $n = quotemeta $name;
	return $line =~ /\b(?:const|let|var)\s+$n\s*=/;
}

# grep's matching line, trimmed. A mention line can be a 700-character qw(...)
# row; the point is enough text to judge the hit, not the whole row.
sub mention_text {
	my ($line) = @_;
	$line =~ s/\A\s+//;
	$line =~ s/\s+\z//;
	if (length($line) > 200) {
		$line = substr($line, 0, 200);
		$line =~ s/[\x80-\xBF]+\z//;
		$line =~ s/[\xC0-\xFD]\z//;
		$line .= '...';
	}
	return " $line";
}

# One row per name the locator was asked about. A miss is the row that matters:
# it is the lookup that sends an agent back to grep, so the panel can show the
# rate rather than guess it. Guarded end to end - a database problem must never
# take a lookup down, and a pre-migration install records nothing.
sub where_log {
	my ($name, $hits) = @_;
	return 0 unless $log_enabled && defined $name && length $name;
	my $db = $ENV{'JAWNOS_WHERE_DB'} || "$root/database/jawnos.db";
	return 0 unless -f $db;
	my $ok = eval {
		require DBI;
		my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
			RaiseError => 0, PrintError => 0, AutoCommit => 1,
			sqlite_busy_timeout => 2000,
		}) or die "connect\n";
		my $now    = time() * 1000;
		my $minute = strftime('%Y-%m-%d %H:%M', localtime);
		my $uuid   = sprintf('%d-%d-%d', time, $$, int(rand(1_000_000)));
		my $safe   = $name;
		$safe =~ s/[\x00-\x1f]+/ /g;
		$safe = substr($safe, 0, 200);
		$dbh->do(
			'insert into where_calls (uuid, machine, minute, name, hit, hits, ost, server_time) values (?,?,?,?,?,?,?,?)',
			undef, $uuid, hostname(), $minute, $safe, ($hits ? 1 : 0), ($hits || 0), $now, $now,
		);
		$dbh->disconnect;
		1;
	};
	return $ok ? 1 : 0;
}

# Every declaration in a file, in line order, so an agent can read a range
# instead of the whole file. The same shapes the locator finds by name; here the
# name is read off the line rather than searched for.
# An agent's verdict on a lookup it acted on. The latest call for the same name
# on this machine is linked when it is recent; the verdict is still recorded
# without one, because a report is worth more than a missing join. A wrong one
# should carry --found, the place the agent actually found the name.
sub report_feedback {
	my ($name, $verdict, $at, $found, $note) = @_;
	my $db = $ENV{'JAWNOS_WHERE_DB'} || "$root/database/jawnos.db";
	unless (-f $db) {
		warn "where: no database at $db\n";
		return 0;
	}
	my $ok = eval {
		require DBI;
		my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
			RaiseError => 0, PrintError => 0, AutoCommit => 1,
			sqlite_busy_timeout => 2000,
		}) or die "connect\n";
		my $now    = time() * 1000;
		my $minute = strftime('%Y-%m-%d %H:%M', localtime);
		my $since  = strftime('%Y-%m-%d %H:%M', localtime(time - 6 * 3600));
		my ($call) = $dbh->selectrow_array(
			'select uuid from where_calls where machine = ? and name = ? and minute >= ? order by server_time desc limit 1',
			undef, hostname(), $name, $since);
		my $uuid = sprintf('%d-%d-%d', time, $$, int(rand(1_000_000)));
		$at    = substr($at, 0, 500)    if defined $at;
		$found = substr($found, 0, 500) if defined $found;
		$note  = substr($note, 0, 500)  if defined $note;
		$dbh->do(
			'insert into where_feedback (uuid, call_uuid, machine, minute, name, verdict, selected, found, note, ost, server_time) values (?,?,?,?,?,?,?,?,?,?,?)',
			undef, $uuid, $call, hostname(), $minute, substr($name, 0, 200), $verdict, $at, $found, $note, $now, $now,
		);
		$dbh->disconnect;
		1;
	};
	unless ($ok) {
		warn "where: could not record the report (is the migration applied?)\n";
		return 0;
	}
	print 'reported ', $name, ' ', $verdict,
		(defined $at && length $at ? " at $at" : ''),
		(defined $found && length $found ? " -> $found" : ''), "\n";
	return 1;
}

sub outline_symbols {
	my ($file) = @_;
	my $text = slurp($file) or return;
	my ($ext) = $file =~ /\.([^.]+)\z/;
	$ext = lc($ext // '');
	my @out;
	my $n = 0;
	for my $line (split /\n/, $text, -1) {
		$n++;
		my $symbol = outline_symbol($ext, $line) or next;
		push @out, [ $n, $symbol->[0], $symbol->[1] ];
	}
	return @out;
}

sub outline_symbol {
	my ($ext, $line) = @_;
	if ($ext eq 'pm' || $ext eq 'pl' || $ext eq 't') {
		return [ 'sub', $1 ] if $line =~ /^\s*sub\s+([A-Za-z_]\w*)\b/;
		return;
	}
	if ($ext eq 'js') {
		return [ 'function', $1 ] if $line =~ /\bfunction\s+([A-Za-z_$][\w$]*)\s*\(/;
		return [ 'class', $1 ] if $line =~ /\bclass\s+([A-Za-z_$][\w$]*)\b/;
		return [ 'const', $1 ] if $line =~ /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|\()/;
		return [ 'method', $1 ] if $line =~ /^\s*([A-Za-z_$][\w$]*)\s*[:=]\s*(?:async\s+)?(?:function\b|\()/;
		return;
	}
	if ($ext eq 'py') {
		return [ 'def', $1 ] if $line =~ /^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\b/;
		return [ 'class', $1 ] if $line =~ /^\s*class\s+([A-Za-z_]\w*)\b/;
		return;
	}
	if ($ext eq 'ino' || $ext eq 'c' || $ext eq 'cpp' || $ext eq 'cc'
		|| $ext eq 'h' || $ext eq 'hpp')
	{
		return [ 'define', $1 ] if $line =~ /^\s*#\s*define\s+([A-Za-z_]\w*)\b/;
		if ($line =~ /^\s*(class|struct|enum|namespace)\s+([A-Za-z_]\w*)\b/) {
			return [ $1, $2 ];
		}
		return [ 'function', $1 ] if $line =~ /^\s*(?!if\b|for\b|while\b|switch\b|return\b|else\b|case\b|do\b)
			(?:[\w:<>*&\[\]]+\s+)+[*&]?\s*([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const\s*)?(?:\{|\z)/x;
		return;
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
usage: perl scripts/where.pl [options] NAME... | --outline FILE...

  NAME   a Manager helper (app_release_sync), a domain sub (subs::path_name or
         path_name), a route action (action_7408), a route path (/manager/pen),
         a function in perl/ or scripts/, a help topic (budget), or a file
         (templates/apps/gallery.html.ep, which reports the help topics
         covering it). Several names may be given.

Prints file:line for each. A name the maps do not know is searched for as a
sub in lib/, perl/ or scripts/, then as a help topic, then as a declaration in a
controller, a JavaScript file or a firmware sketch (jp/, jw/, jt/), then as a
mention: file:line plus the matching line, at most --limit lines. --context N
adds N lines after any hit, --terse prints only file:line, --topics lists every
help topic with the line it is defined on. Exits 0 if anything was found.

  --body        print the declaration and its body, stopping at the closing
                brace (or the dedent of a Python def), at most --body-lines
                (default 16) following lines. On by default when exactly one
                JavaScript or firmware declaration matches; --no-body stops it.
  --body-lines N  the cap for --body (implies --body).
  --body-chars N  the character cap for --body (default 2000; 0 is no cap).
  --context N   the plain N-line form; it wins over --body when both are given.
  --outline     for each FILE, print "line<TAB>kind name" for every declaration
                in it, so an agent can read a range instead of the whole file.
  --no-log      do not record this lookup in database/jawnos.db.
  --report NAME right|wrong [--at LOC] [--found LOC] [--note TEXT]
                record an agent's verdict on a hit it acted on; --at is the hit
                it used, and --found the real location when that hit was wrong.
                This is the signal that scripts/where_audit.pl learns from.

  --tech NAME  the tier-2 technical brief for an app or topic (routes, tables,
               settings, tests, source notes) - same as scripts/agent_help.pl
TXT
	exit $code;
}
