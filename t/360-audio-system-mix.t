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
#            keeps that output at unity, and remove hands back the live mix's
#            own level (the loudness the person hears today) - after a failed
#            unload and after a crash too. The level is written to the output
#            before the default moves, and the sink is unloaded last, so a
#            stream that follows the handover never lands on unity. The start
#            has the same order in reverse: the mix's level is written before
#            it becomes the default, and the output is raised to unity only
#            after the switch, so a restart never plays an app stream at full
#            scale. An output
#            whose level cannot be read leaves both sinks alone and says why.
#            A mix whose state file was wiped is still taken down: the module is
#            found by the sink name it was loaded with, the default leaves
#            jawn_system, the mix's own level is carried onto the real output
#            and unmuted, and the module is unloaded by that id; no sink at all
#            is a clean skip.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

	require JawnOS::Audio::SystemMix;
	require JawnOS::Platform::Audio;
	use JSON::PP ();

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
write_file("$dir/sources", '');
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
if ($cmd eq 'list' && ($ARGV[1] // '') eq 'short' && ($ARGV[2] // '') eq 'sources') {
	print read_file("$dir/sources");
	exit 0;
}
if ($all eq 'list cards') {
	print read_file("$dir/cards_long");
	exit 0;
}
if ($cmd eq 'set-card-profile') {
	# The handback cycles an active profile off and back when the card's
	# nodes were not rebuilt. A marker makes the fake rebuild them on the
	# return, as WirePlumber does after a successful re-probe.
	my $profile = $ARGV[2] // '';
	if ($profile ne 'off' && -e "$dir/card_nodes_rebuild") {
		write_text("$dir/sinks", read_file("$dir/sinks_rebuilt"));
		write_text("$dir/sources", read_file("$dir/sources_rebuilt"));
		unlink "$dir/card_nodes_rebuild";
	}
	exit 0;
}
if ($cmd eq 'info') {
	print "Server Name: PulseAudio (on PipeWire 0.3.85)\n";
	exit 0;
}
if ($cmd eq 'list' && ($ARGV[1] // '') eq 'short' && ($ARGV[2] // '') eq 'sinks') {
	# A removal reads this list straight after a WirePlumber restart, before
	# the card's nodes are rebuilt. With a count in `sink_restore`, the output
	# comes back on the read that takes it to zero.
	if (-e "$dir/sink_restore") {
		my $left = read_file("$dir/sink_restore");
		$left =~ s/\s+//g;
		$left = 0 unless $left =~ /\A\d+\z/;
		if ($left > 0) {
			$left--;
			write_text("$dir/sink_restore", "$left\n");
			if ($left == 0) {
				open(my $sfh, '>>', "$dir/sinks") or exit 9;
				print {$sfh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
				close $sfh;
			}
		}
	}
	print read_file("$dir/sinks");
	exit 0;
}
if ($cmd eq 'list' && ($ARGV[1] // '') eq 'short' && ($ARGV[2] // '') eq 'modules') {
	print read_file("$dir/modules_short");
	exit 0;
}
if ($all eq 'list modules') {
	print read_file("$dir/modules_long");
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
	open(my $mfh, '>', "$dir/modules_short") or exit 9;
	print {$mfh} "42\tmodule-null-sink\tsink_name=jawn_system\n";
	close $mfh;
	open(my $mlh, '>', "$dir/modules_long") or exit 9;
	print {$mlh} "Module #42\n\tName: module-null-sink\n\tArgument: sink_name=jawn_system\n";
	close $mlh;
	print "42\n";
	exit 0;
}
	if ($cmd eq 'unload-module') {
		# A server that refuses the unload leaves the sink in place, so the
		# caller can be seen restoring what it changed on a failed removal.
		exit 1 if ($ENV{FAKE_PACTL_UNLOAD} || '') eq 'fail';
		write_text("$dir/modules_short", '');
		write_text("$dir/modules_long", '');
		open(my $fh, '>', "$dir/sinks") or exit 9;
		print {$fh} "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n";
		close $fh;
		sink_level('jawn_system', undef, undef, 1);
		exit 0;
	}
if ($cmd eq 'get-sink-volume') {
	# A live mix the server will not report, so the saved level is the
	# only fallback; `FAKE_PACTL_LEVEL` fails every read instead.
	if ( ($ARGV[1] // '') eq 'jawn_system'
		&& ($ENV{FAKE_PACTL_MIX_LEVEL} || '') eq 'unreadable' ) {
		print "Failure: No such entity\n";
		exit 1;
	}
	if (($ENV{FAKE_PACTL_LEVEL} || '') eq 'unreadable') {
		print "Failure: No such entity\n";
		exit 1;
	}
	my ($volume) = sink_level($ARGV[1]);
	print "Volume: front-left: 32768 / $volume% / -0.00 dB,   front-right: 32768 / $volume% / -0.00 dB\n";
	exit 0;
}
if ($cmd eq 'get-sink-mute') {
	if ( ($ARGV[1] // '') eq 'jawn_system'
		&& ($ENV{FAKE_PACTL_MIX_LEVEL} || '') eq 'unreadable' ) {
		print "Failure: No such entity\n";
		exit 1;
	}
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

sub write_text {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or exit 9;
	print {$fh} $text;
	close $fh;
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
sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}
sub spew {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or exit 9;
	print {$fh} $text;
	close $fh;
}
# A restart can be told how many more to skip before the card's nodes are
# rebuilt, so a test can model one restart that did not rebuild the graph.
if (-e "$dir/rebuild_restarts") {
	my $left = slurp("$dir/rebuild_restarts");
	$left =~ s/\s+//g;
	if ($left =~ /\A\d+\z/) {
		if ($left > 0) {
			spew("$dir/rebuild_restarts", ($left - 1) . "\n");
		}
		else {
			spew("$dir/sinks", slurp("$dir/sinks_rebuilt"));
			spew("$dir/sources", slurp("$dir/sources_rebuilt"));
			unlink "$dir/rebuild_restarts";
		}
	}
}
exit 0;
SYSTEMCTL
chmod 0755, $systemctl or die "chmod $systemctl: $!";

local $ENV{PATH} = "$bin:$ENV{PATH}";
local $ENV{FAKE_PACTL_DIR} = $dir;
local $ENV{JAWNOS_SYSTEMCTL} = $systemctl;
# No test may look at the developer's real WirePlumber config: the no-state
# recovery inspects our rule there and would unlink it.
local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$dir/wireplumber";
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
	is((level_of('alsa_output.real'))[0], 40,
		'the live mix is the loudness the person hears, so that is what is handed back');
	is((level_of('alsa_output.real'))[1], 'no', 'and the unmuted state the mix carried');
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

# The order is the handover. A stream lands on the output when the default
# moves and again when the sink is unloaded; if the level is written after
# either, the person hears full scale until it catches up. The level first,
# the default second, the unload last.
{
	reset_mix();
	write_levels("alsa_output.real 100 no\n");
	my $out = tempdir(CLEANUP => 1);
	my $on = JawnOS::Audio::SystemMix::ensure($out, 'default');
	is($on->{ok}, 1, 'the mix is up for the handover test');

	# The person turns the tray down while the mix lives.
	write_levels("alsa_output.real 100 no\njawn_system 35 no\n");
	write_file("$dir/pactl.log", '');
	my $off = JawnOS::Audio::SystemMix::remove($out);
	is($off->{ok}, 1, 'the mix removes');

	my $log    = read_file("$dir/pactl.log");
	my $level  = index($log, 'set-sink-volume alsa_output.real 35%');
	my $switch = index($log, 'set-default-sink alsa_output.real');
	my $unload = index($log, 'unload-module 42');
	ok($level >= 0, 'the level is written to the output');
	ok($switch >= 0, 'and the default moves');
	ok($level < $switch, 'the level lands before the default moves');
	ok($switch < $unload, 'and the sink is unloaded last');
	write_levels('');
}

# The start is the same handover in reverse, and a restart is heard through
# it: the person's audio is playing on the hardware output when the new
# supervisor raises the sink. If that raise happens before the default moves,
# the stream is at full scale for however long the switch takes. The mix's
# level first, the default second, the output raised last.
{
	reset_mix();
	write_levels("alsa_output.real 35 no\n");
	my $out = tempdir(CLEANUP => 1);
	write_file("$dir/pactl.log", '');
	my $on = JawnOS::Audio::SystemMix::ensure($out, 'default');
	is($on->{ok}, 1, 'the mix comes up for the start-order test');

	my $log    = read_file("$dir/pactl.log");
	my $mix    = index($log, 'set-sink-volume jawn_system 35%');
	my $switch = index($log, 'set-default-sink jawn_system');
	my $unity  = index($log, 'set-sink-volume alsa_output.real 100%');
	ok($mix >= 0, "the mix takes the person's level");
	ok($switch >= 0, 'and the default moves onto it');
	ok($unity >= 0, 'and the output is raised for the engine');
	ok($mix < $switch, 'the mix level is written before a stream can land on it');
	ok($switch < $unity, 'the output is raised only after the default left it');
	is((level_of('alsa_output.real'))[0], 100, 'the engine plays through unity');
	write_levels('');
}

# A live mix the server will not report is not a reason to leave the output at
# unity: the level the mix was born with is the recorded fallback.
{
	reset_mix();
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/default", "jawn_system\n");
	write_levels("alsa_output.real 100 no\njawn_system 30 no\n");
	my $out = tempdir(CLEANUP => 1);
	write_file("$out/audio-system-mix.json",
		'{"sink":"jawn_system","source":"jawn_system.monitor",'
			. '"previous_default":"alsa_output.real","module_id":42,'
			. '"previous_level":{"volume":65,"mute":1}}');

	local $ENV{FAKE_PACTL_MIX_LEVEL} = 'unreadable';
	my $off = JawnOS::Audio::SystemMix::remove($out);
	is($off->{ok}, 1, 'the mix removes without a readable mix level');
	is((level_of('alsa_output.real'))[0], 65, 'the saved level is the fallback');
	is((level_of('alsa_output.real'))[1], 'yes', 'and its mute');
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

# --- a mix whose state file was wiped is still taken down -------------------
# The boot wipe removed audio-system-mix.json while jawn_system stayed the
# default with nothing capturing it. `manage=0` answered ok:1 and changed
# nothing. The server's own module listing is the record now.
{
	reset_mix();
	write_file("$dir/sinks", "0\tjawn_call_in\tmodule-null-sink\ts16le 2ch 48000Hz\n"
		. "1\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "2\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/default", "jawn_system\n");
	write_file("$dir/modules_short", "41\tmodule-null-sink\tsink_name=jawn_call_in\n"
		. "42\tmodule-null-sink\tsink_name=jawn_system\n");
	write_file("$dir/modules_long",
		"Module #41\n\tName: module-null-sink\n\tArgument: sink_name=jawn_call_in\n"
			. "Module #42\n\tName: module-null-sink\n\tArgument: sink_name=jawn_system\n");
	write_levels("alsa_output.real 100 no\njawn_system 45 yes\n");
	my $lost = tempdir(CLEANUP => 1);

	my $off = JawnOS::Audio::SystemMix::remove($lost);
	is($off->{ok}, 1, 'a mix with no state file is still removed');
	is($off->{recovered}, 1, 'and says it was found without its record');
	is($off->{restored}, 1, 'the default leaves the mix sink');
	is(read_file("$dir/default"), "alsa_output.real\n",
		'for the real output, not another null sink');
	is($off->{unloaded}, 1, 'the module is unloaded by the id the server lists');
	unlike(read_file("$dir/sinks"), qr/jawn_system/, 'and the sink is gone');
	is($off->{level_restored}, 1, 'the loudness carries over');
	is((level_of('alsa_output.real'))[0], 45, "the mix's own level, not the server default");
	is((level_of('alsa_output.real'))[1], 'no', 'and it is unmuted');
	like(read_file("$dir/pactl.log"), qr/unload-module 42/, 'the listed id is what is unloaded');
	write_levels('');
}

# An older tool answers only the long listing; its id works the same way.
{
	reset_mix();
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/default", "jawn_system\n");
	write_file("$dir/modules_long",
		"Module #7\n\tName: module-null-sink\n"
			. "\tArgument: sink_name=jawn_system sink_properties=device.description=System\n");
	my $lost = tempdir(CLEANUP => 1);

	my $off = JawnOS::Audio::SystemMix::remove($lost);
	is($off->{ok}, 1, 'the long module listing is enough to find the sink');
	like(read_file("$dir/pactl.log"), qr/unload-module 7/, 'and its id is used');
	is(read_file("$dir/default"), "alsa_output.real\n", 'the default is back on the real output');
}

# A mix that is not the default still has to go; the level lands on whatever
# output the machine is using.
{
	reset_mix();
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/default", "alsa_output.real\n");
	write_file("$dir/modules_short", "42\tmodule-null-sink\tsink_name=jawn_system\n");
	write_levels("alsa_output.real 100 no\njawn_system 30 no\n");
	my $lost = tempdir(CLEANUP => 1);

	my $off = JawnOS::Audio::SystemMix::remove($lost);
	is($off->{ok}, 1, 'a mix that is not the default is still unloaded');
	is($off->{restored}, 0, 'the default needs no moving');
	is(read_file("$dir/default"), "alsa_output.real\n", 'and stays where it is');
	is((level_of('alsa_output.real'))[0], 30, 'the level still lands on the real output');
	write_levels('');
}

# No sink and no record: the machine is already what it should be.
{
	reset_mix();
	my $nothing = tempdir(CLEANUP => 1);

	my $off = JawnOS::Audio::SystemMix::remove($nothing);
	is($off->{ok}, 1, 'no sink and no record is a quiet success');
	is($off->{skipped}, 1, 'it is skipped');
	ok(!exists $off->{recovered}, 'nothing was recovered');
	is(read_file("$dir/default"), "alsa_output.real\n", 'the default is untouched');
	unlike(read_file("$dir/pactl.log"), qr/unload-module/, 'and nothing is unloaded');
}

# --- the default switch is verified, not trusted ---------------------------
# The hardware run that found this: `pactl load-module` and
# `pactl set-default-sink` raced, ensure answered ok, and the next run found
# the built-in card still the default. The fake ignores the first switch, so a
# run that always succeeds can only pass by asking again.
sub reset_mix {
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	write_file("$dir/sources", '');
	write_file("$dir/default", "alsa_output.real\n");
	write_file("$dir/pactl.log", '');
	write_file("$dir/systemctl.log", '');
	write_file("$dir/levels", '');
	write_file("$dir/modules_short", '');
	write_file("$dir/modules_long", '');
	write_file("$dir/cards_long", '');
	unlink "$dir/set_count";
	unlink "$dir/card_nodes_rebuild";
	unlink "$dir/rebuild_restarts";
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

# --- the handover waits for an output a restart has not rebuilt yet ---------
# `systemctl --user restart wireplumber` returns before the card's nodes are in
# the server's listing. A removal that read the listing once would skip the
# level write, and the node would come back at the unity the engine held it at
# - the burst of full scale this module exists to prevent. The wait is bounded,
# so a card that never returns still ends the removal.
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0');
	is($on->{ok}, 1, 'the card mix comes up for the late-output handover');
	write_levels("alsa_output.real 100 no\njawn_system 35 no\n");

	# The output is out of the listing until the fourth read, as it is while
	# WirePlumber rebuilds the card.
	write_file("$dir/sinks", "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/sink_restore", "4\n");
	write_file("$dir/pactl.log", '');

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	unlink "$dir/sink_restore";

	is($off->{ok}, 1, 'the removal succeeds with a late output');
	is($off->{level_restored}, 1, 'and the level is written once the output is back');
	is((level_of('alsa_output.real'))[0], 35,
		'at the live mix level, not the unity the engine held');
	is((level_of('alsa_output.real'))[1], 'no', 'and unmuted');
	my $log    = read_file("$dir/pactl.log");
	my $level  = index($log, 'set-sink-volume alsa_output.real 35%');
	my $switch = index($log, 'set-default-sink alsa_output.real');
	my $unload = index($log, 'unload-module 42');
	ok($level >= 0, 'the level reaches the late output');
	ok($level < $switch, 'before the default moves to it');
	ok($switch < $unload, 'and the sink is unloaded after both');
	write_levels('');
}

# --- manage off rebuilds the card's nodes when one restart is not enough ----
# Found on `table`: after POST /manager/sound/manage manage=0 the stale rule was
# gone and WirePlumber had restarted, but the UM2's card stayed active on Pro
# Audio while `pactl list short sinks/sources` listed none of its nodes until a
# second restart by hand. The handback must force the rebuild itself and verify
# the names the rule recorded - without moving the default, which stays the
# output the mix replaced.
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	# A class-compliant interface: no mixer controls to hold, so this also
	# covers the card that answers amixer with nothing.
	local $ENV{JAWNOS_AUDIO_SKIP_CARD_MIXER} = 1;

	# The picker names `hw:1,0`, the USB interface. It is active on Pro Audio
	# and offers `off` as every ALSA card does.
	write_file("$dir/cards_long", <<'CARDS');
Card #1
	Name: alsa_card.usb-Burr-Brown_from_TI_USB_Audio_CODEC
	Properties:
		alsa.card = "1"
	Profiles:
		off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
		output:analog-stereo: Analog Stereo Output (sinks: 1, sources: 0, priority: 6500, available: yes)
		pro-audio: Pro Audio (sinks: 2, sources: 2, priority: 1, available: yes)
	Active Profile: pro-audio
CARDS

	# ensure maps the card while its node is listed; the previous default is
	# the PCH sink, which the handback must leave alone.
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "2\talsa_output.usb-card\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	write_file("$dir/sources", "1\talsa_input.usb-card\tmodule-alsa-card\ts16le 2ch 48000Hz\n");

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:1,0');
	is($on->{ok}, 1, 'the USB card is managed');
	is($on->{managed_card}{playback}, 'alsa_output.usb-card',
		'and its playback node is recorded');
	is(read_file("$dir/default"), "jawn_system\n", 'the mix is the default while managed');

	# The restart happened, but the card's graph was not rebuilt: Pro Audio is
	# still active and the short listings have none of its nodes.
	write_file("$dir/sinks_rebuilt", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "2\talsa_output.usb-card\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	write_file("$dir/sources_rebuilt", "1\talsa_input.usb-card\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/sources", '');
	write_file("$dir/card_nodes_rebuild", "1\n");
	my $restarts_before = restart_count();

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	is($off->{ok}, 1, 'manage off removes the rule and hands the card back');
	my $handback = $off->{managed_card}{handback};
	ok(ref $handback eq 'HASH', 'the removal reports a handback');
	is($handback->{verified}, 1, 'the card\'s nodes are verified back');
	is($handback->{profile_cycled}, 1, 'by cycling the profile the rule was written for');
	my $log = read_file("$dir/pactl.log");
	like($log, qr/set-card-profile alsa_card\.usb\S* off/, 'the card is switched off');
	like($log, qr/set-card-profile alsa_card\.usb\S* pro-audio/,
		'and back to Pro Audio, the profile it was on');
	is(restart_count(), $restarts_before + 1,
		'the profile cycle needed no extra WirePlumber restart');
	is(read_file("$dir/default"), "alsa_output.real\n",
		'and the default is the output the mix replaced, not the card');
}

# --- a card with no profile to cycle still gets one more restart ------------
# The fallback: the card is listed, so a restart can rebuild it, but it offers
# no `off` profile to cycle. The handback restarts WirePlumber once more and
# verifies the names rather than trusting the exit status.
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	local $ENV{JAWNOS_AUDIO_SKIP_CARD_MIXER} = 1;

	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "2\talsa_output.usb-card\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	write_file("$dir/sources", "1\talsa_input.usb-card\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:1,0');
	is($on->{ok}, 1, 'the card mix comes up for the restart fallback');

	# A card that is listed but offers no off profile.
	write_file("$dir/cards_long", <<'CARDS');
Card #1
	Name: alsa_card.usb-Burr-Brown_from_TI_USB_Audio_CODEC
	Properties:
		alsa.card = "1"
	Profiles:
		pro-audio: Pro Audio (sinks: 2, sources: 2, priority: 1, available: yes)
	Active Profile: pro-audio
CARDS

	write_file("$dir/sinks_rebuilt", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "2\talsa_output.usb-card\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	write_file("$dir/sources_rebuilt", "1\talsa_input.usb-card\tmodule-alsa-card\ts16le 2ch 48000Hz\n");
	write_file("$dir/sinks", "0\talsa_output.real\tmodule-alsa-card\ts16le 2ch 48000Hz\n"
		. "1\tjawn_system\tmodule-null-sink\ts16le 2ch 48000Hz\n");
	write_file("$dir/sources", '');
	# The removal restart does not rebuild; the handback's second one does.
	write_file("$dir/rebuild_restarts", "1\n");
	my $restarts_before = restart_count();

	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	my $handback = $off->{managed_card}{handback};
	is($off->{ok}, 1, 'the removal succeeds without a profile to cycle');
	is($handback->{restarts}, 1, 'it restarts WirePlumber once more');
	is($handback->{verified}, 1, 'and verifies the card\'s playback node is back');
	is(restart_count(), $restarts_before + 2,
		'that is the removal restart plus the handback retry');
	is(read_file("$dir/default"), "alsa_output.real\n", 'the previous output is the default');
}

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

# --- a card named by id resolves to today's number --------------------------
# The kernel numbers cards by USB enumeration, so the same interface can come
# back as a different card after a reboot. The picker saves the ALSA id; the
# rule needs the number, and this is the one place it is worked out.
{
	reset_mix();
	my $cards = "$dir/asound-card-ids";
	write_file($cards,
		" 0 [PCH            ]: HDA-Intel - HDA Intel PCH\n"
			. " 1 [CODEC          ]: USB-Audio - USB Audio CODEC\n");
	local $ENV{JAWNOS_ASOUND_CARDS} = $cards;

	is(JawnOS::Audio::SystemMix::_card_index('hw:PCH,0'), 0,
		'a card id resolves to the number it has today');
	is(JawnOS::Audio::SystemMix::_card_index('hw:CODEC,0'), 1,
		'and the interface that moved resolves to its new one');
	is(JawnOS::Audio::SystemMix::_card_index('alsa|hw:CODEC,0'), 1,
		'the picker spelling resolves the same way');
	is(JawnOS::Audio::SystemMix::_card_index('hw:1,0'), 1,
		'a number still passes through unchanged');
	is(JawnOS::Audio::SystemMix::_card_index('hw:NOPE,0'), undef,
		'an id the machine does not have resolves to nothing');

	my $map = JawnOS::Audio::SystemMix::card_nodes('hw:CODEC,0', 'playback');
	is($map->{ok}, 1, 'a card named by id maps its playback node');
	is($map->{card}, 1, 'through the number it has now');
	is($map->{playback}, 'alsa_output.usb-card', 'and names the right node');
}

# --- an ALSA card's own mixer is in the path, so it is held at unity -------
# The engine opens the card's PCM directly, so the PipeWire sink's volume is
# not applied to it; the card's mixer is. Without this the person's level is
# applied twice (a mix at 100% over a card at 30% is heard at 30%), and the
# node the engine hides gives them no way to move it.
{
	reset_mix();
	my $card_dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$card_dir/wireplumber";
	my $mixbin = "$dir/mixbin";
	make_path($mixbin);
	my $log = "$dir/amixer.log";
	write_file($log, '');
	write_file("$mixbin/amixer", <<'AMIXER');
#!/bin/sh
printf '%s\n' "$*" >> "$AMIXER_LOG"
control="$4"
case "$control" in
	Master) vol=30; sw=on ;;
	PCM) vol=65; sw=on ;;
	Headphone) vol=0; sw=off ;;
	*) exit 1 ;;
esac
if [ "$3" = "sget" ]; then
	printf "Simple mixer control '%s',0\n  Front Left: Playback %s [%s%%] [%s]\n" "$control" "$vol" "$vol" "$sw"
fi
exit 0
AMIXER
	chmod 0755, "$mixbin/amixer";
	local $ENV{PATH} = "$mixbin:$ENV{PATH}";
	local $ENV{AMIXER_LOG} = $log;

	my $on = JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0');
	is($on->{ok}, 1, 'a card mix comes up');
	my $written = read_file($log);
	like($written, qr/sset Master 100% unmute/, 'the card Master is held at unity');
	like($written, qr/sset PCM 100% unmute/, 'and its PCM too');
	unlike($written, qr/sset Speaker/,
		'a control the card does not have is left alone');
	unlike($written, qr/sset Headphone/,
		'an output the person had switched off is not unmuted');
	my $state = JSON::PP->new->decode(read_file("$card_dir/audio-system-mix.json"));
	is($state->{previous_mixer}{card}, 0, 'the card is recorded for removal');
	is($state->{previous_mixer}{controls}[0]{volume}, 30, 'with the level it had');
	is(scalar @{ $state->{previous_mixer}{controls} }, 2,
		'and only the controls that were on are recorded');

	# A repeat ensure holds unity again but must not overwrite the record.
	write_file($log, '');
	JawnOS::Audio::SystemMix::ensure($card_dir, 'hw:0,0');
	my $again = JSON::PP->new->decode(read_file("$card_dir/audio-system-mix.json"));
	is($again->{previous_mixer}{controls}[0]{volume}, 30,
		'a repeat ensure keeps the level the person had');
	like(read_file($log), qr/sset Master 100% unmute/, 'and holds unity again');

	write_file($log, '');
	my $off = JawnOS::Audio::SystemMix::remove($card_dir);
	is($off->{ok}, 1, 'the mix removes');
	like(read_file($log), qr/sset Master 30% unmute/,
		'and the card gets back the level it had');
	like(read_file($log), qr/sset PCM 65% unmute/, 'for every control it touched');
}

done_testing();
