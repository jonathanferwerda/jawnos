# tests-for: lib/JawnOS/Domain/Say.pm
# covers:    Every method the tree asks the device bridge for must be one the app knows; and an
#            Android shell is recognised from its environment before `uname` is asked.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Find;
use JawnOSTest;

subs::preload('device_setter');

# Every method the tree asks the device bridge for must be one the app knows.
# A typo does not fail loudly: subs::device_call falls back to the termux
# command, which still works, so the mistake would be invisible until the day
# the termux command is deleted. This test is the list.

my %known = map { $_ => 1 } qw(
	battery.status
	network.interfaces
	image.resize
	image.save
	image.edit
	image.cover
	image.identify
	image.convert
	image.gray
	image.normalize
	image.montage
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
	silence.set
	telephony.dial
	telephony.deviceinfo
	media.player
	media.thumbnail
	share.send
	open.url
	notification.list
	media.record
	camera.photo
	auth.fingerprint
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

# An Android shell is recognised before `uname` is asked: ANDROID_ROOT is a
# truthy check, and its value is never read. PATH is emptied for the block so a
# fall-through to `uname -a` cannot answer 'mobile' by accident.
{
	local $subs::config = {};
	local $ENV{'ANDROID_ROOT'} = '/no/such/path';
	local $ENV{'TERMUX_VERSION'} = undef;
	local $ENV{'PATH'} = '/nonexistent/bin';
	is(&subs::device_setter(), 'mobile',
		'ANDROID_ROOT marks the device mobile without running uname');
}

# The probe is environment-only; the block's local must have restored the real
# environment for everything that runs after this file.
isnt($ENV{'ANDROID_ROOT'}, '/no/such/path', 'the fake Android root is cleared after the block');

done_testing();
