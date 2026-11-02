# tests-for: lib/JawnOS/Domain/Ai3.pm lib/JawnOS/Domain/Calendar.pm perl/President.pl
# covers:    cwd-relative, as with t/61: verify_change copies a test to /tmp for the pre-push parse check, while the proces...

use strict;
use warnings;

# cwd-relative, as with t/61: verify_change copies a test to /tmp for the pre-push
# parse check, while the process still runs with the repo as its working directory.
use lib "lib", "t/lib";
use Test::More;

require JawnOS::Domain::Ai3;
no warnings 'once';

# The classifier the error watch uses on the console stream and the supervisor's
# crash tail. The master prints "tree exited on its own" when the tree dies by
# itself; a deliberate restart suppresses it, and the END line "They dead" is not
# a fault. The shutdown sweep's `kill: ... failed` noise must stay out.
$subs::error_watch_noise = qr/Permission denied|cannot open \/proc\/net|President stopping on SIGINT; cleaning up|kill: sending signal to \d+ failed: No such process/;

ok(subs::error_watch_is_error('tree exited on its own (exit=1 signal=0)'),
	'a tree death is a fault even without an error word');
ok(subs::error_watch_is_error("See it's dead"),
	'and the master\'s report of it');
ok(!subs::error_watch_is_error('They dead'),
	'the deliberate END line on a restart is not');
ok(!subs::error_watch_is_error('kill: sending signal to 123 failed: No such process'),
	'the shutdown sweep\'s kill noise is filtered');
ok(subs::error_watch_is_error('Use of uninitialized value $rcv in numeric eq (==) at ./perl/President.pl line 3.'),
	'a Perl warning is still caught');
ok(!subs::error_watch_is_error('remote sync: a peer announced new rows; running the pass now'),
	'an ordinary info line is not');

my $a = subs::error_signature('Use of uninitialized value $rcv at ./perl/../lib/JawnOS/Domain/Calendar.pm line 345.');
my $b = subs::error_signature('Use of uninitialized value $rcv at ./perl/../lib/JawnOS/Domain/Calendar.pm line 902.');
is($a, $b, 'line numbers do not split one signature');

done_testing();
