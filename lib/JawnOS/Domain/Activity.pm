package subs;

# Activity: which screen the person is physically at.
#
# Every Manager page stamps its own device uuid into the synced settings when it
# sees a mouse move, a key, a tap, the wheel or a real movement of a phone or
# tablet, at most once every twenty seconds. The stamp is one row per device, so
# whichever machine serves a voice turn can put the answer on the screen the
# person last touched. The card itself is a console command; this module only
# decides the machine and sends it.

use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

our $ACTIVITY_THROTTLE = 20000;

sub activity_touch($device, $at = undef) {
	$device = '' unless defined $device;
	$device =~ s/^\s+|\s+$//g;
	return 0 unless length $device && $device =~ /^[A-Za-z0-9_.:-]{1,200}$/;
	$at = &rightNow() unless defined $at;
	$at = 0 + $at;
	my $old = eval { &setting_grabber({ app => '__president', setting => 'last_active', device => $device }) } || 0;
	# A page in use all morning must not write a synced row on every movement;
	# the stamp only needs to be newer than every other machine's.
	return 0 + $old if $old && $at - $old < $ACTIVITY_THROTTLE;
	eval { &setting_setter({ app => '__president', setting => 'last_active', device => $device, value => $at }) };
	return $at;
}

sub activity_recent($limit = 20) {
	my $rows = eval {
		&db_select('settings', [ 'device', 'value' ], { app => '__president', setting => 'last_active' })->hashes;
	} || [];
	my @out = sort { (0 + ($b->{'value'} // 0)) <=> (0 + ($a->{'value'} // 0)) }
		grep {
			defined $_->{'device'} && length $_->{'device'}
				&& defined $_->{'value'} && "$_->{'value'}" =~ /^\d+$/
		} @{$rows};
	splice @out, $limit if $limit && @out > $limit;
	return \@out;
}

sub activity_most_recent($exclude = '') {
	$exclude = '' unless defined $exclude;
	foreach my $row ( @{ &activity_recent(50) } ) {
		my $device = $row->{'device'} // '';
		next if length $exclude && $device eq $exclude;
		return $device;
	}
	return '';
}

# The card: the question and the answer, sent to every page; the page whose
# device uuid matches draws it. A voice turn calls this after the reply is
# chosen, so the wrist's answer is visible on the screen in front of the person.
sub voice_card_show($question, $reply, $opts = {}) {
	$opts ||= {};
	return 0 unless defined $question && length $question && defined $reply && length $reply;
	my $target = &activity_most_recent($opts->{'exclude_device'} // '');
	my $js = &Websocket::console_command('voiceCard', {
		device_uuid => $target,
		question => $question,
		reply => $reply,
		at => &rightNow(),
	});
	&Websocket::send('server', { console => $js });
	return 1;
}

1;
