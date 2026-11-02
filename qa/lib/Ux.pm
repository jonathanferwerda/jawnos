package Ux;

# l6 - the nightly UX evaluation loop.
#
# The owner writes ideas and bugs into the Notes app under the JawnOS category.
# This module reads those notes *read-only* from the live database, seeds them
# into the throwaway QA copy (the copy is the only place they are ever written),
# and turns what a browser attempt and (optionally) the Guide's model say about
# them into a verdict per question: was it easy, was the help useful, do the
# parts actually work.
#
# Two safety rules are structural:
#
#   * every live read goes through select_notes(), which opens the file with
#     `?mode=ro` and never holds a lock (sqlite3 exits);
#   * every write is checked by refuse_live_write() against the live path. The
#     only write outside the QA root is file_handbook(), and that is a POST to
#     the app's own /manager/note_save route, never a database write.
#
# No model configured is a `skip`, never a `pass` - the same rule the budgets
# use. Silence must not look like success.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use IO::Socket::INET;
use JSON::PP;
use POSIX ();
use Time::HiRes qw(time sleep);

our $VERSION = '1';

my $JSON = JSON::PP->new->canonical->pretty->utf8;

# ---------------------------------------------------------------------------
# the live database, read-only
# ---------------------------------------------------------------------------

sub live_db {
	my ($class, $repo) = @_;
	$repo ||= '.';
	return File::Spec->catfile($repo, 'database', 'jawnos.db');
}

# SQLite URI form. mode=ro makes the kernel refuse a write even if the SQL is
# wrong later; the live house is never a writable handle.
sub ro_uri {
	my ($class, $path) = @_;
	$path = File::Spec->rel2abs($path);
	return "file:$path?mode=ro";
}

sub _abs {
	my ($path) = @_;
	my $abs = abs_path($path);
	return defined $abs ? $abs : File::Spec->rel2abs($path);
}

# A copy seed must never be pointed at the house. Both sides are made absolute
# so a relative path cannot slip past the comparison.
sub refuse_live_write {
	my ($class, $path, $live) = @_;
	die "Ux: a QA write needs a live_db to compare against\n"
		unless defined $live && length $live;
	if (_abs($path) eq _abs($live)) {
		die "Ux: refusing to write the live database ($path); writes belong to the QA copy\n";
	}
	return 1;
}

sub _sqlite {
	my ($class, $db, $sql, %opt) = @_;
	my $target = $opt{'write'} ? File::Spec->rel2abs($db) : $class->ro_uri($db);
	my @cmd = ('sqlite3', $target, '-cmd', '.timeout 5000', '-json', $sql);
	open(my $fh, '-|', @cmd) or die "Ux: cannot run sqlite3: $!\n";
	local $/;
	my $out = <$fh> // '';
	close $fh;
	my $rc = $? >> 8;
	die "Ux: sqlite3 failed (exit $rc) on $target: " . substr($out, 0, 400) . "\n"
		if $rc;
	return $out;
}

sub sql_quote {
	my ($class, $value) = @_;
	$value = '' unless defined $value;
	$value =~ s/'/''/g;
	return "'$value'";
}

# The category rules are the app's (lib/JawnOS/Domain/Notes.pm), copied rather
# than loaded so qa/ never boots the live application to read a row. A blank
# category with no app, or app 'notes', is a journal note; a draft (another
# app's name) belongs to no category; anything else must be the code itself.
sub category_effective {
	my ($class, $category, $app) = @_;
	$category = '' unless defined $category;
	$category = lc $category;
	$category =~ s/^\s+|\s+$//g;
	return $category if $category =~ /^(?:journal|roadmap|social|shopping|dreams|jawnos)$/;
	$app = '' unless defined $app;
	return '' if length $app && $app ne 'notes';
	return 'journal';
}

# The notes the owner filed in the JawnOS queue, newest first. `limit` is applied
# after the category filter, so `--limit 5` means five JawnOS notes, not five
# rows that might all be journal entries.
sub select_notes {
	my ($class, $db, %opt) = @_;
	my $limit = defined $opt{'limit'} ? 0 + $opt{'limit'} : 5;
	my $want  = $opt{'category'} || 'jawnos';
	die "Ux: no database at $db\n" unless -f $db;

	my $sql = "select uuid, text, timestamp, app, category from notes"
		. " where coalesce(text, '') != '' order by timestamp desc, rowid desc limit 300";
	my $text = $class->_sqlite($db, $sql);
	my $rows = length($text) ? eval { JSON::PP->new->utf8->decode($text) } : [];
	die "Ux: notes query returned unreadable JSON: $@\n" unless ref $rows eq 'ARRAY';

	my @out;
	for my $row (@$rows) {
		my $category = $class->category_effective($row->{'category'}, $row->{'app'});
		next unless $category eq $want;
		my $body = $row->{'text'} // '';
		my ($title) = $body =~ /^\s*(\S.*)$/;
		$title = '' unless defined $title;
		$title =~ s/\s+/ /g;
		$title = substr($title, 0, 90);
		push @out, {
			id        => $row->{'uuid'} // '',
			title     => $title,
			text      => $body,
			timestamp => $row->{'timestamp'} // '',
			category  => $category,
		};
		last if @out >= $limit;
	}
	return \@out;
}

# Seed the QA copy. The copy is <root>/runs/<stamp>/tree/database/jawnos.db;
# passing the live path to live_db makes the guard explicit at every call site.
sub seed_notes {
	my ($class, $db, $notes, %opt) = @_;
	my $live = $opt{'live_db'};
	$class->refuse_live_write($db, $live);
	return 1 unless $notes && @$notes;

	my $now = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime);
	my @sql;
	for my $note (@$notes) {
		my $uuid = $note->{'id'};
		next unless defined $uuid && length $uuid;
		my $stamp = $note->{'timestamp'} || $now;
		push @sql, 'insert or replace into notes'
			. ' (uuid, timestamp, server_time, app, device, text, ost, category) values ('
			. join(', ',
				$class->sql_quote($uuid),
				$class->sql_quote($stamp),
				$class->sql_quote($now),
				$class->sql_quote('notes'),
				$class->sql_quote('computer'),
				$class->sql_quote($note->{'text'} // ''),
				$class->sql_quote('1'),
				$class->sql_quote($note->{'category'} || 'jawnos'),
			) . ')';
	}
	$class->_sqlite($db, "begin;\n" . join(";\n", @sql) . ";\ncommit;", write => 1)
		if @sql;
	return scalar @sql;
}

# ---------------------------------------------------------------------------
# the browser attempt
# ---------------------------------------------------------------------------

sub _free_port {
	my $s = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, ReuseAddr => 1)
		or return 0;
	my $port = $s->sockport;
	close $s;
	return $port;
}

sub _which {
	my ($name) = @_;
	my $p = `command -v $name 2>/dev/null`;
	chomp $p if defined $p;
	return (defined $p && length $p && -x $p) ? $p : undef;
}

# browser_attempt(url => ..., note => {...}, outdir => ...) -> attempt hash.
# A missing Chromium or node is not a pass: the attempt records why it did not
# run, and the rubric keeps that note at skip.
sub browser_attempt {
	my ($class, %opt) = @_;
	my $url    = $opt{'url'} || die "Ux: browser_attempt needs a url\n";
	my $note   = $opt{'note'} || {};
	my $outdir = $opt{'outdir'} || die "Ux: browser_attempt needs an outdir\n";
	make_path($outdir);

	my $empty = {
		steps => [], console_errors => [], screenshot => undef,
		stuck => '', url => $url,
	};

	my $chrome = _which('chromium') || _which('chromium-browser')
		|| _which('google-chrome');
	my $node   = _which('node');
	return { %$empty, stuck => 'chromium is not installed; the attempt was not made' }
		unless $chrome;
	return { %$empty, stuck => 'node is not installed; the CDP attempt was not made' }
		unless $node;

	my $port = _free_port()
		or return { %$empty, stuck => 'no free CDP port; the attempt was not made' };
	my $note_file = "$outdir/note.json";
	_write_json($note_file, $note);
	my $chrome_log = "$outdir/chrome.log";

	my $pid = fork();
	return { %$empty, stuck => "fork failed: $!" } unless defined $pid;
	if (!$pid) {
		POSIX::setsid();
		$ENV{'HOME'} = $outdir;
		open(STDOUT, '>>', $chrome_log) or POSIX::_exit(126);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
		exec $chrome,
			'--headless=new', '--no-sandbox', '--disable-gpu',
			'--disable-dev-shm-usage', '--ignore-certificate-errors',
			'--disable-background-networking', '--no-first-run',
			'--disable-sync', '--disable-extensions',
			"--user-data-dir=$outdir/chrome", "--remote-debugging-port=$port",
			'about:blank';
		POSIX::_exit(127);
	}

	require HTTP::Tiny;
	my $tiny = HTTP::Tiny->new(timeout => 2, keep_alive => 0);
	my $ready = 0;
	for (1 .. 80) {
		my $r = $tiny->get("http://127.0.0.1:$port/json/version");
		if (($r->{'status'} || 0) == 200) { $ready = 1; last }
		sleep 0.25;
	}
	unless ($ready) {
		kill 'KILL', -$pid;
		waitpid($pid, 0);
		return { %$empty, stuck => 'chromium did not expose CDP; the attempt was not made' };
	}

	my $script = File::Spec->catfile(dirname(__FILE__), '..', 'ux', 'attempt.js');
	$script = File::Spec->rel2abs($script);
	$script = $opt{'script'} if $opt{'script'};
	my $rc = system('timeout', '120', $node, $script, $port, $url, $note_file, $outdir);
	kill 'KILL', -$pid;
	kill 'KILL', $pid;
	waitpid($pid, 0);

	my $result = {};
	if (open(my $fh, '<', "$outdir/attempt.json")) {
		local $/;
		my $text = <$fh> // '';
		close $fh;
		$result = eval { JSON::PP->new->utf8->decode($text) } || {};
	}
	return { %$empty, stuck => "attempt.js exited " . ($rc >> 8) . " and wrote no evidence" }
		unless ref $result eq 'HASH' && %$result;
	$result->{'url'} ||= $url;
	return $result;
}

# ---------------------------------------------------------------------------
# the rubric
# ---------------------------------------------------------------------------

my %VERDICT = (
	yes => 'pass', easy => 'pass', pass => 'pass', works => 'pass', useful => 'pass',
	partly => 'warn', partial => 'warn', hard => 'warn', unclear => 'warn', some => 'warn',
	no => 'fail', fail => 'fail', impossible => 'fail', broken => 'fail', useless => 'fail',
);

sub _answer {
	my ($value) = @_;
	return ('', '') unless defined $value;
	if (ref $value eq 'HASH') {
		my $verdict = lc($value->{'verdict'} // $value->{'answer'} // '');
		my $evidence = $value->{'evidence'} // $value->{'why'} // '';
		return ($VERDICT{$verdict} || 'skip', "$evidence");
	}
	my $v = lc "$value";
	return ($VERDICT{$v} || 'skip', "$value");
}

# rubric(\%evidence, model => NAME, answers => { easy => ..., help => ...,
# works => ... }) -> { easy => { verdict, evidence }, ... }
# `answers` is what a model call (or a person rehearsing one) returned. With no
# model the three verdicts are all `skip`: the attempt may still have collected
# screenshots and console errors, but an unjudged attempt is not a pass.
sub rubric {
	my ($class, $evidence, %opt) = @_;
	$evidence ||= {};
	my $model   = $opt{'model'} || '';
	my $answers = $opt{'answers'} || {};
	my $skip    = $opt{'skip_reason'}
		|| 'no model configured; the UX judgement is skipped, never passed';

	my %out;
	for my $question (qw(easy help works)) {
		if (!$model || !exists $answers->{$question}) {
			$out{$question} = { verdict => 'skip', evidence => $skip };
			next;
		}
		my ($verdict, $why) = _answer($answers->{$question});
		$verdict = 'skip' if $verdict eq 'skip';
		$out{$question} = {
			verdict  => $verdict,
			evidence => length($why) ? $why : 'the model gave no supporting evidence',
		};
	}

	# Console errors are evidence the model cannot argue away: if the browser
	# raised them during the attempt, the parts did not entirely work.
	if ($model && @{ $evidence->{'console_errors'} || [] }) {
		$out{'works'} = {
			verdict  => 'fail',
			evidence => 'browser console: ' . $evidence->{'console_errors'}->[0],
		};
	}
	return \%out;
}

# ---------------------------------------------------------------------------
# the model judgement
# ---------------------------------------------------------------------------

# The Guide's model call, injected as the same (model, system, user) shape as
# subs::evaluation_model_call. A call that errors or returns prose that is not
# the requested JSON yields no answers, so the rubric stays at skip.
sub model_answers {
	my ($class, %opt) = @_;
	my $call = $opt{'model_call'} or return (undef, 'no model call was supplied');
	my $note = $opt{'note'} || {};
	my $attempt = $opt{'attempt'} || {};
	my $system = 'You evaluate a software task attempt in a real browser. '
		. 'Answer only with a JSON object with keys easy, help and works. '
		. 'Each value is {"verdict":"pass|warn|fail","evidence":"one quoted fact"}. '
		. 'Use fail when the parts did not work, warn when the task was hard or the help was unclear.';
	my $user = "Note: " . ($note->{'text'} || '') . "\n\n"
		. "Attempt steps: " . join(' -> ', @{ $attempt->{'steps'} || [] }) . "\n"
		. "Stuck: " . ($attempt->{'stuck'} || 'not recorded') . "\n"
		. "Console errors: " . join(' / ', @{ $attempt->{'console_errors'} || [] }) . "\n"
		. "Page title: " . ($attempt->{'probe'}->{'title'} || '') . "\n"
		. "Note visible in the page: " . ($attempt->{'probe'}->{'noteVisible'} ? 'yes' : 'no');
	my ($text, $err) = $call->($opt{'model'}, $system, $user);
	return (undef, $err || 'the model returned nothing') unless defined $text && length $text;
	$text =~ s/^\s*```(?:json)?\s*//;
	$text =~ s/\s*```\s*$//;
	my $answers = eval { JSON::PP->new->utf8->decode($text) };
	return (undef, 'the model did not return a JSON object') unless ref $answers eq 'HASH';
	return ($answers, undef);
}

# ---------------------------------------------------------------------------
# assembling the report
# ---------------------------------------------------------------------------

sub overall_verdict {
	my ($class, $verdicts) = @_;
	my %rank = (fail => 3, warn => 2, skip => 1, pass => 0);
	my $worst = 'pass';
	for my $q (qw(works easy help)) {
		my $v = $verdicts->{$q}->{'verdict'} || 'skip';
		$worst = $v if ($rank{$v} // 1) > $rank{$worst};
	}
	return $worst;
}

sub evaluate {
	my ($class, $notes, $attempts, %opt) = @_;
	my %by_id = map { ($_->{'id'} // '') => $_ } @{ $attempts || [] };
	my @entries;
	for my $note (@$notes) {
		my $attempt = $by_id{$note->{'id'}} || {
			steps => [], console_errors => [], stuck => 'no browser attempt was made',
		};
		my $verdicts = $class->rubric($attempt, %opt);
		push @entries, {
			%$note,
			attempt  => $attempt,
			verdicts => $verdicts,
			overall  => $class->overall_verdict($verdicts),
		};
	}
	return \@entries;
}

sub summary {
	my ($class, $entries, %opt) = @_;
	my %count = (pass => 0, warn => 0, fail => 0, skip => 0);
	$count{ $_->{'overall'} }++ for @$entries;
	my $failures = scalar grep { $_->{'verdicts'}->{'works'}->{'verdict'} eq 'fail' } @$entries;
	return {
		total       => scalar @$entries,
		verdicts    => \%count,
		ux_failures => $failures,
		model       => ($opt{'model'} || ''),
		limit       => ($opt{'limit'} || 0),
		generated   => _iso(),
	};
}

sub queue {
	my ($class, $report) = @_;
	my @items;
	for my $entry (@{ $report->{'notes'} || [] }) {
		my $action;
		if ($entry->{'overall'} eq 'skip') {
			$action = 'Give l6 a model (--model) and re-run; without one the attempt is skip, never pass.';
		}
		elsif ($entry->{'verdicts'}->{'works'}->{'verdict'} eq 'fail') {
			$action = 'Reproduce the task and fix the broken step: '
				. ($entry->{'attempt'}->{'stuck'} || $entry->{'verdicts'}->{'works'}->{'evidence'} || 'see report');
		}
		elsif ($entry->{'verdicts'}->{'help'}->{'verdict'} ne 'pass') {
			$action = 'Update the help topic named by the attempt: '
				. ($entry->{'verdicts'}->{'help'}->{'evidence'} || 'see report');
		}
		else {
			$action = 'Review the ease finding and decide whether a UI change is worth it: '
				. ($entry->{'verdicts'}->{'easy'}->{'evidence'} || 'see report');
		}
		push @items, {
			note_id              => $entry->{'id'},
			title                => $entry->{'title'},
			verdict              => $entry->{'overall'},
			suggested_next_action => $action,
		};
	}
	return {
		schema    => 1,
		generated => _iso(),
		source    => 'qa/ux/run',
		notes     => \@items,
	};
}

sub _iso {
	return POSIX::strftime('%Y-%m-%dT%H:%M:%S%z', localtime);
}

sub write_results {
	my ($class, $dir, $report) = @_;
	make_path("$dir/notes");
	my $queue = $class->queue($report);
	_write_json("$dir/report.json", $report);
	_write_json("$dir/queue.json", $queue);
	_write_text("$dir/ux-report.md", _markdown($report));
	return { dir => $dir, report => "$dir/report.json",
		queue => "$dir/queue.json", markdown => "$dir/ux-report.md" };
}

sub _write_json {
	my ($path, $data) = @_;
	my $tmp = "$path.tmp";
	open(my $fh, '>', $tmp) or die "Ux: $tmp: $!\n";
	print $fh $JSON->encode($data);
	close $fh;
	rename $tmp, $path or die "Ux: $tmp -> $path: $!\n";
}

sub _write_text {
	my ($path, $text) = @_;
	my $tmp = "$path.tmp";
	open(my $fh, '>', $tmp) or die "Ux: $tmp: $!\n";
	print $fh $text;
	close $fh;
	rename $tmp, $path or die "Ux: $tmp -> $path: $!\n";
}

sub _markdown {
	my ($report) = @_;
	my $s = $report->{'summary'} || {};
	my @lines;
	push @lines, '# Nightly UX report', '';
	push @lines, 'Generated by the fenced QA UX loop (`qa/ux/run`) on '
		. ($s->{'generated'} || '') . '.';
	push @lines, 'This is a **nightly report**, not a code change. No application code was edited.', '';
	push @lines, '- Source: JawnOS-category notes, newest first, limit ' . ($s->{'limit'} || 0);
	push @lines, '- Model: ' . (length($s->{'model'} || '') ? $s->{'model'} : 'none (every judgement is skip)');
	push @lines, '- Notes: ' . ($s->{'total'} // 0)
		. '; pass ' . ($s->{'verdicts'}->{'pass'} // 0)
		. ', warn ' . ($s->{'verdicts'}->{'warn'} // 0)
		. ', fail ' . ($s->{'verdicts'}->{'fail'} // 0)
		. ', skip ' . ($s->{'verdicts'}->{'skip'} // 0);
	push @lines, '';

	for my $entry (@{ $report->{'notes'} || [] }) {
		push @lines, '## ' . ($entry->{'title'} || '(untitled note)');
		push @lines, '';
		push @lines, '- Note: `' . ($entry->{'id'} || '') . '` (' . ($entry->{'timestamp'} || '') . ')';
		push @lines, '- Overall: **' . ($entry->{'overall'} || 'skip') . '**';
		for my $q (qw(easy help works)) {
			my $v = $entry->{'verdicts'}->{$q} || {};
			push @lines, '- ' . ucfirst($q) . ': **' . ($v->{'verdict'} || 'skip') . '**'
				. (length($v->{'evidence'} || '') ? ' - ' . $v->{'evidence'} : '');
		}
		my $a = $entry->{'attempt'} || {};
		push @lines, '- Where it got stuck: ' . ($a->{'stuck'} || 'not recorded');
		push @lines, '- Steps: ' . (@{ $a->{'steps'} || [] } ? join(' -> ', @{ $a->{'steps'} }) : 'none');
		push @lines, '- Console errors: ' . (@{ $a->{'console_errors'} || [] }
			? join(' / ', @{ $a->{'console_errors'} }) : 'none');
		push @lines, '- Screenshot: ' . ($a->{'screenshot'} || 'none');
		push @lines, '';
		push @lines, '> ' . join("\n> ", split /\n/, $entry->{'text'} || ''), '';
	}
	return join("\n", @lines) . "\n";
}

# ---------------------------------------------------------------------------
# the one write allowed outside the QA root
# ---------------------------------------------------------------------------

# The summary is filed by the app's own note route, never by SQL. A note with no
# evaluated rows is honest as a Journal entry; anything else is a JawnOS queue
# item, which is where the Coding agent looks.
sub handbook_category {
	my ($class, $report) = @_;
	return @{ $report->{'notes'} || [] } ? 'jawnos' : 'journal';
}

sub file_handbook {
	my ($class, %opt) = @_;
	my $base = $opt{'base'} or die "Ux: file_handbook needs a live base URL\n";
	my $text = $opt{'text'} or die "Ux: file_handbook needs text\n";
	my $category = $opt{'category'} || 'jawnos';

	require Mojo::UserAgent;
	my $ua = Mojo::UserAgent->new(insecure => 1, max_redirects => 5, request_timeout => 30);
	if ($opt{'ticket'}) {
		my $tx = $ua->get($opt{'ticket'});
		die "Ux: the ticket did not mint a session (" . ($tx->res->code // 'no answer') . ")\n"
			unless $tx->res->is_success;
	}
	my $tx = $ua->post("$base/manager/note_save" => form => {
		text => $text, category => $category,
	});
	die "Ux: note_save answered " . ($tx->res->code // 'no answer') . "\n"
		unless $tx->res->is_success;
	my $json = eval { $tx->res->json } || {};
	die "Ux: note_save did not return a uuid\n" unless $json->{'uuid'};
	return { uuid => $json->{'uuid'} // '', category => $category };
}

1;
