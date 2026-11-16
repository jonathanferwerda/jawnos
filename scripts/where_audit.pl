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
# longer defines the name it claims. It also says whether the leads a miss
# printed were followed, since that is what separates a wrong ranking from a name
# that is simply not in the tree. Nothing here edits the tree; the Coding
# agent does that from --prompt, with a test, like any other change.

use strict;
use warnings;

use Cwd qw(abs_path);
use DBI;
use FindBin ();
use Getopt::Long qw(GetOptions);
use IPC::Open3 qw(open3);
use JSON::PP ();
use POSIX qw(strftime);
use Symbol qw(gensym);

my $real_root = abs_path("$FindBin::Bin/..");
my $root      = $real_root;
my $db;
my $days  = 14;
my $limit = 20;
my $since_arg;
my $json  = 0;
my $prompt = 0;
my $strict = 0;

GetOptions(
	'db=s'    => \$db,
	'root=s'  => \$root,
	'days=i'  => \$days,
	'since=s' => \$since_arg,
	'limit=i' => \$limit,
	'json'    => \$json,
	'prompt'  => \$prompt,
	'strict'  => \$strict,
) or usage(2);
usage(2) if $days < 1 || $limit < 1;
$db = "$root/database/jawnos.db" unless defined $db && length $db;

my $since = strftime('%Y-%m-%d %H:%M', localtime(time - $days * 86400));
if (defined $since_arg && length $since_arg) {
	if ($since_arg =~ /^\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2})?$/) {
		$since = $since_arg;
	}
	else {
		warn "where_audit: --since wants YYYY-MM-DD or YYYY-MM-DD HH:MM\n";
		exit 2;
	}
}

my %summary = (calls => 0, hits => 0, misses => 0, right => 0, wrong => 0, leads => 0, followed => 0);
my (@misses, @wrong, @leads);

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
				. " sum(case when verdict in ('wrong','miss') then 1 else 0 end)"
				. ' from where_feedback where minute >= ?', undef, $since);
		};
		if ($feedback) {
			$summary{'right'} = ($feedback->[0] || 0) + 0;
			$summary{'wrong'} = ($feedback->[1] || 0) + 0;
		}
		my $miss_rows = eval {
			$dbh->selectall_arrayref(
				'select name, count(*) as n, max(minute) as last, context'
				. ' from where_calls where hit = 0 and minute >= ?'
				# A flag (`--topics`, `--tools`, `--outline`) records a row so the
				# panel can price it, but its name is not a code name: a pattern
				# that found no topic is not coverage the locator can add, and
				# listing it as the top MISS taught an agent to chase `--topics`.
				. q{ and name not like '--%'}
				. ' group by name order by n desc, last desc limit ' . $limit,
				{ Slice => {} }, $since);
		} || [];
		@misses = @{$miss_rows};
		my $wrong_rows = eval {
			$dbh->selectall_arrayref(
				"select name, verdict, selected, found, note, max(minute) as last"
				. " from where_feedback where verdict in ('wrong','miss') and minute >= ?"
				. ' group by name order by last desc limit ' . $limit,
				{ Slice => {} }, $since);
		} || [];
		@wrong = @{$wrong_rows};

		# A miss that printed a lead carries the names in its context. The only
		# evidence this table holds that a lead helped is a later hit for one of
		# those names; it is a lead, not proof, because the agent may have grepped
		# instead. Kept out of $findings deliberately: an unfollowed lead is a
		# question about the ranking, not a thing the locator must fix.
		my $lead_rows = eval {
			$dbh->selectall_arrayref(
				'select name, minute, context from where_calls'
				. ' where hit = 0 and minute >= ?'
				. q{ and context like '%"near"%'}
				. ' order by minute desc limit 500',
				{ Slice => {} }, $since);
		} || [];
		my $hit_rows = eval {
			$dbh->selectall_arrayref(
				'select name, max(minute) as last from where_calls'
					. ' where hit > 0 and minute >= ? group by name',
				undef, $since);
		} || [];
		my %hit_latest = map { $_->[0] => $_->[1] } @{$hit_rows};
		for my $row (@{$lead_rows}) {
			my $c = eval { JSON::PP->new->decode($row->{'context'}) };
			next unless ref $c eq 'HASH' && ref $c->{'near'} eq 'ARRAY' && @{ $c->{'near'} };
			my @offered  = @{ $c->{'near'} };
			my @followed = grep {
				defined $hit_latest{$_} && $hit_latest{$_} ge $row->{'minute'}
			} @offered;
			push @leads, {
				name     => $row->{'name'},
				minute   => $row->{'minute'},
				offered  => \@offered,
				followed => \@followed,
			};
		}
		$summary{'leads'}    = scalar @leads;
		$summary{'followed'} = scalar(grep { @{ $_->{'followed'} } } @leads);
		$dbh->disconnect;
	}
}

# A wrong report is two different problems. Ask the locator again, read-only:
# if the reported location is already among its hits, the order is the fault
# (ranking); if it is not there at all, the location is missing (coverage).
for my $row (@wrong) {
	$row->{'kind'} = classify_wrong($row);
}
for my $row (@misses) {
	$row->{'context_text'} = context_text($row->{'context'});
}

# One entry per missed name: a guessed name misses repeatedly, and the reply
# needs the lead once, carrying every name followed in any of its calls. The
# JSON keeps the per-call rows; this merged view is what a person reads.
my @lead_names;
{
	my %by;
	for my $row (@leads) {
		my $name = $row->{'name'};
		$by{$name} ||= do {
			push @lead_names, { name => $name, offered => [], followed => [] };
			$lead_names[-1];
		};
		for my $key (qw(offered followed)) {
			my %have = map { $_ => 1 } @{ $by{$name}{$key} };
			push @{ $by{$name}{$key} }, grep { !$have{$_}++ } @{ $row->{$key} };
		}
	}
}

my @drift   = map_drift();
my $findings = @misses + @wrong + @drift;

if ($json) {
	require JSON::PP;
	print JSON::PP->new->canonical->encode({
		days     => $days,
		since    => $since,
		summary  => { %summary },
		misses   => \@misses,
		wrong    => \@wrong,
		leads    => {
			offered  => $summary{'leads'},
			followed => $summary{'followed'},
			rows     => \@leads,
		},
		drift    => \@drift,
		findings => $findings,
	}), "\n";
	exit(($strict && $findings) ? 1 : 0);
}

if ($prompt) {
	print audit_prompt(\@misses, \@wrong, \@drift, \@lead_names, $days, $limit);
	exit(($strict && $findings) ? 1 : 0);
}

printf "where audit: since %s from %s\n", $since, $db;
printf "calls %d · hit %d · miss %d · confirmed %d · wrong %d\n",
	@summary{qw(calls hits misses right wrong)};
printf "near leads %d offered, %d followed\n", @summary{qw(leads followed)} if $summary{'leads'};

if (@misses) {
	print "\nMISSES (the locator found nothing; cover these)\n";
	for my $r (@misses) {
		printf "  %4d  %s  (last %s)\n", $r->{'n'}, $r->{'name'}, $r->{'last'};
		print "        ", $r->{'context_text'}, "\n" if length $r->{'context_text'};
	}
}
if (@wrong) {
	print "\nWRONG OR MISSED (an agent reported a wrong hit or a miss)\n";
	for my $r (@wrong) {
		printf "  %s  ->  %s [%s%s]%s%s\n", $r->{'name'}, ($r->{'found'} || '(no location given)'),
			($r->{'verdict'} || 'wrong'), ($r->{'kind'} ? ' / ' . $r->{'kind'} : ''),
			(defined $r->{'selected'} && length $r->{'selected'} ? ' (selected ' . $r->{'selected'} . ')' : ''),
			($r->{'note'} ? '  [' . $r->{'note'} . ']' : '');
	}
	print "  (ranking = the right answer was among the hits; coverage = it was not returned)\n";
}
if (@leads) {
	print "\nNEAR LEADS (a miss prints up to three names; one is followed when the ledger has a hit for it afterwards)\n";
	printf "  %d of %d led somewhere\n", @summary{ 'followed', 'leads' };
	my $shown = 0;
	for my $r (@lead_names) {
		last if $shown++ >= $limit;
		printf "  %-28s offered %s%s\n", $r->{'name'}, join(', ', @{ $r->{'offered'} }),
			(@{ $r->{'followed'} } ? ' · followed ' . join(', ', @{ $r->{'followed'} }) : '');
	}
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
	my ($misses, $wrong, $drift, $leads, $days, $limit) = @_;
	my @lines = ('Maintain the locator (scripts/where.pl, lib/JawnOS/Manager/Index.pm, lib/JawnOS/Domain/Loader.pm).');
	push @lines, "Its ledger for the last $days days shows:";
	if (@{$misses}) {
		push @lines, '', 'MISSES (find each with `perl scripts/where.pl <name>` and add the missing coverage, map or pattern, with a t/96-where.t case):';
		push @lines, sprintf('  %s (%d, last %s)%s', $_->{'name'}, $_->{'n'}, $_->{'last'},
			($_->{'context_text'} ? ' - ' . $_->{'context_text'} : '')) for @{$misses};
	}
	if (@{$wrong}) {
		push @lines, '', 'WRONG OR MISSED (open the reported location, confirm it, then correct the locator):';
		push @lines, sprintf('  %s -> %s [%s%s]%s%s', $_->{'name'}, ($_->{'found'} || '(no location)'),
			($_->{'verdict'} || 'wrong'), ($_->{'kind'} ? ' / ' . $_->{'kind'} : ''),
			(defined $_->{'selected'} && length $_->{'selected'} ? ' (selected ' . $_->{'selected'} . ')' : ''),
			($_->{'note'} ? ' [' . $_->{'note'} . ']' : '')) for @{$wrong};
		push @lines, '', 'ranking: the right answer was already among the hits - improve the order or priority. coverage: the locator did not return it - add the location.';
	}
	if (@{$drift}) {
		push @lines, '', 'MAP DRIFT (the map names a file that no longer defines the name):';
		push @lines, sprintf('  %s: %s says %s', $_->{'name'}, $_->{'kind'}, $_->{'map'}) for @{$drift};
	}
	my @cold = grep { !@{ $_->{'followed'} } } @{$leads};
	if (@cold) {
		push @lines, '', 'NEAR LEADS nobody followed (the miss printed these names; open one and check whether it was the answer - if it was, the ranking is wrong, if another name was, the coverage is missing):';
		my $shown = 0;
		for my $r (@cold) {
			last if $shown++ >= $limit;
			push @lines, sprintf('  %s offered %s', $r->{'name'}, join(', ', @{ $r->{'offered'} }));
		}
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

# A miss row carries the last call's context as JSON; a compact line is what the
# report and the panel can show. This is deliberately lossy.
sub context_text {
	my ($json) = @_;
	return '' unless defined $json && length $json;
	my $c = eval { JSON::PP->new->decode($json) };
	return '' unless ref $c eq 'HASH';
	my @bits;
	push @bits, 'cwd ' . $c->{'cwd'} if length($c->{'cwd'} // '');
	push @bits, 'args ' . $c->{'args'} if length($c->{'args'} // '');
	push @bits, 'parent ' . $c->{'parent'} if length($c->{'parent'} // '');
	push @bits, 'via ' . $c->{'grandparent'} if length($c->{'grandparent'} // '');
	my $text = join(' · ', @bits);
	return length($text) > 300 ? substr($text, 0, 300) . '...' : $text;
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
  --since STR the window starts at STR (YYYY-MM-DD or YYYY-MM-DD HH:MM);
              the scheduled run passes its last successful minute
  --limit N   the most names per section (default 20)
  --prompt    print a task brief for the Coding agent instead of the report
  --json      machine-readable output
  --strict    exit 1 when there is anything to fix
  --db PATH   the ledger database (default <root>/database/jawnos.db)
  --root DIR  the tree whose name maps are checked (default this checkout)
TXT
	exit $code;
}
