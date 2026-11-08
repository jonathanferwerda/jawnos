# tests-for: lib/JawnOS/Domain/Embedded2.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Loader.pm
# covers:    A press drives every output wired to its app. One output that dies
#            (a bad sighting, an unreachable board) used to abort the fan-out in
#            intelligent_automation_toggle, so the board after it was never
#            commanded and nothing in the log said so. Each output is now on its
#            own, named with chip and pin if it fails, and embedded_toggle says
#            when it takes the device road and when it drops a command as older.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(encode_json);

use JawnOSTest;

my $root = root();
my $read = sub { scalar read_file("$root/$_[0]") };

# The fan-out reads its wiring from settings and its ordering from the stored
# toggle. Both are stubbed so this test is about the loop and nothing else.
my $wiring = {
	'CHIP_A' => { 28 => { component => 'relay', direction => 'output', edt => 'microcontroller',
		ip => '192.0.2.10', movement => 'start', pin => '28' } },
	'CHIP_B' => { 16 => { component => 'led', direction => 'output', edt => 'microcontroller',
		ip => '192.0.2.11', movement => 'start', pin => '16' } },
	'CHIP_C' => { 15 => { component => 'switch', direction => 'input', edt => 'microcontroller',
		ip => '192.0.2.10', movement => 'start', pin => '15' } },
};
my $wired = encode_json($wiring);
{
	no warnings 'redefine';
	*subs::settings_grabber = sub { return { ia => $_[0]->{'app'} eq 't_empty' ? '' : $wired } };
	*subs::toggle_event_is_older = sub { return 0 };
}

# --- the fan-out survives one bad output --------------------------------
my @called;
{
	no warnings 'redefine';
	*subs::embedded_toggle = sub {
		my ($d) = @_;
		push @called, $d->{'chip_id'} . ':' . $d->{'pin'};
		die "this board is unreachable\n";
	};
}
my $survived = eval { subs::intelligent_automation_toggle({ app => 't_fanout', state => 'on', timestamp => subs::rightNow() }); 1 };
ok($survived, 'a dying output does not escape the fan-out')
	or diag("escaped with: $@");
is(scalar @called, 2, 'both outputs were still attempted');
is_deeply([ sort @called ], [ 'CHIP_A:28', 'CHIP_B:16' ], 'the relay and the LED, and not the switch');

# --- the healthy case still hands every output a command ----------------
@called = ();
{
	no warnings 'redefine';
	*subs::embedded_toggle = sub { my ($d) = @_; push @called, $d->{'chip_id'}; 1 };
}
subs::intelligent_automation_toggle({ app => 't_fanout', state => 'off', timestamp => subs::rightNow() });
is_deeply([ sort @called ], [ 'CHIP_A', 'CHIP_B' ], 'a good press commands both outputs');

# A wiring map that never came through used to leave the press with no trace.
@called = ();
eval { subs::intelligent_automation_toggle({ app => 't_empty', state => 'on', timestamp => subs::rightNow() }) };
ok(!$@, 'an app with no wiring map is not an error');
is(scalar @called, 0, 'and it commands nothing');

# --- and the road to the board is named in the log ----------------------
my $notify = $read->('lib/JawnOS/Domain/Notify.pm');
like($notify, qr/' \(send\)'/, 'a device command says when it starts for the board');
like($notify, qr/is older than the stored toggle, output left alone/,
	'and when it is dropped as older, instead of vanishing');

my $fanout = $read->('lib/JawnOS/Domain/Embedded2.pm');
like($fanout, qr/my \$ok = eval \{\n\s*&subs::embedded_toggle\(\{/, 'each output is called under eval');
like($fanout, qr/output ' \. \$chip \. ' pin '/, 'and a failure names the chip and pin');
like($fanout, qr/has no readable wiring/, 'an unreadable wiring map is reported');

done_testing();
