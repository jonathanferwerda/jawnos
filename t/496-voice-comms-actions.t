# tests-for: perl/gb/03_engines_and_tools.pl perl/gb/10_voice_actions_comms.pl lib/JawnOS/Routes/voice_music_extra.pm lib/JawnOS/Controller/voice_music_extra.pm
# covers:    The communications actions voice was missing: mail send and search,
#           chat/sms send_text, the phone dial and the Music transport. Every
#           entry names a route the server dispatches (or the new music route
#           module), a kind and method that agree, an app-scoped help topic and
#           a speech sub; the key actions carry the exact parameters their
#           controllers read.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

require './perl/gb/03_engines_and_tools.pl';
my $base = scalar @gb::app_actions;
require './perl/gb/10_voice_actions_comms.pl';
require './perl/help.pl';
require 'JawnOS/Routes.pm';
require 'JawnOS/Routes/voice_music_extra.pm';

my %mine_key = map { $_ => 1 } qw(email/send email/search chat/send_text phone/dial music/transport);
my @mine = grep { $mine_key{ ($_->{'app'} // '') . '/' . ($_->{'do'} // '') } } @gb::app_actions;
ok(scalar @mine, 'the communications actions file declares entries');

# ------------------------------------------------------------ every entry
my %route = map { lc($_->[1]) . ' ' . $_->[2] => $_->[3] } @{ JawnOS::Routes->table };
foreach my $e ( 'JawnOS::Routes::voice_music_extra'->routes ) {
	$route{ lc($e->[1]) . ' ' . $e->[2] } = $e->[3];
}
my %topic_app = map { (help::get($_->{'id'})->{'app'} // '') => 1 } help::catalogue();
my %seen;
foreach my $a ( @mine ) {
	my $label = $a->{'app'} . ' ' . $a->{'do'};
	ok(!$seen{$label}++, $label . ' is declared once');
	ok(defined $a->{'desc'} && length $a->{'desc'}, $label . ' has a description');
	my $key = lc($a->{'method'} // '') . ' ' . ($a->{'route'} // '');
	ok($route{$key}, $label . ' names a real route');
	like($a->{'kind'} // '', qr/^(?:read|write)$/, $label . ' has a known kind');
	is(lc($a->{'method'} // ''), ($a->{'kind'} // '') eq 'read' ? 'get' : 'post',
		$label . ' uses the method its kind requires');
	ok($topic_app{ $a->{'app'} }, $label . ' names an app with a help topic');
	ok(ref $a->{'speech'} eq 'CODE', $label . ' can speak its result');
	like($a->{'confirm'} // '', qr/\S/, $label . ' carries a confirmation')
		if ($a->{'kind'} // '') eq 'write';
	is(ref $a->{'params'}, 'HASH', $label . ' declares a parameter map');
	foreach my $p ( sort keys %{ $a->{'params'} || {} } ) {
		like($p, qr/^[a-z][a-z0-9_]*$/, $label . ' parameter name is a plain key');
	}
	my $said = eval { $a->{'speech'}->({}, {}) };
	ok(defined $said && length $said, $label . ' speaks a sentence from an empty answer');
}

# ------------------------------------------------------------ the families
my %by;
$by{ $_->{'app'} . '/' . $_->{'do'} } = $_ for @mine;

sub entry_is {
	my ($key, $kind, $method, $path, $name) = @_;
	my $a = $by{$key};
	ok($a, $name . ' is declared') or return;
	is($a->{'kind'}, $kind, $name . ' is a ' . $kind);
	is(lc($a->{'method'}), $method, $name . ' uses ' . uc($method));
	is($a->{'route'}, $path, $name . ' names ' . $path);
	is(ref $a->{'params'}, 'HASH', $name . ' declares parameters');
	return $a;
}

# Email: send a letter, and search the letters by their words. The existing
# email/count entry keeps the list route, so the read here is the search route.
my $send = entry_is('email/send', 'write', 'post', '/manager/mail/email/send', 'email send');
for my $p ( qw(from to subject body cc bcc) ) {
	ok($send->{'params'}->{$p}, 'email send declares ' . $p);
}
# `from` defaults to the first active mailbox account, so a spoken letter
# need only name who it is to and what it says.
for my $r ( qw(to subject body) ) {
	ok($send->{'required'}->{$r}, 'email send requires ' . $r);
}
my $search = entry_is('email/search', 'read', 'get', '/manager/mail/email/search', 'email search');
is_deeply([ sort keys %{ $search->{'params'} } ], [ 'folder', 'q' ], 'email search declares q and folder');
ok($search->{'required'}->{'q'}, 'email search requires q');

# Chat owns the SMS road.
my $text = entry_is('chat/send_text', 'write', 'post', '/manager/sms/message', 'chat send_text');
is_deeply([ sort keys %{ $text->{'params'} } ], [ 'digits', 'message', 'person' ], 'sms declares digits, person and message');
ok($text->{'required'}->{'message'}, 'sms requires the message');
unlike(($text->{'required'}->{'digits'} // ''), qr/\S/, 'sms does not require digits when a person is named');

# Phone dials a number or a person whose number the house knows.
my $dial = entry_is('phone/dial', 'write', 'post', '/manager/phone/dial', 'phone dial');
is_deeply([ sort keys %{ $dial->{'params'} } ], [ 'number', 'person' ], 'phone dial declares number and person');
ok(!($dial->{'required'}->{'number'}), 'phone dial does not require a number when a person is named');
like(($dial->{'params'}->{'person'} // ''), qr/person/i, 'phone dial offers a person name');

# Music transport reaches the new route module.
my $music = entry_is('music/transport', 'write', 'post', '/manager/music/transport', 'music transport');
is_deeply([ sort keys %{ $music->{'params'} } ], [ 'action' ], 'music transport declares action');
ok($music->{'required'}->{'action'}, 'music transport requires the action');

require 'JawnOS/Controller/voice_music_extra.pm';
ok(defined &main::Manager::action_99710, 'the music transport route has a handler');

# ------------------------------------------------------------ speech shapes
is($send->{'speech'}->('success'), 'The letter was sent.', 'email send speaks success');
like($send->{'speech'}->('no server'), qr/could not send.*no server/,
	'email send speaks a refusal');

like($search->{'speech'}->({ count => 3 }, { q => 'invoice' }), qr/3 matching letters/,
	'email search counts the matches');
like($search->{'speech'}->({ count => 1 }, { q => 'invoice' }), qr/1 matching letter\b/,
	'email search counts one match');
like($search->{'speech'}->({ count => 0 }, { q => 'zzz' }), qr/No letters match "zzz"/,
	'email search says nothing matched');

like($text->{'speech'}->('relay', { digits => '5551234' }), qr/sent a text to 5551234/,
	'sms send names the number');
like($text->{'speech'}->('none', { digits => '5551234' }), qr/could not send/,
	'sms send reports a failure');

like($dial->{'speech'}->({ ok => 1, number => '5551234' }), qr/Calling 5551234/,
	'phone dial names the number');

like($music->{'speech'}->({ action => 'pause' }), qr/Paused/, 'music transport speaks pause');
like($music->{'speech'}->({ action => 'prev' }), qr/back a track/, 'music transport speaks previous');

done_testing();
