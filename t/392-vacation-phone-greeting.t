# tests-for: lib/JawnOS/Domain/Phone.pm perl/Reception.pl lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Manager/Part12.pm templates/apps/phone.html.ep public/js/manager/phone.js
# covers:    the away greeting the IVR pane configures: while an away period is
#            active every flow the reception answers speaks the away words and
#            offers a message, the stored flows are untouched, and Ring/Reject
#            still pass; a proposal never speaks it.

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

done_testing();
