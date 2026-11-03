#!/usr/bin/perl

# Tier 2 help: the technical brief for one app or topic, derived from the tree.
#
# JawnOS has two tiers of help and they answer different questions:
#
#   tier 1  perl/help/topics_*.pl - hand-written prose for a person navigating
#           the program. Translated on demand, audited by t/11 and help_audit.pl.
#   tier 2  this script - facts about the code: which routes reach an app, which
#           tables and settings it touches, which tests claim its files, and what
#           its own header comments say. Read by agents, never translated.
#
# Tier 2 is generated, not written. A fact you can derive from the tree must not
# be maintained by hand, or it becomes a lie with a date on it; the rationale -
# why a thing is the way it is - stays where it belongs, in the source comments
# and docs/AGENTS-notes.md, and this brief surfaces the comments instead of
# restating them.
#
#   perl scripts/agent_help.pl budget              # the brief for one app/topic
#   perl scripts/agent_help.pl templates/apps/gallery.html.ep
#   perl scripts/agent_help.pl --list              # every name it can answer
#   perl scripts/agent_help.pl --index             # the compact repository index
#   perl scripts/agent_help.pl --write-index       # rewrite qa/coding_night/agent-index.md
#
# `perl scripts/where.pl <name>` says WHERE something is; this says WHAT it is
# and what depends on it.

package agent_help;

use strict;
use warnings;
no warnings 'once';

use Cwd qw(abs_path);
use FindBin ();
use File::Basename qw(basename dirname);

my $ROOT;
my $LOADED;

my %SCHEMA;        # table => { columns => [ [ name, type ], ... ], indexes => [ 'cols', ... ] }
my @ROUTES;        # { index, method, path, action, module, line }
my @TESTS;         # { file, globs => [ ... ], body => '...' }
my %TOPIC;         # id => the help topic entry
my %APP_PAGE;      # app page basename => 1 (templates/apps/<name>.html.ep)

sub root { $ROOT ||= abs_path("$FindBin::Bin/..") }

# ---- loading ---------------------------------------------------------------

# perl/help.pl resolves templates relative to the working directory, and the
# niggles of a require path are not worth a second mechanism: run from the root.
sub load {
	return if $LOADED;
	my $root = root();
	chdir $root or die "agent_help: cannot enter $root: $!\n";
	require './perl/help.pl';
	%TOPIC = %help::topic;
	%APP_PAGE = map { (my $b = $_) =~ s{.*/}{}; $b =~ s{\.html\.ep$}{}; $b => 1 }
		grep { -f } glob('templates/apps/*.html.ep');
	%SCHEMA = %{ _schema_tables() };
	@ROUTES = _routes();
	@TESTS  = _test_claims();
	$LOADED = 1;
	return;
}

# ---- the names this answers for -------------------------------------------

# A topic id, an app name, or an app page path. A topic's `app` is a second name
# for the same thing, so `budget` and `budget` (page and topic) collapse.
sub resolve_name {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	$name =~ s/^\s+|\s+$//g;
	$name =~ s{^\./}{};

	my $key = help::key($name);
	my $topic = $TOPIC{$key};
	return { name => $key, topic => $key, page => $topic->{'app'} } if $topic;

	# A page name on its own (`pen`, or `pen.html.ep`): the tier-2 entry exists
	# even though the tier-1 one does not, which is the point of two tiers.
	(my $bare = $name) =~ s{\.html\.ep$}{};
	if ($APP_PAGE{$bare}) {
		my $k = help::key($bare);
		return { name => $bare, page => $bare, ($TOPIC{$k} ? (topic => $k) : ()) };
	}

	if ($name =~ m{^(?:templates/)?apps?/([A-Za-z0-9_]+?)(?:\.html\.ep)?$}
		|| $name =~ m{^templates/([A-Za-z0-9_]+?)\.html\.ep$}) {
		my $app = $1;
		return { name => $app, page => $app }
			if $APP_PAGE{$app} || grep { ($TOPIC{$_}{'app'} || '') eq $app } keys %TOPIC;
	}

	# A topic that only exists as `app => <name>` (the page resolved by
	# convention) is addressable by that name too.
	for my $id (sort keys %TOPIC) {
		next unless ( $TOPIC{$id}{'app'} || '' ) eq $name;
		return { name => $name, topic => $id, page => $name };
	}

	return undef;
}

sub names {
	load();
	my %s;
	$s{ $_->{'app'} } = 1 for grep { $_->{'app'} } values %TOPIC;
	$s{$_} = 1 for keys %APP_PAGE;
	$s{$_} = 1 for keys %TOPIC;
	return sort grep { defined && length } keys %s;
}

# ---- derived facts ---------------------------------------------------------

sub _schema_tables {
	open my $fh, '<', 'database/schema.sql' or return {};
	local $/;
	my $sql = <$fh>;
	close $fh;
	return {} unless defined $sql;

	my %t;
	while ($sql =~ /CREATE\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+"?([A-Za-z_]\w*)"?\s*\(/gi) {
		my $name = $1;
		my $body = _paren_body($sql, pos($sql));
		my @columns;
		for my $part (_split_top($body)) {
			(my $def = $part) =~ s/^\s+//;
			# `columns x` is an artifact of the dump; a constraint is not a column.
			$def =~ s/^columns\s+//i;
			next if $def =~ /^(?:PRIMARY|UNIQUE|KEY|INDEX|CONSTRAINT|FOREIGN|CHECK)\b/i;
			my ($col, $type, $size) =
				$def =~ /^"?([A-Za-z_][\w]*)"?\s+([A-Za-z]+)(?:\(([^)]*)\))?/;
			next unless defined $col && length $col;
			$type = uc($type || '');
			$type .= '(' . $size . ')' if defined $size && length $size;
			push @columns, [ $col, $type ];
		}
		$t{$name} = { 'columns' => \@columns, 'indexes' => [] };
	}

	# CREATE [UNIQUE] INDEX name ON table (col, col)
	while ($sql =~ /CREATE\s+(?:UNIQUE\s+)?INDEX\s+\w+\s+ON\s+"?([A-Za-z_]\w*)"?\s*\(([^)]*)\)/gi) {
		my ($table, $cols) = ($1, $2);
		next unless $t{$table};
		$cols =~ s/\s+/ /g;
		$cols =~ s/^ | $//g;
		push @{ $t{$table}{'indexes'} }, $cols;
	}
	return \%t;
}

# The text between the paren at $from-1 and its match.
sub _paren_body {
	my ($text, $from) = @_;
	return '' unless defined $from && $from > 0;
	my $depth = 1;
	my $out   = '';
	for my $i ($from .. length($text) - 1) {
		my $c = substr($text, $i, 1);
		$depth++ if $c eq '(';
		if ($c eq ')') {
			$depth--;
			return $out if $depth == 0;
		}
		$out .= $c;
	}
	return $out;
}

# Split a table body on commas that are not inside a type's parentheses.
sub _split_top {
	my ($body) = @_;
	my (@parts, $cur);
	my $depth = 0;
	$cur = '';
	for my $c (split //, $body) {
		$depth++ if $c eq '(';
		$depth-- if $c eq ')';
		if ($c eq ',' && !$depth) {
			push @parts, $cur;
			$cur = '';
			next;
		}
		$cur .= $c;
	}
	push @parts, $cur if length $cur;
	return @parts;
}

# One row is [the line the route had in Manager.pl, method, path, action]; the
# action body lives in the controller named after the route module.
sub _routes {
	my @out;
	for my $file (sort grep { -f } glob('lib/JawnOS/Routes/*.pm')) {
		my ($module) = $file =~ m{Routes/([^/]+)\.pm$} or next;
		open my $fh, '<', $file or next;
		my $n = 0;
		while (my $row = <$fh>) {
			$n++;
			my ($idx, $method, $path, $action) = $row =~
				/\[\s*(\d+)\s*,\s*'(\w+)'\s*,\s*'([^'\n]*)'\s*,\s*'(action_\d+)'\s*\]/
				or next;
			push @out, {
				'index' => $idx, 'method' => $method, 'path' => $path,
				'action' => $action, 'module' => $module, 'line' => $n,
			};
		}
		close $fh;
	}
	return @out;
}

# Each test declares the paths it covers in its first lines:
#   # tests-for: scripts/where.pl lib/JawnOS/Routes/
# A test also claims a path it spells out in its body (that is how the runner
# reads it, so a source-grep test counts).
sub _test_claims {
	my @out;
	for my $file (sort grep { -f } glob('t/*.t')) {
		open my $fh, '<', $file or next;
		my (@head, $body);
		my $n = 0;
		while (my $line = <$fh>) {
			$n++;
			push @head, $line if $n <= 40;
			$body .= $line if $n > 40;
		}
		close $fh;
		my ($globs) = map { /^#\s*tests-for:\s*(.+)$/ ? $1 : () } @head;
		my @globs = defined $globs ? split ' ', $globs : ();
		push @out, { 'file' => $file, 'globs' => \@globs, 'body' => $body // '' };
	}
	return @out;
}

# The convention help::resolve_files uses, kept in step with it: a topic's
# templates list, plus an app's page and script. A page with no topic still gets
# a brief - that is the point of the second tier.
sub sources {
	my ($entry) = @_;
	return () unless $entry;
	if ($entry->{'topic'} && $TOPIC{ $entry->{'topic'} }) {
		my @files = help::resolve_files($entry->{'topic'});
		return @files if @files;
	}
	my $app = $entry->{'page'} || $entry->{'name'};
	return () unless defined $app && length $app;
	return grep { -f $_ } (
		"templates/apps/$app.html.ep",
		"templates/$app.html.ep",
		"public/js/manager/$app.js",
		"public/js/$app.js",
	);
}

# Routes belong to an app when one path segment is the app's name: /manager/budget
# and /manager/budget/edit are Budget's, /manager/budget_light is not.
sub routes_for {
	my ($app) = @_;
	return () unless defined $app && length $app;
	return grep {
		my $path = $_->{'path'};
		my $hit = 0;
		$hit = 1 foreach grep { $_ eq $app || $_ eq "$app.js" } split m{/}, $path;
		$hit;
	} @ROUTES;
}

sub controllers_for {
	my @mods = do { my %s; $s{ $_->{'module'} } = 1 for @_; sort keys %s };
	return map { "lib/JawnOS/Controller/$_.pm" } grep { -f "lib/JawnOS/Controller/$_.pm" } @mods;
}

sub tables_in {
	my (@files) = @_;
	my %found;
	for my $file (@files) {
		my $text = _slurp($file) or next;
		$found{$_} = 1 for grep { $text =~ /(?<![\w])\Q$_\E(?![\w])/ } keys %SCHEMA;
	}
	return sort keys %found;
}

# Which apps name each table: the reverse of the brief's tables list. Derived by
# scanning an app's files and the controllers its routes reach, so a table an app
# writes is named even when the template never mentions it.
my $APPS_BY_TABLE;

sub apps_by_table {
	return $APPS_BY_TABLE if $APPS_BY_TABLE;
	my %by;
	for my $name (names()) {
		my $entry = resolve_name($name) or next;
		my $app = $entry->{'page'} || $entry->{'name'};
		my @files = sources($entry);
		my @controllers = controllers_for(routes_for($app));
		$by{$_}{$app} = 1 for tables_in(@files, @controllers);
	}
	$APPS_BY_TABLE = \%by;
	return $APPS_BY_TABLE;
}

sub settings_in {
	my (@files) = @_;
	my %found;
	for my $file (@files) {
		my $text = _slurp($file) or next;
		$found{$1} = 1 while $text =~ /\bsetting\s*=>\s*'([^']+)'/g;
	}
	return sort keys %found;
}

sub hints_in {
	my (@files) = @_;
	return () unless $LOADED;
	return help::hints(@files);
}

# tests_for.pl's rule, in miniature: a `tests-for:` glob that matches the path,
# or the path spelled out in the body.
sub tests_for {
	my (@files) = @_;
	my @out;
	for my $test (@TESTS) {
		my $claim = 0;
		for my $file (@files) {
			for my $glob (@{ $test->{'globs'} }) {
				next unless _glob_match($glob, $file);
				$claim = 1;
				last;
			}
			last if $claim;
			$claim = 1 if index($test->{'body'}, $file) >= 0;
		}
		push @out, $test->{'file'} if $claim;
	}
	return @out;
}

# `*` within one segment, `**` across segments, a trailing / for a subtree.
sub _glob_match {
	my ($glob, $path) = @_;
	return 0 unless defined $glob && length $glob;
	$glob =~ s{/$}{/**};
	my @rx;
	for my $part (split m{/}, $glob) {
		if ($part eq '**') { push @rx, '.*'; next }
		my $p = quotemeta $part;
		$p =~ s/\\\*/[^\/]*/g;
		push @rx, $p;
	}
	my $re = join '/', @rx;
	return $path =~ m{^$re$} ? 1 : 0;
}

sub _slurp {
	my ($path) = @_;
	open my $fh, '<', $path or return;
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

# The first comment block within the first 40 lines: where the rationale lives.
# Capped, because a brief is a lookup, not a document dump.
sub notes_for {
	my ($file, $max) = @_;
	$max ||= 5;
	my $text = _slurp($file) or return ();
	my @lines = split /\n/, $text;
	return () unless @lines;
	my @out;
	for my $line (@lines[ 0 .. ( $#lines > 39 ? 39 : $#lines ) ]) {
		next if $line =~ /^#!/;
		if ($line =~ /^\s*(?:#|\/\/|\/\*|\*)\s?(.*)$/) {
			my $body = $1;
			$body =~ s/^\s+//;
			next unless length $body;
			next if $body =~ /\[\[|\[\/\w+\]\]/;    # split markers are not rationale
			push @out, $body;
			last if @out >= $max;
		}
		elsif (@out) {
			last;
		}
	}
	return @out;
}

# ---- the brief -------------------------------------------------------------

# The brief is a lookup, not a dump: most tasks want the sources, tables,
# settings and tests, and routes are the one section that grows with an app.
# Keep the first ROUTE_CAP rows and say what was left; --routes prints every row.
our $ALL_ROUTES = 0;
my $ROUTE_CAP = 15;

sub brief {
	my ($name) = @_;
	load();
	my $entry = resolve_name($name) or return undef;
	my @sources = sources($entry);
	my @routes  = routes_for($entry->{'page'} || $entry->{'name'});
	my @controllers = controllers_for(@routes);
	my @tables = tables_in(@sources, @controllers);
	my @settings = settings_in(@controllers);
	my @hints = hints_in(@sources);
	my @tests = tests_for(@sources, @controllers);

	my $topic = $entry->{'topic'} ? $TOPIC{ $entry->{'topic'} } : undef;
	my $title = $topic ? $topic->{'title'} : $entry->{'name'};
	my @out;
	push @out, "$entry->{'name'} - $title";
	push @out, $topic
		? "tier 1: help topic '$entry->{'topic'}' (vetted "
			. ( $topic->{'verified'} || $help::verified_default || 'never' ) . '); tier 2: generated below'
		: 'tier 1: none - this page has no help topic yet; tier 2: generated below';
	push @out, '';

	push @out, 'sources';
	push @out, @sources ? map {"  $_"} @sources : '  (none resolved)';
	push @out, '';

	push @out, 'routes (' . scalar(@routes) . ')';
	if (@routes) {
		my %controller_line;
		for my $file (@controllers) {
			my $text = _slurp($file) or next;
			my $n = 0;
			for my $line (split /\n/, $text) {
				$n++;
				$controller_line{$1} = "$file:$n" if $line =~ /^\s*sub\s+(action_\d+)\b/;
			}
		}
		my @shown = $ALL_ROUTES ? @routes
			: @routes[ 0 .. ( $#routes > $ROUTE_CAP - 1 ? $ROUTE_CAP - 1 : $#routes ) ];
		for my $r (@shown) {
			push @out, sprintf('  %-6s %-40s %s', $r->{'method'}, $r->{'path'},
				"Routes/$r->{'module'}.pm:$r->{'line'}"
					. ( $controller_line{ $r->{'action'} } ? '  -> ' . $controller_line{ $r->{'action'} } : '' ));
		}
		if (@shown < @routes) {
			my %mods;
			$mods{ $_->{'module'} }++ for @routes;
			my $app = $entry->{'page'} || $entry->{'name'};
			my ($pointer) = map { $_->{'path'} }
				grep { $_->{'path'} =~ m{/\Q$app\E$} } @routes;
			$pointer ||= $routes[0]{'path'};
			push @out, '  ... ' . ( @routes - @shown ) . ' more; by module: '
				. join(', ', map {"$_ ($mods{$_})"}
					sort { $mods{$b} <=> $mods{$a} || $a cmp $b } keys %mods)
				. '; one route: perl scripts/where.pl ' . $pointer;
			push @out, "  all routes: perl scripts/agent_help.pl --routes $app";
		}
	} else {
		push @out, '  (none - no route path names this app)';
	}
	push @out, '';

	push @out, 'tables (' . scalar(@tables) . ')';
	if (@tables) {
		push @out, map {
			'  ' . $_ . ' (' . scalar( @{ $SCHEMA{$_}{'columns'} || [] } ) . ' columns)'
		} @tables;
		push @out, '  schema: perl scripts/agent_help.pl --schema ' . $tables[0];
	}
	else {
		push @out, '  (none named in these files)';
	}
	push @out, '';

	push @out, 'settings (' . scalar(@settings) . ')';
	push @out, @settings ? map {"  $_"} @settings : '  (none read in these routes)';
	push @out, '';

	push @out, 'controls (' . scalar(@hints) . ')';
	push @out, @hints ? map {"  $_"} @hints : '  (none declared with hint="...")';
	push @out, '';

	push @out, 'tests that claim these files (' . scalar(@tests) . ')';
	push @out, @tests ? map {"  $_"} @tests : '  (none - a change here runs the whole suite)';
	push @out, '';

	if (my @notes = map { my $f = $_; map { [$f, $_] } notes_for($f, 5) } @sources[ 0 .. ( $#sources > 2 ? 2 : $#sources ) ]) {
		push @out, 'notes from the sources (why it is this way - the prose lives in the code)';
		push @out, "  $notes[0][0]: $notes[0][1]";
		for my $i (1 .. $#notes) {
			push @out, $notes[$i][0] eq $notes[ $i - 1 ][0]
				? "  $notes[$i][1]"
				: "  $notes[$i][0]: $notes[$i][1]";
		}
	}

	return join("\n", @out) . "\n";
}

# Which app owns a file: the reverse of sources(). A change usually lands on an
# app's page or script, and the app's name is the handle everything else is keyed
# by - routes, tables, settings, tests.
sub app_for_path {
	my ($path) = @_;
	load();
	return () unless defined $path && length $path;
	$path =~ s{^\./}{};
	my %apps;
	for my $name (names()) {
		my $entry = resolve_name($name) or next;
		my $app = $entry->{'page'} || $entry->{'name'};
		for my $file (sources($entry)) {
			$apps{$app} = 1 if $file eq $path;
		}
	}
	return sort keys %apps;
}

# ---- the schema ------------------------------------------------------------
#
# What database/schema.sql declares, table by table: every column with its type,
# the indexes, and the apps whose files or routes name it. This is the part of
# the agent tier an agent needs before touching a query - a column's real name
# and type are not in the code that reads it.

sub schema_brief {
	my ($only) = @_;
	load();
	my @tables = defined $only && length $only ? ($only) : sort keys %SCHEMA;
	my $by = apps_by_table();

	my @out;
	for my $table (@tables) {
		my $info = $SCHEMA{$table};
		unless ($info) {
			push @out, "$table - not declared in database/schema.sql";
			push @out, '';
			next;
		}
		my @columns = map { "$_->[0] $_->[1]" } @{ $info->{'columns'} };
		push @out, "$table - " . scalar( @{ $info->{'columns'} } ) . ' columns, '
			. scalar( @{ $info->{'indexes'} } ) . ' index(es)';
		push @out, '  columns: ' . ( @columns ? join(', ', @columns) : '(none parsed)' );
		push @out, '  indexes: ' . join('; ', @{ $info->{'indexes'} })
			if @{ $info->{'indexes'} };
		my @apps = sort keys %{ $by->{$table} || {} };
		push @out, '  used by: ' . ( @apps ? join(', ', @apps) : '(no app names it)' );
		push @out, '';
	}
	return join("\n", @out);
}

# ---- the compact index -----------------------------------------------------

sub _topic_for_app {
	my ($app) = @_;
	return undef unless defined $app && length $app;
	my $key = help::key($app);
	return $key if $TOPIC{$key};
	# A topic's id is not always the app's name (help -> help_app).
	my ($by_app) = sort grep { ($TOPIC{$_}{'app'} || '') eq $app } keys %TOPIC;
	return $by_app;
}

sub index_text {
	load();
	my @out;
	push @out, '# Repository index (generated)';
	push @out, '';
	push @out, 'Generated by `perl scripts/agent_help.pl --write-index`; do not edit by hand.';
	push @out, 'For one app, `perl scripts/agent_help.pl <name>` prints the brief; for one';
	push @out, 'symbol or route, `perl scripts/where.pl <name>` prints its file:line.';
	push @out, '';

	my %apps;
	$apps{ $_->{'app'} } = 1 for grep { $_->{'app'} } values %TOPIC;
	$apps{$_} = 1 for keys %APP_PAGE;
	push @out, '## apps';
	push @out, '';
	push @out, 'Counts only: `perl scripts/agent_help.pl <app>` names every file, route,'
		. ' table, setting and test behind one line here.';
	push @out, '';
	my @quiet;
	for my $app (sort keys %apps) {
		my @routes = routes_for($app);
		my $id = _topic_for_app($app);
		my $entry = { 'name' => $app, 'page' => $app };
		$entry->{'topic'} = $id if $id;
		my @sources = sources($entry);
		if (!@routes && !$id) {
			# A fragment of an app's page: named in one line, not one each.
			push @quiet, $app;
			next;
		}
		# Counts, not the file list: `agent_help.pl <app>` names the files, and
		# the index has a hard budget for the nightly agent's context.
		push @out, '- ' . $app
			. ($id ? " (topic $id)" : ' (no topic)')
			. ': ' . scalar(@sources) . ' file(s)'
			. ( @routes ? ', ' . scalar(@routes) . ' route(s)' : '' );
	}
	push @out, '- other pages, no topic and no route: ' . join(', ', @quiet) if @quiet;
	push @out, '';

	push @out, '## tables';
	push @out, '';
	push @out, scalar(keys %SCHEMA) . ' tables (database/schema.sql). Columns are inline;'
		. ' `perl scripts/agent_help.pl --schema <table>` adds the apps that use one.';
	for my $table (sort keys %SCHEMA) {
		my @columns = map { $_->[0] } @{ $SCHEMA{$table}{'columns'} };
		push @out, '- ' . $table . ' (' . scalar(@columns) . '): ' . join(', ', @columns);
	}
	push @out, '';

	push @out, '## routes';
	push @out, '';
	my %mods;
	$mods{ $_->{'module'} }++ for @ROUTES;
	my %prefix;
	$prefix{ (split m{/}, $_->{'path'})[1] // '' }++ for @ROUTES;
	push @out, scalar(@ROUTES) . ' routes in ' . scalar(keys %mods) . ' modules.';
	push @out, 'By controller: '
		. join(', ', map { "$_ ($mods{$_})" } sort keys %mods) . '.';
	push @out, 'By first path segment: '
		. join(', ', map { "/$_ ($prefix{$_})" } sort keys %prefix) . '.';
	push @out, 'One route: `perl scripts/where.pl /manager/pen`.';
	push @out, '';

	push @out, '## helpers';
	push @out, '';
	my $helper_count = _count('lib/JawnOS/Manager/Part*.pm', '\bsub\s+([A-Za-z_]\w*)');
	my $domain_count = _count('lib/JawnOS/Domain/*.pm', '\bsub\s+([A-Za-z_]\w*)');
	push @out, "$helper_count Manager helpers across "
		. scalar(grep { -f } glob('lib/JawnOS/Manager/Part*.pm')) . ' parts: '
		. '`lib/JawnOS/Manager/Index.pm` (%SUB) is the name map, `t/54-manager-split.t` keeps it complete.';
	push @out, "$domain_count domain subs in subs::, mapped by `lib/JawnOS/Domain/Loader.pm` "
		. '(%DOMAIN_MODULE); `t/91-domain-loader-qa.t` keeps it complete.';
	push @out, 'One helper: `perl scripts/where.pl app_release_sync`.';
	push @out, '';

	push @out, '## firmware';
	push @out, '';
	for my $sketch (qw(jp/alarmclock jt jw)) {
		next unless -f "$sketch/platformio.ini";
		my $index = $sketch eq 'jp/alarmclock' ? "$sketch/alarmclock.ino" : "$sketch/$sketch.ino";
		my @parts = grep { $_ ne $index } sort grep { -f } glob("$sketch/*.ino");
		push @out, "- $sketch: " . ( -f $index ? $index : 'index missing' )
			. ', ' . scalar(@parts) . ' part file(s), builds with `pio run -j 4`.';
	}
	push @out, '';

	return join("\n", @out);
}

# A plain pattern string, not a qr//: a compiled qr carries its own flag set and
# interpolation resets it (`(?^:...)`), so a `^` anchor quietly stops matching a
# line start when the qr was built without /m. The string has no such surprise.
sub _count {
	my ($glob, $pattern) = @_;
	my %n;
	for my $file (grep { -f } glob($glob)) {
		my $text = _slurp($file) or next;
		$n{$_} = 1 for $text =~ /$pattern/mg;
	}
	return scalar keys %n;
}

# ---- the command -----------------------------------------------------------

sub main {
	my (@argv) = @_;
	load();

	if (!@argv || $argv[0] eq '--help' || $argv[0] eq '-h') {
		print <<'TXT';
usage: perl scripts/agent_help.pl [--list | --index | --write-index | --schema[=TABLE] | --routes] NAME...

  NAME          an app (budget), a help topic (start_menu), or an app page
                (templates/apps/gallery.html.ep). Prints the generated brief.
  --list        every name this answers for
  --schema      every table, its columns and indexes, and the apps that use it
  --schema=T    one table
  --index       print the compact repository index
  --write-index rewrite qa/coding_night/agent-index.md
  --routes      every route that reaches NAME, uncapped (the brief shows 15)
TXT
		return 0;
	}

	if ($argv[0] eq '--routes') {
		shift @argv;
		if (!@argv) {
			warn "agent_help: --routes needs at least one NAME (try --list)\n";
			return 1;
		}
		$ALL_ROUTES = 1;
	}

	if ($argv[0] eq '--list') {
		print "$_\n" for names();
		return 0;
	}

	if ($argv[0] eq '--index' || $argv[0] eq '--write-index') {
		my $text = index_text();
		if ($argv[0] eq '--index') {
			print $text;
			return 0;
		}
		open my $fh, '>', 'qa/coding_night/agent-index.md' or die "agent_help: $!\n";
		print $fh $text;
		close $fh;
		print "wrote qa/coding_night/agent-index.md\n";
		return 0;
	}

	if ($argv[0] eq '--schema' || $argv[0] =~ /^--schema=(.+)$/) {
		my $only = $1;
		print schema_brief($only);
		return 0;
	}

	my $failed = 0;
	for my $name (@argv) {
		my $text = brief($name);
		if (!defined $text) {
			warn "agent_help: no app, topic or page named '$name' (try --list)\n";
			$failed = 1;
			next;
		}
		print $text;
		print "\n" if @argv > 1;
	}
	$ALL_ROUTES = 0;
	return $failed ? 1 : 0;
}

exit( main(@ARGV) ) unless caller;

1;
