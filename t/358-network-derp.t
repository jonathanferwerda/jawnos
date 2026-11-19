# tests-for: perl/crew.pl lib/JawnOS/Controller/manager_misc2.pm lib/JawnOS/Routes/manager_misc2.pm templates/apps/network.html.ep public/js/manager/network.js
# covers:    the public DERP relay is a Crew job (`derp.public`) whose placement
#           is the `headscale` ability, so a machine that cannot reach Headscale
#           can press the Network app's toggle and have a capable peer run it.
#           The command builder is checked without touching ssh or a host.

use strict;
use warnings;

use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

use MIME::Base64 qw(decode_base64);

require "$FindBin::Bin/../perl/crew.pl";

my $root = "$FindBin::Bin/..";

# --- the registry -----------------------------------------------------------
my $spec = crew::job_kind('derp.public');
ok(ref $spec eq 'HASH', 'derp.public is a registered job kind');
is_deeply($spec->{'needs'}, ['headscale'], 'it needs the headscale ability');
is($spec->{'cost'}, 'light', 'it is a light job');

ok(crew::can('derp.public', { tools => { headscale => 1 } }), 'a machine with headscale can run it');
ok(!crew::can('derp.public', { tools => {} }), 'a machine without headscale cannot');

# --- the control target -----------------------------------------------------
{
	local $ENV{'JAWNOS_ROOT'} = tempdir(CLEANUP => 1);
	local $ENV{'HOME'} = $ENV{'JAWNOS_ROOT'};
	local $ENV{'JAWNOS_HEADSCALE_CTL'} = 'ks5 102';
	my $c = crew::_headscale_control();
	ok(ref $c eq 'HASH' && $c->{'host'} eq 'ks5' && $c->{'lxc'} eq '102',
		'the control target is "<host> <lxc>"');
}
{
	local $ENV{'JAWNOS_ROOT'} = tempdir(CLEANUP => 1);
	local $ENV{'HOME'} = $ENV{'JAWNOS_ROOT'};
	delete $ENV{'JAWNOS_HEADSCALE_CTL'};
	make_path("$ENV{'JAWNOS_ROOT'}/.secrets");
	open(my $fh, '>', "$ENV{'JAWNOS_ROOT'}/.secrets/headscale-ctl") or die $!;
	print $fh "alpha 7\n";
	close $fh;
	my $c = crew::_headscale_control();
	ok(ref $c eq 'HASH' && $c->{'host'} eq 'alpha' && $c->{'lxc'} eq '7',
		'the control target is read from .secrets/headscale-ctl');
}
{
	local $ENV{'JAWNOS_ROOT'} = tempdir(CLEANUP => 1);
	local $ENV{'HOME'} = $ENV{'JAWNOS_ROOT'};
	local $ENV{'JAWNOS_HEADSCALE_CTL'} = 'not/a/host 102';
	ok(!defined crew::_headscale_control(), 'a target that is not a host is refused');
}

# --- the command builder ----------------------------------------------------
{
	my @cmd = crew::_derp_command({ host => 'ks5', lxc => '102' }, 'on');
	is($cmd[0], 'ssh', 'a target in an lxc is reached over ssh');
	is($cmd[-2], 'ks5', 'the ssh host is the target');
	like($cmd[-1], qr/sudo -n pct exec 102 -- sh -c '.*sh -s -- on'$/,
		'the lxc is entered and the state is passed as its own argument');
	my ($b64) = $cmd[-1] =~ /echo (\S+) \| base64 -d/;
	ok(defined $b64 && length $b64, 'the shell is carried as base64, not inline');
	my $script = defined $b64 ? decode_base64($b64) : '';
	like($script, qr/controlplane\.tailscale\.com\/derpmap\/default/,
		'the on relay is the public DERP map');
	like($script, qr/headscale configtest -c/,
		'it validates a candidate config before installing it');
	like($script, qr/urls: \[\]/, 'it can also write the empty urls list');
}
{
	my @cmd = crew::_derp_command({ host => 'myhost', lxc => '' }, 'off');
	is($cmd[0], 'sh', 'a local Headscale needs no ssh');
	like($cmd[-1], qr/sh -s -- off$/, 'the state still arrives as its own argument');
}
{
	my @cmd = crew::_derp_command({ host => 'ks5', lxc => '102' }, 'bogus');
	is_deeply(\@cmd, [], 'an unknown state builds no command');
	my $answer = crew::_headscale_apply('bogus');
	ok(ref $answer eq 'HASH' && !$answer->{'ok'}, 'the apply refuses an unknown state before any host is touched');
}

# --- the route, the page and the script are wired ---------------------------
sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

my $routes = slurp("$root/lib/JawnOS/Routes/manager_misc2.pm");
like($routes, qr/\[7946, 'get', '\/manager\/network\/derp_public', 'action_7946'\]/,
	'the status route is registered');
like($routes, qr/\[7947, 'post', '\/manager\/network\/derp_public', 'action_7947'\]/,
	'the toggle route is registered');

my $controller = slurp("$root/lib/JawnOS/Controller/manager_misc2.pm");
like($controller, qr/sub action_7946\b/, 'the status action exists');
like($controller, qr/sub action_7947\b/, 'the toggle action exists');
like($controller, qr/&crew::dispatch\('derp\.public'/, 'the toggle is placed through the Crew');

my $template = slurp("$root/templates/apps/network.html.ep");
like($template, qr/id="network_derp_toggle"/, 'the Network page has the relay control');
like($template, qr/data-state="<%= \$derp_public %>"/, 'the control starts from the stored state');

my $js = slurp("$root/public/js/manager/network.js");
like($js, qr/#network_derp_toggle/, 'the script handles a press on the control');
like($js, qr/networkPost\('derp_public'/, 'the press posts to the toggle route');

my $help = slurp("$root/perl/help/topics_web.pl");
like($help, qr/Tailnet relay is the public-relay switch/, 'the help topic explains the control');

done_testing();
