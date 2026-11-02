# tests-for: lib/JawnOS/Domain/Coding.pm lib/JawnOS/Controller/manager_misc11.pm lib/JawnOS/Routes/manager_misc11.pm templates/configure/plat_setting_list.html.ep
# covers:    review before commit - the setting, the diff a person is shown, the
#           pause and its verdicts, the approve/reject routes, and the checkbox.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use Test::More;

my $root = "$FindBin::Bin/..";

require JawnOS::Domain::Coding;

sub source {
	my ($rel) = @_;
	return read_file("$root/$rel");
}

sub put {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "open $path: $!";
	print $fh $text;
	close $fh;
}

# --- the setting -------------------------------------------------------------
# Review is on by default: only an explicit "off" turns it off.
{
	no warnings 'redefine';
	my $value;
	local *subs::setting_grabber = sub { $value };

	$value = undef;
	is(&subs::coding_review_setting(), 1, 'a missing setting means review is on');
	$value = '';
	is(&subs::coding_review_setting(), 1, 'an empty setting means review is on');
	$value = 'on';
	is(&subs::coding_review_setting(), 1, 'an explicit on is on');
	$value = 'off';
	is(&subs::coding_review_setting(), 0, 'off turns review off');
	$value = ' OFF ';
	is(&subs::coding_review_setting(), 0, 'off is read case- and space-insensitively');
}

# --- the diff ----------------------------------------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	system('git', '-C', $dir, 'init', '-q') == 0 or die 'git init failed';
	put("$dir/tracked.txt", "one\n");
	system('git', '-C', $dir, 'add', 'tracked.txt') == 0 or die 'git add failed';
	put("$dir/tracked.txt", "one\ntwo\n");
	put("$dir/new.txt", "brand new\n");

	no warnings 'redefine';
	local *subs::coding_repo = sub { $dir };
	local *subs::coding_rel = sub { $_[0] };
	my $diff = &subs::coding_diff_text([ 'tracked.txt', 'new.txt' ]);
	like($diff, qr/\+two/, 'the modification is in the diff');
	like($diff, qr/new\.txt/, 'a new file is in the diff (add -N)');
	is(&subs::coding_diff_text([]), '', 'no files is an empty diff');
	is(&subs::coding_diff_text('tracked.txt'), '', 'a non-list is an empty diff');
}

# An unsafe path never reaches the command line. A fake `git` records the
# arguments it is handed, so the assertion is about the command, not the diff.
{
	my $bin = tempdir(CLEANUP => 1);
	my $log = "$bin/args.log";
	put("$bin/git", "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> \"\$ARGS_LOG\"\nexit 0\n");
	chmod 0755, "$bin/git";
	local $ENV{'ARGS_LOG'} = $log;
	local $ENV{'PATH'} = "$bin:$ENV{'PATH'}";

	no warnings 'redefine';
	local *subs::coding_repo = sub { $bin };
	local *subs::coding_rel = sub { $_[0] };
	my $diff = &subs::coding_diff_text([ 'lib/fine.pm', '../etc/passwd' ]);
	is($diff, '', 'the fake git produces no diff');
	my $seen = -f $log ? read_file($log) : '';
	like($seen, qr/lib\/fine\.pm/, 'a safe path reaches git');
	unlike($seen, qr{\.\./etc/passwd}, 'an unsafe path is dropped before the shell');
}

# --- the pause ---------------------------------------------------------------
{
	my %state;
	no warnings 'redefine';
	local *subs::coding_diff_text = sub { 'diff --git a/x b/x' };
	local *subs::coding_run_state_save = sub { $state{ $_[0] } = $_[1]; 1 };
	local *subs::coding_run_state_load = sub { $state{ $_[0] } || {} };
	local *subs::coding_run_push = sub { 1 };
	local *subs::rightNow = sub { 1000 };
	local $subs::coding_approve_poll = 0;

	# approve: the commit may run, and the pending review is gone
	$state{7} = { run => 7, conversation => 'selftest', state => 'active', approve => 1 };
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'approved',
		'an approve verdict lets the commit run');
	ok(!exists $state{7}{'pending_commit'}, 'the approved review is cleared');
	ok(!exists $state{7}{'approve'}, 'the approve flag is consumed');
	is($state{7}{'state'}, 'active', 'the run is active again');

	# reject: the commit does not run
	$state{7} = { run => 7, conversation => 'selftest', state => 'active', reject => 1 };
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'rejected',
		'a reject verdict stops the commit');
	ok(!exists $state{7}{'reject'}, 'the reject flag is consumed');
	is($state{7}{'state'}, 'active', 'the run is active again after a rejection');

	# cancel: the run stops, the review is not approved
	$state{7} = { run => 7, conversation => 'selftest', state => 'active', cancel => 1 };
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'cancelled',
		'a cancel verdict stops the review');

	# timeout: a zero deadline is already past
	$state{7} = { run => 7, conversation => 'selftest', state => 'active' };
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm'], 0), 'timeout',
		'a past deadline times the review out');

	# an empty diff is nothing to review, so no pause and no state write
	%state = ();
	local *subs::coding_diff_text = sub { '' };
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'approved',
		'an empty diff approves at once');
	ok(!exists $state{7}, 'an empty diff writes no awaiting state');
}

# An approved commit is the only verdict that reaches the toolset; rejected and
# cancelled end the run without one.
{
	my $domain = source('lib/JawnOS/Domain/Coding.pm');
	my ($body) = $domain =~ /sub\s+coding_run_job\s*(?:\([^)]*\))?\s*\{(.*?)\n\}\n\n1;/s;
	$body //= '';
	like($body, qr/coding_await_commit/, 'the job pauses before a reviewed commit');
	like($body, qr/Stopped: the commit was rejected\./, 'a rejection has its own end');
	like($body, qr/Stopped at your request\./, 'a cancel has its own end');
	like($body, qr/coding_review_setting/, 'the pause is gated by the setting');
}

# --- the routes and the actions ---------------------------------------------
require JawnOS::Routes::manager_misc11;
my $routes = [ JawnOS::Routes::manager_misc11::routes() ];
{
	my ($approve) = grep { ($_->[2] // '') eq '/manager/coding/approve' } @$routes;
	ok($approve, 'the approve route is registered');
	is($approve->[1], 'post', 'approve is a POST');
	is($approve->[3], 'action_37571', 'approve names its action');

	my ($reject) = grep { ($_->[2] // '') eq '/manager/coding/reject' } @$routes;
	ok($reject, 'the reject route is registered');
	is($reject->[1], 'post', 'reject is a POST');
	is($reject->[3], 'action_37572', 'reject names its action');
}

my $controller = source('lib/JawnOS/Controller/manager_misc11.pm');
{
	my ($approve) = $controller =~ /sub\s+action_37571\s*\{/;
	ok($approve, 'the approve action exists');
	my ($reject) = $controller =~ /sub\s+action_37572\s*\{/;
	ok($reject, 'the reject action exists');
	my ($approve_body) = $controller =~ /sub\s+action_37571\s*\{(.*?)\n\}/s;
	like($approve_body // '', qr/awaiting_approval/, 'approve refuses a run that is not waiting');
	like($approve_body // '', qr/\{'approve'\}\s*=\s*1/, 'approve writes the approve flag');
	my ($reject_body) = $controller =~ /sub\s+action_37572\s*\{(.*?)\n\}/s;
	like($reject_body // '', qr/awaiting_approval/, 'reject refuses a run that is not waiting');
	like($reject_body // '', qr/\{'reject'\}\s*=\s*1/, 'reject writes the reject flag');
}

# --- the checkbox ------------------------------------------------------------
my $template = source('templates/configure/plat_setting_list.html.ep');
like($template, qr/setting="coding_review"/, 'the checkbox saves the review setting');
like($template, qr/&subs::lang\('review_before_commit'\)|Review before commit/, 'the checkbox says what it does');
like($template, qr/\(\$review \/\/ 'on'\) ne 'off'/, 'the checkbox is checked unless the setting is off');

done_testing();
