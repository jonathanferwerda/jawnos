package gb;
use strict;
use warnings;

# Communications actions voice was missing - mail, chat/sms, the phone and the
# Music transport. Same shape as perl/gb/03_engines_and_tools.pl: an app whose
# help topic names it, a "do" the model may pick, a real route that answers
# JSON, the exact parameters that route reads, and a speech sub that reads only
# that JSON. A write carries a confirm, because the bridge proposes it before
# anything runs.
#
# Every route below returns JSON today. The phone and SMS routes take a bare
# number or a person's name (the controller resolves a known contact); the Music
# transport route lives in lib/JawnOS/Routes/voice_music_extra.pm, listed in
# JawnOS::Routes' @NAMES.

push @gb::app_actions, (

	# ---- Email ------------------------------------------------------------
	{
		app => 'email', do => 'send', kind => 'write',
		method => 'post', route => '/manager/mail/email/send',
		params => {
			from => 'the sending account\'s uuid from the mailbox email settings; defaults to the first active account',
			to => 'the recipient\'s email address (required)',
			subject => 'the subject line (required)',
			body => 'the letter itself (required)',
			cc => 'carbon-copy addresses, optional',
			bcc => 'blind carbon-copy addresses, optional',
			attachments => 'a JSON list of attachments, optional',
			magic_vars => 'the compose context for spoken text, optional',
			in_reply_to_uuid => 'the uuid of the letter this answers, optional',
			uuid => 'the draft uuid when sending a saved draft, optional',
			timestamp => 'the letter\'s time, optional',
			sender => 'the sending device, optional',
		},
		required => {
			to => 'the recipient',
			subject => 'the subject',
			body => 'the letter',
		},
		confirm => 'I can send that letter. Confirm it and I will.',
		desc => 'send an email letter now',
		speech => sub {
			my $raw = $_[0];
			my $r = ref $raw eq 'HASH' ? ($raw->{'result'} // '') : (defined $raw && !ref $raw ? "$raw" : '');
			return 'The letter was sent.' if $r eq 'success';
			return 'I could not send the letter' . ($r ne '' ? ': ' . $r . '.' : '.');
		},
	},
	{
		app => 'email', do => 'search', kind => 'read',
		method => 'get', route => '/manager/mail/email/search',
		params => {
			q => 'the words to look for in the subject, body, sender and copies (required)',
			folder => 'one folder to search instead of everything, optional',
		},
		required => { q => 'what to search for' },
		desc => 'find letters by their words',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			my $n = 0 + ($d->{'count'} // 0);
			my $q = ($p->{'q'} // '') ne '' ? $p->{'q'} : '';
			return 'I found ' . $n . ' matching letter' . ($n == 1 ? '' : 's') . '.'
				if $n;
			return 'No letters match' . ($q ne '' ? ' "' . $q . '"' : ' that') . '.';
		},
	},

	# ---- Chat / SMS -------------------------------------------------------
	# The SMS road belongs to the Chat app's help topic (app => 'chat').
	{
		app => 'chat', do => 'send_text', kind => 'write',
		method => 'post', route => '/manager/sms/message',
		params => {
			digits => 'the phone number to text; leave it out when the person is named in "person"',
			person => 'the person to text, when the house knows their number',
			message => 'the words to send (required)',
		},
		required => { message => 'the words' },
		confirm => 'I can send that text. Confirm it and I will.',
		desc => 'send a text message (SMS) to a phone',
		speech => sub {
			my ($d, $p) = @_;
			$p = {} unless ref $p eq 'HASH';
			my $via = ref $d ? '' : (defined $d ? "$d" : '');
			my $who = ($p->{'person'} // '') ne ''
				? $p->{'person'}
				: (($p->{'digits'} // '') ne '' ? $p->{'digits'} : 'that number');
			return 'I could not send the text.' if $via eq 'none';
			return 'I sent a text to ' . $who . '.';
		},
	},

	# ---- Phone ------------------------------------------------------------
	# The route dials a bare number or a person's name the controller resolves.
	{
		app => 'phone', do => 'dial', kind => 'write',
		method => 'post', route => '/manager/phone/dial',
		params => {
			number => 'the phone number to call, digits, # and * only; leave it out when the person is named in "person"',
			person => 'the person to call, when the house knows their number',
		},
		required => {},
		confirm => 'I can place that call. Confirm it and I will.',
		desc => 'place a phone call to a number',
		speech => sub {
			my $d = ref $_[0] eq 'HASH' ? $_[0] : {};
			my $p = ref $_[1] eq 'HASH' ? $_[1] : {};
			my $num = ($d->{'number'} // '') ne '' ? $d->{'number'} : 'that number';
			my $who = ($p->{'person'} // '') ne '' ? $p->{'person'} : $num;
			return 'Calling ' . $who . '.';
		},
	},

	# ---- Music transport --------------------------------------------------
	# The player's transport lives in the browser (musicTransportLocal); the
	# new route speaks that console command over the websocket.
	{
		app => 'music', do => 'transport', kind => 'write',
		method => 'post', route => '/manager/music/transport',
		params => {
			action => 'play, pause, next, previous or stop (required)',
		},
		required => { action => 'what the player should do' },
		confirm => 'I can control the music. Confirm it and I will.',
		desc => 'play, pause, skip or stop the music player',
		speech => sub {
			my ($d, $p) = @_;
			$p = {} unless ref $p eq 'HASH';
			my $a = (ref $d eq 'HASH' && ($d->{'action'} // '') ne '')
				? $d->{'action'}
				: (($p->{'action'} // '') ne '' ? $p->{'action'} : 'play');
			my %word = (
				play => 'Playing',
				pause => 'Paused',
				next => 'Skipping to the next track',
				prev => 'Going back a track',
				stop => 'Stopped',
			);
			return ($word{$a} || 'Sent that to the player') . '.';
		},
	},
);

1;
