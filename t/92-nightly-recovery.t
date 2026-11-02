use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../qa/lib", "$FindBin::Bin/../qa/coding_night/lib";
use Test::More;
use Cwd qw(abs_path);
use DBI;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use JSON::PP;

require CodingNight;
require JawnOS::Domain::Records2;
require QaSetting;

# The 06:00 coding night's backup and failure path, and the customizable push
# repository. Everything here uses throwaway repositories, databases and a fake
# manager; no real push, publish or restart is run.

my $root = abs_path("$FindBin::Bin/..");
my $runner = "$root/qa/coding_night/run.pl";
my $recover = "$root/qa/coding_night/recover.pl";

$ENV{'GIT_AUTHOR_NAME'}     ||= 'qa-test';
$ENV{'GIT_AUTHOR_EMAIL'}    ||= 'qa-test@example.invalid';
$ENV{'GIT_COMMITTER_NAME'}  ||= 'qa-test';
$ENV{'GIT_COMMITTER_EMAIL'} ||= 'qa-test@example.invalid';

my $git_version = `git --version 2>/dev/null` // '';
chomp $git_version;
my $have_git = $git_version =~ /\bgit version/;

# --- the push-target rule ----------------------------------------------------
my @accepted = (
	'owner/name',
	'owner/name.git',
	'https://github.com/owner/name.git',
	'https://git.example.com/team/project',
	'https://github.com/owner/name/',
);
my @rejected = (
	'owner name/name',
	'https://user:pass@github.com/owner/name',
	'git@github.com:owner/name.git',
	'owner',
	'http://github.com/owner/name',
	'https://github.com/owner',
	'https://github.com/owner/na me',
	'owner/../name',
);
for my $value (@accepted) {
	my $night = CodingNight::push_repo_valid($value);
	ok($night->{'ok'}, "the nightly accepts the push repo '$value'");
	my $app = subs::coding_push_repo_valid($value);
	ok($app->{'ok'}, "the panel accepts the push repo '$value'");
}
for my $value (@rejected) {
	my $night = CodingNight::push_repo_valid($value);
	ok(!$night->{'ok'}, "the nightly refuses the push repo '$value'");
	my $app = subs::coding_push_repo_valid($value);
	ok(!$app->{'ok'}, "the panel refuses the push repo '$value'");
}
is(CodingNight::push_repo_target('owner/name'), 'https://github.com/owner/name.git',
	'owner/name resolves to a GitHub URL');
is(CodingNight::push_repo_target('https://git.example.com/team/project'),
	'https://git.example.com/team/project', 'a full URL is used as it is');
is(subs::coding_push_repo_slug('https://github.com/acme/widgets.git'), 'acme/widgets',
	'the release script gets owner/name even from a URL');

# --- the setting round-trips -------------------------------------------------
my %store;
my $setter  = sub { my ($setting, $value) = @_; $store{$setting} = $value; };
my $grabber = sub { my ($setting) = @_; return $store{$setting}; };

my $saved = subs::coding_push_repo_save('repo', 'acme/widgets', { setter => $setter });
ok($saved->{'ok'}, 'a valid coding push repo saves');
is($store{'coding_push_repo'}, 'acme/widgets', 'it is stored on coding_push_repo');
is($saved->{'effective'}, 'https://github.com/acme/widgets.git',
	'the save answers with the effective target');

my $read = subs::coding_push_repo_get('repo', { grabber => $grabber });
ok($read->{'ok'}, 'the saved value reads back');
is($read->{'effective'}, 'https://github.com/acme/widgets.git', 'the effective target is shown');

$store{'coding_push_repo'} = 'bad value';
my $bad_read = subs::coding_push_repo_get('repo', { grabber => $grabber });
ok(!$bad_read->{'ok'}, 'a saved value with a space reads as an error, not a silent fallback');

my $app_saved = subs::coding_push_repo_save('app', 'https://github.com/acme/termux-app.git',
	{ setter => $setter });
ok($app_saved->{'ok'}, 'the app push repo saves');
is($store{'coding_app_push_repo'}, 'https://github.com/acme/termux-app.git',
	'it is stored on coding_app_push_repo');
is($app_saved->{'effective'}, 'https://github.com/acme/termux-app.git', 'the app effective target');

my $cleared = subs::coding_push_repo_save('repo', '', { setter => $setter });
ok($cleared->{'ok'}, 'an empty value clears the setting');
is($store{'coding_push_repo'}, '', 'the empty value is stored');
is($cleared->{'effective'}, 'origin', 'empty means origin');

my $bad_save = subs::coding_push_repo_save('repo', 'https://token@github.com/a/b',
	{ setter => $setter });
ok(!$bad_save->{'ok'}, 'a credential-bearing URL is refused');
is($store{'coding_push_repo'}, '', 'the refused value did not change the setting');

# --- the database reader -----------------------------------------------------
sub make_db {
	my $dir = tempdir(CLEANUP => 1);
	my $db  = "$dir/jawnos.db";
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

sub setting {
	my ($dbh, $setting, $value) = @_;
	$dbh->do("insert into settings (app, setting, device, value, server_time)"
		. " values ('__president', ?, 'all', ?, '1000')", undef, $setting, $value);
}

my ($pdb, $pdir, $pdbh) = make_db();
setting($pdbh, 'coding_push_repo', 'acme/widgets');
setting($pdbh, 'coding_app_push_repo', 'acme/termux-app');
$pdbh->disconnect;
my $target = CodingNight::push_target($pdb, 'repo');
ok($target->{'ok'}, 'the nightly reads the saved push repo');
is($target->{'target'}, 'https://github.com/acme/widgets.git', 'and resolves it to a URL');
is($target->{'slug'}, 'acme/widgets', 'and knows the owner/name for app_publish');
my $app_target = CodingNight::push_target($pdb, 'app');
is($app_target->{'target'}, 'https://github.com/acme/termux-app.git', 'the app target is separate');

$pdbh = DBI->connect("dbi:SQLite:dbname=$pdb", '', '', { RaiseError => 1, PrintError => 0 });
$pdbh->do("delete from settings");
$pdbh->disconnect;
is(CodingNight::push_target($pdb, 'repo')->{'target'}, 'origin',
	'no saved repo means origin');
is(CodingNight::push_target($pdb, 'app')->{'target'}, 'fork',
	'no saved app repo means fork');

$pdbh = DBI->connect("dbi:SQLite:dbname=$pdb", '', '', { RaiseError => 1, PrintError => 0 });
setting($pdbh, 'coding_push_repo', 'https://user:pass@github.com/a/b');
$pdbh->disconnect;
my $bad_target = CodingNight::push_target($pdb, 'repo');
ok(!$bad_target->{'ok'}, 'a bad saved value stops the night instead of using origin');
is($bad_target->{'target'}, 'origin', 'the fallback is named in the answer');

# --- rollback.sh -------------------------------------------------------------
sub git_ok  { return system('git', @_) == 0 }
sub git_out { my $out = `git @_ 2>/dev/null`; return $out }

SKIP: {
	skip 'git is not installed', 12 unless $have_git;

	my $dir  = tempdir(CLEANUP => 1);
	my $repo = "$dir/repo";
	make_path("$repo/scripts");
	git_ok('init', '-q', '-b', 'main', $repo) or die 'git init failed';
	write_file("$repo/tracker.txt", "original\n");
	write_file("$repo/scripts/restart.pl", "#!/usr/bin/perl\nexit 0;\n");
	git_ok('-C', $repo, 'add', '-A') or die 'git add failed';
	git_ok('-C', $repo, 'commit', '-q', '-m', 'initial') or die 'git commit failed';
	my $base = git_out("-C $repo rev-parse HEAD");
	chomp $base;

	my ($script, $err) = CodingNight::write_rollback_script(
		$dir, tag => 'nightly-pre-test', repo => $repo,
		health => '', restart => 'scripts/restart.pl');
	ok($script && -f $script, 'rollback.sh is written') or diag $err;
	ok(-x $script, 'rollback.sh is executable');

	my $missing = `sh $script 2>&1`;
	my $missing_rc = $? >> 8;
	isnt($missing_rc, 0, 'rollback.sh refuses when the tag is missing');
	like($missing, qr/refused/i, 'the refusal says so');
	like($missing, qr/nightly-pre-test/, 'the refusal names the tag');

	git_ok('-C', $repo, 'tag', 'nightly-pre-test', $base) or die 'git tag failed';
	write_file("$repo/tracker.txt", "later\n");
	git_ok('-C', $repo, 'add', '-A') or die 'git add failed';
	git_ok('-C', $repo, 'commit', '-q', '-m', 'later') or die 'git commit failed';

	my $rolled = `sh $script 2>&1`;
	my $rolled_rc = $? >> 8;
	is($rolled_rc, 0, 'rollback.sh succeeds with the tag present') or diag $rolled;
	like($rolled, qr/rolled back to nightly-pre-test/, 'it says where it landed');
	my $now = git_out("-C $repo rev-parse HEAD");
	chomp $now;
	is($now, $base, 'it restores the exact commit');
	is(read_file("$repo/tracker.txt"), "original\n", 'the tree is the tagged tree again');
}

# --- the release backup ------------------------------------------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $repo = "$dir/repo";
	make_path("$repo/releases");
	write_file("$repo/releases/jawnos-app-7-0.9.2.apk", "old apk\n");
	write_file("$repo/releases/app_release.json", "{\"old\":true}\n");

	my $backup = CodingNight::releases_backup($repo, "$dir/backup");
	ok($backup->{'ok'}, 'the release backup succeeds');
	is_deeply([ sort @{ $backup->{'files'} } ],
		[ 'app_release.json', 'jawnos-app-7-0.9.2.apk' ],
		'the APK and manifest are copied');

	write_file("$repo/releases/jawnos-app-8-0.9.3.apk", "new apk\n");
	write_file("$repo/releases/app_release.json", "{\"new\":true}\n");

	my $restore = CodingNight::releases_restore($repo, $backup);
	ok($restore->{'ok'}, 'the release restore succeeds');
	is(read_file("$repo/releases/app_release.json"), "{\"old\":true}\n",
		'the old manifest is restored');
	ok(-f "$repo/releases/jawnos-app-7-0.9.2.apk", 'the old APK is restored');
	ok(!-f "$repo/releases/jawnos-app-8-0.9.3.apk", 'the new APK is removed');
}

# --- runner fixtures ---------------------------------------------------------
sub agent_script {
	my ($dir) = @_;
	my $path = "$dir/agent.pl";
	write_file($path, <<'AGENT');
use strict;
use warnings;
use File::Path qw(make_path);
make_path('public/js/manager');
open(my $fh, '>', 'public/js/manager/zz_agent_change.js') or die $!;
print $fh "// the agent changed this\n";
close $fh;
exit 0;
AGENT
	return $path;
}

sub fake_repo {
	my $dir  = tempdir(CLEANUP => 1);
	my $bare = "$dir/origin.git";
	my $repo = "$dir/repo";
	make_path("$repo/scripts", "$repo/qa", "$repo/public/js/manager");
	git_ok('init', '--bare', '-q', $bare) or die 'bare git init failed';
	git_ok('init', '-q', '-b', 'main', $repo) or die 'git init failed';

	write_file("$repo/VERSION", "0.0.1\n");
	write_file("$repo/scripts/version_bump.pl", <<'BUMP');
use strict;
use warnings;
open(my $fh, '>', 'VERSION') or die $!;
print $fh "0.0.2\n";
close $fh;
exit 0;
BUMP
	write_file("$repo/scripts/restart.pl", <<'RESTART');
use strict;
use warnings;
my $log = $ENV{'FAKE_RESTART_LOG'} || '';
if (length $log) {
	open(my $fh, '>>', $log) or die $!;
	print $fh join(' ', @ARGV), "\n";
	close $fh;
}
my $count = $ENV{'FAKE_RESTART_COUNT'} || '';
my $n = 0;
if (length $count && -f $count) {
	open(my $cf, '<', $count) or die $!;
	my $line = <$cf>;
	close $cf;
	$line = '' unless defined $line;
	$line =~ s/\s+//g;
	$n = $line =~ /^\d+$/ ? $line : 0;
}
$n++;
if (length $count) {
	open(my $of, '>', $count) or die $!;
	print $of $n;
	close $of;
}
exit 1 if $ENV{'FAKE_RESTART_FAIL_FIRST'} && $n == 1;
exit 0 + ($ENV{'FAKE_RESTART_EXIT'} // 0);
RESTART
	write_file("$repo/qa/run.pl", <<'QA');
use strict;
use warnings;
my $log = $ENV{'FAKE_QA_LOG'} || '';
if (length $log) {
	open(my $fh, '>>', $log) or die $!;
	print $fh join(' ', @ARGV), "\n";
	close $fh;
}
exit 0 + ($ENV{'FAKE_QA_EXIT'} // 0);
QA
	write_file("$repo/qa/device_target.pl", "#!/usr/bin/perl\nexit 0;\n");
	write_file("$repo/tracker.txt", "original\n");

	git_ok('-C', $repo, 'add', '-A') or die 'git add failed';
	git_ok('-C', $repo, 'commit', '-q', '-m', 'initial') or die 'git commit failed';
	git_ok('-C', $repo, 'remote', 'add', 'origin', $bare) or die 'git remote failed';
	git_ok('-C', $repo, 'push', '-q', '-u', 'origin', 'main') or die 'git push failed';
	return { dir => $dir, repo => $repo, bare => $bare };
}

sub run_runner {
	my ($env, @args) = @_;
	my $pid = open(my $fh, '-|');
	defined $pid or die "fork: $!";
	if (!$pid) {
		for my $key (keys %{ $env || {} }) {
			if (defined $env->{$key}) { $ENV{$key} = $env->{$key} }
			else { delete $ENV{$key} }
		}
		open(STDERR, '>&', \*STDOUT);
		exec($^X, $runner, @args);
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
	die 'the fake manager did not start' unless $port =~ /^\d+$/;
	return ($pid, $port);
}

sub decode_body {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
	$text =~ s/\+/ /g;
	return $text;
}

SKIP: {
	skip 'git is not installed', 60 unless $have_git;

	# -- a post-merge failure rolls back to the exact commit ---------------
	my $fx = fake_repo();
	my ($db, $dbdir, $dbh) = make_db();
	add_note($dbh, uuid => 'rb-1', timestamp => '2000',
		text => "A note that ships but breaks the restart\nwith a test");
	$dbh->disconnect;
	my $qa_root = "$fx->{'dir'}/qa-root";
	my $agent   = agent_script($fx->{'dir'});
	my $head    = git_out("-C $fx->{'repo'} rev-parse HEAD");
	chomp $head;
	my ($pid, $port) = app_server($fx->{'dir'});
	my ($rc, $out) = run_runner(
		{
			'JAWNOS_CODING_AGENT'       => "$^X $agent",
			'FAKE_RESTART_COUNT'        => "$fx->{'dir'}/restart.count",
			'FAKE_RESTART_FAIL_FIRST'   => 1,
			'FAKE_RESTART_LOG'          => "$fx->{'dir'}/restart.log",
		},
		'--ignore-device', '--repo', $fx->{'repo'}, '--root', $qa_root,
		'--db', $db, '--stamp', 'rb01', '--limit', '1',
		'--live-url', "http://127.0.0.1:$port",
		'--health-url', "http://127.0.0.1:$port/manager/health",
		'--health-wait', '1', '--ticket', '');
	kill 'KILL', $pid;
	waitpid($pid, 0);

	is($rc, 1, 'a post-merge failure exits 1');
	my $report = report_for($qa_root, 'rb01');
	my $run = $report->{'runs'}->[0] || {};
	is($run->{'status'}, 'restart_failed', 'the report names the refused restart');
	ok($run->{'merged'}, 'main had been merged');
	is($run->{'rolled_back'}, 'yes', 'the run rolled back automatically');
	is($run->{'rollback_tag'}, 'nightly-pre-rb01', 'the tag is recorded on the run');
	ok($run->{'rollback_reset_ok'}, 'the reset succeeded');
	ok($run->{'rollback_restart_ok'}, 'the rollback restart succeeded');
	ok($run->{'rollback_health_ok'}, 'the rollback health was 200');
	is($report->{'rollback_tag'}, 'nightly-pre-rb01', 'the report records the tag');
	my $after_head = git_out("-C $fx->{'repo'} rev-parse HEAD");
	chomp $after_head;
	is($after_head, $head, 'main is back on the exact pre-run commit');
	like(git_out("-C $fx->{'repo'} tag --list nightly-pre-rb01"), qr/nightly-pre-rb01/,
		'the tag exists');
	ok(-f "$qa_root/coding/rb01/failure.md", 'failure.md is written');
	ok(-d "$qa_root/work/rb01-1", 'the worktree is left for inspection');
	like(read_file("$qa_root/coding/rb01/failure.md"), qr/rollback tag: `nightly-pre-rb01`/,
		'failure.md names the rollback tag');
	like(read_file("$qa_root/coding/rb01/rollback.sh"), qr/git reset --hard/,
		'rollback.sh carries the exact recovery');

	my $requests = -f "$fx->{'dir'}/requests.log" ? read_file("$fx->{'dir'}/requests.log") : '';
	my $body = decode_body($requests);
	like($body, qr/Nightly failed: A note that ships/, 'the failure note names the note');
	like($body, qr/status=open/, 'the failure note is filed with status open');
	like($body, qr/category=jawnos/, 'the failure note is a JawnOS note');
	unlike($body, qr/uuid=rb-1/, 'the original note is never marked completed');
	is(note_status($db, 'rb-1'), 'open', 'the original note stays open');

	# -- recover.pl reads the run and writes nothing by default ------------
	my $run_dir = "$qa_root/coding/rb01";
	my $before_report = read_file("$run_dir/report.json");
	my @before = sort grep { !/^\.\.?$/ } do {
		opendir(my $dh, $run_dir) or die $!;
		readdir $dh;
	};
	my $summary = `$^X $recover --run $run_dir 2>&1`;
	my $summary_rc = $? >> 8;
	is($summary_rc, 0, 'recover.pl exits 0');
	like($summary, qr/rollback tag: nightly-pre-rb01/, 'the summary names the tag');
	like($summary, qr/status: restart_failed/, 'the summary says what failed');
	like($summary, qr/worktree: \Q$qa_root\E\/work\/rb01-1/, 'the summary names the worktree');
	like($summary, qr/Next action:/, 'the summary says what to do next');
	like($summary, qr/rolled back: yes/, 'the summary says it rolled back');
	is(read_file("$run_dir/report.json"), $before_report,
		'recover.pl did not rewrite the report');
	my @after = sort grep { !/^\.\.?$/ } do {
		opendir(my $dh, $run_dir) or die $!;
		readdir $dh;
	};
	is_deeply(\@after, \@before, 'recover.pl wrote no files');

	# -- recover.pl --note re-files the failure through the app route ------
	my ($npid, $nport) = app_server($fx->{'dir'});
	my $note_out = `$^X $recover --run $run_dir --note --live-url http://127.0.0.1:$nport --ticket '' 2>&1`;
	my $note_rc = $? >> 8;
	kill 'KILL', $npid;
	waitpid($npid, 0);
	is($note_rc, 0, 'recover.pl --note exits 0') or diag $note_out;
	my $note_requests = -f "$fx->{'dir'}/requests.log" ? read_file("$fx->{'dir'}/requests.log") : '';
	my $note_body = decode_body($note_requests);
	like($note_body, qr/POST \/manager\/note_save .*status=open/, 'the re-filed note is open');
	like($note_body, qr/Nightly failed: A note that ships/, 'the re-filed note keeps the title');
}

SKIP: {
	skip 'git is not installed', 30 unless $have_git;

	# -- the night pushes to the configured target, never to origin --------
	my $fx = fake_repo();
	my ($db, $dbdir, $dbh) = make_db();
	add_note($dbh, uuid => 'push-1', timestamp => '2000', text => 'Ship to the fork');
	setting($dbh, 'coding_push_repo', 'acme/widgets');
	$dbh->disconnect;

	my $bin = "$fx->{'dir'}/bin";
	make_path($bin);
	my $real_git = `which git`;
	chomp $real_git;
	my $wrapper = <<"SH";
#!/bin/sh
printf '%s\\n' "\$*" >> "\$FAKE_GIT_LOG"
case "\$1" in
	push) exit 0 ;;
	ls-remote) exit 0 ;;
esac
exec $real_git "\$@"
SH
	write_file("$bin/git", $wrapper);
	chmod 0755, "$bin/git";

	my $qa_root = "$fx->{'dir'}/qa-root";
	my $agent   = agent_script($fx->{'dir'});
	my ($pid, $port) = app_server($fx->{'dir'});
	my ($rc, $out) = run_runner(
		{
			'JAWNOS_CODING_AGENT' => "$^X $agent",
			'PATH'                => "$bin:" . ($ENV{'PATH'} // ''),
			'FAKE_GIT_LOG'        => "$fx->{'dir'}/git.log",
		},
		'--ignore-device', '--repo', $fx->{'repo'}, '--root', $qa_root,
		'--db', $db, '--stamp', 'push01', '--limit', '1',
		'--live-url', "http://127.0.0.1:$port",
		'--health-url', "http://127.0.0.1:$port/manager/health",
		'--health-wait', '1', '--ticket', '');
	kill 'KILL', $pid;
	waitpid($pid, 0);

	is($rc, 0, 'a green night with a push target exits 0');
	my $report = report_for($qa_root, 'push01');
	my $run = $report->{'runs'}->[0] || {};
	is($run->{'status'}, 'green', 'the note is green');
	is($run->{'push_target'}, 'https://github.com/acme/widgets.git', 'the report names the target');
	is($run->{'rollback_tag'}, 'nightly-pre-push01', 'it still tagged main');
	my $gitlog = -f "$fx->{'dir'}/git.log" ? read_file("$fx->{'dir'}/git.log") : '';
	like($gitlog, qr{^ls-remote https://github\.com/acme/widgets\.git$}m,
		'the target is checked before merging');
	like($gitlog, qr{^push -u https://github\.com/acme/widgets\.git qa/nightly-push01-1$}m,
		'the branch goes to the configured target');
	like($gitlog, qr{^push https://github\.com/acme/widgets\.git HEAD:main$}m,
		'main is pushed with HEAD:main to the same target');
	unlike($gitlog, qr{^push\b.*\borigin\b}m, 'nothing is pushed to origin');
}

SKIP: {
	skip 'git is not installed', 15 unless $have_git;

	# -- an unreachable target fails before any merge ----------------------
	my $fx = fake_repo();
	my ($db, $dbdir, $dbh) = make_db();
	add_note($dbh, uuid => 'reach-1', timestamp => '2000', text => 'The fork is unreachable');
	setting($dbh, 'coding_push_repo', 'acme/widgets');
	$dbh->disconnect;

	my $bin = "$fx->{'dir'}/bin";
	make_path($bin);
	my $real_git = `which git`;
	chomp $real_git;
	my $wrapper = <<"SH";
#!/bin/sh
printf '%s\\n' "\$*" >> "\$FAKE_GIT_LOG"
case "\$1" in
	ls-remote) exit 1 ;;
	push) exit 99 ;;
esac
exec $real_git "\$@"
SH
	write_file("$bin/git", $wrapper);
	chmod 0755, "$bin/git";

	my $qa_root = "$fx->{'dir'}/qa-root";
	my $agent   = agent_script($fx->{'dir'});
	my $head = git_out("-C $fx->{'repo'} rev-parse HEAD");
	chomp $head;
	my ($pid, $port) = app_server($fx->{'dir'});
	my ($rc, $out) = run_runner(
		{
			'JAWNOS_CODING_AGENT' => "$^X $agent",
			'PATH'                => "$bin:" . ($ENV{'PATH'} // ''),
			'FAKE_GIT_LOG'        => "$fx->{'dir'}/git.log",
		},
		'--ignore-device', '--repo', $fx->{'repo'}, '--root', $qa_root,
		'--db', $db, '--stamp', 'reach01', '--limit', '1',
		'--live-url', "http://127.0.0.1:$port",
		'--health-url', "http://127.0.0.1:$port/manager/health",
		'--health-wait', '1', '--ticket', '');
	kill 'KILL', $pid;
	waitpid($pid, 0);

	is($rc, 1, 'an unreachable push target exits 1');
	my $report = report_for($qa_root, 'reach01');
	my $run = $report->{'runs'}->[0] || {};
	is($run->{'status'}, 'push_target_unreachable', 'the report names the target');
	ok(!$run->{'merged'}, 'main was not merged');
	my $after_head = git_out("-C $fx->{'repo'} rev-parse HEAD");
	chomp $after_head;
	is($after_head, $head, 'main is untouched');
	is(note_status($db, 'reach-1'), 'open', 'the note stays open');
	my $gitlog = -f "$fx->{'dir'}/git.log" ? read_file("$fx->{'dir'}/git.log") : '';
	unlike($gitlog, qr{^push\b}m, 'nothing was pushed');
}

# --- the UI, route, language and help ---------------------------------------
my $body = read_file("$root/templates/configure/device_lister/body.html.ep");
like($body, qr/id="coding_push_repo"/, 'the Dev panel carries the coding push repo field');
like($body, qr/id="coding_app_push_repo"/, 'the Dev panel carries the app push repo field');
like($body, qr/id="coding_push_repo_effective"/, 'the effective repo is shown');
like($body, qr/id="coding_app_push_repo_effective"/, 'the app effective repo is shown');
like($body, qr/configure\.coding_push_repo/, 'the label is a core language key');

my $js = read_file("$root/public/js/manager/configure.js");
like($js, qr#/manager/configure/coding_push_repo#, 'the script posts to the validated route');
like($js, qr/coding_app_push_repo_input/, 'the script listens to the app field');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure2.pm");
like($controller, qr/coding_push_repo_save/, 'the route validates server-side');
my $routes = read_file("$root/lib/JawnOS/Routes/manager_configure2.pm");
like($routes, qr#/manager/configure/coding_push_repo#, 'the route is registered');

my $misc = read_file("$root/lib/JawnOS/Controller/manager_misc13.pm");
like($misc, qr/coding_push_repo_valid/, 'the generic setter validates the same values');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/coding_push_repo_save/, 'the loader maps the new helpers');

{
	no warnings 'once';
	require "$root/perl/language.pl";
	for my $lang (@language::languages) {
		for my $key (qw(configure.coding_push_repo configure.coding_app_push_repo
			configure.coding_push_effective)) {
			my $label = language::translate($lang->{'code'}, $key);
			ok(defined $label && length $label && $label ne $key,
				$lang->{'code'} . " has $key");
		}
	}
}

my $help = read_file("$root/perl/help/topics_configure.pl");
like($help, qr/Coding push repo/, 'the Configure help topic explains the field');
like($help, qr/effective target/, 'the help explains the effective repo line');

done_testing();
