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
	system('git', '-C', $dir, 'config', 'user.email', 'test@example.com') == 0 or die 'git config failed';
	system('git', '-C', $dir, 'config', 'user.name', 'test') == 0 or die 'git config failed';
	put("$dir/tracked.txt", "one\n");
	system('git', '-C', $dir, 'add', 'tracked.txt') == 0 or die 'git add failed';
	system('git', '-C', $dir, 'commit', '-qm', 'init') == 0 or die 'git commit failed';
	put("$dir/tracked.txt", "one\ntwo\n");
	put("$dir/new.txt", "brand new\n");
	put("$dir/staged.txt", "someone else\n");
	system('git', '-C', $dir, 'add', 'staged.txt') == 0 or die 'git add staged failed';

	no warnings 'redefine';
	local *subs::coding_repo = sub { $dir };
	local *subs::coding_rel = sub { $_[0] };
	my $bundle = &subs::coding_diff_bundle([ 'tracked.txt', 'new.txt' ]);
	is($bundle->{'error'}, '', 'a normal change produces a bundle without an error');
	like($bundle->{'text'}, qr/\+two/, 'the modification is in the diff');
	like($bundle->{'text'}, qr/new\.txt/, 'a new file is in the diff (add -N)');
	unlike($bundle->{'text'}, qr/staged\.txt/, 'work already staged by someone else is not in the review');
	ok(length $bundle->{'hash'}, 'the bundle carries a fingerprint of what was shown');
	ok(!$bundle->{'truncated'}, 'a short diff is not reported as truncated');
	is(&subs::coding_diff_text([]), '', 'no files is an empty diff');
	is(&subs::coding_diff_text('tracked.txt'), '', 'a non-list is an empty diff');

	# the throwaway index leaves the real one alone: a refused review must not
	# change what the person's next commit does
	my $status = `cd "$dir" && git status --porcelain`;
	like($status, qr/^\?\? new\.txt$/m, 'a reviewed new file is still untracked for the real index');
	unlike($status, qr/^A\s+new\.txt/m, 'the review did not stage the new file');

	# a diff past the cap is cut on a character boundary and says so
	put("$dir/big.txt", "\xC3\xA9\n" x 8000);
	my $long = &subs::coding_diff_bundle(['big.txt']);
	ok($long->{'truncated'}, 'a long diff is reported as truncated');
	my $probe = $long->{'text'};
	ok(utf8::decode($probe), 'the truncated text is still valid UTF-8');
	like($long->{'text'}, qr/rest of the diff is not shown/, 'the cut says the rest is missing');
}

# An unsafe path refuses the whole review. It is never rewritten into a name
# that matches no file: the empty diff that produced would read as an approval.
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
	my $bundle = &subs::coding_diff_bundle([ 'lib/fine.pm', '../etc/passwd' ]);
	like($bundle->{'error'}, qr{etc/passwd}, 'an escaping path is named in the refusal');
	is($bundle->{'text'}, '', 'and no diff is produced');
	ok(!-f $log, 'no git command runs for a refused path');

	my $plus = &subs::coding_diff_bundle(['lib/a+b.txt']);
	like($plus->{'error'}, qr/a\+b\.txt/, 'a name git would rewrite is refused, not mangled');
}

# --- the list the review and the commit share --------------------------------
{
	no warnings 'redefine';
	local *subs::coding_repo = sub { $root };
	is_deeply([ &subs::coding_review_files({ 'b.pm' => 1, 'a.pm' => 1 }) ],
		[ 'a.pm', 'b.pm', 'VERSION' ],
		'the review list is sorted and carries the version file the commit adds');
	is_deeply([ &subs::coding_review_files({ 'VERSION' => 1, 'a' => 1 }) ],
		[ 'VERSION', 'a' ], 'VERSION is not listed twice');
	is_deeply([ &subs::coding_review_files(undef) ], [ 'VERSION' ],
		'an untouched run still reviews the version file');
}

# --- one path, one shell word ------------------------------------------------
is(&subs::coding_shell_quote('a b.pm'), "'a b.pm'", 'a space keeps a path one word');
is(&subs::coding_shell_quote('x$y'), "'x\$y'", 'a dollar sign is quoted, not expanded');
is(&subs::coding_shell_quote("it's"), "'it'\\''s'", 'an apostrophe cannot end the word');

# --- the pause ---------------------------------------------------------------
{
	my %state;
	my @answers;
	my @cleared;
	no warnings 'redefine';
	local *subs::coding_diff_bundle = sub {
		return { text => 'diff --git a/x b/x', hash => 'shown', truncated => 0, error => '' };
	};
	local *subs::coding_run_state_save = sub { $state{ $_[0] } = $_[1]; 1 };
	local *subs::coding_run_state_load = sub { $state{ $_[0] } || {} };
	local *subs::coding_run_push = sub { 1 };
	local *subs::rightNow = sub { 1000 };
	local *subs::coding_verdict_set = sub { push @cleared, [ $_[0], $_[1] ]; 1 };
	local *subs::coding_verdict_take = sub { return @answers ? shift(@answers) : ''; };
	local $subs::coding_approve_poll = 0;

	# approve: the commit may run, and the pending review is gone
	$state{7} = { run => 7, conversation => 'selftest', state => 'active' };
	@answers = ('approve');
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'approved',
		'an approve verdict lets the commit run');
	ok(!exists $state{7}{'pending_commit'}, 'the approved review is cleared');
	ok(!exists $state{7}{'approve'}, 'the verdict is not written into the run snapshot');
	is($state{7}{'state'}, 'active', 'the run is active again');
	is_deeply($cleared[0], [ 7, '' ], 'a verdict left from an earlier pause is cleared first');

	# reject: the commit does not run
	$state{7} = { run => 7, conversation => 'selftest', state => 'active' };
	@answers = ('reject');
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'rejected',
		'a reject verdict stops the commit');
	ok(!exists $state{7}{'reject'}, 'the reject verdict is not left in the snapshot');
	is($state{7}{'state'}, 'active', 'the run is active again after a rejection');

	# cancel: the run stops, the review is not approved
	$state{7} = { run => 7, conversation => 'selftest', state => 'active' };
	@answers = ();
	$state{7}{'cancel'} = 1;
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'cancelled',
		'a cancel verdict stops the review');

	# timeout: a zero deadline is already past
	$state{7} = { run => 7, conversation => 'selftest', state => 'active' };
	@answers = ();
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm'], 0), 'timeout',
		'a past deadline times the review out');

	# an empty diff is not an approval: it fails closed, with the reason on the run
	%state = ();
	@answers = ('approve');
	local *subs::coding_diff_bundle = sub { { text => '', hash => '', truncated => 0, error => '' } };
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'diff_failed',
		'an empty diff does not approve itself');
	like($state{7}{'error'} // '', qr/no change/, 'and says there was no change to show');
	ok(!exists $state{7}{'pending_commit'}, 'and leaves no review on the panel');

	# a diff that could not be produced is the same refusal
	%state = ();
	local *subs::coding_diff_bundle = sub { { text => '', hash => '', truncated => 0, error => 'cannot show a diff for that path: x' } };
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'diff_failed',
		'an unshowable change is not committed');
	like($state{7}{'error'} // '', qr/cannot show a diff/, 'and the reason reaches the run');

	# a tree that moved between the review and the approval is not committed
	%state = ();
	@answers = ('approve');
	my $calls = 0;
	local *subs::coding_diff_bundle = sub {
		$calls++;
		return { text => 'diff --git a/x b/x', hash => ($calls == 1 ? 'shown' : 'moved'), truncated => 0, error => '' };
	};
	is(&subs::coding_await_commit(7, 'selftest', ['lib/x.pm']), 'changed',
		'a tree that moved after it was shown is not committed');
	like($state{7}{'error'} // '', qr/moved after it was shown/, 'and says why');
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
	like($approve_body // '', qr/coding_verdict_set\(\$id, 'approve'\)/, 'approve writes its own verdict');
	like($approve_body // '', qr/coding_worker_alive/, 'approve refuses when no worker would take it');
	my ($reject_body) = $controller =~ /sub\s+action_37572\s*\{(.*?)\n\}/s;
	like($reject_body // '', qr/awaiting_approval/, 'reject refuses a run that is not waiting');
	like($reject_body // '', qr/coding_verdict_set\(\$id, 'reject'\)/, 'reject writes its own verdict');
	like($reject_body // '', qr/coding_worker_alive/, 'reject refuses when no worker would take it');
}

# --- the commit stages what was reviewed -------------------------------------
my $part29 = source('lib/JawnOS/Manager/Part29.pm');
{
	like($part29, qr/coding_review_files/, 'the commit stages the list the review showed');
	like($part29, qr/git commit -m .*?-- /s, 'the commit takes a pathspec, so already-staged work is not swept in');
	like($part29, qr/coding_shell_quote/, 'the paths are shell-quoted, not interpolated');
}

# --- the panel ---------------------------------------------------------------
my $panels = source('public/js/manager/coding/02_panels.js');
{
	like($panels, qr/coding_poll_gen/, 'a replaced poll chain stops instead of arming a second one');
	like($panels, qr/diff_truncated/, 'a shortened diff says so');
	like($panels, qr/approved_committing/, 'the approved word is a language key, not English');
	like($panels, qr{/manager/coding/reject}, 'a new ask answers a review the worker is still waiting on');
	like($panels, qr/coding_review_at/, 'a second review in one run starts the block over');
}

# --- the checkbox ------------------------------------------------------------
my $template = source('templates/configure/plat_setting_list.html.ep');
like($template, qr/setting="coding_review"/, 'the checkbox saves the review setting');
like($template, qr/&subs::lang\('review_before_commit'\)|Review before commit/, 'the checkbox says what it does');
like($template, qr/\(\$review \/\/ 'on'\) ne 'off'/, 'the checkbox is checked unless the setting is off');

done_testing();
