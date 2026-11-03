#!/usr/bin/perl

# What the locator got wrong, and what to do about it.
#
#   perl scripts/where_audit.pl                 # the last 14 days
#   perl scripts/where_audit.pl --days 30
#   perl scripts/where_audit.pl --prompt        # a task brief for the Coding agent
#   perl scripts/where_audit.pl --json
#   perl scripts/where_audit.pl --strict        # exit 1 when there is anything to fix
#
# where.pl writes one row per lookup (where_calls) and one per explicit report
# (where_feedback). This reads both, plus the two name maps, and prints the
# misses worth covering, the hits an agent said were wrong, and any map that no
# longer defines the name it claims. Nothing here edits the tree; the Coding
# agent does that from --prompt, with a test, like any other change.

use strict;
use warnings;

use Cwd qw(abs_path);
use DBI;
use FindBin ();
use Getopt::Long qw(GetOptions);
use IPC::Open3 qw(open3);
use POSIX qw(strftime);
use Symbol qw(gensym);

my $real_root = abs_path("$FindBin::Bin/..");
my $root      = $real_root;
my $db;
my $days  = 14;
my $limit = 20;
my $json  = 0;
my $prompt = 0;
my $strict = 0;

GetOptions(
	'db=s'    => \$db,
	'root=s'  => \$root,
	'days=i'  => \$days,
	'limit=i' => \$limit,
	'json'    => \$json,
	'prompt'  => \$prompt,
	'strict'  => \$strict,
) or usage(2);
usage(2) if $days < 1 || $limit < 1;
$db = "$root/database/jawnos.db" unless defined $db && length $db;

my $since = strftime('%Y-%m-%d %H:%M', localtime(time - $days * 86400));

my %summary = (calls => 0, hits => 0, misses => 0, right => 0, wrong => 0);
my (@misses, @wrong);

if (-f $db) {
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
		RaiseError => 0, PrintError => 0, ReadOnly => 1,
		sqlite_busy_timeout => 2000,
	});
	if ($dbh) {
		my $row = eval {
			$dbh->selectrow_arrayref(
				'select count(*),'
				. ' sum(case when hit > 0 then 1 else 0 end),'
				. ' sum(case when hit = 0 then 1 else 0 end)'
				. ' from where_calls where minute >= ?', undef, $since);
		};
		if ($row) {
			$summary{'calls'}  = ($row->[0] || 0) + 0;
			$summary{'hits'}   = ($row->[1] || 0) + 0;
			$summary{'misses'} = ($row->[2] || 0) + 0;
		}
		my $feedback = eval {
			$dbh->selectrow_arrayref(
				"select sum(case when verdict = 'right' then 1 else 0 end),"
				. " sum(case when verdict = 'wrong' then 1 else 0 end)"
				. ' from where_feedback where minute >= ?', undef, $since);
		};
		if ($feedback) {
			$summary{'right'} = ($feedback->[0] || 0) + 0;
			$summary{'wrong'} = ($feedback->[1] || 0) + 0;
		}
		my $miss_rows = eval {
			$dbh->selectall_arrayref(
				'select name, count(*) as n, max(minute) as last'
				. ' from where_calls where hit = 0 and minute >= ?'
				. ' group by name order by n desc, last desc limit ' . $limit,
				{ Slice => {} }, $since);
		} || [];
		@misses = @{$miss_rows};
		my $wrong_rows = eval {
			$dbh->selectall_arrayref(
				"select name, selected, found, note, max(minute) as last"
				. " from where_feedback where verdict = 'wrong' and minute >= ?"
				. ' group by name order by last desc limit ' . $limit,
				{ Slice => {} }, $since);
		} || [];
		@wrong = @{$wrong_rows};
		$dbh->disconnect;
	}
}

# A wrong report is two different problems. Ask the locator again, read-only:
# if the reported location is already among its hits, the order is the fault
# (ranking); if it is not there at all, the location is missing (coverage).
for my $row (@wrong) {
	$row->{'kind'} = classify_wrong($row);
}

my @drift   = map_drift();
my $findings = @misses + @wrong + @drift;

if ($json) {
	require JSON::PP;
	print JSON::PP->new->canonical->encode({
		days     => $days,
		summary  => { %summary },
		misses   => \@misses,
		wrong    => \@wrong,
		drift    => \@drift,
		findings => $findings,
	}), "\n";
	exit(($strict && $findings) ? 1 : 0);
}

if ($prompt) {
	print audit_prompt(\@misses, \@wrong, \@drift, $days);
	exit(($strict && $findings) ? 1 : 0);
}

printf "where audit: last %d days from %s\n", $days, $db;
printf "calls %d · hit %d · miss %d · confirmed %d · wrong %d\n",
	@summary{qw(calls hits misses right wrong)};

if (@misses) {
	print "\nMISSES (the locator found nothing; cover these)\n";
	for my $r (@misses) {
		printf "  %4d  %s  (last %s)\n", $r->{'n'}, $r->{'name'}, $r->{'last'};
	}
}
if (@wrong) {
	print "\nWRONG (an agent said the hit was not the right one)\n";
	for my $r (@wrong) {
		printf "  %s  ->  %s [%s]%s%s\n", $r->{'name'}, ($r->{'found'} || '(no location given)'),
			$r->{'kind'},
			(defined $r->{'selected'} && length $r->{'selected'} ? ' (selected ' . $r->{'selected'} . ')' : ''),
			($r->{'note'} ? '  [' . $r->{'note'} . ']' : '');
	}
	print "  (ranking = the right answer was among the hits; coverage = it was not returned)\n";
}
if (@drift) {
	print "\nMAP DRIFT (the map names a file that no longer defines the name)\n";
	for my $r (@drift) {
		printf "  %s  %s says %s, not defined there\n", $r->{'name'}, $r->{'kind'}, $r->{'map'};
	}
}
print "\nnothing to fix in this window.\n" unless $findings;
exit(($strict && $findings) ? 1 : 0);

# --- the brief ---------------------------------------------------------------

sub audit_prompt {
	my ($misses, $wrong, $drift, $days) = @_;
	my @lines = ('Maintain the locator (scripts/where.pl, lib/JawnOS/Manager/Index.pm, lib/JawnOS/Domain/Loader.pm).');
	push @lines, "Its ledger for the last $days days shows:";
	if (@{$misses}) {
		push @lines, '', 'MISSES (find each with `perl scripts/where.pl <name>` and add the missing coverage, map or pattern, with a t/96-where.t case):';
		push @lines, sprintf('  %s (%d, last %s)', $_->{'name'}, $_->{'n'}, $_->{'last'}) for @{$misses};
	}
	if (@{$wrong}) {
		push @lines, '', 'WRONG (open the reported location, confirm it, then correct the locator):';
		push @lines, sprintf('  %s -> %s [%s]%s%s', $_->{'name'}, ($_->{'found'} || '(no location)'),
			$_->{'kind'},
			(defined $_->{'selected'} && length $_->{'selected'} ? ' (selected ' . $_->{'selected'} . ')' : ''),
			($_->{'note'} ? ' [' . $_->{'note'} . ']' : '')) for @{$wrong};
		push @lines, '', 'ranking: the right answer was already among the hits - improve the order or priority. coverage: the locator did not return it - add the location.';
	}
	if (@{$drift}) {
		push @lines, '', 'MAP DRIFT (the map names a file that no longer defines the name):';
		push @lines, sprintf('  %s: %s says %s', $_->{'name'}, $_->{'kind'}, $_->{'map'}) for @{$drift};
	}
	push @lines, '', 'Confirm every case in the source before editing; add a test for each new shape; run `perl scripts/tests_for.pl --staged --run`, then `perl scripts/run_tests.pl`; finish with bump, commit, push, restart.';
	return join("\n", @lines) . "\n";
}

# --- the maps ----------------------------------------------------------------

my %file_text;

sub file_text {
	my ($path) = @_;
	$file_text{$path} = slurp($path) // '' unless exists $file_text{$path};
	return $file_text{$path};
}

sub find_sub {
	my ($path, $name) = @_;
	my $text = file_text($path);
	my $n    = 0;
	for my $line (split /\n/, $text, -1) {
		$n++;
		return $n if $line =~ /^\s*sub\s+\Q$name\E\b/;
	}
	return;
}

# The locator's hits for one name, read-only. undef when it could not run;
# an empty list is a real miss, which is what makes a coverage gap.
sub locator_hits {
	my ($name) = @_;
	my $script = "$real_root/scripts/where.pl";
	return undef unless -f $script;
	my $err = gensym;
	my ($in, $out);
	my $pid = eval {
		open3($in, $out, $err, $^X, $script, '--root', $root, '--no-log', '--terse', $name);
	};
	return undef unless $pid;
	close $in;
	my @lines = <$out>;
	chomp @lines;
	{
		local $/;
		my $junk = <$err>;
	}
	waitpid($pid, 0);
	return \@lines;
}

sub classify_wrong {
	my ($row) = @_;
	my $found = defined $row->{'found'} ? $row->{'found'} : '';
	return 'unknown' unless length $found;
	my $hits = locator_hits($row->{'name'});
	return 'unknown' unless defined $hits;
	return (grep { $_ eq $found } @{$hits}) ? 'ranking' : 'coverage';
}

sub map_drift {
	my @out;

	my %helper;
	my $index = file_text("$root/lib/JawnOS/Manager/Index.pm");
	while ($index =~ /'([A-Za-z_][A-Za-z0-9_]*)'\s*=>\s*'(JawnOS\/Manager\/[^']+)'/g) {
		$helper{$1} = "$root/lib/$2";
	}
	for my $name (sort keys %helper) {
		my $file = $helper{$name};
		next if find_sub($file, $name);
		push @out, { name => $name, kind => 'Index.pm', map => rel($file) };
	}

	my %domain;
	my $loader = file_text("$root/lib/JawnOS/Domain/Loader.pm");
	while ($loader =~ /'(JawnOS::Domain::[A-Za-z0-9_]+)'\s*for\s+qw\(([^)]*)\)/g) {
		my ($module, $names) = ($1, $2);
		my $file = join('/', "$root/lib", split /::/, $module) . '.pm';
		$domain{$_} = $file for split ' ', $names;
	}
	for my $name (sort keys %domain) {
		my $file = $domain{$name};
		next if find_sub($file, $name);
		push @out, { name => $name, kind => 'Loader.pm', map => rel($file) };
	}

	return @out;
}

sub rel {
	my ($path) = @_;
	my $prefix = $root;
	$prefix =~ s{/+$}{};
	$path =~ s{^\Q$prefix\E/+}{};
	return $path;
}

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or return;
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

sub usage {
	my ($code) = @_;
	my $fh = $code ? \*STDERR : \*STDOUT;
	print $fh <<'TXT';
usage: perl scripts/where_audit.pl [--days N] [--limit N] [--json] [--prompt] [--strict] [--db PATH] [--root DIR]

  --days N    the window to read (default 14)
  --limit N   the most names per section (default 20)
  --prompt    print a task brief for the Coding agent instead of the report
  --json      machine-readable output
  --strict    exit 1 when there is anything to fix
  --db PATH   the ledger database (default <root>/database/jawnos.db)
  --root DIR  the tree whose name maps are checked (default this checkout)
TXT
	exit $code;
}
