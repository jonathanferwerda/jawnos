# tests-for: lib/JawnOS/Domain/Vacation.pm lib/JawnOS/Domain/Log.pm public/js/manager/calendarprinter.js
# covers:    the calendar's month mask of away days, the payload that carries
#            it, and the shaded band the month grid draws for those days.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JSON::PP qw(encode_json);
use JawnOSTest;
use RepoSource;

my $now = ts(2026, 11, 15, 12, 0, 0);

sub set_vacation {
	my ($from, $to, $state) = @_;
	my $json = encode_json({
		version => 1,
		periods => [ {
			uuid => 'away-calendar', from => $from,
			(defined $to ? (to => $to) : ()),
			state => $state || 'active', kind => 'vacation',
		} ],
		policy => {},
		auto => { detect => 0, after_hours => 24 },
	});
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'vacation', 'all');
	&subs::db_query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
		'vacation', $json, '__president', 'all', 'vacation-calendar', $now);
	&subs::vacation_forget();
}

sub clear_vacation {
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'vacation', 'all');
	&subs::vacation_forget();
}

my $nov = ts(2026, 11, 15, 12, 0, 0);

# a whole period inside the month; the end day is not away
set_vacation(ts(2026, 11, 3, 0, 0, 0), ts(2026, 11, 6, 0, 0, 0));
is_deeply(&subs::vacation_month_days($nov), [ '2026-11-03', '2026-11-04', '2026-11-05' ],
	'the month mask names each away day inside the month');

# a period that starts in the previous month is clipped to this one
set_vacation(ts(2026, 10, 30, 0, 0, 0), ts(2026, 11, 2, 0, 0, 0));
is_deeply(&subs::vacation_month_days($nov), [ '2026-11-01' ],
	'a period crossing into the month contributes only its days here');

# a period wholly in another month leaves this month empty
set_vacation(ts(2026, 12, 1, 0, 0, 0), ts(2026, 12, 5, 0, 0, 0));
is_deeply(&subs::vacation_month_days($nov), [], 'another month has no days here');

# an open period shades the month out to its end
set_vacation(ts(2026, 10, 30, 0, 0, 0), undef);
my $open_days = &subs::vacation_month_days($nov);
is(scalar @{$open_days}, 30, 'an open period shades every day of the month');
is($open_days->[0], '2026-11-01', 'the mask starts at the first day');
is($open_days->[-1], '2026-11-30', 'the mask ends at the last day');

# a proposal is a question, not an away span
set_vacation(ts(2026, 11, 3, 0, 0, 0), ts(2026, 11, 6, 0, 0, 0), 'proposed');
is_deeply(&subs::vacation_month_days($nov), [], 'a proposed period is not shaded');

clear_vacation();
is_deeply(&subs::vacation_month_days($nov), [], 'no period leaves the month unshaded');

# the payload carries the mask, and the grid draws it
my $root = repo_root();
like(read_file("$root/lib/JawnOS/Domain/Log.pm"),
	qr/__specs'\}->\{'away_days'\} = &subs::vacation_month_days\(\$timestamp\)/,
	'the appointment payload sends the month mask');
like(read_file("$root/public/js/manager/calendarprinter.js"),
	qr/away_days\[calendarDayKey\(day\)\]/,
	'the month grid looks up the away day');
like(read_file("$root/public/js/manager/calendarprinter.js"),
	qr/jawnosT\('Away'\)/,
	'the band is labelled Away through the translator');

done_testing();
