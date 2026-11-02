# tests-for: qa/coding_night/agent.pl qa/coding_night/lib/ qa/coding_night/run.pl qa/device_target.pl qa/lib/ scripts/app_publish.pl scripts/app_release.pl
# covers:    The 06:00 coding nightly's Android lane.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../qa/lib", "$FindBin::Bin/../qa/coding_night/lib";
use Test::More;
use Cwd qw(abs_path);
use DBI;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use JSON::PP;

require CodingNight;

# The 06:00 coding nightly's Android lane.
#
# A note about the app is built in the app checkout, never in this repository's
# worktree. Everything here uses throwaway repositories, a fake gradlew and a
# fake gh; no real Gradle build, APK stage or publish is run, and the app
# checkout that is actually on this machine is never touched.

my $root  = abs_path("$FindBin::Bin/..");
my $runner = "$root/qa/coding_night/run.pl";
my $agent  = "$root/qa/coding_night/agent.pl";

$ENV{'GIT_AUTHOR_NAME'}     ||= 'qa-test';
$ENV{'GIT_AUTHOR_EMAIL'}    ||= 'qa-test@example.invalid';
$ENV{'GIT_COMMITTER_NAME'}  ||= 'qa-test';
$ENV{'GIT_COMMITTER_EMAIL'} ||= 'qa-test@example.invalid';

my $git_version = `git --version 2>/dev/null` // '';
chomp $git_version;
my $have_git = $git_version =~ /\bgit version/;

# --- classification ----------------------------------------------------------

my %app_notes = (
	'android'        => 'The Android back button does nothing',
	'apk'            => 'The new APK will not install',
	'app'            => 'The app loses its session at night',
	'termux'         => 'Termux shows a notification on every start',
	'status bar'     => 'The status bar overlaps the title',
	'navigation bar' => 'The navigation bar is black on black',
	'soft keyboard'  => 'The soft keyboard pushes the whole window up',
	'ime'            => 'The IME draws behind the composer',
	'webview'        => 'The WebView loses its scroll position',
	'wakelock'       => 'Add a wakelock so the tunnel survives sleep',
	'vibrate'        => 'The button should vibrate on press',
	'soft-keyboard'  => 'A soft-keyboard inset is doubled',
);
for my $keyword (sort keys %app_notes) {
	ok(CodingNight::is_app_note({ title => $app_notes{$keyword}, text => $app_notes{$keyword} }),
		"a note naming '$keyword' is app-side");
}

ok(CodingNight::is_app_note({ title => 'Fix the layout', text => "The layout is wrong\n[app]" }),
	'an explicit [app] marker selects the app lane');
ok(CodingNight::is_app_note({ title => 'Fix the layout', tags => ['app'] }),
	'an explicit app tag selects the app lane without a keyword');
ok(CodingNight::is_app_note({ title => 'Fix the layout', tag => 'android' }),
	'an explicit android tag selects the app lane');

my @repo_notes = (
	'Fix the budget totals in the manager',
	'The download queue stalls after ten files',
	"Add a test for the notes table\nand run prove -l t",
	'Search returns the wrong appointment',
);
for my $text (@repo_notes) {
	ok(!CodingNight::is_app_note({ title => $text, text => $text }),
		"a normal repository note is not app-side: $text");
}

# --- names, the bump and the APK ---------------------------------------------

my $app_paths = CodingNight::plan_app_paths('/qa/root', '20261102-060000', 2);
is($app_paths->{'worktree'}, '/qa/root/work-app/20261102-060000-2',
	'the app worktree lives under work-app, apart from the repo worktrees');
is($app_paths->{'branch'}, 'qa/nightly-20261102-060000-2', 'the app branch keeps the <stamp>-<n> name');
is(CodingNight::plan_paths('/qa/root', '20261102-060000', 2)->{'worktree'},
	'/qa/root/work/20261102-060000-2', 'the repository lane is unchanged');
is(CodingNight::app_base_branch(), 'jawnos', 'the app lane bases on jawnos');
is(CodingNight::app_remote(), 'fork', 'the app lane pushes to fork');
is(CodingNight::app_java_home(), '/usr/lib/jvm/java-17-openjdk',
	'the build uses the JDK 17 on this box');
is_deeply(CodingNight::app_build_command(),
	[ './gradlew', '--max-workers=4', ':app:assembleDebug' ], 'the Gradle command is pinned');
is(CodingNight::app_repo_dir('/tmp/a-fixture-app'), '/tmp/a-fixture-app',
	'an explicit app checkout wins');
{
	local $ENV{'JAWNOS_APP_DIR'} = '/tmp/from-env';
	is(CodingNight::app_repo_dir(), '/tmp/from-env', 'JAWNOS_APP_DIR names the checkout');
}

my $bump_dir = tempdir(CLEANUP => 1);
make_path("$bump_dir/app");
write_file("$bump_dir/app/build.gradle", <<'GRADLE');
android {
    defaultConfig {
        versionCode 41
        versionName "1.2.7"
    }
}
GRADLE
my ($bumped, $bump_error) = CodingNight::bump_app_version($bump_dir);
ok($bumped, 'a semver build.gradle can be bumped') or diag $bump_error;
is($bumped->{'versionCode'}, 42, 'versionCode goes up by one');
is($bumped->{'versionName'}, '1.2.8', 'the versionName patch goes up by one');
like(read_file("$bump_dir/app/build.gradle"), qr/versionCode 42/, 'the bumped code is on disk');
like(read_file("$bump_dir/app/build.gradle"), qr/versionName "1\.2\.8"/, 'the bumped name is on disk');

my $no_app = tempdir(CLEANUP => 1);
my ($none, $why) = CodingNight::bump_app_version($no_app);
ok(!defined $none, 'a worktree without app/build.gradle is refused');
like($why // '', qr/app\/build\.gradle/, 'the refusal names the file');

# --- fixtures ----------------------------------------------------------------

sub git_ok { return system('git', @_) == 0 }
sub git_out { my $out = `git @_ 2>/dev/null`; return $out }

sub fake_jawnos_repo {
	my $dir  = tempdir(CLEANUP => 1);
	my $repo = "$dir/repo";
	make_path("$repo/scripts", "$repo/qa");
	write_file("$repo/VERSION", "0.0.1\n");
	write_file("$repo/qa/device_target.pl", "#!/usr/bin/perl\nexit 0;\n");
	write_file("$repo/scripts/app_release.pl", <<'RELEASE');
use strict;
use warnings;
my $log = $ENV{'FAKE_RELEASE_LOG'} || '';
if (length $log) {
	open(my $fh, '>>', $log) or die $!;
	print $fh 'stage ' . join(' ', @ARGV) . "\n";
	close $fh;
}
exit 0;
RELEASE
	write_file("$repo/scripts/app_publish.pl", <<'PUBLISH');
use strict;
use warnings;
my $log = $ENV{'FAKE_PUBLISH_LOG'} || '';
if (length $log) {
	open(my $fh, '>>', $log) or die $!;
	print $fh "publish\n";
	close $fh;
}
exit 0;
PUBLISH
	git_ok('init', '-q', '-b', 'main', $repo) or die "git init failed";
	git_ok('-C', $repo, 'add', '-A') or die "git add failed";
	git_ok('-C', $repo, 'commit', '-q', '-m', 'initial') or die "git commit failed";
	return { dir => $dir, repo => $repo };
}

sub fake_app_repo {
	my $dir  = tempdir(CLEANUP => 1);
	my $app  = "$dir/app";
	my $bare = "$dir/fork.git";
	my $bin  = "$dir/bin";
	make_path("$app/app/src", $bin);
	git_ok('init', '--bare', '-q', $bare) or die "bare git init failed";
	git_ok('init', '-q', '-b', 'jawnos', $app) or die "app git init failed";

	write_file("$app/app/build.gradle", <<'GRADLE');
android {
    defaultConfig {
        applicationId "com.example.fixture"
        versionCode 7
        versionName "0.9.2"
    }
}
GRADLE
	write_file("$app/app/src/Main.java", "class Main { }\n");
	write_file("$app/AGENTS.md", "# APP RULES\n\nBump versionCode and versionName for every APK change.\n");
	write_file("$app/JAWNOS.md", "# Fork deltas\n\n- fixture delta\n");
	write_file("$app/README.md", "# Fixture Android app\n");

	my $gradlew = <<'SH';
#!/bin/sh
if [ -n "$FAKE_GRADLE_LOG" ]; then
	printf '%s\n' "$*" >> "$FAKE_GRADLE_LOG"
fi
if [ "${FAKE_GRADLE_EXIT:-0}" != "0" ]; then
	exit "$FAKE_GRADLE_EXIT"
fi
mkdir -p app/build/outputs/apk/debug
printf 'fake apk\n' > app/build/outputs/apk/debug/app-debug.apk
exit 0
SH
	write_file("$app/gradlew", $gradlew);
	chmod 0755, "$app/gradlew";
	# The constraint for the test harness: the fake tools are on PATH too.
	write_file("$bin/gradlew", $gradlew);
	chmod 0755, "$bin/gradlew";

	my $gh = <<'SH';
#!/bin/sh
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
	exit "${FAKE_GH_AUTH_EXIT:-0}"
fi
exit "${FAKE_GH_EXIT:-0}"
SH
	write_file("$bin/gh", $gh);
	chmod 0755, "$bin/gh";

	git_ok('-C', $app, 'add', '-A') or die "app git add failed";
	git_ok('-C', $app, 'commit', '-q', '-m', 'fixture app') or die "app git commit failed";
	git_ok('-C', $app, 'remote', 'add', 'fork', $bare) or die "app remote failed";
	git_ok('-C', $app, 'push', '-q', '-u', 'fork', 'jawnos') or die "app push failed";

	return { dir => $dir, app => $app, bare => $bare, bin => $bin };
}

sub fake_agent {
	my ($dir) = @_;
	my $path = "$dir/agent.pl";
	write_file($path, <<'AGENT');
use strict;
use warnings;
my $log = $ENV{'FAKE_APP_AGENT_LOG'} || '';
if (length $log) {
	open(my $lf, '>>', $log) or die $!;
	print $lf join("\t", $ENV{'JAWNOS_APP_LANE'} // '', $ENV{'JAWNOS_APP_DIR'} // '',
		$ENV{'JAWNOS_NOTE_TITLE'} // ''), "\n";
	close $lf;
}
open(my $fh, '>>', 'app/src/Main.java') or die $!;
print $fh "// changed by the fixture agent\n";
close $fh;
exit 0;
AGENT
	return $path;
}

sub make_db {
	my $dir = tempdir(CLEANUP => 1);
	my $db = "$dir/jawnos.db";
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '',
		{ RaiseError => 1, PrintError => 0 });
	$dbh->do('create table notes (uuid text unique, timestamp text, server_time text,'
		. ' app text, device text, text text, ost text, category text, status text)');
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

sub note_status {
	my ($db, $uuid) = @_;
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
	my $row = $dbh->selectrow_hashref('select status from notes where uuid = ?', undef, $uuid);
	$dbh->disconnect;
	return $row ? ($row->{'status'} // '') : '';
}

sub run_runner {
	my ($env, @args) = @_;
	my $pid = open(my $fh, '-|');
	defined $pid or die "fork: $!";
	if (!$pid) {
		for my $key (keys %{$env || {}}) {
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

sub app_server {
	my ($dir) = @_;
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
	my $payload = (defined $path && $path =~ m{/note_save})
		? '{"uuid":"posted"}' : '{"ok":1}';
	print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
		. "Content-Length: " . length($payload) . "\r\nConnection: close\r\n\r\n$payload";
	close $c;
}
SERVER

	my $portfile = "$dir/port";
	unlink $portfile;
	my $pid = fork();
	defined $pid or die "fork: $!";
	if (!$pid) {
		exec($^X, $server, "$dir/requests.log", $portfile);
		exit 127;
	}
	for (1 .. 200) { last if -f $portfile; select undef, undef, undef, 0.02 }
	my $port = -f $portfile ? read_file($portfile) : '';
	$port =~ s/\s+//g;
	die "the fake manager did not start" unless $port =~ /^\d+$/;
	return ($pid, $port);
}

sub app_night {
	my (%a) = @_;
	my ($db, $dbdir, $dbh) = make_db();
	add_note($dbh, uuid => $a{'uuid'}, timestamp => '2000', text => $a{'text'});
	$dbh->disconnect;
	my ($pid, $port) = app_server($a{'dir'});
	my $stamp = $a{'stamp'};
	my $qa_root = "$a{'dir'}/qa-root";
	my $path = "$a{'bin'}:" . ($ENV{'PATH'} // '');
	my ($rc, $out) = run_runner(
		{
			'JAWNOS_CODING_AGENT' => "$^X " . $a{'agent'},
			'JAWNOS_APP_DIR'      => $a{'app'},
			'PATH'                => $path,
			'FAKE_GRADLE_LOG'     => "$a{'dir'}/gradle.log",
			'FAKE_APP_AGENT_LOG'  => "$a{'dir'}/agent.log",
			'FAKE_RELEASE_LOG'    => "$a{'dir'}/release.log",
			'FAKE_PUBLISH_LOG'    => "$a{'dir'}/publish.log",
			%{ $a{'env'} || {} },
		},
		'--ignore-device', '--repo', $a{'repo'}, '--root', $qa_root,
		'--db', $db, '--stamp', $stamp, '--limit', '1',
		'--live-url', "http://127.0.0.1:$port",
		'--health-url', "http://127.0.0.1:$port/manager/health",
		'--health-wait', '1', '--ticket', '');
	kill 'KILL', $pid;
	waitpid($pid, 0);
	return ($rc, $out, report_for($qa_root, $stamp), $qa_root, $db, "$a{'dir'}/requests.log");
}

SKIP: {
	skip 'git is not installed', 1 unless $have_git;

	# -- app checkout context: its AGENTS.md, not this repository's -----------
	{
		my $fixture = fake_app_repo();
		my $work = tempdir(CLEANUP => 1);
		local $ENV{'JAWNOS_APP_LANE'} = '1';
		local $ENV{'JAWNOS_APP_DIR'}  = $fixture->{'app'};
		local $ENV{'JAWNOS_NOTE_ID'}    = 'ctx-1';
		local $ENV{'JAWNOS_NOTE_TITLE'} = 'Soft keyboard inset';
		local $ENV{'JAWNOS_NOTE_TEXT'}  = 'The soft keyboard leaves a gap below the composer';
		my $out = `$^X '$agent' --dry-run --worktree '$work' 2>&1`;
		like($out, qr/# APP RULES/, "the app checkout's AGENTS.md is the context");
		like($out, qr/# Fork deltas/, 'the app fork delta list is context too');
		like($out, qr/the Android app checkout/, 'the dry run names the app checkout');
		unlike($out, qr/Stop and ask after 3 attempts/,
			"this repository's AGENTS.md rules are not the app lane's context");
	}

	# -- a clean checkout: build, bump, commit, push, ff, stage, publish ------
	{
		my $fixture = fake_app_repo();
		my $repo    = fake_jawnos_repo();
		my $agent   = fake_agent($fixture->{'dir'});
		my ($rc, $out, $report, $qa_root, $db, $requests) = app_night(
			dir => $fixture->{'dir'}, app => $fixture->{'app'}, bare => $fixture->{'bare'},
			bin => $fixture->{'bin'}, repo => $repo->{'repo'}, agent => $agent,
			stamp => 'app01', uuid => 'app-1',
			text => "Soft keyboard hides the send button\nwhen the status bar is on",
		);

		is($rc, 0, 'a green app night exits 0');
		my $run = $report->{'runs'}->[0] || {};
		is($run->{'lane'}, 'app', 'the report says the app lane ran');
		is($run->{'status'}, 'green', 'the note is green');
		is($run->{'worktree'}, "$qa_root/work-app/app01-1", 'the app worktree naming is pinned');
		is($run->{'branch'}, 'qa/nightly-app01-1', 'the app branch naming is pinned');
		is($run->{'app_version_code'}, 8, 'versionCode was bumped');
		is($run->{'app_version_name'}, '0.9.3', 'the versionName patch was bumped');
		ok($run->{'pushed'}, 'the app branch was pushed');
		ok($run->{'ff_jawnos'}, 'jawnos was fast-forwarded');
		ok($run->{'jawnos_pushed'}, 'jawnos was pushed to fork');
		ok($run->{'staged'}, 'the APK was staged');
		is($run->{'publish'}, 'published', 'the APK was published');
		ok($run->{'marked_completed'}, 'the note was marked completed');

		my $gradle = -f "$fixture->{'dir'}/gradle.log" ? read_file("$fixture->{'dir'}/gradle.log") : '';
		like($gradle, qr/--max-workers=4 :app:assembleDebug/,
			'the pinned Gradle command ran in the worktree');
		my @gradle_calls = grep { /\S/ } split /\n/, $gradle;
		is(scalar @gradle_calls, 2, 'the build runs once before and once after the bump');

		my $agent_log = -f "$fixture->{'dir'}/agent.log" ? read_file("$fixture->{'dir'}/agent.log") : '';
		like($agent_log, qr/^1\t\Q$fixture->{'app'}\E\tSoft keyboard hides the send button/m,
			'the agent knew it was the app lane and where the app checkout is');

		my $release = -f "$fixture->{'dir'}/release.log" ? read_file("$fixture->{'dir'}/release.log") : '';
		like($release, qr/stage .*app-debug\.apk/, 'app_release.pl was handed the built APK');
		my $publish = -f "$fixture->{'dir'}/publish.log" ? read_file("$fixture->{'dir'}/publish.log") : '';
		like($publish, qr/publish/, 'app_publish.pl ran after the stage');

		like(read_file("$fixture->{'app'}/app/build.gradle"), qr/versionCode 8/,
			'jawnos in the app checkout carries the bump');
		like(read_file("$fixture->{'app'}/app/build.gradle"), qr/versionName "0\.9\.3"/,
			'jawnos in the app checkout carries the versionName bump');
		is(git_out("-C $fixture->{'bare'} log -1 --pretty=%s refs/heads/jawnos"),
			"v0.9.3 - Soft keyboard hides the send button\n",
			'fork jawnos carries the versioned commit');
		isnt(git_out("-C $fixture->{'bare'} rev-parse --verify refs/heads/qa/nightly-app01-1"),
			'', 'the nightly branch is on fork');

		my $req = -f $requests ? read_file($requests) : '';
		like($req, qr/POST \/manager\/note_save .*uuid=app-1.*status=completed|POST \/manager\/note_save .*status=completed.*uuid=app-1/,
			'the note is completed through the app route');
	}

	# -- no gh auth: stage, report skipped, never claim a publish -------------
	{
		my $fixture = fake_app_repo();
		my $repo    = fake_jawnos_repo();
		my $agent   = fake_agent($fixture->{'dir'});
		my ($rc, $out, $report, $qa_root, $db) = app_night(
			dir => $fixture->{'dir'}, app => $fixture->{'app'}, bare => $fixture->{'bare'},
			bin => $fixture->{'bin'}, repo => $repo->{'repo'}, agent => $agent,
			stamp => 'noauth01', uuid => 'app-2',
			text => 'The APK update notification is missing',
			env => { 'FAKE_GH_AUTH_EXIT' => 1 },
		);
		is($rc, 0, 'a stage-only app night still exits 0');
		my $run = $report->{'runs'}->[0] || {};
		ok($run->{'staged'}, 'the APK was staged');
		is($run->{'publish'}, 'skipped (no gh auth)', 'the report says the publish was skipped');
		like($out, qr/publish: skipped \(no gh auth\)/, 'the run prints the skip');
		my $publish = -f "$fixture->{'dir'}/publish.log" ? read_file("$fixture->{'dir'}/publish.log") : '';
		unlike($publish, qr/publish/, 'app_publish.pl did not run without gh auth');
		ok($run->{'marked_completed'}, 'a staged build still completes the note');
	}

	# -- a failed build: no bump, no push, no stage, note stays open ----------
	{
		my $fixture = fake_app_repo();
		my $repo    = fake_jawnos_repo();
		my $agent   = fake_agent($fixture->{'dir'});
		my ($rc, $out, $report, $qa_root, $db) = app_night(
			dir => $fixture->{'dir'}, app => $fixture->{'app'}, bare => $fixture->{'bare'},
			bin => $fixture->{'bin'}, repo => $repo->{'repo'}, agent => $agent,
			stamp => 'buildfail01', uuid => 'app-3',
			text => 'The WebView crashes on rotation',
			env => { 'FAKE_GRADLE_EXIT' => 1 },
		);
		is($rc, 1, 'a failed app build exits 1');
		my $run = $report->{'runs'}->[0] || {};
		is($run->{'status'}, 'build_failed', 'the report names the build');
		ok(!defined $run->{'app_version_code'}, 'no versionCode was reported');
		like(read_file("$fixture->{'app'}/app/build.gradle"), qr/versionCode 7/,
			'the app checkout was not bumped');
		is(git_out("-C $fixture->{'bare'} rev-parse --verify refs/heads/qa/nightly-buildfail01-1"),
			'', 'nothing was pushed to fork');
		my $release = -f "$fixture->{'dir'}/release.log" ? read_file("$fixture->{'dir'}/release.log") : '';
		is($release, '', 'nothing was staged');
		is(note_status($db, 'app-3'), 'open', 'the note stays open');
	}

	# -- a dirty app checkout is never touched --------------------------------
	{
		my $fixture = fake_app_repo();
		write_file("$fixture->{'app'}/app/src/Main.java", "class Main { /* WIP */ }\n");
		my $repo  = fake_jawnos_repo();
		my $agent = fake_agent($fixture->{'dir'});
		my ($rc, $out, $report, $qa_root, $db) = app_night(
			dir => $fixture->{'dir'}, app => $fixture->{'app'}, bare => $fixture->{'bare'},
			bin => $fixture->{'bin'}, repo => $repo->{'repo'}, agent => $agent,
			stamp => 'dirty01', uuid => 'app-4',
			text => 'Android: the navigation bar flashes white',
		);
		is($rc, 0, 'a dirty app checkout does not fail the night');
		my $run = $report->{'runs'}->[0] || {};
		ok(!$run->{'ff_jawnos'}, 'jawnos was not fast-forwarded over the WIP');
		like($run->{'warning'} // '', qr/not clean on jawnos/, 'the report explains why');
		is(read_file("$fixture->{'app'}/app/src/Main.java"), "class Main { /* WIP */ }\n",
			"the other agent's work is untouched");
		like(read_file("$fixture->{'app'}/app/build.gradle"), qr/versionCode 7/,
			'the dirty checkout was not committed around');
		ok($run->{'pushed'}, 'the nightly branch was still pushed');
		ok($run->{'staged'}, 'and the built APK was still staged');
	}
}

done_testing();
