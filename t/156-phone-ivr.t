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
like $defaults->{'prompt'}, qr/name/i, 'the default name prompt asks for a name';
ok length($defaults->{'greeting'}) && length($defaults->{'voicemail'}),
	'the greeting and voicemail prompt have defaults';

# ---------------------------------------------------------------- reading
{
	my %stored = (
		ivr_enabled => 'yes', ivr_machine => 'gw-sig', ivr_route => 'all',
		ivr_voice => 'piper-john', ivr_greeting => 'Hi there',
		ivr_prompt => 'Who is this?', ivr_voicemail => 'Leave a message',
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
		voice => 'piper-john', greeting => '  Hello  ',
		prompt => 'Name?', voicemail => 'Leave it',
	});
	is $saved->{'enabled'}, 'yes', 'saving normalises enabled to yes';
	is $saved->{'machine'}, 'gw-sig', 'a known gateway is kept';
	is $saved->{'route'}, 'all', 'a known route is kept';
	is $saved->{'voice'}, 'piper-john', 'a known voice is kept';
	is $saved->{'greeting'}, 'Hello', 'the prompt text is trimmed';
	is scalar @writes, 7, 'every IVR setting is written';
	is $writes[0]->{'app'}, 'phone', 'the settings belong to the phone app';
	like $writes[0]->{'setting'}, qr/^ivr_/, 'the settings carry the ivr_ prefix';
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

# ---------------------------------------------------------------- machines
{
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
like $manager, qr{phone_ivr_save\(}, 'the action saves the IVR settings';
like $manager, qr{ivr => \$ivr}, 'the sync blob carries the IVR policy';

my $template = template_source('apps/phone');
like $template, qr{pane="ivr"}, 'the Phone app has an IVR pane';
like $template, qr{phone_ivr_prompt}, 'the pane has a name-prompt field';
like $template, qr{phone_app_row_call}, 'a recent call carries a phone icon';
like $template, qr{phone_ivr_machine}, 'the pane chooses a remote machine';

my $js = js_source('public/js/manager/phone.js');
like $js, qr{/manager/phone/ivr}, 'the pane saves through its route';
like $js, qr{JawnPhone\.dial}, 'the recent icon asks the native bridge to dial';
like $js, qr{phone_app_row_call}, 'the recent icon has a click handler';

my $sync = js_source('public/js/manager/manager.js');
like $sync, qr{ivr:\s*\(response && response\.ivr\)}, 'the sync blob carries the IVR policy';

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
