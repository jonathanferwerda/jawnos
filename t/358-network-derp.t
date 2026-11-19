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

use MIME::Base64 qw(decode_base64 encode_base64);

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
	like($cmd[-1], qr/sudo -n pct exec 102 -- sh -c '.*sh -s -- on all'$/,
		'the lxc is entered and the state and the closest-region default are arguments');
	my ($b64) = $cmd[-1] =~ /echo (\S+) \| base64 -d/;
	ok(defined $b64 && length $b64, 'the shell is carried as base64, not inline');
	my $script = defined $b64 ? decode_base64($b64) : '';
	like($script, qr/controlplane\.tailscale\.com\/derpmap\/default/,
		'the on relay is the public DERP map');
	like($script, qr/headscale configtest -c/,
		'it validates a candidate config before installing it');
	like($script, qr/urls: \[\]/, 'it can also write the empty urls list');
	like($script, qr/derp-public\.yaml/, 'a pinned region set is a local derp.paths map');
}
{
	my @cmd = crew::_derp_command({ host => 'ks5', lxc => '102' }, 'on', '8,21', 'YWJj');
	like($cmd[-1], qr/sh -s -- on 8,21 YWJj'$/,
		'a pinned region set and its filtered map travel as their own arguments');
}
{
	my @cmd = crew::_derp_command({ host => 'myhost', lxc => '' }, 'off');
	is($cmd[0], 'sh', 'a local Headscale needs no ssh');
	like($cmd[-1], qr/sh -s -- off all$/, 'the state still arrives as its own argument');
}
{
	my @cmd = crew::_derp_command({ host => 'ks5', lxc => '102' }, 'bogus');
	is_deeply(\@cmd, [], 'an unknown state builds no command');
	my $answer = crew::_headscale_apply('bogus');
	ok(ref $answer eq 'HASH' && !$answer->{'ok'}, 'the apply refuses an unknown state before any host is touched');
	my $bad = crew::_headscale_apply('on', '8,not-a-region');
	ok(ref $bad eq 'HASH' && !$bad->{'ok'}, 'the apply refuses a region list that is not ids before any host is touched');
}

# --- the chosen regions -----------------------------------------------------
is(crew::derp_regions_clean(undef), 'all', 'no region means Closest');
is(crew::derp_regions_clean(''), 'all', 'an empty region means Closest');
is(crew::derp_regions_clean('all'), 'all', 'all is the named default');
is(crew::derp_regions_clean('21,8,21'), '8,21', 'a pinned set is deduplicated and sorted');
is(crew::derp_regions_clean(' 8 , 21 '), '8,21', 'spaces around ids are tolerated');
ok(!defined crew::derp_regions_clean('8,x'), 'a non-numeric region is refused');
ok(!defined crew::derp_regions_clean('0'), 'region 0 is refused');
ok(!defined crew::derp_regions_clean('-1'), 'a negative region is refused');

my $map_json = q({"Regions":{
	"8":{"RegionID":8,"RegionCode":"lhr","RegionName":"London","Latitude":51.5,"Nodes":[
		{"Name":"8a","RegionID":8,"HostName":"derp8a.example.com","IPv4":"192.0.2.8","IPv6":"::8","CanPort80":true}
	]},
	"21":{"RegionID":21,"RegionCode":"tor","RegionName":"Toronto","Nodes":[
		{"Name":"21a","RegionID":21,"HostName":"derp21a.example.com","CanPort80":false}
	]},
	"1":{"RegionID":1,"RegionCode":"nyc","RegionName":"New York City","Nodes":[]}
}});

my $list = crew::derp_region_list($map_json);
is_deeply([ map { $_->{'id'} } @{$list} ], [ 1, 8, 21 ], 'the offered regions are the map keyed by id, in order');
is($list->[1]{'code'}, 'lhr', 'a region carries its code for the picker');
is($list->[1]{'name'}, 'London', 'and its name');

my $filtered = crew::_derp_map_filter($map_json, '8,21');
is($filtered->{'regions'}, '8,21', 'the filtered map reports the regions it really keeps');
like($filtered->{'yaml'}, qr/^regions:/m, 'the local map is a YAML regions document');
like($filtered->{'yaml'}, qr/^  8:/m, 'the first chosen region is present');
like($filtered->{'yaml'}, qr/^  21:/m, 'the second chosen region is present');
unlike($filtered->{'yaml'}, qr/^  1:/m, 'an unchosen region is not written');
unlike($filtered->{'yaml'}, qr/RegionID|HostName|CanPort80/, 'the Go field names are lowered for yaml.Unmarshal');
like($filtered->{'yaml'}, qr/regionid: 8/, 'the region id keeps its number');
like($filtered->{'yaml'}, qr/canport80: true/, 'a node boolean keeps its boolean spelling');
like($filtered->{'yaml'}, qr/hostname: "derp8a\.example\.com"/, 'a node hostname is quoted');
unlike($filtered->{'yaml'}, qr/\t/, 'the map is indented with spaces, not tabs');
ok(!defined crew::_derp_map_filter($map_json, '99'), 'a set that left the map is refused rather than written empty');
my $partial = crew::_derp_map_filter($map_json, '8,99');
is($partial->{'regions'}, '8', 'a stale id beside a live one is not reported as served');

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
like($controller, qr/&crew::dispatch\('derp\.public', \{ state => \$state, regions => \$regions \}/,
	'the toggle is placed through the Crew with the chosen regions');
like($controller, qr/setting => 'derp_public_regions'/, 'the page and the status action read the stored region choice');
like($controller, qr/derp_region_catalog/, 'the status action offers the public map\'s regions');

my $template = slurp("$root/templates/apps/network.html.ep");
like($template, qr/id="network_derp_toggle"/, 'the Network page has the relay control');
like($template, qr/data-state="<%= \$derp_public %>"/, 'the control starts from the stored state');
like($template, qr/id="network_derp_regions"/, 'the page has a regions select');
like($template, qr/value="all"/, 'the select offers the closest-region default');
like($template, qr/Closest \(all regions\)/, 'the default is named in the on-screen words');
like($template, qr/\$derp_region_choices/, 'the select is built from the public map\'s regions');

my $js = slurp("$root/public/js/manager/network.js");
like($js, qr/#network_derp_toggle/, 'the script handles a press on the control');
like($js, qr/#network_derp_regions/, 'the script handles a change of regions');
like($js, qr/networkPost\('derp_public'/, 'the press posts to the toggle route');
like($js, qr/networkScrollAnchor/, 'the script saves the scroller before a repaint');
like($js, qr/networkScrollRestoreSoon/, 'and restores it after');
like($js, qr/sessionStorage\.setItem\(network_scroll_key/, 'the anchor survives a full reload');

my $help = slurp("$root/perl/help/topics_web.pl");
like($help, qr/Tailnet relay is the public-relay switch/, 'the help topic explains the control');
like($help, qr/Closest \(all regions\)/, 'the help topic explains the region choice');

done_testing();
