# tests-for: lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Routes/manager_phone.pm lib/JawnOS/Manager/Part12.pm lib/JawnOS/Domain/Phone.pm templates/apps/phone.html.ep public/js/manager/phone.js public/js/manager/manager/02_web_nfc.js perl/help/topics_web.pl
# covers:    The IVR pane's settings and named flows, the remote-machine list, the sync blob, and the recent-call dialer icon.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Template;
use Cwd qw(realpath);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use RepoSource;
use JawnOSTest;

require(root() . '/lib/JawnOS/Manager/Part12.pm');

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

my $gateway = {
	signatorial => 'gw-sig', hostname => 'gateway', ip => '10.0.0.5',
	connection => 'active', device => 'computer',
	manager => 'https://gateway:45545/manager', server_time => '100',
};
my $sleepy = {
	signatorial => '', hostname => '', ip => '10.0.0.9',
	connection => 'inactive', device => 'computer',
	manager => '', server_time => '90',
};

# ---------------------------------------------------------------- defaults
my $defaults = Manager::phone_ivr_defaults();
is $defaults->{'enabled'}, 'no', 'IVR starts off';
is $defaults->{'route'}, 'unknown', 'strangers are the default route';
is $defaults->{'voice'}, &subs::say_default_voice(), 'the default voice is the house default';
is $defaults->{'bluetooth'}, 'jawn-gateway', 'the gateway adapter has a Bluetooth name';
like $defaults->{'prompt'}, qr/name/i, 'the default name prompt asks for a name';
ok length($defaults->{'greeting'}) && length($defaults->{'voicemail'}) && length($defaults->{'thanks'}),
	'the greeting, voicemail prompt and thanks have defaults';
is_deeply [ sort keys %{ $defaults->{'flows'} } ],
	[ qw(blacklisted enemy friend self stranger unknown) ],
	'the flow matrix has the six buckets';
is $defaults->{'flows'}->{'unknown'}, 'ivr', 'an unknown caller goes to IVR by default';
is $defaults->{'flows'}->{'friend'}, 'ring', 'a friend rings by default';
is $defaults->{'flows'}->{'enemy'}, 'reject', 'an enemy is rejected by default';

# ---------------------------------------------------------------- seeded flows
{
	local *subs::setting_grabber = sub { return undef };
	my $defs = &subs::phone_ivr_flow_defs();
	is_deeply [ sort keys %{$defs} ], [ qw(receptionist voicemail) ],
		'two flows are seeded so an existing house keeps behaving as it does now';
	is $defs->{'receptionist'}->{'name'}, 'Receptionist', 'the receptionist is named';
	is $defs->{'receptionist'}->{'builtin'}, 1, 'the receptionist is built in';
	is $defs->{'receptionist'}->{'after'}, 'hold', 'the receptionist plays hold music after the thanks';
	like $defs->{'receptionist'}->{'prompt'}, qr/name/i, 'the receptionist asks for a name';
	is $defs->{'voicemail'}->{'name'}, 'Voicemail', 'the voicemail flow is named';
	is $defs->{'voicemail'}->{'builtin'}, 1, 'the voicemail flow is built in';
	is $defs->{'voicemail'}->{'after'}, 'end', 'the voicemail flow ends after its message';
	is_deeply $defs->{'voicemail'}->{'steps'}, [ { type => 'voicemail' } ],
		'the voicemail flow takes a message instead of speaking the legacy order';
	like $defs->{'voicemail'}->{'voicemail'}, qr/message/i, 'the voicemail flow leaves a message';
	is $defs->{'receptionist'}->{'voice'}, &subs::say_default_voice(), 'the seed speaks in the house voice';
	is $defs->{'receptionist'}->{'voicemail_greeting'}, '', 'a flow starts on its spoken greeting';
}
{
	# a house that never opened the flow editor keeps its own legacy words
	local *subs::setting_grabber = sub {
		my $request = shift;
		return 'Howdy' if $request->{'setting'} eq 'ivr_greeting';
		return 'piper-john' if $request->{'setting'} eq 'ivr_voice';
		return undef;
	};
	my $defs = &subs::phone_ivr_flow_defs();
	is $defs->{'receptionist'}->{'greeting'}, 'Howdy', 'the receptionist speaks the legacy greeting';
	is $defs->{'receptionist'}->{'voice'}, 'piper-john', 'and the legacy voice';
	is $defs->{'receptionist'}->{'after'}, 'hold', 'and keeps the receptionist after step';
}

# ---------------------------------------------------------------- reading
{
	my %stored = (
		ivr_enabled => 'yes', ivr_machine => 'gw-sig', ivr_route => 'all',
		ivr_voice => 'piper-john', ivr_greeting => 'Hi there',
		ivr_prompt => 'Who is this?', ivr_voicemail => 'Leave a message',
		ivr_thanks => 'Thanks',
		ivr_flows => '{"unknown":"ring","friend":"ivr"}',
	);
	local *subs::setting_grabber = sub {
		my $request = shift;
		return $stored{ $request->{'setting'} };
	};
	my $settings = Manager::phone_ivr_settings();
	is $settings->{'enabled'}, 'yes', 'an enabled setting is read back';
	is $settings->{'route'}, 'all', 'the routing choice is read back';
	is $settings->{'voice'}, 'piper-john', 'the chosen voice is read back';
	is $settings->{'prompt'}, 'Who is this?', 'the prompt is read back';
	is $settings->{'machine'}, 'gw-sig', 'the gateway is read back';
	is $settings->{'thanks'}, 'Thanks', 'the thanks prompt is read back';
	is $settings->{'flows'}->{'unknown'}, 'ring', 'a saved flow is read back';
	is $settings->{'flows'}->{'friend'}, 'ivr', 'a saved relationship flow is read back';
	is $settings->{'flows'}->{'stranger'}, 'ivr', 'a missing flow falls back to the route';
	is ref($settings->{'flow_defs'}), 'HASH', 'the settings carry the named flows';
}
{
	local *subs::setting_grabber = sub {
		my $request = shift;
		return 'bogus' if $request->{'setting'} =~ /route|voice/;
		return undef;
	};
	my $settings = Manager::phone_ivr_settings();
	is $settings->{'route'}, 'unknown', 'an unknown route falls back to strangers';
	is $settings->{'voice'}, &subs::say_default_voice(), 'an unknown voice falls back to the default';
}

# ---------------------------------------------------------------- a custom flow
{
	my %stored = (
		ivr_route => 'unknown',
		ivr_flow_defs => encode_json({
			receptionist => {
				name => 'Front desk', voice => 'piper-john',
				greeting => 'Hi', prompt => 'Name?', voicemail => 'Leave it',
				thanks => 'Thanks', hold => 'shuffle', after => 'hold',
			},
			voicemail => { name => 'Voicemail', voicemail => 'Leave a message', after => 'end' },
			night => {
				name => 'Night', voice => 'piper-alba',
				greeting => 'Closed', prompt => 'Say it', voicemail => 'Message',
				thanks => 'Bye', hold => '', after => 'voicemail',
			},
		}),
		ivr_flows => encode_json({
			unknown => 'night', stranger => 'ivr', self => 'voicemail',
			friend => 'ring', blacklisted => 'reject', enemy => 'reject',
		}),
	);
	local *subs::setting_grabber = sub {
		my $request = shift;
		return $stored{ $request->{'setting'} };
	};
	my $flow = &subs::phone_ivr_flow_for_bucket('unknown');
	is ref($flow), 'HASH', 'a bucket pointing at a custom flow resolves to it';
	is $flow->{'name'}, 'Night', 'the resolved flow is the custom one';
	is $flow->{'after'}, 'voicemail', 'with its own after step';
	is $flow->{'voice'}, 'piper-alba', 'and its own voice';
	my $rec = &subs::phone_ivr_flow_for_bucket('stranger');
	is ref($rec), 'HASH', 'the old ivr value still resolves';
	is $rec->{'name'}, 'Front desk', 'to the receptionist flow';
	is &subs::phone_ivr_flow_for_bucket('self')->{'name'}, 'Voicemail', 'the old voicemail value resolves to the voicemail flow';
	is &subs::phone_ivr_flow_for_bucket('friend'), '', 'ring is not answered with a flow';
	is &subs::phone_ivr_flow_for_bucket('enemy'), '', 'reject is not answered with a flow';
	is &subs::phone_ivr_flow_for_bucket('nonsense'), '', 'a bucket that is not one of the six is not answered';
}

# ---------------------------------------------------------------- a deleted flow
{
	my %stored = (
		ivr_route => 'unknown',
		ivr_flow_defs => encode_json({
			receptionist => { name => 'Receptionist', prompt => 'Name?', after => 'hold' },
			voicemail => { name => 'Voicemail', voicemail => 'Leave a message', after => 'end' },
		}),
		ivr_flows => encode_json({
			unknown => 'gone', stranger => 'gone',
			friend => 'ring', self => 'ring', blacklisted => 'reject', enemy => 'reject',
		}),
	);
	local *subs::setting_grabber = sub {
		my $request = shift;
		return $stored{ $request->{'setting'} };
	};
	is &subs::phone_ivr_flows()->{'unknown'}, 'ivr',
		'a bucket naming a flow that no longer exists falls back to its default';
	my $flow = &subs::phone_ivr_flow_for_bucket('unknown');
	is ref($flow), 'HASH', 'and still resolves to a flow';
	is $flow->{'name'}, 'Receptionist', 'the fallback default is the receptionist';
	is &subs::phone_ivr_flow_for_bucket('stranger')->{'name'}, 'Receptionist', 'the stranger bucket falls back the same way';
}

# ---------------------------------------------------------------- cleaning
{
	local *subs::setting_grabber = sub { return undef };
	my $defs = &subs::phone_ivr_flow_defs_clean({
		'Bad Key!' => { name => 'x' },
		'night_1' => {
			name => 'Night', voice => 'not-a-voice', greeting => 'x' x 2000,
			hold => '../../etc/passwd', after => 'explode',
		},
		'SHUFFLE' => { hold => 'SHUFFLE', after => 'end' },
	});
	ok !exists $defs->{'Bad Key!'}, 'a flow key that is not a slug is dropped';
	ok !exists $defs->{'SHUFFLE'}, 'a flow key is lower case only';
	is length($defs->{'night_1'}->{'greeting'}), 1000, 'a flow text is capped at 1000 characters';
	is $defs->{'night_1'}->{'voice'}, &subs::say_default_voice(), 'an unknown voice falls back to the default';
	is $defs->{'night_1'}->{'hold'}, '', 'a hold choice cannot name its way out of the library';
	is $defs->{'night_1'}->{'after'}, 'hold', 'an unknown after step falls back to hold';
	ok !$defs->{'night_1'}->{'builtin'}, 'a custom flow is not built in';
	is $defs->{'receptionist'}->{'builtin'}, 1, 'the built-ins are always present';
}
{
	local *subs::setting_grabber = sub { return undef };
	my $defs = &subs::phone_ivr_flow_defs_clean({ 'shuffly' => { hold => 'SHUFFLE' } });
	is $defs->{'shuffly'}->{'hold'}, 'shuffle', 'SHUFFLE is lowercased';
}
{
	# A recorded greeting is a WAV in the house's media folders. The cleaner keeps
	# one it can see and drops a path that is outside the house or no longer there.
	my $root = realpath(tempdir(CLEANUP => 1));
	make_path("$root/phone");
	my $wav = "$root/phone/greeting.wav";
	write_file($wav, 'RIFF-greeting');
	local $ENV{'JAWNOS_SCO_AUDIO_ROOTS'} = $root;
	local *subs::setting_grabber = sub { return undef };
	my $defs = &subs::phone_ivr_flow_defs_clean({
		night => { name => 'Night', voicemail_greeting => $wav },
		noon  => { name => 'Noon', voicemail_greeting => '../../etc/passwd' },
		gone  => { name => 'Gone', voicemail_greeting => "$root/phone/missing.wav" },
	});
	is $defs->{'night'}->{'voicemail_greeting'}, $wav,
		'a recorded greeting the house holds is kept';
	is $defs->{'noon'}->{'voicemail_greeting'}, '',
		'a greeting cannot name its way out of the media folders';
	is $defs->{'gone'}->{'voicemail_greeting'}, "$root/phone/missing.wav",
		'a greeting named on another machine is kept as a house path';
}

# ---------------------------------------------------------------- saving
{
	my @writes;
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub {
		my ($table, $columns, $where) = @_;
		my @rows = ($gateway);
		my @match = grep {
			my $ok = 1;
			foreach my $key ( keys %{ $where || {} } ) {
				$ok = 0 if (($$_{$key} // '') ne ($where->{$key} // ''));
			}
			$ok;
		} @rows;
		return FakeRows->new(\@match);
	};
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	my $saved = Manager::phone_ivr_save({
		enabled => 'yes', machine => 'gw-sig', route => 'all',
		voice => 'piper-john', bluetooth => 'jawn-gateway', greeting => '  Hello  ',
		prompt => 'Name?', voicemail => 'Leave it', thanks => 'Thanks',
		hold => 'shuffle',
		flows => '{"unknown":"reject","blacklisted":"voicemail","friend":"ivr"}',
	});
	is $saved->{'enabled'}, 'yes', 'saving normalises enabled to yes';
	is $saved->{'machine'}, 'gw-sig', 'a known gateway is kept';
	is $saved->{'route'}, 'all', 'a known route is kept';
	is $saved->{'voice'}, 'piper-john', 'a known voice is kept';
	is $saved->{'greeting'}, 'Hello', 'the prompt text is trimmed';
	is $saved->{'thanks'}, 'Thanks', 'the thanks prompt is kept';
	is $saved->{'hold'}, 'shuffle', 'the hold music choice is kept';
# the flow list folds to one open at a time
{
	my $phone_js = '';
	if (open(my $pf, '<', root() . '/public/js/manager/phone.js')) { local $/; $phone_js = <$pf>; close $pf; }
	like($phone_js, qr/opening one flow folds the others/, 'the flows editor is an accordion');
}
	is $saved->{'flows'}->{'unknown'}, 'reject', 'the unknown flow is saved';
	is $saved->{'flows'}->{'blacklisted'}, 'voicemail', 'the blacklist flow is saved';
	is $saved->{'flows'}->{'friend'}, 'ivr', 'the friend flow is saved';
	is $saved->{'flows'}->{'enemy'}, 'reject', 'a missing flow keeps its default';
	is $saved->{'flow_defs'}->{'receptionist'}->{'greeting'}, 'Hello',
		'the legacy prompt edits the receptionist flow, so the two agree';
	is scalar @writes, 12, 'every IVR setting is written';
	is $writes[0]->{'app'}, 'phone', 'the settings belong to the phone app';
	like $writes[0]->{'setting'}, qr/^ivr_/, 'the settings carry the ivr_ prefix';
	is $writes[9]->{'setting'}, 'ivr_hold', 'the hold music is one more house row';
	is $writes[10]->{'setting'}, 'ivr_flows', 'the flow matrix is written as one row';
	like $writes[10]->{'value'}, qr/"unknown":"reject"/, 'the flow row is JSON';
	is $writes[11]->{'setting'}, 'ivr_flow_defs', 'the named flows are one more house row';
	is $writes[11]->{'device'}, 'all', 'and the house, not the device, owns them';
	like $writes[11]->{'value'}, qr/"receptionist"/, 'the flow row is JSON';
}
{
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub { return FakeRows->new([]) };
	my @writes;
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	my $saved = Manager::phone_ivr_save({ machine => 'not-a-machine', prompt => 'x' x 2000, hold => '../../etc/passwd' });
	is $saved->{'machine'}, '', 'a machine that is not in remote_machines is dropped';
	is $saved->{'hold'}, '', 'and a hold choice cannot name its way out of the music library';
	is length($saved->{'prompt'}), 1000, 'a prompt is capped at 1000 characters';
}
{
	# the pane posts the flows and the matrix in one save; a bucket may name a
	# flow that same save adds
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub { return FakeRows->new([ $gateway ]) };
	my @writes;
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	my $saved = Manager::phone_ivr_save({
		enabled => 'yes', machine => 'gw-sig', route => 'unknown',
		flow_defs => encode_json({
			receptionist => {
				name => 'Front desk', voice => 'piper-john', greeting => 'Hello',
				prompt => 'Name?', voicemail => 'Leave it', thanks => 'Thanks',
				hold => 'shuffle', after => 'hold',
			},
			voicemail => { name => 'Voicemail', voicemail => 'Leave a message', after => 'end' },
			night => { name => 'Night', voice => 'piper-alba', greeting => 'Closed', after => 'voicemail' },
		}),
		flows => encode_json({
			unknown => 'night', stranger => 'night', self => 'voicemail',
			friend => 'ring', blacklisted => 'reject', enemy => 'reject',
		}),
	});
	is $saved->{'flow_defs'}->{'night'}->{'name'}, 'Night', 'the new flow is saved';
	is $saved->{'flow_defs'}->{'night'}->{'after'}, 'voicemail', 'with its own after step';
	is $saved->{'flow_defs'}->{'receptionist'}->{'builtin'}, 1, 'the receptionist stays built in';
	is $saved->{'flow_defs'}->{'night'}->{'builtin'}, 0, 'a custom flow is not built in';
	is $saved->{'flows'}->{'unknown'}, 'night', 'a bucket may point at the new flow';
	is $saved->{'greeting'}, 'Hello', 'the legacy greeting follows the receptionist flow';
	is $saved->{'voice'}, 'piper-john', 'and so does the voice';
	like $writes[11]->{'value'}, qr/"night"/, 'the saved flow row carries the custom flow';
}
{
	# a client that posts no flows (or a payload that is not JSON) must not wipe
	# the house's flows
	my $stored = encode_json({
		receptionist => { name => 'Receptionist', prompt => 'Name?', after => 'hold' },
		voicemail => { name => 'Voicemail', voicemail => 'Leave a message', after => 'end' },
		night => { name => 'Night', greeting => 'Closed', after => 'voicemail' },
	});
	local *subs::setting_grabber = sub {
		my $request = shift;
		return $stored if $request->{'setting'} eq 'ivr_flow_defs';
		return undef;
	};
	local *subs::db_select = sub { return FakeRows->new([]) };
	local *subs::setting_setter = sub { };
	my $saved = Manager::phone_ivr_save({ flow_defs => 'not json' });
	is $saved->{'flow_defs'}->{'night'}->{'name'}, 'Night',
		'a flow payload that is not JSON leaves the saved flows alone';
	my $again = Manager::phone_ivr_save({ enabled => 'yes' });
	is $again->{'flow_defs'}->{'night'}->{'name'}, 'Night', 'a save with no flows at all keeps them';
}

{
	# The pane posts the whole flow set; the stored row must keep the step order
	# and a keypad's digit map so the gateway reads exactly what the person built.
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub { return FakeRows->new([ $gateway ]) };
	my @writes;
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	my $saved = Manager::phone_ivr_save({
		enabled => 'yes', machine => 'gw-sig', route => 'unknown',
		flow_defs => encode_json({
			receptionist => {
				name => 'Receptionist',
				steps => [
					{ type => 'keypad', text => 'Press 1 for the night line', timeout_ms => 4000, digits => { '1' => 'night' } },
					{ type => 'say', text_key => 'greeting' },
					{ type => 'ask' },
					{ type => 'hold', seconds => 10 },
				],
				voicemail_seconds => 45,
			},
			night => { name => 'Night', steps => [ { type => 'say', text_key => 'greeting' } ] },
		}),
	});
	my ($row) = grep { $_->{'setting'} eq 'ivr_flow_defs' } @writes;
	ok $row, 'the flow set is written as one house row';
	my $stored = eval { decode_json($row->{'value'}) };
	is ref $stored, 'HASH', 'the stored flow row is JSON';
	is_deeply $stored->{'receptionist'}->{'steps'}, [
		{ type => 'keypad', text => 'Press 1 for the night line', timeout_ms => 4000, digits => { '1' => 'night' } },
		{ type => 'say', text_key => 'greeting' },
		{ type => 'ask' },
		{ type => 'hold', seconds => 10 },
	], 'the stored JSON keeps the step order and the keypad digit map';
	is $stored->{'receptionist'}->{'voicemail_seconds'}, 45,
		'and the flow\'s own voicemail length travels in the same save';
}

{
	# The Chat note a message points at is read by uuid, through the house key.
	local *subs::suds_grabber = sub { return 'secret' };
	local *subs::db_select = sub {
		return FakeRows->new([ { uuid => 'note-1', body => 'sealed', timestamp => '100', ost => undef } ]);
	};
	local *subs::note_decrypter = sub { return 'Call from: Ada' };
	my $one = Manager::phone_voicemail_transcript('note-1');
	is $one->{'ok'}, 1, 'the pane can open a voicemail\'s transcript';
	is $one->{'text'}, 'Call from: Ada', 'and gets the words back, not the sealed body';
	is Manager::phone_voicemail_transcript('bad note!')->{'ok'}, 0, 'only a uuid is asked for';
}

# ---------------------------------------------------------------- relationships
{
	local *Manager::phone_names = sub {
		return { '5199188319' => 'alice', '5550100' => 'bob' };
	};
	local *subs::person_relationships = sub {
		return { alice => { value => 'self', rating => 1 }, bob => { value => 'enemy', rating => 3 } };
	};
	my $relations = Manager::phone_relationships();
	is $relations->{'5199188319'}->{'value'}, 'self', 'a self relationship is carried by number';
	is $relations->{'5199188319'}->{'app'}, 'alice', 'the relationship names the person app';
	is $relations->{'5550100'}->{'value'}, 'enemy', 'an enemy relationship is carried by number';
}

# ---------------------------------------------------------------- machines
{
	# a machine with the helper built offers itself first (Part12::phone_ivr_machines
	# probes ./perl/sco/sco_helper). This block is about the remote rows, so the
	# local entry is taken out of the picture: without this the test passes on a
	# desktop and fails on every machine that can actually be a gateway.
	local *Manager::phone_self_signatorial = sub { return '' };
	local *subs::db_select = sub { return FakeRows->new([ $sleepy, $gateway ]) };
	my $machines = Manager::phone_ivr_machines();
	is scalar @{$machines}, 2, 'every remote machine is offered';
	is $machines->[0]->{'key'}, 'gw-sig', 'the online machine sorts first';
	is $machines->[0]->{'available'}, 1, 'the online machine is available';
	is $machines->[1]->{'key'}, '10.0.0.9', 'a machine with no signatorial keys on its IP';
	is $machines->[1]->{'available'}, 0, 'the offline machine is not available';
}

# ---------------------------------------------------------------- steps
{
	local *subs::setting_grabber = sub { return undef };
	my $flow = { name => 'Plain', greeting => 'Hi', prompt => 'Name?', thanks => 'Thanks', after => 'hold' };
	my $legacy = &subs::phone_ivr_flow_steps($flow);
	is_deeply $legacy, [
		{ type => 'say', text_key => 'greeting' },
		{ type => 'ask' },
		{ type => 'say', text_key => 'thanks' },
		{ type => 'after' },
	], 'a flow with no steps speaks the legacy order: greeting, ask, thanks, after';
	is_deeply &subs::phone_ivr_flow_steps({ steps => [] }), $legacy,
		'an empty step list means the same legacy order';
	my $defs = &subs::phone_ivr_flow_defs_clean({ receptionist => { name => 'Receptionist' } });
	is_deeply $defs->{'receptionist'}->{'steps'}, [],
		'a legacy flow keeps an empty list, so the def never pretends to have steps';
	is_deeply &subs::phone_ivr_flow_steps($defs->{'receptionist'}), $legacy,
		'and reads back as the legacy order';
}
{
	my $steps = &subs::phone_ivr_steps_clean([
		{ type => 'keypad', text => '  Press 1  ', timeout_ms => '4000', digits => {
			'1' => 'night', 'A' => 'night', '2' => 'ring', '3' => 'reject', '4' => 'bad key!',
		} },
		{ type => 'say', text_key => 'prompt' },
		{ type => 'say', text_key => 'nope' },
		{ type => 'hold', seconds => '9999' },
		{ type => 'explode' },
		{ type => 'after' },
	]);
	is scalar @{$steps}, 4, 'an unknown step type and an unknown say text are dropped';
	is $steps->[0]->{'type'}, 'keypad', 'the list keeps the order it was given';
	is $steps->[0]->{'text'}, 'Press 1', 'the keypad text is trimmed';
	is $steps->[0]->{'timeout_ms'}, 4000, 'the keypad timeout is kept';
	is_deeply $steps->[0]->{'digits'}, { '1' => 'night', '2' => 'ring', '3' => 'reject' },
		'a digit is one keypad character naming a slug';
	is $steps->[1]->{'text_key'}, 'prompt', 'a say names one of the flow texts';
	is $steps->[2]->{'type'}, 'hold', 'the hold step is still in its place';
	is $steps->[2]->{'seconds'}, 600, 'a hold is capped at 600 seconds';
	is $steps->[3]->{'type'}, 'after', 'and the after step still follows';
	my $defaults = &subs::phone_ivr_steps_clean([{ type => 'keypad', digits => {} }]);
	is $defaults->[0]->{'timeout_ms'}, 5000, 'a keypad without a timeout waits five seconds';
}
{
	my @many = map { { type => ($_ % 2 ? 'say' : 'hold'), text_key => 'greeting', seconds => 1 } } 1 .. 25;
	my $capped = &subs::phone_ivr_steps_clean(\@many);
	is scalar @{$capped}, 20, 'a step list is capped at 20';
}
{
	local *subs::setting_grabber = sub { return undef };
	my $defs = &subs::phone_ivr_flow_defs_clean({
		receptionist => {
			name => 'Receptionist',
			steps => [
				{ type => 'keypad', text => 'Press 1', timeout_ms => 5000, digits => {
					'1' => 'night', '2' => 'ring', '3' => 'gone', '4' => 'voicemail',
				} },
				{ type => 'hold', seconds => 5 },
				{ type => 'say', text_key => 'thanks' },
			],
		},
		night => { name => 'Night', steps => [ { type => 'say', text_key => 'greeting' } ] },
	});
	is_deeply $defs->{'receptionist'}->{'steps'}->[0]->{'digits'},
		{ '1' => 'night', '2' => 'ring', '4' => 'voicemail' },
		'a digit naming a flow the set does not have is dropped; Ring and a real flow stay';
	is $defs->{'receptionist'}->{'steps'}->[1]->{'type'}, 'hold', 'the step order survives cleaning';
	is $defs->{'receptionist'}->{'steps'}->[2]->{'type'}, 'say', 'down to the last step';
}
{
	local *subs::setting_grabber = sub { return undef };
	# night is absent from this save, so the receptionist menu must forget it
	my $defs = &subs::phone_ivr_flow_defs_clean({
		receptionist => {
			name => 'Receptionist',
			steps => [ { type => 'keypad', text => 'Press 1', digits => { '1' => 'night' } } ],
		},
	});
	ok !exists $defs->{'receptionist'}->{'steps'}->[0]->{'digits'}->{'1'},
		'deleting a flow drops every digit that pointed at it';
}

# ---------------------------------------------------------------- voicemail length
{
	local *subs::setting_grabber = sub { return undef };
	my $defs = &subs::phone_ivr_flow_defs_clean({
		receptionist => { name => 'Receptionist', voicemail_seconds => '5' },
		night => { name => 'Night', voicemail_seconds => '5000' },
		noon => { name => 'Noon', voicemail_seconds => 'not a number' },
		quiet => { name => 'Quiet', voicemail_seconds => '45' },
	});
	is $defs->{'receptionist'}->{'voicemail_seconds'}, 15,
		'a message shorter than 15 seconds is raised to the floor';
	is $defs->{'night'}->{'voicemail_seconds'}, 1800,
		'a message longer than half an hour is capped';
	is $defs->{'noon'}->{'voicemail_seconds'}, 300,
		'a value that is not a number keeps the five-minute default';
	is $defs->{'quiet'}->{'voicemail_seconds'}, 45, 'a valid length is kept';
	is $defs->{'voicemail'}->{'voicemail_seconds'}, 300,
		'the seeded voicemail flow defaults to five minutes';
}

# ---------------------------------------------------------------- recorded greeting save
{
	my $root = realpath(tempdir(CLEANUP => 1));
	make_path("$root/phone");
	my $wav = "$root/phone/greeting.wav";
	write_file($wav, 'RIFF-greeting');
	local $ENV{'JAWNOS_SCO_AUDIO_ROOTS'} = $root;
	my @writes;
	local *subs::setting_grabber = sub { return undef };
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	my $saved = Manager::phone_ivr_save({
		flow_defs => encode_json({
			receptionist => { name => 'Receptionist' },
			night => { name => 'Night', voicemail_greeting => $wav },
		}),
	});
	is $saved->{'flow_defs'}->{'night'}->{'voicemail_greeting'}, $wav,
		'a recorded greeting survives the save';
	my ($row) = grep { $_->{'setting'} eq 'ivr_flow_defs' } @writes;
	like $row->{'value'}, qr/greeting\.wav/,
		'and it is in the house row the gateway reads';
}

# ---------------------------------------------------------------- the filed message
# A voicemail is filed the way a capture is: one entry in the appointment's file
# column, type audio, pointing at the Chat note that holds the words.
{
	my $root = tempdir(CLEANUP => 1);
	local *subs::setting_grabber = sub { return $root };
	local *subs::rightNow = sub { return 1700000000000 };
	my $source = "$root/source.wav";
	write_file($source, 'RIFF-voicemail-bytes');
	my $entry = &subs::voicemail_file($source,
		app => 'phone', timestamp => '1700000000', note_uuid => 'note-1');
	ok $entry && ref $entry eq 'HASH', 'a voicemail becomes one file entry';
	is $entry->{'type'}, 'audio', 'the entry is an audio file';
	is $entry->{'note_uuid'}, 'note-1', 'it points at the words already in Chat';
	ok !exists $entry->{'thumb'}, 'a voicemail has no thumbnail';
	ok !exists $entry->{'ocr'}, 'and nothing to read out of it';
	ok -f $entry->{'f'}, 'the WAV is written into the app folder';
	like $entry->{'f'}, qr{/phone/phone_1700000000\.wav$}, 'named the way a capture is';
	is read_file($entry->{'f'}), 'RIFF-voicemail-bytes', 'and carries the recording';
}
{
	# bytes may be handed over directly, for a gateway that is another machine
	my $root = tempdir(CLEANUP => 1);
	local *subs::setting_grabber = sub { return $root };
	local *subs::rightNow = sub { return 1700000000000 };
	my $entry = &subs::voicemail_file('RIFF-bytes', app => 'phone', timestamp => '7');
	ok $entry && -f $entry->{'f'}, 'bytes are written too';
	is read_file($entry->{'f'}), 'RIFF-bytes', 'without a source file';
	ok !exists $entry->{'note_uuid'}, 'and no note reference when there was none';
}
{
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		is $args[0], '5555550100', 'the note is looked up by the call\'s number';
		return FakeRows->new([ { uuid => 'note-uuid' } ]);
	};
	is &subs::voicemail_note_uuid('+1 (555) 555-0100', 1700000000000), 'note-uuid',
		'a voicemail references the newest Chat note for the call';
}
{
	local *subs::db_query = sub { return FakeRows->new([]) };
	is &subs::voicemail_note_uuid('5550100', 1700000000000), '',
		'a call with no transcript has no note to reference';
}

# ---------------------------------------------------------------- keeping the recording
# A recorded greeting is written the way a capture is: a WAV in the app's own
# media folder, one appointment file entry, and the tree sealed through
# file_encrypter. The path the flow names is the one left on disk.
{
	my $root = realpath(tempdir(CLEANUP => 1));
	my $row;
	local *subs::setting_grabber = sub { return $root };
	local *subs::rightNow = sub { return 1700000000000 };
	local *subs::db_insert = sub { my ($table, $data) = @_; $row = { %{$data} }; return 1; };
	local *subs::db_select = sub { return FakeRows->new([ $row ]); };
	local *subs::file_encrypter = sub { return };
	my $path = &subs::phone_ivr_greeting_store('RIFF-greeting', timestamp => '1700000000');
	is $path, "$root/phone/phone_greeting_1700000000.wav",
		'a greeting is written under the app\'s media folder';
	is read_file($path), 'RIFF-greeting', 'with the bytes it was given';
	is $row->{'subtype'}, 'ivr_greeting', 'filed as an IVR greeting';
	is $row->{'app'}, 'phone', 'on the Phone app';
}
SKIP: {
	skip 'ffmpeg is not installed, so an upload cannot be converted', 3
		unless system('sh', '-c', 'command -v ffmpeg >/dev/null 2>&1') == 0;
	my $n = 8000;
	my $data = join '', map { pack('s<', 0) } 1 .. $n;
	my $tiny = 'RIFF' . pack('V', 36 + length $data)
		. 'WAVEfmt ' . pack('VvvVVvv', 16, 1, 1, 8000, 16000, 2, 16)
		. 'data' . pack('V', length $data) . $data;
	my ($wav, $seconds) = &subs::phone_ivr_greeting_wav($tiny);
	ok defined $wav && length $wav, 'an upload becomes a WAV the house can keep';
	like $wav, qr/^RIFF/, 'and it is a real WAV';
	cmp_ok $seconds, '<=', 2, 'with the length the recorder gave it';
}

# ---------------------------------------------------------------- callers
# A flow may name the callers that get it. Resolution is: an exact number in a
# flow's callers, then the person/vendor/corporation the number belongs to, then
# the bucket matrix. The entries are validated here because they arrive from a
# browser and name rows that may have been deleted since.
{
	local *subs::setting_grabber = sub { return undef };
	my $callers = &subs::phone_ivr_callers_clean([
		{ kind => 'number', value => '+1 (555) 123-4567', label => '  Ada  ' },
		{ kind => 'number', value => '5551234567' },
		{ kind => 'number', value => '12' },
		{ kind => 'explode', uuid => 'x' },
		{ kind => 'person', uuid => 'u-dad', label => 'Dad' },
		{ kind => 'person', uuid => 'u-dad' },
	]);
	is scalar @{$callers}, 2, 'a caller list drops a bad number, a bad kind and a repeated entry';
	is $callers->[0]->{'kind'}, 'number', 'the first entry is the number';
	is $callers->[0]->{'value'}, '5551234567', 'a number is kept in the house normal form';
	is $callers->[0]->{'label'}, 'Ada', 'the label is what the person typed, trimmed';
	is $callers->[1]->{'uuid'}, 'u-dad', 'a person keeps the settings uuid it names';
	is $callers->[1]->{'label'}, 'Dad', 'and the label the picker showed';
}
{
	local *subs::db_query = sub {
		my ($sql) = @_;
		return FakeRows->new([ { uuid => 'u-dad', app => 'dad', setting => 'pos', value => 'person' } ])
			if $sql =~ /setting in/;
		return FakeRows->new([]);
	};
	my $kept = &subs::phone_ivr_callers_clean([ { kind => 'vendor', uuid => 'u-dad' } ], 1);
	is scalar @{$kept}, 0, 'a body that is not that kind is dropped on save';
	my $ok = &subs::phone_ivr_callers_clean([ { kind => 'person', uuid => 'u-dad' } ], 1);
	is scalar @{$ok}, 1, 'a body the house really has is kept';
	my $gone = &subs::phone_ivr_callers_clean([ { kind => 'vendor', uuid => 'u-gone' } ], 1);
	is scalar @{$gone}, 0, 'a body that no longer exists is dropped on save';
	my $shaped = &subs::phone_ivr_callers_clean([ { kind => 'vendor', uuid => 'u-gone' } ], 0);
	is scalar @{$shaped}, 1, 'a read keeps the shape, so a body restored later still names it';
}
{
	local *subs::setting_grabber = sub { return undef };
	my @warnings;
	my $defs = &subs::phone_ivr_flow_defs_clean({
		receptionist => { name => 'Front desk', callers => [ { kind => 'number', value => '5551234567' } ] },
		night => { name => 'Night', callers => [ { kind => 'number', value => '5551234567' } ] },
	}, { order => [ 'receptionist', 'night' ], warnings => \@warnings });
	my @numbers;
	foreach my $key ( qw(receptionist night) ) {
		push @numbers, "$key:$_->{'value'}" for @{ $defs->{$key}->{'callers'} };
	}
	is_deeply \@numbers, ['night:5551234567'], 'a number put in two flows stays with the later save';
	is scalar @warnings, 1, 'and the losing flow says so';
	is $warnings[0]->{'from'}, 'Front desk', 'the warning names the flow that lost the number';
	is $warnings[0]->{'to'}, 'Night', 'and the flow that kept it';
}
{
	local *subs::setting_grabber = sub { return undef };
	my @warnings;
	# night is where the number was; day is where the later save puts it
	my $defs = &subs::phone_ivr_flow_defs_clean({
		day => { name => 'Day', callers => [ { kind => 'number', value => '5551234567' } ] },
		night => { name => 'Night', callers => [ { kind => 'number', value => '5551234567' } ] },
	}, {
		order => [ 'day', 'night' ],
		previous => { night => { callers => [ { kind => 'number', value => '5551234567' } ] } },
		warnings => \@warnings,
	});
	is $defs->{'day'}->{'callers'}->[0]->{'value'}, '5551234567',
		'a number a save moves is in the flow it moved to, not the flow that had it';
	is scalar @{ $defs->{'night'}->{'callers'} }, 0, 'the old owner lets it go';
	is $warnings[0]->{'to'}, 'Day', 'and the warning names the new flow';
}
{
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		if ($sql =~ /setting in \(\'pos\',\'mab\'\)/) {
			return FakeRows->new([
				{ uuid => 'u-dad', app => 'dad', setting => 'pos', value => 'person' },
				{ uuid => 'u-bmo', app => 'bmo', setting => 'pos', value => 'vendor' },
			]);
		}
		return FakeRows->new([ { app => 'dad', value => '5551234567' } ]) if ($args[0] || '') eq 'phone';
		return FakeRows->new([]);
	};
	my $defs = {
		receptionist => { name => 'Receptionist', callers => [ { kind => 'person', uuid => 'u-dad', label => 'Dad' } ] },
		night => { name => 'Night', callers => [ { kind => 'number', value => '5551234567', label => 'Ada' } ] },
	};
	my $match = &subs::phone_ivr_caller_match('5551234567', $defs);
	is $match->{'flow'}, 'night', 'an exact number beats the person the number belongs to';
	is $match->{'kind'}, 'number', 'and the match says which entry decided it';
	$match = &subs::phone_ivr_caller_match('+1 (555) 123-4567', $defs);
	is $match->{'flow'}, 'night', 'a number is matched in the house normal form';
	$defs->{'night'}->{'callers'} = [];
	$match = &subs::phone_ivr_caller_match('5551234567', $defs);
	is $match->{'flow'}, 'receptionist', 'the person the number belongs to claims it next';
	is $match->{'uuid'}, 'u-dad', 'the match names the settings row';
	is &subs::phone_ivr_caller_match('5559999999', $defs), undef, 'a number nobody names does not match';
}
{
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_query = sub { return FakeRows->new([]) };
	my $defs = { receptionist => { name => 'Receptionist', callers => [ { kind => 'number', value => '5551234567' } ] } };
	my $flow = &subs::phone_ivr_flow_for_number('5551234567', 'unknown', $defs);
	is ref($flow), 'HASH', 'a number named in a flow resolves to that flow';
	is $flow->{'key'}, 'receptionist', 'the resolved flow carries its key for the phone';
	is $flow->{'name'}, 'Receptionist', 'and its own words';
	my $bucket = &subs::phone_ivr_flow_for_number('5550000000', 'unknown', $defs);
	is $bucket->{'name'}, 'Receptionist', 'a number nobody names falls back to the bucket flow';
	ok !exists $bucket->{'key'}, 'the bucket answer is not a caller match';
	my $index = &subs::phone_ivr_caller_index($defs);
	is $index->{'5551234567'}->{'flow'}, 'receptionist', 'the sync index resolves the number to its flow';
}
{
	local *Manager::phone_routes_read = sub { return {} };
	local *Manager::phone_relationships = sub { return {} };
	local *Manager::phone_names = sub { return {} };
	local *subs::db_query = sub { return FakeRows->new([]) };
	my $defs = {
		receptionist => { name => 'Receptionist' },
		night => { name => 'Night', callers => [ { kind => 'number', value => '5551234567' } ] },
	};
	local *subs::setting_grabber = sub {
		my $request = shift;
		return 'yes' if $request->{'setting'} eq 'ivr_enabled';
		return encode_json({ unknown => 'ivr', stranger => 'ivr' }) if $request->{'setting'} eq 'ivr_flows';
		return encode_json($defs) if $request->{'setting'} eq 'ivr_flow_defs';
		return undef;
	};
	my $route = Manager::phone_route_for('5551234567');
	is $route->{'flow'}, 'night', 'the phone route reads a flow\'s callers';
	is $route->{'source'}, 'caller', 'and says the caller list decided it';
	is $route->{'kind'}, 'number', 'with the kind that claimed the number';
	my $other = Manager::phone_route_for('5550000000');
	is $other->{'flow'}, 'ivr', 'a number nobody names keeps the bucket matrix';
	is $other->{'source'}, 'unknown', 'from the unknown bucket';
}
{
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub { return FakeRows->new([]) };
	local *subs::db_query = sub {
		my ($sql) = @_;
		return FakeRows->new([ { uuid => 'u-dad', app => 'dad', setting => 'pos', value => 'person' } ])
			if $sql =~ /setting in/;
		return FakeRows->new([]);
	};
	my @writes;
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	my $saved = Manager::phone_ivr_save({
		enabled => 'yes',
		flow_defs => encode_json({
			receptionist => { name => 'Front desk', callers => [
				{ kind => 'person', uuid => 'u-dad', label => 'Dad' },
				{ kind => 'vendor', uuid => 'u-gone' },
			] },
			night => { name => 'Night', callers => [ { kind => 'number', value => '5551234567' } ] },
			day => { name => 'Day', callers => [ { kind => 'number', value => '5551234567' } ] },
		}),
		flow_order => encode_json([ 'receptionist', 'night', 'day' ]),
	});
	is scalar @{ $saved->{'flow_defs'}->{'receptionist'}->{'callers'} }, 1,
		'a body the house no longer has is dropped on save';
	is $saved->{'flow_defs'}->{'receptionist'}->{'callers'}->[0]->{'uuid'}, 'u-dad', 'the real person stays';
	is $saved->{'flow_defs'}->{'day'}->{'callers'}->[0]->{'value'}, '5551234567',
		'the later save keeps the shared number';
	is scalar @{ $saved->{'flow_defs'}->{'night'}->{'callers'} }, 0, 'and the earlier flow loses it';
	is scalar @{ $saved->{'caller_warnings'} }, 1, 'the losing flow is named in a warning';
	my ($row) = grep { $_->{'setting'} eq 'ivr_flow_defs' } @writes;
	like $row->{'value'}, qr/"callers"/, 'the callers are written with the flows';
}
{
	local *subs::db_query = sub {
		my ($sql) = @_;
		return FakeRows->new([
			{ uuid => 'u-dad', app => 'dad', setting => 'pos', value => 'person' },
			{ uuid => 'u-bmo', app => 'bmo', setting => 'pos', value => 'vendor' },
			{ uuid => 'u-own', app => 'my_company', setting => 'pos', value => 'corporation' },
		]) if $sql =~ /setting in/;
		return FakeRows->new([]);
	};
	my $choices = Manager::phone_caller_choices();
	is scalar @{$choices}, 3, 'the picker offers every person, vendor and corporation';
	is $choices->[0]->{'kind'}, 'person', 'with the kind the entry travels as';
	is $choices->[0]->{'uuid'}, 'u-dad', 'and the settings uuid';
	is $choices->[0]->{'label'}, 'Dad', 'and the name the house shows';
}

# ---------------------------------------------------------------- wiring
my $manager = manager_source();
like $manager, qr{/manager/phone/ivr}, 'the IVR route is registered';
like $manager, qr{sub action_24760}, 'the IVR route has its action';
# the save reaches the gateway machine and the phone now, not at the next sync
like $manager, qr/remote_relay_request\(\$c, \{ dissemination => 'yes' \}\)/,
	'an IVR save is relayed to the peers';
like $manager, qr{phone_ivr_save\(}, 'the action saves the IVR settings';
like $manager, qr{flow_defs => \$c->param\('flow_defs'\)}, 'the action forwards the named flows';
like $manager, qr{/manager/phone/greeting}, 'the greeting routes are registered';
like $manager, qr{sub action_24763}, 'the recorded greeting has an upload action';
like $manager, qr{sub action_24764}, 'and a route that plays it';
like $manager, qr{ivr => \$ivr}, 'the sync blob carries the IVR policy';
like $manager, qr{flow_callers}, 'the sync blob carries the resolved caller index';
like $manager, qr{phone_ivr_caller_index}, 'built from the flow defs, so each entry\'s lines resolve';
like $manager, qr{caller_choices}, 'the pane receives the picker choices';
like $manager, qr{phone_ivr_flow_for_number}, 'the phone route resolves the number through a flow\'s callers';
like $manager, qr{phone_ivr_save\(}, 'the action saves the IVR settings';
like $manager, qr{flow_order}, 'the save forwards the flow order that decides a shared number';

my $template = template_source('apps/phone');
like $template, qr{pane="ivr"}, 'the Phone app has an IVR pane';
like $template, qr{phone_ivr_machine}, 'the pane chooses a remote machine';
like $template, qr{phone_app_ivr_flow}, 'the pane has the per-caller flow matrix';
like $template, qr{phone_ivr_flows_editor}, 'the pane has the flows editor';
like $template, qr{phone_ivr_flow_list}, 'the pane has a list to draw the flows into';
like $template, qr{phone_ivr_flow_add}, 'the pane can add a flow';
like $template, qr{phone_app_row_call}, 'a recent call carries a phone icon';
like $template, qr{id="phone_voicemail"}, 'the voicemail pane has the message list';
like $template, qr{pane="voicemail"}, 'the app has a Voicemail pill';
like $template, qr{phone_ivr_voicemail_count}, 'the IVR pane keeps a count back to the messages';
like $template, qr{data-caller-choices}, 'the pane carries the picker choices for a flow\'s callers';

my $js = js_source('public/js/manager/phone.js');
like $js, qr{/manager/phone/ivr}, 'the pane saves through its route';
like $js, qr{/manager/phone/greeting}, 'the pane records and plays greetings through its route';
like $js, qr{MediaRecorder}, 'the pane records with the browser recorder';
like $js, qr{voicemail_greeting}, 'the flow carries the recorded greeting field';
like $js, qr{hint="Record greeting"}, 'the record control has its hint';
like $js, qr{hint="Play greeting"}, 'the play control has its hint';
like $js, qr{hint="Remove greeting"}, 'the remove control has its hint';
like $js, qr{JawnPhone\.dial}, 'the recent icon asks the native bridge to dial';
like $js, qr{phone_app_row_call}, 'the recent icon has a click handler';
like $js, qr{phone_app_ivr_flow}, 'the pane collects the flow matrix';
like $js, qr{flow_defs}, 'the pane saves the named flows';
like $js, qr{phone_ivr_flow_list}, 'the pane draws the flow list';
like $template, qr{\.phone_app_ivr_flow_edit\[hidden\] \{ display:none}, 'a folded flow\'s editor is really hidden';
like $js, qr{#phone_app \.phone_app_ivr_flow_head}, 'a flow\'s head is the handler that folds it';
like $js, qr{find\('\.phone_app_ivr_flow_head'\)\.removeClass\('on'\)}, 'the handler clears the open marker on the other flows';
like $js, qr{edit\.prop\('hidden', !open\)}, 'the handler opens and closes the same row';
like $js, qr{hint="Rename flow"}, 'a flow can be renamed';
like $js, qr{hint="Delete flow"}, 'a flow can be deleted';
like $js, qr{thanks}, 'the pane saves the thanks prompt';
like $js, qr{\.sortable\(}, 'the steps use the house drag helper (jQuery UI sortable)';
like $js, qr{handle: '\.phone_app_ivr_step_handle'}, 'only the step handle drags';
like $js, qr{jawnPhoneFlowStepsRead}, 'the editor reads the steps back in DOM order';
like $js, qr{hint="Drag to reorder"}, 'the drag handle is named for the stylus and the mouse';
like $js, qr{hint="Add step"}, 'a step can be added';
like $js, qr{hint="Remove step"}, 'a step can be removed';
like $js, qr{jawnPhoneFlowDigitSelect}, 'a keypad offers a digit menu';
like $js, qr{jawnPhoneFlowDigitsDrop}, 'deleting a flow drops its digit references';
like $js, qr{voicemail_seconds}, 'the flow editor carries the voicemail length';
like $js, qr{/manager/sco/transcript}, 'the voicemail list fetches the transcript by note';
like $js, qr{hint="Transcript"}, 'the transcript is a named control';
like $js, qr{hint="Voicemail length"}, 'the voicemail length is a named control';
like $js, qr{phone_app_vm_words}, 'a message opens its transcript beside it';
like $js, qr{#phone_app #phone_voicemail}, 'the pane draws the gateway\'s list';
like $js, qr{messages\.sort\(function \(a, b\) \{ return \(b\.at \|\| 0\) - \(a\.at \|\| 0\); \}\)}, 'the messages are newest first';
like $js, qr{/manager/sco/recording\?name=}, 'Play asks the gateway for the recording';
like $js, qr{phone_app_ivr_vm_link}, 'the IVR line opens the messages';
like $js, qr/jawnPhoneGatewayPoll\(polling\)/, 'the open pane polls the gateway';
like $js, qr/var polling = \(pane === 'ivr' \|\| pane === 'voicemail'\)/, 'both the IVR and Voicemail panes poll while open';
like $js, qr{jawnPhoneCallerChoices}, 'the pane reads the caller choices';
like $js, qr{hint="Add caller"}, 'a person, vendor or corporation can be added as a caller';
like $js, qr{hint="Add number"}, 'a number can be added as a caller';
like $js, qr{hint="Remove caller"}, 'a caller can be removed';
like $js, qr{flow_order}, 'the pane tells the save which flow was later';
like $js, qr{caller_warnings}, 'the pane shows a number that moved between flows';

my $sync = js_source('public/js/manager/manager.js');
like $sync, qr{ivr:\s*\(response && response\.ivr\)}, 'the sync blob carries the IVR policy';
like $sync, qr{relationships:\s*\(response && response\.relationships\)}, 'the sync blob carries the relationships';

my $help = help_source();
like $help, qr/IVR is the reception page/, 'the help topic explains the IVR pane';
like $help, qr/Add flow/, 'the help topic names the flows editor';
like $help, qr/A flow is one voice/, 'the help topic says what a flow is';
like $help, qr/Drag a step/, 'the help topic explains reordering';
like $help, qr/Keypad menu/, 'the help topic explains the keypad step';
like $help, qr/no steps still speaks the old order/, 'the help topic explains the legacy order';
like $help, qr/Voicemail length/, 'the help topic names the per-flow message length';
like $help, qr/Transcript/, 'the help topic explains the voicemail transcript row';
like $help, qr/Voicemail pill/, 'the help topic names the new pill';
like $help, qr/folds to one open flow at a time/, 'the help topic says a flow folds on its own';
like $help, qr/Callers/, 'the help topic explains the callers list';
like $help, qr/Add caller/, 'the help topic names the body picker';
like $help, qr/Add number/, 'the help topic names the number control';

# The pane has to render with the settings the controller passes, not only match
# a source grep. Empty call/list data keeps the rest of the page quiet.
{
	my $ivr;
	{
		local *subs::setting_grabber = sub { return undef };
		$ivr = Manager::phone_ivr_settings();
	}
	my $mt = Mojo::Template->new(vars => 1, auto_escape => 1);
	my $out = eval {
		$mt->render_file(
			root() . '/templates/apps/phone.html.ep',
			{
				calls => [], known => [], numbers => [], blocked => [],
				ivr => $ivr,
				ivr_machines => [],
				ivr_voices => [ &subs::say_voices() ],
				caller_choices => [],
			},
		);
	};
	is $@, '', 'the Phone template renders with the IVR pane';
	like $out, qr{id="phone_ivr_flows_editor"}, 'the rendered pane has the flows editor';
	like $out, qr{id="phone_ivr_flow_list"}, 'the rendered pane has the flow list';
	like $out, qr{data-flow-defs="[^"]*receptionist}, 'the rendered pane carries the flows as JSON';
	like $out, qr{data-caller-choices}, 'the rendered pane carries the caller choices';
	like $out, qr{pane="ivr"}, 'the rendered pane is present';
	like $out, qr{pane="voicemail"}, 'the rendered page has the Voicemail pill';
	like $out, qr{id="phone_voicemail"}, 'the rendered page has the message list';
	like $out, qr{No voicemail messages yet\.}, 'the empty state says so';
}

done_testing();
