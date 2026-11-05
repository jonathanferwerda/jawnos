# tests-for: lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Routes/manager_phone.pm lib/JawnOS/Manager/Part12.pm templates/apps/phone.html.ep public/js/manager/phone.js public/js/manager/manager/02_web_nfc.js perl/help/topics_web.pl
# covers:    The IVR pane's settings, the remote-machine list, the sync blob, and the recent-call dialer icon.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
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
		flows => '{"unknown":"reject","blacklisted":"voicemail","friend":"ivr"}',
	});
	is $saved->{'enabled'}, 'yes', 'saving normalises enabled to yes';
	is $saved->{'machine'}, 'gw-sig', 'a known gateway is kept';
	is $saved->{'route'}, 'all', 'a known route is kept';
	is $saved->{'voice'}, 'piper-john', 'a known voice is kept';
	is $saved->{'greeting'}, 'Hello', 'the prompt text is trimmed';
	is $saved->{'thanks'}, 'Thanks', 'the thanks prompt is kept';
	is $saved->{'flows'}->{'unknown'}, 'reject', 'the unknown flow is saved';
	is $saved->{'flows'}->{'blacklisted'}, 'voicemail', 'the blacklist flow is saved';
	is $saved->{'flows'}->{'friend'}, 'ivr', 'the friend flow is saved';
	is $saved->{'flows'}->{'enemy'}, 'reject', 'a missing flow keeps its default';
	is scalar @writes, 10, 'every IVR setting is written';
	is $writes[0]->{'app'}, 'phone', 'the settings belong to the phone app';
	like $writes[0]->{'setting'}, qr/^ivr_/, 'the settings carry the ivr_ prefix';
is $writes[9]->{'setting'}, 'ivr_flows', 'the flow matrix is written as one row';
	like $writes[9]->{'value'}, qr/"unknown":"reject"/, 'the flow row is JSON';
}
{
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub { return FakeRows->new([]) };
	my @writes;
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	my $saved = Manager::phone_ivr_save({ machine => 'not-a-machine', prompt => 'x' x 2000 });
	is $saved->{'machine'}, '', 'a machine that is not in remote_machines is dropped';
	is length($saved->{'prompt'}), 1000, 'a prompt is capped at 1000 characters';
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
like $manager, qr{ivr => \$ivr}, 'the sync blob carries the IVR policy';

my $template = template_source('apps/phone');
like $template, qr{pane="ivr"}, 'the Phone app has an IVR pane';
like $template, qr{phone_ivr_prompt}, 'the pane has a name-prompt field';
like $template, qr{phone_app_row_call}, 'a recent call carries a phone icon';
like $template, qr{phone_ivr_machine}, 'the pane chooses a remote machine';
like $template, qr{phone_app_ivr_flow}, 'the pane has the per-caller flow matrix';
like $template, qr{phone_ivr_thanks}, 'the pane has the thanks prompt';

my $js = js_source('public/js/manager/phone.js');
like $js, qr{/manager/phone/ivr}, 'the pane saves through its route';
like $js, qr{JawnPhone\.dial}, 'the recent icon asks the native bridge to dial';
like $js, qr{phone_app_row_call}, 'the recent icon has a click handler';
like $js, qr{phone_app_ivr_flow}, 'the pane collects the flow matrix';
like $js, qr{thanks}, 'the pane saves the thanks prompt';

my $sync = js_source('public/js/manager/manager.js');
like $sync, qr{ivr:\s*\(response && response\.ivr\)}, 'the sync blob carries the IVR policy';
like $sync, qr{relationships:\s*\(response && response\.relationships\)}, 'the sync blob carries the relationships';

my $help = help_source();
like $help, qr/IVR is the reception page/, 'the help topic explains the IVR pane';

# The pane has to render with the settings the controller passes, not only match
# a source grep. Empty call/list data keeps the rest of the page quiet.
{
	my $mt = Mojo::Template->new(vars => 1);
	my $out = eval {
		$mt->render_file(
			root() . '/templates/apps/phone.html.ep',
			{
				calls => [], known => [], numbers => [], blocked => [],
				ivr => $defaults,
				ivr_machines => [],
				ivr_voices => [ &subs::say_voices() ],
			},
		);
	};
	is $@, '', 'the Phone template renders with the IVR pane';
	like $out, qr{id="phone_ivr_prompt"}, 'the rendered pane has the name-prompt field';
	like $out, qr{pane="ivr"}, 'the rendered pane is present';
}

done_testing();
