package subs;

# Audio: the saved house plan and the mixer's master switch.
#
# The plan is one JSON setting on the house row, not a table: it is the
# document `JawnOS::Audio::Plan` normalises and the engine compiles
# (docs/studio-audio-roadmap.md §8). This module is the seam between that data
# and the two things that act on it - the Sound page, which reads and writes it,
# and the engine's control socket, which applies it.
#
# Why a setting and not a table: Power's plan and the house's other policies
# already live this way, and a plan has no rows to query. The value is one
# document, saved whole; a partial merge would be a second model to test.
#
# Two rules that keep it honest:
#
# * **A save never fails because the engine is down.** The plan is durable
#   before the engine is asked anything. A machine with no engine, or one whose
#   binary was not built, still saves the house's intent and reports the reason
#   it is not applied. That is D11's graceful fallback, applied to the write.
# * **The switch is the only way to take the mixer.** `audio_plan_write` applies
#   only while `audio_manage` is on. Turning it off hands the machine back to
#   PipeWire and leaves the plan on disk for the day it is turned on again.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json encode_json);

# One key for the house's plan and one for the switch. `device => 'all'` is the
# house row: every machine reads the same plan, which is the point of a central
# mixer. The Sound page's per-device volume rows stay per-device.
our $audio_plan_setting = 'audio_plan';
our $audio_manage_setting = 'audio_manage';

sub audio_plan_read {
	require JawnOS::Audio::Plan;
	my $raw = &subs::setting_grabber({
		app    => 'sound',
		setting => $audio_plan_setting,
		device => 'all',
	});
	my $decoded = (defined $raw && length $raw) ? eval { decode_json($raw) } : undef;
	return JawnOS::Audio::Plan::audio_plan_normalize($decoded);
}

sub audio_manage_read {
	my $raw = &subs::setting_grabber({
		app    => 'sound',
		setting => $audio_manage_setting,
		device => 'all',
	});
	return (defined $raw && $raw =~ /^(?:1|on|true|yes)$/i) ? 1 : 0;
}

# The plan's shape, the switch, and what the engine on this machine says. The
# engine is optional: `engine_available` is false on a machine that has none,
# and the page says so rather than drawing a switch that does nothing.
sub audio_plan_status {
	require JawnOS::Audio::Engine;
	require JawnOS::Audio::Plan;
	require Sys::Hostname;
	my $plan = &audio_plan_read();
	my %latency;
	foreach my $sink (@{ $plan->{sinks} || [] }) {
		$latency{ $sink->{id} } = JawnOS::Audio::Plan::audio_plan_latency($plan, $sink->{id});
	}
	my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
	my $engine = $available
		? eval { JawnOS::Audio::Engine::audio_engine_status() }
		: undef;
	return {
		plan             => $plan,
		latency          => \%latency,
		manage           => &audio_manage_read(),
		engine_available => $available,
		engine           => $engine,
		machine          => (eval { Sys::Hostname::hostname() } || ''),
	};
}

# Save one plan. The write path refuses a wrong shape instead of repairing it:
# a dangling route or a gain of 5 is a mistake, and the read path already
# repairs an older plan, so the two never disagree about what is stored.
sub audio_plan_write {
	my ($plan) = @_;
	require JawnOS::Audio::Plan;
	return { ok => 0, error => 'a plan is one object with sources, buses, sinks and routes' }
		unless ref $plan eq 'HASH';
	return { ok => 0, error => 'the plan is not valid: check every route names a declared node and every gain and pan is in range' }
		unless JawnOS::Audio::Plan::audio_plan_valid($plan);

	my $clean = JawnOS::Audio::Plan::audio_plan_normalize($plan);
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_plan_setting,
		device  => 'all',
		value   => encode_json($clean),
	});
	&_audio_plan_boot_write(&audio_manage_read(), $clean);

	# Saving is durable whether or not the engine is up; applying is the second
	# answer, and it is reported rather than allowed to undo the save.
	my $applied;
	$applied = &audio_plan_apply($clean) if &audio_manage_read();
	return { ok => 1, plan => $clean, applied => $applied };
}

# Ask this machine's engine to run the saved plan. A caller may pass the plan
# it just saved so the engine is not asked to re-read a setting in the same
# request; with no argument the stored plan is read.
sub audio_plan_apply {
	my ($plan) = @_;
	require JawnOS::Audio::Engine;
	my $clean = ref $plan eq 'HASH' ? $plan : &audio_plan_read();
	return { ok => 0, skipped => 1, error => 'the house mixer is not managed on this machine' }
		unless &audio_manage_read();
	return JawnOS::Audio::Engine::audio_engine_patch($clean);
}

# The engine's startup copy, written beside the socket the supervisor reads:
# `{"manage":0|1,"plan":{...}}`. The setting on the house row is the source of
# truth; this file exists only so a fresh engine can arm the saved plan without
# a running manager to ask. It is written atomically - a temp file renamed over
# the target - so a crash mid-write cannot leave a torn JSON object for the next
# boot, and the directory is made if the install has never run the engine.
sub _audio_plan_boot_write {
	my ($manage, $plan) = @_;
	require JawnOS::Audio::Engine;
	require File::Basename;
	require File::Path;

	my $path = JawnOS::Audio::Engine::audio_engine_plan_path();
	return { ok => 0, error => 'the plan boot file has no path' }
		unless defined $path && length $path;

	my $dir = File::Basename::dirname($path);
	eval { File::Path::make_path($dir) };

	my $json = encode_json({ manage => $manage ? 1 : 0, plan => $plan });
	my $tmp  = "$path.tmp.$$";
	my $wrote = eval {
		open my $fh, '>', $tmp or die "open: $!";
		print {$fh} $json or die "write: $!";
		close $fh or die "close: $!";
		rename $tmp, $path or die "rename: $!";
		1;
	};
	unless ($wrote) {
		my $error = $@ || 'unknown error';
		unlink $tmp;
		return { ok => 0, error => "the plan boot file could not be written: $error" };
	}
	return { ok => 1, path => $path };
}

# The master switch. On applies the saved plan now; off stops the engine's
# patch and hands the outputs back. The plan itself is never removed.
sub audio_manage_set {
	my ($on) = @_;
	my $want = $on ? 1 : 0;
	&subs::setting_setter({
		app     => 'sound',
		setting => $audio_manage_setting,
		device  => 'all',
		value   => $want ? '1' : '0',
	});
	&_audio_plan_boot_write($want, &audio_plan_read());

	require JawnOS::Audio::Engine;
	my $answer;
	if ($want) {
		$answer = &audio_plan_apply();
	}
	else {
		my $available = eval { JawnOS::Audio::Engine::audio_engine_available() } ? 1 : 0;
		$answer = $available
			? JawnOS::Audio::Engine::audio_engine_unpatch()
			: { ok => 1, skipped => 1, error => '' };
	}
	return { ok => 1, manage => $want, applied => $answer };
}

1;
