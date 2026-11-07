# tests-for: lib/JawnOS/Domain/Resolve.pm lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Manager/Part33.pm
# covers:    A phone must not be called localhost: Android has no hostname of its own, so the name a person reads
#            comes from the machine's own config and house domain, and an unusable report heals from the fqdn.
#            The same per-machine name is the computer segment of the durable id a device stores as its
#            homebase, so a mesh-synced me/computer_name can never make two machines answer to one id.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;
use JawnOSTest;

# Android/Termux answers `hostname` with 'localhost' (or a build token like
# 'fe'), so the OS hostname is never the name a person should see for a
# handheld. The config's own name and its house domain label are.

# ------------------------------------------------- device_hostname_from_domain
is subs::device_hostname_from_domain('tablet.jonathanferwerda.com'), 'Tablet',
	'the house domain names the tablet';
is subs::device_hostname_from_domain('phone.jonathanferwerda.com'), 'Phone',
	'and the phone';
is subs::device_hostname_from_domain('https://tablet.jonathanferwerda.com:45545/manager'), 'Tablet',
	'a manager url is reduced to its machine label';
is subs::device_hostname_from_domain('table.jonathanferwerda.com'), 'Table',
	'and a desktop';

foreach my $not_a_name ('', 'localhost', '127.0.0.1', '192.168.1.142', '100.64.0.6', '::1', 'tablet') {
	is subs::device_hostname_from_domain($not_a_name), '',
		"device_hostname_from_domain('$not_a_name') is not a machine name";
}

# -------------------------------------------------- device_hostname_better
is subs::device_hostname_better('localhost', 'Tablet', 'tablet.jonathanferwerda.com'), 'Tablet',
	'a report of localhost does not overwrite the name already learned';
is subs::device_hostname_better('localhost', '', 'tablet.jonathanferwerda.com'), 'Tablet',
	'with nothing remembered, the fqdn names the device';
is subs::device_hostname_better('fe', '', ''), 'fe',
	'a real reported hostname still wins';
is subs::device_hostname_better('localhost', 'localhost', '192.168.1.142'), '',
	'and localhost is never handed back as a name';

# ---------------------------------------------------------------- machine_name
is subs::machine_name_from_config({ name => 'Tablet', domain => 'tablet.jonathanferwerda.com' }, ''),
	'Tablet', 'a configured name is the machine name';
is subs::machine_name_from_config({ domain => 'phone.jonathanferwerda.com' }, 'localhost'),
	'Phone', 'without a configured name the domain label is used';
is subs::machine_name_from_config({ domain => '127.0.0.1' }, 'localhost'),
	'', 'a hostname of localhost is never the machine name';
is subs::machine_name_from_config({ domain => '127.0.0.1' }, 'vivotop'),
	'vivotop', 'a real OS hostname is still the last resort';

# ------------------------------------------------------- machine_file_from
is subs::machine_file_from('Jonathan Ferwerda', 'database/jawnos.db', 'Phone', 'localhost'),
	'Jonathan Ferwerda@jawnos.Phone', 'the durable id names the machine the person paired it to';
is subs::machine_file_from('Jonathan Ferwerda', 'homes/jawnos.db', 'Table', 'table'),
	'Jonathan Ferwerda@jawnos.Table', 'a nested database path is reduced to its name';
is subs::machine_file_from('Jonathan Ferwerda', 'database/jawnos.db', '', 'localhost'),
	'Jonathan Ferwerda@jawnos.localhost', 'an unnamed machine falls back to its hostname';
is subs::machine_file_from('', 'database/jawnos.db', 'Phone', 'vivotop'),
	'vivotop@jawnos.Phone', 'a missing person falls back to the hostname too';

# Both copies of manager_file_maker must build the id from machine_name: a
# mesh-synced me/computer_name is shared, so it cannot name a machine.
foreach my $file ('lib/JawnOS/Domain/Generate.pm', 'lib/JawnOS/Manager/Part33.pm') {
	my $src = read_file(repo_root() . '/' . $file);
	my ($maker) = $src =~ /(sub manager_file_maker\b.*?\n\};)/s;
	ok(defined $maker && length $maker, "$file has a manager_file_maker");
	like($maker, qr/machine_file_from\(/, "$file composes the durable id in one place");
	like($maker, qr/&subs::machine_name\(\)/, "$file names the machine by its own name");
	unlike($maker, qr/app => 'me', setting => 'computer_name'/, "$file does not read the synced computer_name");
}

done_testing();
