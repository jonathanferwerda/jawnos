# tests-for: lib/JawnOS/Controller/manager_controllers.pm lib/JawnOS/Routes/manager_controllers.pm scripts/gou_provision.pl public/js/manager/controllers.js templates/controllers/style.html.ep perl/help/topics_apps.pl
# covers:    The flash job: the provisioner's progress file, the status and
#            cancel routes that read it, and the page's bar. The point is that a
#            panel restart leaves the write running and the next poll (or a
#            reopened window) reads the same state rather than declaring failure.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use JSON::PP ();
use POSIX ();

require 'JawnOS/Controller/manager_controllers.pm';
require JawnOS::Platform::Process;

my $JSON = JSON::PP->new->canonical(1);
my $dry = tempdir(CLEANUP => 1);

{
	package FlashProbe;
	sub new {
		return bless {
			params => {},
			answer => undef,
			session => { authentication => 'approved', privilege => 'citizen' },
		}, $_[0];
	}
	sub param { my ($s, $k) = @_; return $s->{'params'}->{$k} }
	sub render { my ($s, %o) = @_; $s->{'answer'} = $o{'json'}; return $s }
	sub session { my ($s, $k) = @_; return $s->{'session'}->{$k} }
	sub inactivity_timeout { return $_[0] }
	package main;
}

sub job_file { return "$dry/gou_flash.json" }

sub write_job {
	my (%job) = @_;
	return Manager::_flash_job_write({ %job }, job_file());
}

sub read_job {
	return Manager::_flash_job_read(job_file());
}

sub status {
	my $c = FlashProbe->new;
	Manager::action_54012($c);
	return $c->{'answer'} || {};
}

sub cancel {
	my $c = FlashProbe->new;
	Manager::action_54013($c);
	return $c->{'answer'} || {};
}

sub token_row {
	my ($secret) = @_;
	return subs::db_select('cache', undef, { context => 'controller_join', subcontext => $secret })->hash;
}

sub insert_token {
	my ($secret) = @_;
	my $now = subs::rightNow();
	subs::db_insert('cache', {
		uuid => subs::random_string_creator(18),
		context => 'controller_join', subcontext => $secret,
		app => '__president', data => '{}', timestamp => $now, server_time => $now,
	});
}

{
	local $ENV{'JAWNOS_FLASH_JOB'} = job_file();
	no warnings 'redefine';
	no warnings 'once';
	local *subs::privilege_is_house = sub { 1 };

	my $ticks = JawnOS::Platform::Process::start_time($$);

	# --- the job file ------------------------------------------------------
	ok(write_job(
		state => 'writing', pid => $$, start_ticks => $ticks,
		bytes => 512, total => 1024, rate => 256,
		started_ms => 1000, updated_ms => 2000,
	), 'the job is written');
	my $job = read_job();
	is($job->{'state'}, 'writing', 'and reads back');
	my $view = Manager::_flash_job_view($job);
	is($view->{'percent'}, 50, 'the page gets a percentage');
	is($view->{'rate'}, 256, 'and the rate the writer recorded');
	ok(!exists $view->{'token_path'}, 'the token file path is not sent to the page');
	ok(Manager::_flash_job_active('writing'), 'writing is an active state');
	ok(!Manager::_flash_job_active('done'), 'done is not');
	ok(!Manager::_flash_job_active('cancelled'), 'cancelled is not');

	ok(Manager::_flash_job_alive($job), 'a live process with its start time is the flash');
	ok(!Manager::_flash_job_alive({ pid => 999_999, start_ticks => '1' }), 'a dead pid is not');
	ok(!Manager::_flash_job_alive({ pid => $$, start_ticks => 'wrong' }), 'a recycled pid is not');

	# --- status ------------------------------------------------------------
	unlink job_file();
	{
		my $said = status();
		is($said->{'state'}, 'idle', 'no job reads idle');
		ok($said->{'ok'}, 'and the page can read it');
	}

	write_job(
		state => 'writing', pid => $$, start_ticks => $ticks,
		bytes => 256, total => 1024, rate => 1024,
		started_ms => (time() * 1000) - 2000, updated_ms => (time() * 1000) - 1000,
	);
	{
		my $said = status();
		is($said->{'state'}, 'writing', 'a live job is reported as writing');
		is($said->{'percent'}, 25, 'with its percentage');
		is($said->{'rate'}, 1024, 'and its rate');
	}

	# A pid that is gone with no final state is a stopped flash, not a running
	# one: the manager restarted unwatched, or the write was killed outside the
	# page. Report it failed rather than poll forever.
	write_job(
		state => 'writing', pid => 999_999, start_ticks => '1',
		started_ms => (time() * 1000) - 10_000, updated_ms => (time() * 1000) - 9000,
	);
	{
		my $said = status();
		is($said->{'state'}, 'failed', 'a dead writer reads failed');
		like($said->{'error'}, qr/stopped before it finished/, 'and says why');
	}

	# --- a finished job settles its token once -----------------------------
	my $failed_secret = 'testflashsecret000000000000000001';
	my $failed_token = "$dry/failed-token.json";
	write_file($failed_token, $JSON->encode({ kind => 'jawnos-controller-join', secret => $failed_secret }));
	insert_token($failed_secret);
	write_job(
		state => 'failed', error => 'the write stopped', token_path => $failed_token,
		started_ms => (time() * 1000) - 5000, updated_ms => time() * 1000,
	);
	{
		my $said = status();
		is($said->{'state'}, 'failed', 'the failed job is reported');
		ok(!-f $failed_token, 'its token file is removed');
		ok(!token_row($failed_secret), 'and the token is spent');
		ok((read_job())->{'cleaned'}, 'the job is marked settled once');
	}

	my $done_secret = 'testflashsecret000000000000000002';
	my $done_token = "$dry/done-token.json";
	write_file($done_token, $JSON->encode({ kind => 'jawnos-controller-join', secret => $done_secret }));
	insert_token($done_secret);
	write_job(
		state => 'done', bytes => 1024, total => 1024, sha256_match => 1,
		token_path => $done_token,
		started_ms => (time() * 1000) - 5000, updated_ms => time() * 1000,
	);
	{
		my $said = status();
		is($said->{'state'}, 'done', 'a done job is reported');
		ok(!-f $done_token, 'the host copy of the token is removed');
		ok(token_row($done_secret), 'but the cache row is kept for the board to redeem');
		subs::db_delete('cache', { context => 'controller_join', subcontext => $done_secret });
	}

	# --- cancel ------------------------------------------------------------
	unlink job_file();
	{
		my $said = cancel();
		is($said->{'ok'}, 0, 'there is nothing to cancel with no job');
		like($said->{'error'}, qr/no flash/, 'and it says so');
	}
	write_job(
		state => 'writing', pid => 999_999, start_ticks => '1',
		started_ms => (time() * 1000) - 5000, updated_ms => time() * 1000,
	);
	{
		my $said = cancel();
		is($said->{'ok'}, 0, 'a dead job is not cancelled either');
	}

	# The real signal path: a session leader that never finishes on its own is
	# TERMed as a group. Its state has no writer after the kill, so the route
	# writes the final cancelled record.
	my $child = fork();
	if (!defined $child) {
		skip 'could not fork a fake flash', 3;
	}
	elsif (!$child) {
		POSIX::setsid();
		sleep 30;
		POSIX::_exit(0);
	}
	else {
		select(undef, undef, undef, 0.2);
		my $child_ticks = JawnOS::Platform::Process::start_time($child);
		write_job(
			state => 'writing', pid => $child, start_ticks => $child_ticks,
			bytes => 1024, total => 4096,
			started_ms => (time() * 1000) - 2000, updated_ms => time() * 1000,
		);
		my $said = cancel();
		ok($said->{'ok'}, 'a running flash is cancelled');
		is($said->{'state'}, 'cancelled', 'and the state says cancelled');
		waitpid($child, 0);
		ok(!JawnOS::Platform::Process::running($child), 'the process group is gone');
	}

	# A job that has a live session leader but has not written a byte yet is
	# checking the image, not dead. The route records the pid before the child can
	# spend a minute hashing, so a status poll during that wait leaves it alone.
	write_job(
		state => 'starting', pid => $$, start_ticks => $ticks,
		started_ms => (time() * 1000) - 60_000, updated_ms => (time() * 1000) - 60_000,
	);
	{
		my $said = status();
		is($said->{'state'}, 'starting', 'a live job that has not written yet is not called dead');
	}

	# --- the script and the page ------------------------------------------
	my $provision = read_file(root() . '/scripts/gou_provision.pl');
	like($provision, qr/'progress=s'/, 'the provisioner takes a progress file');
	like($provision, qr/_progress_write\('checking'/, 'and says when it is checking the image');
	like($provision, qr/_progress_write\('writing'/, 'and writes the byte count as it goes');
	like($provision, qr/_progress_write\('verifying'/, 'then verifying');
	like($provision, qr/_progress_write\('preparing'/, 'then preparing the board');
	like($provision, qr/_progress_write\('done'/, 'and done');
	like($provision, qr/\$SIG\{'TERM'\}/, 'TERM cancels the write');
	like($provision, qr/return \{ ok => 0, cancelled => 1/, 'a cancelled write is not a write error');
	like($provision, qr/"if=\$dev", 'bs=8M'/, 'the read-back reads whole blocks through dd');
	like($provision, qr/_progress_write\('verifying', bytes => 0/, 'the verify starts the bar again');
	like($provision, qr/_wait_for_reboot/, 'the flash waits for the board to restart');
	like($provision, qr/'no-reboot'/, 'and can be told not to ask it to');
	# An empty machine-id hangs the boot before the kiosk: systemd cannot write
	# one while the initrd's root is read-only and writes `uninitialized`, and
	# journald then restarts forever ahead of sysinit.target.
	like($provision, qr/sub _fresh_machine_id/, 'the flash mints a machine-id for the board');
	like($provision, qr/unpack\('H\*', \$bytes\)/, 'as 32 hex characters from /dev/urandom');
	like($provision, qr/push \@done, 'machine-id'/, 'and reports it as filled in');
	# A wants link is relative to its own directory. Pointing at the bare unit
	# name made it resolve to itself, which systemd refuses, so the first-boot
	# unit never ran: no config seed, no join, no kiosk ticket.
	like($provision, qr/sub _wants_link/, 'wants links are made by one helper');
	like($provision, qr/my \$target = "\.\.\/\$unit"/, 'and point at the unit beside them, not at themselves');
	like($provision, qr/sub _splash_unit/, 'the panel carries the mark while the Manager starts');
	like($provision, qr/sub _tune_kiosk/, 'the kiosk is tuned for a low-memory board');
	like($provision, qr/enable-low-end-device-mode/, 'with Chromium low-end mode');
	like($provision, qr/renderer-process-limit=1/, 'and a single renderer');

	# The failed-image path writes the progress file without root or a device,
	# so the page still shows the reason.
	my $progress = "$dry/provision-progress.json";
	my $status = system($^X, root() . '/scripts/gou_provision.pl',
		'--flash', '--dry-run', '--image', "$dry/no-such-image.img", '--progress', $progress);
	isnt($status, 0, 'a missing image fails the provisioner');
	my $written = eval { $JSON->decode(read_file($progress)) } || {};
	is($written->{'state'}, 'failed', 'and the progress file says failed');
	like($written->{'error'}, qr/image not found/, 'with the reason the page shows');
	ok(($written->{'pid'} // 0) > 1, 'the provisioner records its own pid');
	ok(length($written->{'start_ticks'} // ''), 'and its start time');
	# The provisioner runs as root under the manager's umask 0077. The file holds no
	# secret and the manager reads it, so a root 0600 file is a job nobody can see.
	is(sprintf('%04o', (stat($progress))[2] & 07777), '0644', 'the progress file is readable by the manager');
	like($provision, qr/chmod 0644, \$tmp/, 'and the writer sets that mode itself');

	my $routes = read_file(root() . '/lib/JawnOS/Routes/manager_controllers.pm');
	like($routes, qr{54012, 'get',\s+'/manager/controllers/new/flash/status'}, 'the status route is registered');
	like($routes, qr{54013, 'post',\s+'/manager/controllers/new/flash/cancel'}, 'the cancel route is registered');

	my $controller = read_file(root() . '/lib/JawnOS/Controller/manager_controllers.pm');
	unlike($controller, qr/pid => \$pid,\s*\n\s*start_ticks/,
		'the route does not read-modify-write the job after the fork');
	like($provision, qr/_progress_write\('starting'/, 'the provisioner says it has started before any check');

	my $js = read_file(root() . '/public/js/manager/controllers.js');
	like($js, qr{/manager/controllers/new/flash/status}, 'the page polls the status route');
	like($js, qr{/manager/controllers/new/flash/cancel}, 'and offers Cancel');
	like($js, qr/controller_flash_bar/, 'with a progress bar');
	like($js, qr/MB\/s/, 'a rate in MB per second');
	like($js, qr/controllerFlashResume/, 'a reopened window resumes the job');
	like($js, qr/The panel restarted; the flash is still running\./, 'and a restart is not a failure');
	like($js, qr/F3\+F6/, 'the page says how to restart a board that stayed in recovery');
	like(read_file(root() . '/templates/controllers/style.html.ep'), qr/\.controller_flash_bar/, 'the bar has a style');
	like(read_file(root() . '/perl/help/topics_apps.pl'), qr/Cancel button beside it/, 'the guide names the bar and Cancel');
}

done_testing();
