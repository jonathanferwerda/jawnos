# tests-for: lib/JawnOS/Domain/Calendar.pm
# covers:    an appointment with no time does not make the alarm poke warn.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

require JawnOS::Domain::Calendar;

# The alarm poke compares the appointment's three moments with now. A row built
# without one of them (a model/tick row) reached the comparison undefined and
# warned twice on every save; on a phone that was a steady log write on the
# appointment path. A missing time must be quiet and not due.
my @warnings;
{
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	subs::appt_alarm_setter({ type => 'start', uuid => 'x', app => 'email_test' });
}
is( scalar @warnings, 0, 'no warning when every time is missing' );

@warnings = ();
{
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	# The shapes a half-built row carries: an empty string and a non-numeric one.
	subs::appt_alarm_setter({ type => 'start', timestamp => '', stop_timestamp => 'later', next_duty => undef });
}
is( scalar @warnings, 0, 'no warning for empty and non-numeric times' );

done_testing();
