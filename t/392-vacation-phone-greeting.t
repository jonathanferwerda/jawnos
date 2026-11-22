# tests-for: lib/JawnOS/Domain/Phone.pm perl/Reception.pl lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Manager/Part12.pm templates/apps/phone.html.ep public/js/manager/phone.js
# covers:    the away greeting the IVR pane configures: while an away period is
#            active every flow the reception answers speaks the away words (or
#            plays the house's recorded clip) and offers a message, the stored
#            flows are untouched, and Ring/Reject still pass; a proposal never
#            speaks it.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JSON::PP qw(encode_json);
use JawnOSTest;
use RepoSource;

my $now = &subs::rightNow();
my $away_words = 'We are away. Please leave a message after the tone.';

sub set_vacation {
	my ($from, $to, $state) = @_;
	my $json = encode_json({
		version => 1,
		periods => [ {
			uuid => 'away-phone', from => $from,
			(defined $to ? (to => $to) : ()),
			state => $state || 'active', kind => 'vacation',
		} ],
		policy => {},
		auto => { detect => 0, after_hours => 24 },
	});
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'vacation', 'all');
	&subs::db_query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
		'vacation', $json, '__president', 'all', 'vacation-phone', $now);
	&subs::vacation_forget();
}

sub clear_vacation {
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'vacation', 'all');
	&subs::vacation_forget();
}

sub set_phone {
	my ($setting, $value) = @_;
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?', 'phone', $setting, 'all');
	&subs::db_query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
		$setting, $value, 'phone', 'all', 'phone-' . $setting, $now);
}

sub clear_phone {
	&subs::db_query('delete from settings where app = ? and device = ?', 'phone', 'all');
}

sub flow_greeting {
	my ($settings, $key) = @_;
	return $settings->{'flow_defs'}->{$key}->{'greeting'} // '';
}

# --- the overlay ------------------------------------------------------------
clear_phone();
set_phone('ivr_enabled', 'yes');
set_phone('ivr_away', 'yes');
set_phone('ivr_away_greeting', $away_words);
set_vacation($now - 86400000, $now + 86400000);

my $settings = &subs::phone_ivr_settings();
is($settings->{'away'}, 'yes', 'the pane reads its away switch from the house row');
is($settings->{'away_greeting'}, $away_words, 'and the away words it saved');
ok(&subs::phone_ivr_away_ready($settings), 'the away greeting is ready while the period is active');
is(flow_greeting($settings, 'receptionist'), &subs::phone_ivr_defaults()->{'greeting'},
	'the canonical settings keep the flow\'s own greeting');

my $broadcast = &subs::phone_ivr_broadcast_settings();
is($broadcast->{'away_active'}, 1, 'the broadcast copy says the away period is active');
is(flow_greeting($broadcast, 'receptionist'), $away_words,
	'the receptionist speaks the away words');
is(flow_greeting($broadcast, 'voicemail'), $away_words,
	'every flow the reception can answer speaks them, not only the receptionist');
is_deeply($broadcast->{'flow_defs'}->{'receptionist'}->{'steps'},
	[ { type => 'say', text_key => 'greeting' }, { type => 'voicemail' } ],
	'the away flow offers a message after the greeting');
is($broadcast->{'flow_defs'}->{'receptionist'}->{'after'}, 'voicemail',
	'and its After choice is the message');
is(flow_greeting(&subs::phone_ivr_settings(), 'receptionist'), &subs::phone_ivr_defaults()->{'greeting'},
	'the stored flow was not edited by the overlay');

# --- off, inactive, proposed -------------------------------------------------
set_phone('ivr_away', 'no');
my $off = &subs::phone_ivr_broadcast_settings();
ok(!$off->{'away_active'}, 'the switch off means no away overlay');
is(flow_greeting($off, 'receptionist'), &subs::phone_ivr_defaults()->{'greeting'},
	'the ordinary greeting is untouched');

set_phone('ivr_away', 'yes');
set_vacation($now - 30 * 86400000, $now - 29 * 86400000);
my $past = &subs::phone_ivr_broadcast_settings();
ok(!$past->{'away_active'}, 'a finished period does not greet anyone away');

set_vacation($now - 86400000, $now + 86400000, 'proposed');
my $proposed = &subs::phone_ivr_broadcast_settings();
ok(!$proposed->{'away_active'}, 'a proposal is a question, not an away period');
is(flow_greeting($proposed, 'receptionist'), &subs::phone_ivr_defaults()->{'greeting'},
	'a proposal leaves the ordinary greeting in place');

clear_vacation();
set_vacation($now - 86400000, undef);
my $open = &subs::phone_ivr_broadcast_settings();
is(flow_greeting($open, 'receptionist'), $away_words, 'an open period greets the same way');

# --- a recorded away greeting wins ------------------------------------------
clear_phone();
set_phone('ivr_enabled', 'yes');
set_phone('ivr_away', 'yes');
set_phone('ivr_away_greeting', $away_words);
set_phone('ivr_away_greeting_file', '/tmp/away-greeting.wav');
clear_vacation();
set_vacation($now - 86400000, $now + 86400000);

my $recorded = &subs::phone_ivr_settings();
is($recorded->{'away_greeting_file'}, '/tmp/away-greeting.wav',
	'the pane reads the recorded away greeting from the house row');
is(flow_greeting(&subs::phone_ivr_settings(), 'receptionist'), &subs::phone_ivr_defaults()->{'greeting'},
	'and the stored flow is still untouched');

my $recorded_broadcast = &subs::phone_ivr_broadcast_settings();
is($recorded_broadcast->{'flow_defs'}->{'receptionist'}->{'voicemail_greeting'},
	'/tmp/away-greeting.wav', 'the away flow plays the recorded clip');
is_deeply($recorded_broadcast->{'flow_defs'}->{'receptionist'}->{'steps'},
	[ { type => 'voicemail' } ], 'the away plan is one voicemail step');
is($recorded_broadcast->{'flow_defs'}->{'receptionist'}->{'after'}, 'voicemail',
	'and records a message after it');
is($recorded_broadcast->{'flow_defs'}->{'receptionist'}->{'voicemail'}, $away_words,
	'and the typed away words are the fallback if the clip has moved');
is(flow_greeting($recorded_broadcast, 'receptionist'), &subs::phone_ivr_defaults()->{'greeting'},
	'the typed away words are not spoken when a recording is set');

# the recording alone is enough, even with the words cleared
set_phone('ivr_away_greeting', '');
my $file_only = &subs::phone_ivr_broadcast_settings();
ok($file_only->{'away_active'}, 'a recorded greeting answers without typed words');
is($file_only->{'flow_defs'}->{'receptionist'}->{'voicemail_greeting'}, '/tmp/away-greeting.wav',
	'and still plays the recording');

# without the file the typed plan is back
clear_phone();
set_phone('ivr_enabled', 'yes');
set_phone('ivr_away', 'yes');
set_phone('ivr_away_greeting', $away_words);
set_vacation($now - 86400000, $now + 86400000);
my $typed = &subs::phone_ivr_broadcast_settings();
is_deeply($typed->{'flow_defs'}->{'receptionist'}->{'steps'},
	[ { type => 'say', text_key => 'greeting' }, { type => 'voicemail' } ],
	'with no recording the away plan still speaks the typed words first');
ok(!defined $typed->{'flow_defs'}->{'receptionist'}->{'voicemail_greeting'}
	|| !length $typed->{'flow_defs'}->{'receptionist'}->{'voicemail_greeting'},
	'and names no recorded greeting');

# --- the wiring -------------------------------------------------------------
my $root = repo_root();
like(read_file("$root/perl/Reception.pl"), qr/phone_ivr_broadcast_settings/,
	'the gateway is armed from the away-aware copy');
like(read_file("$root/lib/JawnOS/Controller/manager_phone.pm"), qr/phone_ivr_broadcast_settings/,
	'the phone sync carries the away-aware copy');
like(read_file("$root/lib/JawnOS/Manager/Part12.pm"), qr/away_greeting/,
	'the IVR save knows the away greeting');
like(read_file("$root/templates/apps/phone.html.ep"), qr/id="phone_ivr_away"/,
	'the pane offers the away switch');
like(read_file("$root/templates/apps/phone.html.ep"), qr/id="phone_ivr_away_greeting"/,
	'the pane offers the away words');
like(read_file("$root/public/js/manager/phone.js"), qr/away_greeting:/,
	'the pane saves the away words');
like(read_file("$root/lib/JawnOS/Controller/manager_phone.pm"), qr/ivr_away_greeting_file/,
	'the greeting route stores the recorded away greeting house-wide');
like(read_file("$root/lib/JawnOS/Controller/manager_phone.pm"), qr/away eq 'clear'/,
	'and clears it on request');
like(read_file("$root/lib/JawnOS/Domain/Phone.pm"), qr/away_greeting_file/,
	'the domain knows the recorded away greeting');
like(read_file("$root/templates/apps/phone.html.ep"), qr/id="phone_ivr_away_record"/,
	'the away block offers Record');
like(read_file("$root/templates/apps/phone.html.ep"), qr/id="phone_ivr_away_play"/,
	'and Play');
like(read_file("$root/templates/apps/phone.html.ep"), qr/id="phone_ivr_away_remove"/,
	'and Remove');
like(read_file("$root/public/js/manager/phone.js"), qr/phone_ivr_away_record/,
	'the pane wires the away recorder');
like(read_file("$root/public/js/manager/phone.js"), qr/away=1/,
	'the away recording uploads as the away greeting');

done_testing();
