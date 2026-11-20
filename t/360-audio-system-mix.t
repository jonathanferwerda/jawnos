# tests-for: lib/JawnOS/Audio/SystemMix.pm
# covers:    the machine's ordinary audio while the engine owns the card: a
#            machine with no pactl keeps its output and skips, the sink is
#            created and made the default once, a repeat changes nothing, and
#            off restores the previous default and unloads the sink. A state
#            file left by a crash is cleaned up rather than stranded.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

require JawnOS::Audio::SystemMix;
require JawnOS::Platform::Audio;

sub write_file {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} $text;
	close $fh;
}

sub read_file {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

# --- a machine with no tool keeps its ordinary output ------------------------
{
	my $empty = tempdir(CLEANUP => 1);
	local $ENV{PATH} = $empty;
	JawnOS::Platform::Audio::reset_backend();

	my $state = tempdir(CLEANUP => 1);
	ok(!JawnOS::Audio::SystemMix::available(), 'no pactl means no system mix here');

	my $answer = JawnOS::Audio::SystemMix::ensure($state);
	is($answer->{ok}, 0, 'ensure does not claim success');
	is($answer->{skipped}, 1, 'it is skipped, not a failure');
	like($answer->{error}, qr/pactl|PulseAudio/, 'and it says why');
	ok(!-e "$state/audio-system-mix.json", 'and writes no state to strand');
}

# --- a fake PulseAudio, so the lifecycle is testable without a card ---------
my $dir = tempdir(CLEANUP => 1);
my $bin = "$dir/bin";
make_path($bin);
write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
write_file("$dir/default", "alsa_output.real\n");
write_file("$dir/pactl.log", '');

my $pactl = "$bin/pactl";
write_file($pactl, <<'PACTL');
#!/usr/bin/env perl
use strict;
use warnings;
my $dir = $ENV{FAKE_PACTL_DIR} or exit 9;
open(my $log, '>>', "$dir/pactl.log") or exit 9;
print {$log} join(' ', @ARGV), "\n";
close $log;
my $cmd = $ARGV[0] // '';
if ($cmd eq 'info') {
	print "Server Name: PulseAudio (on PipeWire 0.3.85)\n";
	exit 0;
}
if ($cmd eq 'list' && ($ARGV[1] // '') eq 'short' && ($ARGV[2] // '') eq 'sinks') {
	print read_file("$dir/sinks");
	exit 0;
}
if ($cmd eq 'get-default-sink') {
	print read_file("$dir/default");
	exit 0;
}
if ($cmd eq 'set-default-sink') {
	# A server can accept the switch and not move the default yet. `once`
	# ignores the first request and honours the second; `never` ignores all of
	# them. The count file lets the test see how many attempts were made.
	my $count_file = "$dir/set_count";
	my $count = read_file($count_file);
	$count =~ s/\s+//g;
	$count = 0 unless $count =~ /\A\d+\z/;
	$count++;
	open(my $cfh, '>', $count_file) or exit 9;
	print {$cfh} "$count\n";
	close $cfh;
	my $mode = $ENV{FAKE_PACTL_SET} || '';
	exit 0 if $mode eq 'never';
	exit 0 if $mode eq 'once' && $count == 1;
	open(my $fh, '>', "$dir/default") or exit 9;
	print {$fh} $ARGV[1], "\n";
	close $fh;
	exit 0;
}
if ($cmd eq 'load-module') {
	open(my $fh, '>>', "$dir/sinks") or exit 9;
	print {$fh} "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n";
	close $fh;
	print "42\n";
	exit 0;
}
if ($cmd eq 'unload-module') {
	open(my $fh, '>', "$dir/sinks") or exit 9;
	print {$fh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $fh;
	exit 0;
}
exit 0;
sub read_file {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}
PACTL
chmod 0755, $pactl or die "chmod $pactl: $!";

local $ENV{PATH} = "$bin:$ENV{PATH}";
local $ENV{FAKE_PACTL_DIR} = $dir;
JawnOS::Platform::Audio::reset_backend();

my $state_dir = "$dir/state";
make_path($state_dir);

ok(JawnOS::Audio::SystemMix::available(), 'the fake server answers');

my $before = JawnOS::Audio::SystemMix::status($state_dir);
is($before->{available}, 1, 'status sees the server');
is($before->{active}, 0, 'and nothing is managed yet');
is($before->{current}, 'alsa_output.real', 'the current default is the real output');

my $on = JawnOS::Audio::SystemMix::ensure($state_dir);
is($on->{ok}, 1, 'ensure creates the system sink');
is($on->{sink}, 'jawn_system', 'named jawn_system');
is($on->{source}, 'jawn_system.monitor', 'whose monitor is the engine source');
is($on->{previous_default}, 'alsa_output.real', 'it remembers the default it replaced');
is($on->{created}, 1, 'and reports it created the sink');
is(read_file("$dir/default"), "jawn_system\n", 'the sink is the default output now');
ok(-s "$state_dir/audio-system-mix.json", 'the state file records the cleanup');

my $again = JawnOS::Audio::SystemMix::ensure($state_dir);
is($again->{ok}, 1, 'a repeat ensure succeeds');
is($again->{created}, 0, 'without loading a second sink');
is($again->{module_id}, 42, 'and keeps the same module id');
is(read_file("$dir/default"), "jawn_system\n", 'the default is unchanged');

my $mid = JawnOS::Audio::SystemMix::status($state_dir);
is($mid->{active}, 1, 'status says the mix is active');
is($mid->{present}, 1, 'and the sink is there');

my $off = JawnOS::Audio::SystemMix::remove($state_dir);
is($off->{ok}, 1, 'remove succeeds');
is($off->{restored}, 1, 'it restores the previous default');
is($off->{unloaded}, 1, 'and unloads the module');
is(read_file("$dir/default"), "alsa_output.real\n", 'the real output is back');
unlike(read_file("$dir/sinks"), qr/jawn_system/, 'the sink is gone');
ok(!-e "$state_dir/audio-system-mix.json", 'and the state file is gone');

my $twice = JawnOS::Audio::SystemMix::remove($state_dir);
is($twice->{ok}, 1, 'a second remove is harmless');
is($twice->{skipped}, 1, 'and changes nothing');

# A supervisor killed after ensure leaves exactly this state behind. The next
# run restores the output before it starts an engine of its own.
{
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/default", "jawn_system\n");
	write_file("$state_dir/audio-system-mix.json",
		'{"sink":"jawn_system","source":"jawn_system.monitor","previous_default":"alsa_output.real","module_id":42}');

	my $stale = JawnOS::Audio::SystemMix::remove($state_dir);
	is($stale->{ok}, 1, 'a crash remnant is removed');
	is(read_file("$dir/default"), "alsa_output.real\n", 'the machine is handed back');
}

# --- the default switch is verified, not trusted ---------------------------
# The hardware run that found this: `pactl load-module` and
# `pactl set-default-sink` raced, ensure answered ok, and the next run found
# the built-in card still the default. The fake ignores the first switch, so a
# run that always succeeds can only pass by asking again.
sub reset_mix {
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	write_file("$dir/default", "alsa_output.real\n");
	write_file("$dir/pactl.log", '');
	unlink "$dir/set_count";
}
sub set_attempts {
	my $count = () = read_file("$dir/pactl.log") =~ /set-default-sink jawn_system/g;
	return $count;
}

{
	reset_mix();
	local $ENV{FAKE_PACTL_SET} = 'once';
	my $race_state = tempdir(CLEANUP => 1);

	my $on = JawnOS::Audio::SystemMix::ensure($race_state);
	is($on->{ok}, 1, 'ensure succeeds when the server honours the retried switch');
	is(read_file("$dir/default"), "jawn_system\n", 'the sink is the default after the retry');
	is(set_attempts(), 2, 'it asked for the switch twice rather than trusting the first');
	is($on->{source}, 'jawn_system.monitor', 'the engine source is still the sink monitor');
	ok(-s "$race_state/audio-system-mix.json", 'and the state file is written');

	my $off = JawnOS::Audio::SystemMix::remove($race_state);
	is($off->{ok}, 1, 'the sink can still be removed after the retry');
	is(read_file("$dir/default"), "alsa_output.real\n", 'and the previous default comes back');
}

{
	reset_mix();
	local $ENV{FAKE_PACTL_SET} = 'never';
	my $race_state = tempdir(CLEANUP => 1);

	my $on = JawnOS::Audio::SystemMix::ensure($race_state);
	is($on->{ok}, 0, 'ensure refuses success when the default never moves');
	like($on->{error}, qr/default output/, 'and says the switch did not take in one sentence');
	is(set_attempts(), 2, 'it retried once and then gave up');
	is(read_file("$dir/default"), "alsa_output.real\n", 'the machine keeps the output it had');
	unlike(read_file("$dir/sinks"), qr/jawn_system/, 'the sink this call created is unloaded');
	ok(!-e "$race_state/audio-system-mix.json", 'and no state is left to strand');
}

done_testing();
