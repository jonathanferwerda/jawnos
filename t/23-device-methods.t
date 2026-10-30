use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Find;

# Every method the tree asks the device bridge for must be one the app knows.
# A typo does not fail loudly: subs::device_call falls back to the termux
# command, which still works, so the mistake would be invisible until the day
# the termux command is deleted. This test is the list.

my %known = map { $_ => 1 } qw(
	battery.status
	notification.post
	notification.remove
	toast.show
	clipboard.get
	clipboard.set
	audio.volume
	hardware.torch
	power.wake_lock
	power.wake_unlock
	sms.send
	sms.list
	telephony.call_log
	contact.list
	location.current
	speech.speak
	telephony.dial
	telephony.deviceinfo
);

my $root = "$FindBin::Bin/..";
my @files;
File::Find::find({
	no_chdir => 1,
	wanted   => sub {
		my $path = $File::Find::name;
		push @files, $path if -f $path && $path =~ /\.(?:pl|pm)$/
			&& $path !~ m{/(?:\.shots|\.stage|\.git)(?:/|$)};
	},
}, $root);
push @files, "$root/jawn" if -f "$root/jawn";

my %seen;
for my $file (@files) {
	open(my $fh, '<', $file) or next;
	while (my $line = <$fh>) {
		next if $line =~ /^\s*#/;
		while ($line =~ /device_call\s*\(\s*['"]([A-Za-z0-9_.-]+)['"]/g) {
			$seen{$1}->{$file} = 1;
		}
	}
	close $fh;
}

ok(scalar keys %seen, 'the tree calls the device bridge');

for my $method (sort keys %seen) {
	ok($known{$method}, "device_call('$method') is a known bridge method");
}

done_testing();
