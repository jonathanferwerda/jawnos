# tests-for: lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Routes/manager_phone.pm lib/JawnOS/Manager/Part12.pm lib/JawnOS/Domain/Phone.pm templates/apps/phone.html.ep public/js/manager/phone.js public/js/manager/manager/02_web_nfc.js perl/help/topics_web.pl
# covers:    The IVR pane's settings and named flows, the remote-machine list, the sync blob, and the recent-call dialer icon.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Template;
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
	like $defs->{'voicemail'}->{'voicemail'}, qr/message/i, 'the voicemail flow leaves a message';
	is $defs->{'receptionist'}->{'voice'}, &subs::say_default_voice(), 'the seed speaks in the house voice';
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

# ---------------------------------------------------------------- wiring
my $manager = manager_source();
like $manager, qr{/manager/phone/ivr}, 'the IVR route is registered';
like $manager, qr{sub action_24760}, 'the IVR route has its action';
# the save reaches the gateway machine and the phone now, not at the next sync
like $manager, qr/remote_relay_request\(\$c, \{ dissemination => 'yes' \}\)/,
	'an IVR save is relayed to the peers';
like $manager, qr{phone_ivr_save\(}, 'the action saves the IVR settings';
like $manager, qr{flow_defs => \$c->param\('flow_defs'\)}, 'the action forwards the named flows';
like $manager, qr{ivr => \$ivr}, 'the sync blob carries the IVR policy';

my $template = template_source('apps/phone');
like $template, qr{pane="ivr"}, 'the Phone app has an IVR pane';
like $template, qr{phone_ivr_machine}, 'the pane chooses a remote machine';
like $template, qr{phone_app_ivr_flow}, 'the pane has the per-caller flow matrix';
like $template, qr{phone_ivr_flows_editor}, 'the pane has the flows editor';
like $template, qr{phone_ivr_flow_list}, 'the pane has a list to draw the flows into';
like $template, qr{phone_ivr_flow_add}, 'the pane can add a flow';
like $template, qr{phone_app_row_call}, 'a recent call carries a phone icon';

my $js = js_source('public/js/manager/phone.js');
like $js, qr{/manager/phone/ivr}, 'the pane saves through its route';
like $js, qr{JawnPhone\.dial}, 'the recent icon asks the native bridge to dial';
like $js, qr{phone_app_row_call}, 'the recent icon has a click handler';
like $js, qr{phone_app_ivr_flow}, 'the pane collects the flow matrix';
like $js, qr{flow_defs}, 'the pane saves the named flows';
like $js, qr{phone_ivr_flow_list}, 'the pane draws the flow list';
like $js, qr{hint="Rename flow"}, 'a flow can be renamed';
like $js, qr{hint="Delete flow"}, 'a flow can be deleted';
like $js, qr{thanks}, 'the pane saves the thanks prompt';

my $sync = js_source('public/js/manager/manager.js');
like $sync, qr{ivr:\s*\(response && response\.ivr\)}, 'the sync blob carries the IVR policy';
like $sync, qr{relationships:\s*\(response && response\.relationships\)}, 'the sync blob carries the relationships';

my $help = help_source();
like $help, qr/IVR is the reception page/, 'the help topic explains the IVR pane';
like $help, qr/Add flow/, 'the help topic names the flows editor';
like $help, qr/A flow is one voice/, 'the help topic says what a flow is';

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
			},
		);
	};
	is $@, '', 'the Phone template renders with the IVR pane';
	like $out, qr{id="phone_ivr_flows_editor"}, 'the rendered pane has the flows editor';
	like $out, qr{id="phone_ivr_flow_list"}, 'the rendered pane has the flow list';
	like $out, qr{data-flow-defs="[^"]*receptionist}, 'the rendered pane carries the flows as JSON';
	like $out, qr{pane="ivr"}, 'the rendered pane is present';
}

done_testing();
