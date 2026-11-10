# tests-for: lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Controller/manager_misc.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Remote.pm perl/Manager.pl perl/help/topics_configure.pl perl/language.pl public/js/manager/ qa/coding_night/agent.pl qa/coding_night/lib/ qa/coding_night/run.pl qa/device_target.pl qa/lib/ qa/run.pl qa/systemd/jawnos-qa-coding.service qa/systemd/jawnos-qa-coding.timer qa/systemd/jawnos-qa.service scripts/restart.pl scripts/version_bump.pl templates/
# covers:    The 06:00 coding nightly and the Notes-per-night picker.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../qa/lib", "$FindBin::Bin/../qa/coding_night/lib";
use Test::More;
use Cwd qw(abs_path);
use DBI;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JSON::PP;

# The 06:00 coding nightly and the Notes-per-night picker.
#
# Everything here uses throwaway git repositories and databases under a
# tempdir: no real worktree is created, the live tree is never fetched,
# committed or restarted, and no HTTP request leaves loopback. The one live
# path is the fake manager the green test posts its note_save to.

my $root = abs_path("$FindBin::Bin/..");

require JawnOS::Domain::Remote;
require CodingNight;
require QaSetting;

$ENV{'GIT_AUTHOR_NAME'}     ||= 'qa-test';
$ENV{'GIT_AUTHOR_EMAIL'}    ||= 'qa-test@example.invalid';
$ENV{'GIT_COMMITTER_NAME'}  ||= 'qa-test';
$ENV{'GIT_COMMITTER_EMAIL'} ||= 'qa-test@example.invalid';

my $git_version = `git --version 2>/dev/null` // '';
chomp $git_version;
my $have_git = $git_version =~ /\bgit version/;

# --- the clamp, shared by the panel and the runner ---------------------------
my @clamp_cases = (
	[ undef, 3 ], [ '', 3 ], [ 'abc', 3 ], [ '3.9', 3 ],
	[ 0, 1 ], [ -7, 1 ], [ 1, 1 ], [ 7, 7 ], [ ' 7 ', 7 ],
	[ 25, 25 ], [ 26, 25 ], [ 1000, 25 ],
);
for my $case (@clamp_cases) {
	my ($in, $want) = @{$case};
	is(QaSetting::clamp_note_limit($in), $want,
		"QaSetting clamps " . (defined $in ? "'$in'" : 'undef') . " to $want");
	is(subs::qa_note_limit_clamp($in), $want,
		"the panel helper agrees on " . (defined $in ? "'$in'" : 'undef'));
}

# --- the round trip the panel performs --------------------------------------
my %store;
my $setter = sub { $store{'value'} = $_[0]; };
my $grabber = sub { $store{'value'} };

my $saved = subs::qa_note_limit_save(7, { setter => $setter });
ok($saved->{'ok'}, 'a valid number saves');
is($store{'value'}, 7, 'seven is stored as seven');
is(subs::qa_note_limit({ grabber => $grabber }), 7, 'the panel reads it back');

my $high = subs::qa_note_limit_save(99, { setter => $setter });
is($high->{'note_limit'}, 25, 'an out-of-range save is clamped to 25');
is($high->{'clamped'}, 1, 'the response says it was clamped');
is($store{'value'}, 25, 'the clamped value is what is written');

my $low = subs::qa_note_limit_save(0, { setter => $setter });
is($low->{'note_limit'}, 1, 'zero clamps to 1');

my $junk = subs::qa_note_limit_save('tomorrow', { setter => $setter });
is($junk->{'note_limit'}, 3, 'junk reads as the default');

# --- the UX judgement model (its own setting, not the Coding role) -----------
my %model_store;
my $model_set = sub { $model_store{'value'} = $_[0] };
my $model_saved = subs::qa_ux_model_save('deepseek:deepseek-flash', { setter => $model_set });
ok($model_saved->{'ok'}, 'a model saves');
is($model_store{'value'}, 'deepseek:deepseek-flash', 'and is stored as written');
is(subs::qa_ux_model({ grabber => sub { $model_store{'value'} } }), 'deepseek:deepseek-flash',
	'the panel reads it back');
my $model_blank = subs::qa_ux_model_save('', { setter => $model_set });
ok($model_blank->{'ok'}, 'an empty model is allowed');
is($model_store{'value'}, '', 'and turns the judgement off');
is(subs::qa_ux_model({ grabber => sub { $model_store{'value'} } }), '', 'an empty model reads empty');
my $model_bad = subs::qa_ux_model_save("deepseek flash\nrm -rf /", { setter => $model_set });
ok(!$model_bad->{'ok'}, 'a value that is not a model id is refused');
is($model_store{'value'}, '', 'and nothing is overwritten');
is(subs::qa_ux_model_clean('  @table/gemma4:cloud  '), '@table/gemma4:cloud',
	'a host-qualified model id is kept');

# --- the dropdown offers only models that can answer here --------------------
my @fake_catalogue = (
	{ id => 'deepseek', label => 'DeepSeek', models => [
		{ value => 'deepseek:deepseek-flash', name => 'deepseek-flash', caps => ['chat'], paid => 0, bucket => 'deepseek' },
		{ value => 'deepseek:deepseek-v4-pro', name => 'deepseek-v4-pro', caps => ['chat'], paid => 1, bucket => 'deepseek' },
		{ value => 'deepseek:picture', name => 'picture', caps => ['image'], paid => 0, bucket => 'deepseek' },
	]},
	{ id => 'openai', label => 'OpenAI', models => [
		{ value => 'openai:gpt-5', name => 'gpt-5', caps => ['chat'], paid => 0, bucket => 'openai' },
	]},
	{ id => 'ollama:Laptop', label => 'Ollama \x{00b7} Laptop', models => [
		{ value => '@Laptop/llama', name => 'llama', caps => ['chat'], paid => 0, bucket => 'ollama' },
	]},
);
my $choices = subs::qa_ux_model_choices({
	catalogue => \@fake_catalogue,
	ready => sub { $_[0] ne 'openai' },
	available => sub { $_[0] ne 'deepseek' },
});
is_deeply([ map { $_->{'label'} } @{$choices} ], [ 'DeepSeek', 'Ollama \x{00b7} Laptop' ],
	'the dropdown skips a provider with no key and keeps the peer group');
is_deeply([ map { $_->{'value'} } @{ $choices->[0]->{'models'} } ], [ 'deepseek:deepseek-flash' ],
	'a paid model in a stood-down bucket and a non-chat model are not offered');
is_deeply([ map { $_->{'value'} } @{ $choices->[1]->{'models'} } ], [ '@Laptop/llama' ],
	'a peer Ollama model is offered under its machine');

# A fixture database for the queue and for the setting's read path.
sub make_db {
	my $dir = tempdir(CLEANUP => 1);
	my $db = "$dir/jawnos.db";
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '',
		{ RaiseError => 1, PrintError => 0 });
	$dbh->do('create table notes (uuid text unique, timestamp text, server_time text,'
		. ' app text, device text, text text, ost text, category text, status text)');
	$dbh->do('create table settings (app text, setting text, device text,'
		. ' value text, server_time text)');
	return ($db, $dir, $dbh);
}

sub add_note {
	my ($dbh, %n) = @_;
	$dbh->do('insert into notes (uuid, timestamp, server_time, app, device, text, ost, category, status)'
		. ' values (?,?,?,?,?,?,?,?,?)', undef,
		$n{'uuid'}, $n{'timestamp'} // '1000', '1000', 'notes', 'qa',
		$n{'text'} // ('note ' . $n{'uuid'}), $n{'ost'} // '',
		$n{'category'} // 'jawnos', $n{'status'} // 'open');
}

my ($qdb, $qdir, $qdbh) = make_db();
add_note($qdbh, uuid => 'n-open-new', timestamp => '5000', text => "Fix the new thing\nbecause it matters");
add_note($qdbh, uuid => 'n-done',     timestamp => '4000', status => 'completed');
add_note($qdbh, uuid => 'n-gone',     timestamp => '3500', ost => 'deleting');
add_note($qdbh, uuid => 'n-journal',  timestamp => '3000', category => 'journal');
add_note($qdbh, uuid => 'n-open-old', timestamp => '2000', text => 'Older open note');
add_note($qdbh, uuid => 'n-empty',    timestamp => '9000', text => '');
$qdbh->disconnect;

my $queue = CodingNight::select_notes($qdb, limit => 25);
is_deeply([ map { $_->{'id'} } @{$queue} ], [ 'n-open-new', 'n-open-old' ],
	'only open JawnOS notes are in the queue; completed, tombstoned, journal and empty rows are not');
is($queue->[0]->{'title'}, 'Fix the new thing', 'the title is the first line');
is(CodingNight::select_notes($qdb, limit => 1)->[0]->{'id'}, 'n-open-new',
	'the limit takes the newest open notes first');
is_deeply(CodingNight::select_notes($qdb, limit => 1000), $queue,
	'a huge limit is clamped to a sane queue, not a crash');

my ($sdb, $sdir, $sdbh) = make_db();
$sdbh->do("insert into settings (app, setting, device, value, server_time)"
	. " values ('__president', 'qa_note_limit', 'all', ?, '1000')", undef, '30');
$sdbh->disconnect;
is(QaSetting::read_note_limit($sdb), 25, 'a saved 30 reads back clamped to 25');

$sdbh = DBI->connect("dbi:SQLite:dbname=$sdb", '', '', { RaiseError => 1, PrintError => 0 });
$sdbh->do("delete from settings");
$sdbh->disconnect;
is(QaSetting::read_note_limit($sdb), 3, 'no saved row reads as the default');

# --- what the coding night works on ----------------------------------------
# The panel and the fenced runner share one rule for the lanes, like the note
# limit, and the queue is built from the reports the two nightly jobs leave.

my @lane_cases = (
	[ undef,                     [ 'notes' ] ],
	[ '',                        [ 'notes' ] ],
	[ 'notes',                   [ 'notes' ] ],
	[ 'security',                [ 'security' ] ],
	[ 'security,notes',          [ 'notes', 'security' ] ],
	[ ' installers , security ', [ 'security', 'installers' ] ],
	[ 'bogus,notes',             [ 'notes' ] ],
	[ 'bogus',                   [ 'notes' ] ],
	[ [ 'installers', 'notes', 'installers' ], [ 'notes', 'installers' ] ],
);
for my $case (@lane_cases) {
	my ($in, $want) = @{$case};
	is_deeply([ QaSetting::clamp_coding_lanes($in) ], $want,
		'QaSetting lanes for ' . (ref $in ? 'an array' : (defined $in ? "'$in'" : 'undef')));
	is_deeply([ subs::qa_coding_lanes_clamp($in) ], $want, 'and the panel helper agrees');
}

my %lane_store;
my $lane_set = sub { $lane_store{'value'} = $_[0] };
my $lane_saved = subs::qa_coding_lanes_save('security,notes', { setter => $lane_set });
ok($lane_saved->{'ok'}, 'a lane list saves');
is($lane_store{'value'}, 'notes,security', 'and is stored in canonical order');
is_deeply($lane_saved->{'lanes'}, [ 'notes', 'security' ], 'the response says what was kept');
my $lane_empty = subs::qa_coding_lanes_save('', { setter => $lane_set });
ok(!$lane_empty->{'ok'}, 'an empty choice is refused');
is($lane_store{'value'}, 'notes,security', 'and nothing is overwritten');

# A QA root holding the two reports the night reads.
my $qa_night = tempdir(CLEANUP => 1);
make_path("$qa_night/reports/security/20261106T044500Z", "$qa_night/reports/installers/20261106T034500Z");
write_file("$qa_night/reports/security/20261106T044500Z/report.json", encode_json({
	findings => [
		{ id => 'x.high',   severity => 'high',     known => 0, title => 'high one', path => 'lib/A.pm', line => 3, area => 'rce', evidence => 'e', fix => 'f' },
		{ id => 'x.known',  severity => 'critical', known => 1, title => 'known',    path => 'lib/B.pm', line => 4 },
		{ id => 'x.medium', severity => 'medium',   known => 0, title => 'medium',   path => 'lib/C.pm', line => 5 },
		{ id => 'x.crit',   severity => 'critical', known => 0, title => 'crit',     path => 'lib/D.pm', line => 6 },
	],
}));
write_file("$qa_night/reports/installers/20261106T034500Z/report.json", encode_json({
	modules   => [ { name => 'Gone::Module', status => 'missing', installed => '1.0' },
				   { name => 'Fine',        status => 'current', installed => '2.0' } ],
	debian    => [ { package => 'gone-pkg', status => 'missing', installed => '1' } ],
	arch      => [ { package => 'old-pkg', status => 'outdated', installed => '1', latest => '2' } ],
	android   => [],
	toolchain => [],
}));

my $sec = CodingNight::security_items($qa_night);
is_deeply([ map { $_->{'title'} } @{$sec} ], [ 'Security: crit', 'Security: high one' ],
	'only new findings at or above high are queued, worst first');
is(CodingNight::security_items($qa_night, max => 1)->[0]->{'title'}, 'Security: crit',
	'the cap keeps the worst one');
like($sec->[0]->{'text'}, qr/security_audit\.pl --check/, 'the task names the check that must stay clean');
is_deeply([ map { $_->{'id'} } @{ CodingNight::installer_items($qa_night) } ],
	[ 'installers:modules:Gone::Module', 'installers:debian:gone-pkg' ],
	'only installer rows reported missing are queued');

my $all_lanes = CodingNight::select_queue($qdb,
	lanes => [ 'notes', 'security', 'installers' ], limit => 25, qa_root => $qa_night);
is_deeply([ map { $_->{'source'} } @{$all_lanes} ],
	[ 'notes', 'notes', 'security', 'security', 'installers', 'installers' ],
	'the queue carries the lanes in order, notes first');
my $notes_only = CodingNight::select_queue($qdb, lanes => [ 'notes' ], limit => 25, qa_root => $qa_night);
is(scalar @{$notes_only}, 2, 'notes only leaves the reports unread');
my $sec_only = CodingNight::select_queue($qdb, lanes => [ 'security' ], limit => 25, qa_root => $qa_night);
is_deeply([ map { $_->{'source'} } @{$sec_only} ], [ 'security', 'security' ],
	'a security-only night has no notes');
is_deeply(CodingNight::select_queue($qdb, lanes => [ 'security' ], limit => 25,
	qa_root => tempdir(CLEANUP => 1)), [], 'a machine that wrote no report has no work');

# --- naming and layers ------------------------------------------------------
my $paths = CodingNight::plan_paths('/qa/root', '20261102-060000', 3);
is($paths->{'branch'}, 'qa/nightly-20261102-060000-3', 'the branch naming is <stamp>-<n>');
is($paths->{'worktree'}, '/qa/root/work/20261102-060000-3', 'the worktree lives under the QA root');

is(CodingNight::layers_for_files([ 'qa/run.pl', 't/88-x.t' ]), 'l0,l1',
	'a QA/test-only change runs l0 and l1');
is(CodingNight::layers_for_files([ 'templates/apps/x.html.ep' ]), 'l0,l1,l2,l3',
	'a template change adds the database and browser layers');
is(CodingNight::layers_for_files([ 'public/js/manager/x.js' ]), 'l0,l1,l2,l3',
	'a JavaScript change adds them');
is(CodingNight::layers_for_files([ 'lib/JawnOS/Controller/manager_misc.pm' ]), 'l0,l1,l2,l3',
	'a route change adds them');
is(CodingNight::layers_for_files([ 'perl/Manager.pl' ]), 'l0,l1,l2,l3',
	'a perl service change adds them');

# --- the runner, against throwaway repositories ------------------------------
sub git_ok {
	my ($cwd, @args) = @_;
	my $rc = system('git', '-C', $cwd, @args);
	return $rc == 0;
}

sub git_out {
	my ($cwd, @args) = @_;
	my $out = `git -C '$cwd' @args 2>/dev/null`;
	return $out;
}

sub agent_script {
	my ($dir) = @_;
	my $path = "$dir/agent.pl";
	write_file($path, <<'AGENT');
use strict;
use warnings;
use File::Path qw(make_path);
my $log = $ENV{'FAKE_AGENT_LOG'} || '';
if (length $log) {
	open(my $lf, '>>', $log) or die $!;
	print $lf join("\t", $ENV{'JAWNOS_NOTE_ID'} // '', $ENV{'JAWNOS_NOTE_TITLE'} // '',
		($ENV{'JAWNOS_NOTE_TEXT'} // '') =~ s/\n/\\n/gr), "\n";
	close $lf;
}
make_path('public/js/manager');
open(my $fh, '>', 'public/js/manager/zz_agent_change.js') or die $!;
print $fh "// the agent changed this\n";
close $fh;
exit 0;
AGENT
	return $path;
}

sub fake_repo {
	my (%a) = @_;
	my $dir = tempdir(CLEANUP => 1);
	my $bare = "$dir/origin.git";
	my $repo = "$dir/repo";
	make_path("$repo/scripts", "$repo/qa", "$repo/public/js/manager");
	git_ok($dir, 'init', '--bare', '-q', $bare) or die "bare git init failed";
	git_ok($dir, 'init', '-q', '-b', 'main', $repo) or die "git init failed";

	write_file("$repo/VERSION", "0.0.1\n");
	write_file("$repo/scripts/version_bump.pl", <<'BUMP');
#!/usr/bin/perl
open(my $fh, '>', 'VERSION') or die $!;
print $fh "0.0.2\n";
close $fh;
exit 0;
BUMP
	write_file("$repo/scripts/restart.pl", <<'RESTART');
#!/usr/bin/perl
use strict;
use warnings;
my $log = $ENV{'FAKE_RESTART_LOG'} || '';
if (length $log) {
	open(my $fh, '>>', $log) or die $!;
	print $fh join(' ', @ARGV), "\n";
	close $fh;
}
exit(0 + ($ENV{'FAKE_RESTART_EXIT'} // 0));
RESTART
	write_file("$repo/qa/run.pl", <<'QA');
#!/usr/bin/perl
use strict;
use warnings;
my $log = $ENV{'FAKE_QA_LOG'} || '';
if (length $log) {
	open(my $fh, '>>', $log) or die $!;
	print $fh join(' ', @ARGV), "\n";
	close $fh;
}
# A counter-driven exit sequence lets one run be red and the next green
# without changing the plain FAKE_QA_EXIT contract older tests rely on.
my $exit = 0;
if (defined $ENV{'FAKE_QA_EXITS'} && length $ENV{'FAKE_QA_EXITS'}) {
	my @exits = grep { length } split /[,\s]+/, $ENV{'FAKE_QA_EXITS'};
	my $n = 0;
	if (my $counter = $ENV{'FAKE_QA_COUNTER'}) {
		if (-f $counter) {
			open(my $cf, '<', $counter) or die $!;
			$n = <$cf> // 0;
			close $cf;
			$n =~ s/\s+//g;
		}
		$n++;
		open(my $cf, '>', $counter) or die $!;
		print $cf $n;
		close $cf;
	}
	else {
		$n = 1;
	}
	my $i = $n > 0 ? $n - 1 : 0;
	$i = $#exits if $i > $#exits;
	$exit = 0 + $exits[$i];
}
else {
	$exit = 0 + ($ENV{'FAKE_QA_EXIT'} // 0);
}
# A real suite names its failing test on stdout, which is what the repair
# prompt reads back out of the suite log.
print "not ok 1 - t/99_fake.t\n# Failed test 'the fake suite'\n" if $exit != 0;
exit($exit);
QA
	write_file("$repo/qa/device_target.pl", "#!/usr/bin/perl\nexit 0;\n");
	write_file("$repo/tracker.txt", "original\n");

	git_ok($repo, 'add', '-A') or die "git add failed";
	git_ok($repo, 'commit', '-q', '-m', 'initial') or die "git commit failed";
	git_ok($repo, 'remote', 'add', 'origin', $bare) or die "git remote failed";
	git_ok($repo, 'push', '-q', '-u', 'origin', 'main') or die "git push failed";

	return { dir => $dir, repo => $repo, bare => $bare };
}

sub run_runner {
	my ($env, @args) = @_;
	my $script = "$root/qa/coding_night/run.pl";
	my $pid = open(my $fh, '-|');
	defined $pid or die "fork: $!";
	if (!$pid) {
		# These cases exercise the landing path; the nightly's own
		# default is branch-only until an operator opts in.
		$ENV{'JAWNOS_QA_AUTO_MERGE'} = '1';
		for my $key (keys %{$env || {}}) {
			if (defined $env->{$key}) { $ENV{$key} = $env->{$key} }
			else { delete $ENV{$key} }
		}
		open(STDERR, '>&', \*STDOUT);
		exec($^X, $script, @args);
		exit 127;
	}
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return (($? >> 8), $out);
}

sub report_for {
	my ($rootdir, $stamp) = @_;
	my $path = "$rootdir/coding/$stamp/report.json";
	return undef unless -f $path;
	return JSON::PP->new->utf8->decode(scalar read_file($path));
}

sub note_status {
	my ($db, $uuid) = @_;
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
	my $row = $dbh->selectrow_hashref('select status from notes where uuid = ?', undef, $uuid);
	$dbh->disconnect;
	return $row ? ($row->{'status'} // '') : '';
}

sub has_branch {
	my ($repo, $branch) = @_;
	return system('git', '-C', $repo, 'show-ref', '--verify', '--quiet', "refs/heads/$branch") == 0;
}

sub app_server {
	my ($dir, %a) = @_;
	my $server = "$dir/app_server.pl";
	write_file($server, <<'SERVER');
use strict;
use warnings;
use IO::Socket::INET;
my ($log, $portfile) = @ARGV;
my $srv = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 20, ReuseAddr => 1)
	or die "listen: $!";
open(my $pf, '>', $portfile) or die $!;
print $pf $srv->sockport;
close $pf;
while (my $c = $srv->accept) {
	my $line = <$c> // '';
	my %h;
	while (my $l = <$c>) {
		last if $l =~ /^\r?\n$/;
		my ($k, $v) = split /:\s*/, $l, 2;
		$h{lc $k} = defined $v ? $v : '' if defined $k;
	}
	my $body = '';
	my $len = $h{'content-length'};
	if ($len) { read($c, $body, $len); }
	$body =~ s/\r//g;
	my ($method, $path) = $line =~ /^(\S+)\s+(\S+)/;
	if ($log) {
		open(my $lf, '>>', $log) or die $!;
		print $lf join(' ', $method // '', $path // '', $body), "\n";
		close $lf;
	}
	my $health = defined $path && $path =~ m{/manager/health};
	my $status = $health
		? (0 + ($ENV{'FAKE_HEALTH_STATUS'} // 200))
		: (0 + ($ENV{'FAKE_NOTE_STATUS'} // 200));
	my $payload = (defined $path && $path =~ m{/note_save}) ? '{"uuid":"posted"}' : '{"ok":1}';
	print $c "HTTP/1.1 $status Result\r\nContent-Type: application/json\r\n"
		. "Content-Length: " . length($payload) . "\r\nConnection: close\r\n\r\n$payload";
	close $c;
}
SERVER

	my $portfile = "$dir/port";
	unlink $portfile;
	my $pid = fork();
	defined $pid or die "fork: $!";
	if (!$pid) {
		for my $key (keys %a) { $ENV{$key} = $a{$key} if defined $a{$key} }
		exec($^X, $server, "$dir/requests.log", $portfile);
		exit 127;
	}
	for (1 .. 200) { last if -f $portfile; select undef, undef, undef, 0.02 }
	my $port = -f $portfile ? read_file($portfile) : '';
	$port =~ s/\s+//g;
	die "the fake manager did not start" unless $port =~ /^\d+$/;
	return ($pid, $port);
}

SKIP: {
	skip 'git is not installed', 81 unless $have_git;

	# -- dry run changes nothing -------------------------------------------
	my $dry = fake_repo();
	my ($ddb, $ddir, $ddbh) = make_db();
	add_note($ddbh, uuid => 'dry-1', timestamp => '2000', text => 'Dry run note');
	$ddbh->disconnect;
	my $dry_root = "$dry->{'dir'}/qa-root";
	my $head_before = git_out($dry->{'repo'}, 'rev-parse', 'HEAD');
	my ($dry_rc, $dry_out) = run_runner(
		{ 'JAWNOS_CODING_AGENT' => "$^X /bin/true" },
		'--dry-run', '--ignore-device', '--repo', $dry->{'repo'},
		'--root', $dry_root, '--db', $ddb, '--stamp', 'dry01', '--limit', '5');
	is($dry_rc, 0, 'a dry run exits 0');
	like($dry_out, qr/qa\/nightly-dry01-1/, 'the dry run prints the planned branch');
	like($dry_out, qr/notes per night: 5/i, 'the dry run prints the limit');
	ok(!-e "$dry_root/work", 'a dry run creates no work directory');
	ok(!-e "$dry_root/coding", 'a dry run writes no report');
	ok(!-e "$dry_root/.coding-night.lock", 'a dry run takes no lock');
	ok(!has_branch($dry->{'repo'}, 'qa/nightly-dry01-1'), 'a dry run creates no branch');
	is(git_out($dry->{'repo'}, 'rev-parse', 'HEAD'), $head_before,
		'a dry run leaves main untouched');

	# -- no agent is exit 3, and no branch --------------------------------
	my $none = fake_repo();
	my ($ndb, $ndir, $ndbh) = make_db();
	add_note($ndbh, uuid => 'no-agent-1', timestamp => '2000', text => 'Needs an agent');
	$ndbh->disconnect;
	my $none_root = "$none->{'dir'}/qa-root";
	my $none_head = git_out($none->{'repo'}, 'rev-parse', 'HEAD');
	my ($no_rc, $no_out) = run_runner(
		{ 'JAWNOS_CODING_AGENT' => undef },
		'--agent', '', '--ignore-device', '--repo', $none->{'repo'}, '--root', $none_root,
		'--db', $ndb, '--stamp', 'noagent01');
	is($no_rc, 3, 'no configured agent exits 3');
	like($no_out, qr/no coding agent configured/i, 'the message says why');
	ok(!-e "$none_root/work", 'no worktree was created');
	ok(!-e "$none_root/coding", 'no report was written');
	ok(!has_branch($none->{'repo'}, 'qa/nightly-noagent01-1'), 'no branch was created');
	is(git_out($none->{'repo'}, 'rev-parse', 'HEAD'), $none_head,
		'main was not touched');

	# -- a red suite leaves the worktree, removes the branch, keeps the note open
	my $red = fake_repo();
	my ($rdb, $rdir, $rdbh) = make_db();
	add_note($rdbh, uuid => 'red-1', timestamp => '2000', text => 'A note that breaks the suite');
	$rdbh->disconnect;
	my $red_root = "$red->{'dir'}/qa-root";
	my $red_agent = agent_script($red->{'dir'});
	my $red_head = git_out($red->{'repo'}, 'rev-parse', 'HEAD');
	my ($red_rc, $red_out) = run_runner(
		{ 'JAWNOS_CODING_AGENT' => "$^X $red_agent", 'FAKE_QA_EXIT' => 1 },
		'--ignore-device', '--repo', $red->{'repo'}, '--root', $red_root,
		'--db', $rdb, '--stamp', 'red01', '--limit', '1',
		'--live-url', 'http://127.0.0.1:1', '--health-url', 'http://127.0.0.1:1/health',
		'--ticket', '');
	is($red_rc, 1, 'a red suite exits 1');
	my $red_report = report_for($red_root, 'red01');
	ok(ref $red_report eq 'HASH', 'a red run writes a report');
	is($red_report->{'runs'}->[0]->{'status'}, 'red', 'the report says the suite was red');
	ok(-d "$red_root/work/red01-1", 'the worktree is left for inspection');
	ok(!has_branch($red->{'repo'}, 'qa/nightly-red01-1'), 'the branch is removed');
	is(git_out($red->{'repo'}, 'rev-parse', 'HEAD'), $red_head, 'main is untouched');
	is(note_status($rdb, 'red-1'), 'open', 'the note stays open');
	like($red_report->{'runs'}->[0]->{'error'}, qr/suite failed/i, 'the report names the failure');

	# -- a red suite that one repair turns green ---------------------------
	my $rep = fake_repo();
	my ($pdb, $pdir, $pdbh) = make_db();
	add_note($pdbh, uuid => 'repair-1', timestamp => '2000',
		text => "Fix the failing thing\nwith the test");
	$pdbh->disconnect;
	my $rep_root = "$rep->{'dir'}/qa-root";
	my $rep_agent = agent_script($rep->{'dir'});
	my ($rpid, $rport) = app_server($rep->{'dir'});
	my ($rep_rc, $rep_out) = run_runner(
		{
			'JAWNOS_CODING_AGENT' => "$^X $rep_agent",
			'FAKE_QA_EXITS'       => '1,0',
			'FAKE_QA_COUNTER'     => "$rep->{'dir'}/qa-counter",
			'FAKE_AGENT_LOG'      => "$rep->{'dir'}/agent.log",
			'FAKE_RESTART_LOG'    => "$rep->{'dir'}/restart.log",
		},
		'--ignore-device', '--repo', $rep->{'repo'}, '--root', $rep_root,
		'--db', $pdb, '--stamp', 'repair01', '--limit', '1',
		'--live-url', "http://127.0.0.1:$rport",
		'--health-url', "http://127.0.0.1:$rport/manager/health",
		'--health-wait', '3', '--ticket', '');
	kill 'KILL', $rpid;
	waitpid($rpid, 0);

	is($rep_rc, 0, 'a repair that turns the suite green exits 0');
	my $rep_report = report_for($rep_root, 'repair01');
	ok(ref $rep_report eq 'HASH', 'a repaired run writes a report');
	my $rep_run = $rep_report->{'runs'}->[0] || {};
	is($rep_run->{'status'}, 'green', 'the repaired note is green');
	is($rep_run->{'repair_attempts'}, 1, 'exactly one repair was attempted');
	is_deeply($rep_run->{'repair_exits'}, [0], 'the repair agent exited 0');
	is_deeply($rep_run->{'repair_suite_exits'}, [0], 'the repaired suite exited 0');
	is($rep_run->{'suite_exit'}, 0, 'the recorded suite exit is the repaired run');
	like($rep_run->{'suite_log'} // '', qr/suite-repair-1\.log$/, 'the report points at the repair suite log');
	ok($rep_run->{'marked_completed'}, 'the note was marked completed');
	my $rep_requests = -f "$rep->{'dir'}/requests.log" ? read_file("$rep->{'dir'}/requests.log") : '';
	like($rep_requests, qr/POST \/manager\/note_save .*uuid=repair-1.*status=completed|POST \/manager\/note_save .*status=completed.*uuid=repair-1/,
		'the note is completed through note_save');
	my $rep_agent_log = -f "$rep->{'dir'}/agent.log" ? read_file("$rep->{'dir'}/agent.log") : '';
	like($rep_agent_log, qr/the nightly suite failed \(repair attempt 1 of 2\)/i,
		'the repair agent was told which attempt it was');
	like($rep_agent_log, qr/not ok 1 - t\/99_fake\.t/,
		'the repair note carried the failing test name');
	like(git_out($rep->{'repo'}, 'log', '-1', '--pretty=%s'), qr/^v0\.0\.2 - Fix the failing thing/,
		'the repaired work shipped to main');
	ok(!-d "$rep_root/work/repair01-1", 'a green worktree is cleaned up after a repair');
	ok(!has_branch($rep->{'repo'}, 'qa/nightly-repair01-1'), 'a repaired branch is cleaned up');

	# -- a suite that stays red stops after two repairs --------------------
	my $hard = fake_repo();
	my ($hdb, $hdir, $hdbh) = make_db();
	add_note($hdbh, uuid => 'hard-1', timestamp => '2000', text => 'A note the repair cannot save');
	$hdbh->disconnect;
	my $hard_root = "$hard->{'dir'}/qa-root";
	my $hard_agent = agent_script($hard->{'dir'});
	my $hard_head = git_out($hard->{'repo'}, 'rev-parse', 'HEAD');
	my ($hard_rc, $hard_out) = run_runner(
		{
			'JAWNOS_CODING_AGENT' => "$^X $hard_agent",
			'FAKE_QA_EXITS'       => '1,1,1',
			'FAKE_QA_COUNTER'     => "$hard->{'dir'}/qa-counter",
			'FAKE_AGENT_LOG'      => "$hard->{'dir'}/agent.log",
		},
		'--ignore-device', '--repo', $hard->{'repo'}, '--root', $hard_root,
		'--db', $hdb, '--stamp', 'hard01', '--limit', '1',
		'--live-url', 'http://127.0.0.1:1', '--health-url', 'http://127.0.0.1:1/health',
		'--ticket', '');
	is($hard_rc, 1, 'a suite still red after the repairs exits 1');
	my $hard_report = report_for($hard_root, 'hard01');
	my $hard_run = $hard_report->{'runs'}->[0] || {};
	is($hard_run->{'status'}, 'red', 'the note is red after the repairs');
	is($hard_run->{'repair_attempts'}, 2, 'two repairs were attempted');
	is_deeply($hard_run->{'repair_exits'}, [0, 0], 'both repair agents exited 0');
	is_deeply($hard_run->{'repair_suite_exits'}, [1, 1], 'both repaired suites stayed red');
	ok(-d "$hard_root/work/hard01-1", 'the worktree is still left for inspection');
	ok(!has_branch($hard->{'repo'}, 'qa/nightly-hard01-1'), 'the branch is removed');
	is(git_out($hard->{'repo'}, 'rev-parse', 'HEAD'), $hard_head, 'main is untouched');
	is(note_status($hdb, 'hard-1'), 'open', 'the note stays open');
	my $hard_failure = -f "$hard_root/coding/hard01/failure.md"
		? read_file("$hard_root/coding/hard01/failure.md") : '';
	like($hard_failure, qr/repairs: 2 \(agent exits 0, 0/,
		'failure.md says how many repairs were tried');
	my $hard_md = -f "$hard_root/coding/hard01/report.md"
		? read_file("$hard_root/coding/hard01/report.md") : '';
	like($hard_md, qr/repairs: 2 \(agent exits 0, 0/,
		'report.md says how many repairs were tried');

	# -- green only after health 200 --------------------------------------
	my $green = fake_repo();
	my ($gdb, $gdir, $gdbh) = make_db();
	add_note($gdbh, uuid => 'green-1', timestamp => '2000',
		text => "Make the thing work\nwith a test");
	$gdbh->disconnect;
	my $green_root = "$green->{'dir'}/qa-root";
	my $green_agent = agent_script($green->{'dir'});
	my ($pid, $port) = app_server($green->{'dir'});
	my ($green_rc, $green_out) = run_runner(
		{
			'JAWNOS_CODING_AGENT' => "$^X $green_agent",
			'FAKE_QA_LOG' => "$green->{'dir'}/qa.log",
			'FAKE_RESTART_LOG' => "$green->{'dir'}/restart.log",
			'FAKE_AGENT_LOG' => "$green->{'dir'}/agent.log",
		},
		'--ignore-device', '--repo', $green->{'repo'}, '--root', $green_root,
		'--db', $gdb, '--stamp', 'green01', '--limit', '2',
		'--live-url', "http://127.0.0.1:$port",
		'--health-url', "http://127.0.0.1:$port/manager/health",
		'--health-wait', '3', '--ticket', '');
	kill 'KILL', $pid;
	waitpid($pid, 0);

	is($green_rc, 0, 'a green night exits 0');
	my $green_report = report_for($green_root, 'green01');
	ok(ref $green_report eq 'HASH', 'a green run writes a report');
	my $run = $green_report->{'runs'}->[0] || {};
	is($run->{'status'}, 'green', 'the note is green');
	is($run->{'branch'}, 'qa/nightly-green01-1', 'the branch naming is pinned');
	is($run->{'worktree'}, "$green_root/work/green01-1", 'the worktree naming is pinned');
	ok($run->{'pushed'}, 'the branch was pushed');
	ok($run->{'merged'}, 'main fast-forwarded');
	ok($run->{'restarted'}, 'the restart was accepted');
	is($green_report->{'rollback_tag'}, 'nightly-pre-green01', 'the run records its pre-merge tag');
	ok(-x "$green_root/coding/green01/rollback.sh", 'rollback.sh is written and executable');
	ok(git_out($green->{'repo'}, 'tag', '--list', 'nightly-pre-green01') =~ /nightly-pre-green01/,
		'the tag exists in the checkout');
	ok($run->{'health_ok'}, 'health answered 200');
	ok($run->{'marked_completed'}, 'only then was the note marked completed');
	is($run->{'layers'}, 'l0,l1,l2,l3', 'a JavaScript change added l2 and l3');

	like(scalar read_file("$green->{'dir'}/qa.log"), qr/--layers l0,l1,l2,l3/,
		'the suite ran inside the worktree with the chosen layers');
	my $agent_log = -f "$green->{'dir'}/agent.log" ? read_file("$green->{'dir'}/agent.log") : '';
	like($agent_log, qr/green-1\tMake the thing work\tMake the thing work\\nwith a test/,
		'the agent got the note id, title and text in its environment');
	like(scalar read_file("$green->{'dir'}/restart.log"), qr/--reason v0\.0\.2 - Make the thing work/,
		'the restart carries the versioned note title');
	my $requests = -f "$green->{'dir'}/requests.log" ? read_file("$green->{'dir'}/requests.log") : '';
	like($requests, qr/POST \/manager\/note_save .*uuid=green-1.*status=completed|POST \/manager\/note_save .*status=completed.*uuid=green-1/,
		'the note is completed through POST /manager/note_save');
	like($requests, qr/category=journal/, 'the nightly files a journal report note');
	like(git_out($green->{'repo'}, 'log', '-1', '--pretty=%s'), qr/^v0\.0\.2 - Make the thing work/,
		'main carries the versioned commit');
	ok(!-d "$green_root/work/green01-1", 'a green worktree is cleaned up');
	ok(!has_branch($green->{'repo'}, 'qa/nightly-green01-1'), 'a merged branch is cleaned up');

	# -- the same night, but health never turns 200 -----------------------
	my $sick = fake_repo();
	my ($kdb, $kdir, $kdbh) = make_db();
	add_note($kdbh, uuid => 'sick-1', timestamp => '2000', text => 'A note that ships but never gets healthy');
	$kdbh->disconnect;
	my $sick_root = "$sick->{'dir'}/qa-root";
	my $sick_agent = agent_script($sick->{'dir'});
	my ($spid, $sport) = app_server($sick->{'dir'}, 'FAKE_HEALTH_STATUS' => 503);
	my ($sick_rc) = run_runner(
		{
			'JAWNOS_CODING_AGENT' => "$^X $sick_agent",
			'FAKE_RESTART_LOG' => "$sick->{'dir'}/restart.log",
		},
		'--ignore-device', '--repo', $sick->{'repo'}, '--root', $sick_root,
		'--db', $kdb, '--stamp', 'sick01', '--limit', '1',
		'--live-url', "http://127.0.0.1:$sport",
		'--health-url', "http://127.0.0.1:$sport/manager/health",
		'--health-wait', '1', '--ticket', '');
	kill 'KILL', $spid;
	waitpid($spid, 0);

	is($sick_rc, 1, 'a house that never answers 200 exits 1');
	my $sick_report = report_for($sick_root, 'sick01');
	is($sick_report->{'runs'}->[0]->{'status'}, 'health_failed', 'the report names health');
	ok(!$sick_report->{'runs'}->[0]->{'marked_completed'}, 'the note is not completed');
	is(note_status($kdb, 'sick-1'), 'open', 'the note stays open');
	is($sick_report->{'runs'}->[0]->{'rolled_back'}, 'yes',
		'a post-merge health failure rolls main back to the pre-night tag');
	ok(!$sick_report->{'runs'}->[0]->{'rollback_health_ok'},
		'the rollback health result is recorded honestly');
	ok(-f "$sick_root/coding/sick01/failure.md", 'a failure.md hands the night over');
	my $sick_requests = -f "$sick->{'dir'}/requests.log" ? read_file("$sick->{'dir'}/requests.log") : '';
	my $sick_body = $sick_requests;
	$sick_body =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
	$sick_body =~ s/\+/ /g;
	like($sick_body, qr/POST \/manager\/note_save .*status=open/,
		'a failure note is filed with status open');
	like($sick_body, qr/Nightly failed: A note that ships/,
		'the failure note names the original note');
	unlike($sick_body, qr/uuid=sick-1/,
		'the original note is never marked completed on a failure');
	like(scalar read_file("$sick->{'dir'}/restart.log"), qr/--reason/, 'the restart still happened (health was the gate)');
}

# --- the unit files ---------------------------------------------------------
my $coding_unit = read_file("$root/qa/systemd/jawnos-qa-coding.service");
like($coding_unit, qr/ExecStart=.*qa\/coding_night\/run\.pl/, 'the coding unit runs the runner');
like($coding_unit, qr/ExecCondition=.*device_target\.pl/, 'it is gated like the QA nightly');
like($coding_unit, qr/Nice=/, 'it is nice');
like($coding_unit, qr/MemoryMax=4G/, 'it is capped at 4G');
like($coding_unit, qr/ReadWritePaths=.*\/home\/jawn\/jawnos\b/, 'the checkout is writable');
unlike($coding_unit, qr/ProtectHome=read-only/,
	'the coding night has repo write access (the one unit without ProtectHome=read-only)');
unlike($coding_unit, qr/manager_killer/,
	'the unit never names manager_killer');
like($coding_unit, qr/PrivateTmp=yes/, 'it still has its private tmp');

my $qa_unit = read_file("$root/qa/systemd/jawnos-qa.service");
like($qa_unit, qr/ProtectHome=read-only/, 'the 04:00 QA unit keeps the read-only home');

my $coding_timer = read_file("$root/qa/systemd/jawnos-qa-coding.timer");
like($coding_timer, qr/OnCalendar=\*-\*-\* 06:00:00/, 'the timer is 06:00 daily');
like($coding_timer, qr/Unit=jawnos-qa-coding\.service/, 'the timer drives the coding service');
like($coding_timer, qr/Persistent=true/, 'a missed night is caught up');

# --- the picker, the panel route, language and help -------------------------
my $panel = read_file("$root/templates/configure/qa_panel.html.ep");
like($panel, qr/id="qa_note_limit"/, 'the QA panel carries the notes-per-night select');
like($panel, qr/\$qa_note_min \.\. \$qa_note_max/, 'the options come from the server bounds');
like($panel, qr/qa_note_limit\(\)/, 'the saved number is rendered');
like($panel, qr/configure\.qa_note_limit/, 'the label is a core language key');
my $plat = read_file("$root/templates/configure/plat_setting_list.html.ep");
like($plat, qr/<select[^>]*id="qa_ux_model"/, 'the UX model is a dropdown in the AI tab');
like($plat, qr/configure\.qa_ux_model/, 'the model label is a core language key');
like($plat, qr/optgroup/, 'the dropdown groups eligible models by provider');
like($plat, qr/qa_ux_model_choices/, 'the dropdown is built from the eligible-model helper');
unlike($panel, qr/id="qa_ux_model"/, 'and has left the QA Nightly tab');

my $js = read_file("$root/public/js/manager/configure/07_qa_nightly.js");
like($js, qr/'#qa_note_limit'/, 'the script listens to the select');
like($js, qr/field: 'note_limit'/, 'the script names the field it saves');
like($js, qr/'#qa_ux_model'/, 'the script listens to the model field');
like($js, qr/field: 'ux_model'/, 'the script names the model field it saves');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure2.pm");
like($controller, qr/qa_note_limit_save\(/, 'the route validates the number server-side');
like($controller, qr/field.*note_limit/s, 'the route only saves the limit when that field is named');
like($controller, qr/qa_ux_model_save\(/, 'the route validates the UX model server-side');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Remote.*qa_note_limit_save/, 'the loader maps the new helpers');
like($loader, qr/JawnOS::Domain::Remote.*qa_ux_model_save/, 'the loader maps the UX model helpers');

{
	no warnings 'once';
	require "$root/perl/language.pl";
	my @codes = map { $_->{'code'} } @language::languages;
	is(scalar(grep { $_ eq 'en' || $_ eq 'zh' } @codes), 2, 'the language list is available');
	for my $code (@codes) {
		my $label = language::translate($code, 'configure.qa_note_limit');
		ok(defined $label && length $label && $label ne 'configure.qa_note_limit',
			"$code has a Notes per night label");
		my $model = language::translate($code, 'configure.qa_ux_model');
		ok(defined $model && length $model && $model ne 'configure.qa_ux_model',
			"$code has a UX judgement model label");
	}
}

my $help = read_file("$root/perl/help/topics_configure.pl");
like($help, qr/Notes per night/, 'the Configure help topic explains the picker');
like($help, qr/06:00 coding night/, 'the topic explains what the number feeds');
like($help, qr/UX judgement model/, 'the topic explains the UX model field');

my $runner_source = read_file("$root/qa/coding_night/run.pl");
unlike($runner_source, qr/manager_killer\.pl/,
	'the runner never invokes manager_killer');
like($runner_source, qr/kill 'KILL'/, 'a bound command is SIGKILLed');

done_testing();
