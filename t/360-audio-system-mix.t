# tests-for: lib/JawnOS/Audio/SystemMix.pm
# covers:    the machine's ordinary audio while the engine plays it: a machine
#            with no pactl keeps its output and skips, the sink is created and
#            made the default once, a repeat changes nothing, and off restores
#            the previous default and unloads the sink. A state file left by a
#            crash is cleaned up rather than stranded. A PipeWire device gets
#            the sink and the switch and no card rule, and a mix with no known
#            output to play through is refused rather than looped. The sink is
#            born with the replaced output's volume and mute, so the tray does
#            not jump to 100%, while the output the engine plays through is
#            held at unity; a repeated ensure leaves a level the person set but
#            keeps that output at unity, and remove puts the level and mute
#            back - after a failed unload and after a crash too. An output
#            whose level cannot be read leaves both sinks alone and says why.

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

# The card facts pactl reports. Card 0 is the laptop's built-in PCH: one
# playback node and one capture node. Card 1 stands in for a USB interface.
write_file("$dir/sinks_json", <<'JSON');
[
  {"index":0,"name":"alsa_output.pci-0000_00_1f.3.analog-stereo",
   "properties":{"alsa.card":"0","api.alsa.pcm.stream":"playback",
                 "node.name":"alsa_output.pci-0000_00_1f.3.analog-stereo"}},
  {"index":1,"name":"alsa_output.usb-card",
   "properties":{"alsa.card":"1","api.alsa.pcm.stream":"playback",
                 "node.name":"alsa_output.usb-card"}}
]
JSON
write_file("$dir/sources_json", <<'JSON');
[
  {"index":0,"name":"alsa_input.pci-0000_00_1f.3.analog-stereo",
   "properties":{"alsa.card":"0","api.alsa.pcm.stream":"capture",
                 "node.name":"alsa_input.pci-0000_00_1f.3.analog-stereo"}},
  {"index":1,"name":"alsa_input.usb-card",
   "properties":{"alsa.card":"1","api.alsa.pcm.stream":"capture",
                 "node.name":"alsa_input.usb-card"}}
]
JSON
write_file("$dir/sinks_long", <<'LONG');
Sink #0
	Name: alsa_output.pci-0000_00_1f.3.analog-stereo
	Properties:
		alsa.card = "0"
		api.alsa.pcm.stream = "playback"
		node.name = "alsa_output.pci-0000_00_1f.3.analog-stereo"
LONG
write_file("$dir/sources_long", <<'LONG');
Source #0
	Name: alsa_input.pci-0000_00_1f.3.analog-stereo
	Properties:
		alsa.card = "0"
		api.alsa.pcm.stream = "capture"
		node.name = "alsa_input.pci-0000_00_1f.3.analog-stereo"
LONG
write_file("$dir/systemctl.log", '');

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
my $all = join(' ', @ARGV);
if ($all eq '-f json list sinks') {
	if ($ENV{FAKE_PACTL_TEXT_ONLY}) {
		print "pactl: -f json is not supported\n";
		exit 0;
	}
	print read_file("$dir/sinks_json");
	exit 0;
}
if ($all eq '-f json list sources') {
	if ($ENV{FAKE_PACTL_TEXT_ONLY}) {
		print "pactl: -f json is not supported\n";
		exit 0;
	}
	print read_file("$dir/sources_json");
	exit 0;
}
if ($all eq 'list sinks') {
	print read_file("$dir/sinks_long");
	exit 0;
}
if ($all eq 'list sources') {
	print read_file("$dir/sources_long");
	exit 0;
}
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
	# A server that refuses the unload leaves the sink in place, so the
	# caller can be seen restoring what it changed on a failed removal.
	exit 1 if ($ENV{FAKE_PACTL_UNLOAD} || '') eq 'fail';
	open(my $fh, '>', "$dir/sinks") or exit 9;
	print {$fh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
	close $fh;
	sink_level('jawn_system', undef, undef, 1);
	exit 0;
}
if ($cmd eq 'get-sink-volume') {
	if (($ENV{FAKE_PACTL_LEVEL} || '') eq 'unreadable') {
		print "Failure: No such entity\n";
		exit 1;
	}
	my ($volume) = sink_level($ARGV[1]);
	print "Volume: front-left: 32768 / $volume% / -0.00 dB,   front-right: 32768 / $volume% / -0.00 dB\n";
	exit 0;
}
if ($cmd eq 'get-sink-mute') {
	if (($ENV{FAKE_PACTL_LEVEL} || '') eq 'unreadable') {
		print "Failure: No such entity\n";
		exit 1;
	}
	my (undef, $mute) = sink_level($ARGV[1]);
	print "Mute: $mute\n";
	exit 0;
}
	if ($cmd eq 'set-sink-volume') {
		my $volume = $ARGV[2] // '';
		$volume =~ s/%//g;
		sink_level($ARGV[1], $volume, undef);
		exit 0;
	}
	if ($cmd eq 'set-sink-mute') {
		my $mute = ($ARGV[2] // '0') =~ /^(?:1|yes|true|on)$/i ? 'yes' : 'no';
		sink_level($ARGV[1], undef, $mute);
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

# One line per sink: `name volume mute`. A sink with no line is the server
# default the server gives every new sink: 100%, unmuted.
sub sink_level {
	my ($name, $volume, $mute, $drop) = @_;
	my (@lines, $found);
	foreach my $line (split /\n/, read_file("$dir/levels")) {
		my ($n, $v, $m) = split /\s+/, $line;
		next unless defined $n && length $n;
		if ($n eq $name) {
			$found = [ $v, $m ];
			next if $drop;
			$v = $volume if defined $volume;
			$m = $mute if defined $mute;
			push @lines, "$n $v $m";
			next;
		}
		push @lines, $line;
	}
	unless ($drop) {
		push @lines, "$name " . ($volume // 100) . ' ' . ($mute // 'no')
			unless $found;
	}
	open(my $fh, '>', "$dir/levels") or exit 9;
	print {$fh} join("\n", @lines) . (@lines ? "\n" : '');
	close $fh;
	return $found ? @{$found} : (100, 'no');
}
PACTL
chmod 0755, $pactl or die "chmod $pactl: $!";

# WirePlumber is only restarted through this fake; the host's real session
# manager is never touched by the test.
my $systemctl = "$bin/systemctl";
write_file($systemctl, <<'SYSTEMCTL');
#!/usr/bin/env perl
use strict;
use warnings;
my $dir = $ENV{FAKE_PACTL_DIR} or exit 9;
open(my $log, '>>', "$dir/systemctl.log") or exit 9;
print {$log} join(' ', @ARGV), "\n";
close $log;
exit 0;
SYSTEMCTL
chmod 0755, $systemctl or die "chmod $systemctl: $!";

local $ENV{PATH} = "$bin:$ENV{PATH}";
local $ENV{FAKE_PACTL_DIR} = $dir;
local $ENV{JAWNOS_SYSTEMCTL} = $systemctl;
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

# --- the mix carries the person's level, so the tray does not jump ---------
# The hardware run that found this: the sink was created at the server default,
# so the desktop tray read 100% while the loudness stayed where it was.
{
	reset_mix();
	write_levels("alsa_output.real 65 yes\n");
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = tempdir(CLEANUP => 1) . '/wireplumber';
	my $level_state = tempdir(CLEANUP => 1);

	my $on = JawnOS::Audio::SystemMix::ensure($level_state, 'default');
	is($on->{ok}, 1, 'ensure creates the sink');
	is($on->{level}{volume}, 65, 'and reports the volume it copied');
	my ($volume, $mute) = level_of('jawn_system');
	is($volume, 65, "the person's volume, not the server default");
	is($mute, 'yes', 'and its mute state too');
	is((level_of('alsa_output.real'))[0], 100,
		'the output the engine plays through is raised to unity');

	# The person moves the live mix; a repeated ensure must not undo that.
	write_levels("alsa_output.real 65 yes\njawn_system 40 no\n");
	my $again = JawnOS::Audio::SystemMix::ensure($level_state, 'default');
	is($again->{ok}, 1, 'a repeat ensure succeeds');
	ok(!exists $again->{level}, 'and copies nothing a second time');
	is((level_of('jawn_system'))[0], 40, 'leaving the level the person set');

	# Something moved the hardware sink; the level must still be applied once.
	write_levels("alsa_output.real 55 no\njawn_system 40 no\n");
	JawnOS::Audio::SystemMix::ensure($level_state, 'default');
	is((level_of('alsa_output.real'))[0], 100,
		'a repeat ensure holds the hardware output at unity');

	my $off = JawnOS::Audio::SystemMix::remove($level_state);
	is($off->{ok}, 1, 'the mix still removes cleanly');
	is($off->{level_restored}, 1, 'and reports the level put back');
	is(read_file("$dir/default"), "alsa_output.real\n", 'and the previous output comes back');
	is((level_of('alsa_output.real'))[0], 65,
		'the output is handed back at the volume it had');
	is((level_of('alsa_output.real'))[1], 'yes', 'and muted as it was');
	write_levels('');
}

# A failed removal and a crashed mix both end at the same place: the output must
# not be left pinned at 100%, or the person's next ordinary playback is loud.
{
	reset_mix();
	write_levels("alsa_output.real 30 no\n");
	my $out = tempdir(CLEANUP => 1);
	my $on = JawnOS::Audio::SystemMix::ensure($out, 'default');
	is($on->{ok}, 1, 'a quiet hardware output is raised for the mix');
	is((level_of('alsa_output.real'))[0], 100, 'it sits at unity while the mix lives');

	local $ENV{FAKE_PACTL_UNLOAD} = 'fail';
	my $stuck = JawnOS::Audio::SystemMix::remove($out);
	is($stuck->{ok}, 0, 'a removal that cannot unload the sink fails');
	is($stuck->{level_restored}, 1, 'and still reports the level put back');
	is((level_of('alsa_output.real'))[0], 30, 'the output gets its level back anyway');
	ok(-e "$out/audio-system-mix.json", 'the state is kept for a retry');

	local $ENV{FAKE_PACTL_UNLOAD} = '';
	my $retry = JawnOS::Audio::SystemMix::remove($out);
	is($retry->{ok}, 1, 'the retry removes the mix');
	is((level_of('alsa_output.real'))[0], 30, 'and the level stays where it belongs');
	write_levels('');
}

{
	reset_mix();
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/default", "jawn_system\n");
	write_levels("alsa_output.real 100 no\njawn_system 30 yes\n");
	my $out = tempdir(CLEANUP => 1);
	write_file("$out/audio-system-mix.json",
		'{"sink":"jawn_system","source":"jawn_system.monitor",'
			. '"previous_default":"alsa_output.real","module_id":42,'
			. '"previous_level":{"volume":30,"mute":1}}');

	my $stale = JawnOS::Audio::SystemMix::remove($out);
	is($stale->{ok}, 1, 'a mix a crash left behind is removed');
	is($stale->{level_restored}, 1, 'and the level it carried goes back');
	is((level_of('alsa_output.real'))[0], 30, 'the output is no longer pinned at 100%');
	is((level_of('alsa_output.real'))[1], 'yes', 'and its mute comes back too');
	is(read_file("$dir/default"), "alsa_output.real\n", 'it is the default again');
	write_levels('');
}

# A level the server will not report is not guessed at.
{
	reset_mix();
	write_levels("alsa_output.real 30 yes\n");
	local $ENV{FAKE_PACTL_LEVEL} = 'unreadable';
	my $out = tempdir(CLEANUP => 1);

	my $on = JawnOS::Audio::SystemMix::ensure($out, 'default');
	is($on->{ok}, 1, 'the mix still comes up without a level');
	is($on->{level}{ok}, 0, 'and reports that it could not be read');
	like($on->{level}{error}, qr/cannot be read/, 'with the reason in one sentence');
	is((level_of('alsa_output.real'))[0], 30, 'the hardware output keeps its level');
	is((level_of('alsa_output.real'))[1], 'yes', 'and its mute');
	is((level_of('jawn_system'))[0], 100, 'the mix keeps the server default');

	JawnOS::Audio::SystemMix::remove($out);
	write_levels('');
}

# An output the server no longer lists has no level to copy; the sink stays at
# the server default rather than the module guessing one.
{
	reset_mix();
	write_levels("alsa_output.real 65 no\n");
	write_file("$dir/default", "alsa_output.gone\n");
	my $gone_state = tempdir(CLEANUP => 1);

	my $on = JawnOS::Audio::SystemMix::ensure($gone_state, 'default');
	is($on->{ok}, 1, 'ensure still creates the sink when the replaced output is gone');
	is($on->{level}{ok}, 0, 'it reports that no level could be read');
	like($on->{level}{error}, qr/cannot be read/, 'and says why');
	is((level_of('jawn_system'))[0], 100, 'and the sink stays at the server default');

	JawnOS::Audio::SystemMix::remove($gone_state);
	write_levels('');
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
	write_file("$dir/systemctl.log", '');
	write_file("$dir/levels", '');
	unlink "$dir/set_count";
}

# The fake server's per-sink levels: `name volume mute`. A sink with no line is
# what the server gives a new sink, 100% and unmuted.
sub write_levels {
	write_file("$dir/levels", @_ ? $_[0] : '');
}

sub level_of {
	my ($name) = @_;
	foreach my $line (split /\n/, read_file("$dir/levels")) {
		my ($n, $volume, $mute) = split /\s+/, $line;
		return ($volume, $mute) if defined $n && $n eq $name;
	}
	return (100, 'no');
}
sub restart_count {
	my $log = read_file("$dir/systemctl.log");
	my $count = () = $log =~ /--user restart wireplumber/g;
	return $count;
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

# --- the card's playback node is freed, its microphone is not ---------------
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	my $rule = "$card_dir/wireplumber/51-jawnos-studio-card.conf";

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0');
	is($on->{ok}, 1, 'ensure with the laptop card succeeds');
	is($on->{managed_card}{node}, 'alsa_output.pci-0000_00_1f.3.analog-stereo',
		'it maps hw:0,0 to the card\'s playback node');
	ok(-s $rule, 'and writes the WirePlumber rule');
	my $text = read_file($rule);
	like($text, qr/node\.name = "alsa_output\.pci-0000_00_1f\.3\.analog-stereo"/,
		'the rule matches the playback node');
	unlike($text, qr/alsa_input|api\.alsa\.pcm\.stream = "capture"/,
		'the microphone node is not disabled');
	like($text, qr/microphone node is deliberately left/i,
		'and a comment says the source stays with PipeWire');
	is(restart_count(), 1, 'WirePlumber is restarted once for the new rule');
	is(read_file("$dir/default"), "jawn_system\n", 'the sink is the default as before');

	# With the rule live, WirePlumber no longer offers the playback sink to
	# pactl. A repeated ensure must reuse the recorded mapping rather than
	# mistaking that for a missing card, and must not restart the manager again.
	my $json_again = read_file("$dir/sinks_json");
	my $long_again = read_file("$dir/sinks_long");
	write_file("$dir/sinks_json", "[]\n");
	write_file("$dir/sinks_long", "");
	my $again = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0');
	is($again->{ok}, 1, 'a repeat ensure reuses the recorded node');
	is($again->{managed_card}{node}, $on->{managed_card}{node},
		'and keeps the same playback node');
	is(restart_count(), 1, 'without restarting WirePlumber a second time');
	write_file("$dir/sinks_json", $json_again);
	write_file("$dir/sinks_long", $long_again);

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	is($off->{ok}, 1, 'remove succeeds');
	ok(!-e $rule, 'remove unlinks the rule this module wrote');
	is(read_file("$dir/default"), "alsa_output.real\n", 'and restores the previous output');
	is(restart_count(), 2, 'WirePlumber is restarted again to read the removal');
}

# --- a card that cannot be mapped is an error, never a guessed rule ---------
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	my $rule = "$card_dir/wireplumber/51-jawnos-studio-card.conf";

	my $bad = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:7,0');
	is($bad->{ok}, 0, 'a card with no playback sink is refused');
	like($bad->{error}, qr/card 7|playback node/, 'and the reason names the card');
	ok(!-e $rule, 'no rule is written');
	ok(!-e "$card_dir/audio-system-mix.json", 'and no sink state is left behind');
	is(read_file("$dir/default"), "alsa_output.real\n", 'the machine keeps its output');

	# Duplex needs both nodes; a missing capture node is the same refusal.
	my $sjson = read_file("$dir/sources_json");
	my $slong = read_file("$dir/sources_long");
	write_file("$dir/sources_json", "[]\n");
	write_file("$dir/sources_long", "");
	my $no_cap = JawnOS::Audio::SystemMix::ensure(
		tempdir(CLEANUP => 1), 'hw:0,0', 'duplex');
	is($no_cap->{ok}, 0, 'a duplex plan with no capture node is refused');
	like($no_cap->{error}, qr/capture node/, 'and the reason names the capture node');
	write_file("$dir/sources_json", $sjson);
	write_file("$dir/sources_long", $slong);
}

# --- an older pactl answers the long listing instead of JSON ----------------
{
	reset_mix();
	local $ENV{FAKE_PACTL_TEXT_ONLY} = 1;
	my $map = JawnOS::Audio::SystemMix::card_playback_node('hw:0,0');
	is($map->{ok}, 1, 'the long listing maps without JSON');
	is($map->{node}, 'alsa_output.pci-0000_00_1f.3.analog-stereo',
		'and names the same playback node');
}

# --- a PipeWire device gets the sink and no card rule ----------------------
{
	reset_mix();
	my $wp_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$wp_dir/wireplumber";
	my $rule = "$wp_dir/wireplumber/51-jawnos-studio-card.conf";

	my $map = JawnOS::Audio::SystemMix::card_nodes('default', 'playback');
	is($map->{ok}, 0, 'a PipeWire device names no ALSA card');
	like($map->{error}, qr/not an ALSA card/, 'and card_nodes says so');

	my $on = JawnOS::Audio::SystemMix::ensure($wp_dir, 'default');
	is($on->{ok}, 1, 'ensure with default creates the system sink');
	is($on->{source}, 'jawn_system.monitor', 'whose monitor is the engine source');
	is($on->{playback_device}, 'alsa_output.real',
		'and names the output the engine must play through');
	ok(!exists $on->{managed_card}, 'no WirePlumber rule is installed');
	ok(!-e $rule, 'and no rule file is written');
	is(read_file("$dir/default"), "jawn_system\n", 'the sink is the default output');

	my $off = JawnOS::Audio::SystemMix::remove($wp_dir);
	is($off->{ok}, 1, 'remove succeeds');
	is(read_file("$dir/default"), "alsa_output.real\n", 'and the output comes back');
}

# --- with no known previous output the mix would capture itself ------------
{
	reset_mix();
	my $wp_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$wp_dir/wireplumber";
	write_file("$dir/default", "jawn_system\n");

	my $on = JawnOS::Audio::SystemMix::ensure($wp_dir, 'default');
	is($on->{ok}, 0, 'ensure refuses when the sink is default with no history');
	like($on->{error}, qr/own capture/, 'and says it will not play into itself');
	unlike(read_file("$dir/sinks"), qr/jawn_system/, 'no sink is loaded');
	ok(!-e "$wp_dir/audio-system-mix.json", 'and no state is written');
}

{
	reset_mix();
	my $wp_dir = tempdir(CLEANUP => 1);
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/default", "jawn_system\n");
	write_file("$wp_dir/audio-system-mix.json",
		'{"sink":"jawn_system","source":"jawn_system.monitor",'
			. '"previous_default":"","module_id":42}');

	my $on = JawnOS::Audio::SystemMix::ensure($wp_dir, 'default');
	is($on->{ok}, 0, 'an active mix with no playback device is refused');
	unlike(read_file("$dir/sinks"), qr/jawn_system/,
		'the sink that would capture itself is unloaded');
	ok(!-e "$wp_dir/audio-system-mix.json", 'and its state is cleared');
}

# --- duplex disables both nodes because the engine captures the mic --------
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	my $rule = "$card_dir/wireplumber/51-jawnos-studio-card.conf";

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0', 'duplex');
	is($on->{ok}, 1, 'a duplex ensure succeeds');
	is($on->{managed_card}{mode}, 'duplex', 'the state records the mode');
	is($on->{managed_card}{playback}, 'alsa_output.pci-0000_00_1f.3.analog-stereo',
		'it maps the playback node');
	is($on->{managed_card}{capture}, 'alsa_input.pci-0000_00_1f.3.analog-stereo',
		'and the capture node');
	my $text = read_file($rule);
	like($text, qr/node\.name = "alsa_output\.pci-0000_00_1f\.3\.analog-stereo"/,
		'the rule matches playback');
	like($text, qr/node\.name = "alsa_input\.pci-0000_00_1f\.3\.analog-stereo"/,
		'and capture, like the table rule');
	like($text, qr/engine captures this card's\n# microphone/,
		'and says the engine captures the microphone');

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	is($off->{ok}, 1, 'remove succeeds');
	ok(!-e $rule, 'and unlinks the duplex rule');
}

# --- a mode flip maps only the node our own rule had hidden ---------------
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	my $rule = "$card_dir/wireplumber/51-jawnos-studio-card.conf";

	is(JawnOS::Audio::SystemMix::mode_union('playback', 'duplex'), 'duplex',
		'playback plus duplex is duplex');
	is(JawnOS::Audio::SystemMix::mode_union('duplex', 'playback'), 'duplex',
		'duplex plus playback stays duplex while the engine catches up');
	is(JawnOS::Audio::SystemMix::mode_union('playback', 'playback'), 'playback',
		'only two playback answers are sink-only');

	my $play = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0', 'playback');
	is($play->{ok}, 1, 'a playback ensure installs the sink-only rule');
	my $restarts = restart_count();

	# The playback node is now hidden from pactl; the capture node is not.
	my $json = read_file("$dir/sinks_json");
	my $long = read_file("$dir/sinks_long");
	write_file("$dir/sinks_json", "[]\n");
	write_file("$dir/sinks_long", "");
	my $up = JawnOS::Audio::SystemMix::mode_union('playback', 'duplex');
	my $duplex = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0', $up);
	is($duplex->{ok}, 1, 'playback to duplex succeeds');
	is($duplex->{managed_card}{capture}, 'alsa_input.pci-0000_00_1f.3.analog-stereo',
		'it mapped the capture node the old rule left visible');
	like(read_file($rule), qr/node\.name = "alsa_input\./,
		'and rewrote the rule with both nodes');
	is(restart_count(), $restarts + 1, 'the changed rule restarted WirePlumber once');
	write_file("$dir/sinks_json", $json);
	write_file("$dir/sinks_long", $long);

	# The reverse: the plan is playback but the engine still says duplex. The
	# rule stays duplex until the respawn; ensure must not fail.
	my $down = JawnOS::Audio::SystemMix::mode_union('duplex', 'playback');
	my $still = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0', $down);
	is($still->{ok}, 1, 'duplex to playback does not fail');
	like(read_file($rule), qr/node\.name = "alsa_input\./,
		'and the rule may stay duplex until the engine respawns');
	is(restart_count(), $restarts + 1, 'an unchanged duplex rule is not restarted');

	JawnOS::Audio::SystemMix::remove($card_dir);
}

# --- table's hand-written both-direction rule is adopted -------------------
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	my $rule = "$card_dir/wireplumber/51-jawnos-studio-card.conf";
	make_path("$card_dir/wireplumber");
	my $table = <<'TABLE';
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_output.usb-Burr-Brown_from_TI_USB_Audio_CODEC.*" }
      { node.name = "~alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC.*" }
    ]
    actions = { update-props = { node.disabled = true } }
  }
]
TABLE
	write_file($rule, $table);

	# The rule hides both nodes from pactl, so only the file can supply them.
	my $json  = read_file("$dir/sinks_json");
	my $long  = read_file("$dir/sinks_long");
	my $sjson = read_file("$dir/sources_json");
	my $slong = read_file("$dir/sources_long");
	write_file("$dir/sinks_json", "[]\n");
	write_file("$dir/sinks_long", "");
	write_file("$dir/sources_json", "[]\n");
	write_file("$dir/sources_long", "");

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0', 'duplex');
	is($on->{ok}, 1, 'the hidden card is adopted rather than refused');
	is($on->{managed_card}{previous_present}, 0,
		'and the engine rule is not saved as a person\'s file');
	like(read_file($rule), qr/managed by JawnOS Sound/, 'the managed marker is added');
	like(read_file($rule), qr/alsa_output\.usb-Burr-Brown/, 'the playback match is kept');
	like(read_file($rule), qr/alsa_input\.usb-Burr-Brown/, 'and the capture match');

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	is($off->{ok}, 1, 'remove succeeds');
	ok(!-e $rule, 'and unlinks the adopted rule instead of restoring it');

	write_file("$dir/sinks_json", $json);
	write_file("$dir/sinks_long", $long);
	write_file("$dir/sources_json", $sjson);
	write_file("$dir/sources_long", $slong);
}

# --- a playback plan on table rewrites the adopted rule sink-only ----------
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	my $rule = "$card_dir/wireplumber/51-jawnos-studio-card.conf";
	make_path("$card_dir/wireplumber");
	my $table = <<'TABLE';
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_output.usb-Burr-Brown.*" }
      { node.name = "~alsa_input.usb-Burr-Brown.*" }
    ]
    actions = { update-props = { node.disabled = true } }
  }
]
TABLE
	write_file($rule, $table);

	my $json = read_file("$dir/sinks_json");
	my $long = read_file("$dir/sinks_long");
	write_file("$dir/sinks_json", "[]\n");
	write_file("$dir/sinks_long", "");

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0', 'playback');
	is($on->{ok}, 1, 'a playback plan adopts the hidden card');
	unlike(read_file($rule), qr/alsa_input/,
		'and rewrites it with the playback match only');
	like(read_file($rule), qr/microphone node is deliberately left/,
		'with the comment that the mic stays with PipeWire');

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	is($off->{ok}, 1, 'remove succeeds');
	ok(!-e $rule, 'and the card is handed back, not re-hidden');

	write_file("$dir/sinks_json", $json);
	write_file("$dir/sinks_long", $long);
}

# --- a person's unrelated rule at the path is replaced and put back --------
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	my $rule = "$card_dir/wireplumber/51-jawnos-studio-card.conf";
	make_path("$card_dir/wireplumber");
	my $person = <<'PERSON';
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "bluez_output.00_11_22_33_44_55.1" }
    ]
    actions = { update-props = { node.disabled = true } }
  }
]
PERSON
	write_file($rule, $person);

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0');
	is($on->{ok}, 1, 'a pre-existing rule does not block ensure');
	unlike(read_file($rule), qr/bluez_output/,
		'its unrelated match is replaced by the card rule');
	is($on->{managed_card}{previous_present}, 1, 'the previous file is recorded');

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	is($off->{ok}, 1, 'remove succeeds');
	is(read_file($rule), $person, 'and the person\'s file is restored verbatim');
}

# --- a machine without systemd still writes the rule and says so -----------
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	local $ENV{JAWNOS_SYSTEMCTL} = '';
	my $rule = "$card_dir/wireplumber/51-jawnos-studio-card.conf";

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0');
	is($on->{ok}, 1, 'a machine without systemctl still succeeds');
	like($on->{managed_card}{note}, qr/next start/, 'and says when the rule takes effect');
	ok(-s $rule, 'the rule is written for that next start');
	is(restart_count(), 0, 'nothing pretends to restart WirePlumber');

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	is($off->{ok}, 1, 'remove is also skipped cleanly');
	ok(!-e $rule, 'and the rule is gone');
}

done_testing();
