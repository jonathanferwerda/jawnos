# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm templates/studio/markup.html.ep public/js/manager/studio.js public/js/manager/studio/06_controls.js perl/help/topics_apps.pl
# covers:    Studio's latency backend picker: the route runs the staged engine for one validated
#            backend and relays its JSON, while the browser path stays in the page.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../qa/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use RepoSource qw(repo_root);
use Probe;

my $root = repo_root();

# --- the route is registered and its action exists (the t/58 shape) ----------
my $routes = Probe::routes($root);
my ($route) = grep {
	lc($_->{'method'}) eq 'post' && $_->{'path'} eq '/manager/studio/latency'
} @$routes;
ok($route, 'POST /manager/studio/latency is registered');
is($route->{'action'}, 'action_44022', 'and it names its action') if $route;

require "$root/lib/JawnOS/Controller/manager_misc9.pm";
ok(Manager->can('action_44022'), 'the controller defines action_44022');

# --- a mock engine is a small executable Perl script -------------------------
# The route execs the binary directly, with a fixed list argv, so the fixture is
# a real executable file; its body is whatever this test asks it to print.
sub mock_engine {
	my ($out) = @_;
	my $dir  = tempdir(CLEANUP => 1);
	my $path = "$dir/jawn-audio";
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n";
	print {$fh} "my \$out = <<'ENGINE_OUT';\n$out\nENGINE_OUT\nprint \$out;\n";
	close $fh;
	chmod 0755, $path or die "chmod $path: $!";
	return $path;
}

my $contract = '{"ok":true,"backend":"alsa","device":"hw:1,0","rate":48000,"period":64,"buffer":256,"samples":152,"ms":3.1667,"precision_samples":64,"method":"linked","error":""}';

{
	my $engine = mock_engine("$contract\n");
	local $ENV{JAWNOS_AUDIO_ENGINE} = $engine;
	my ($status, $data) = Manager::studio_latency_engine('alsa');
	is($status, 200, 'a measured engine answers 200');
	is(ref $data, 'HASH', 'and the payload is one object');
	is($data->{'ok'}, 1, 'ok is relayed unchanged');
	is($data->{'ms'}, 3.1667, 'ms is relayed unchanged');
	is($data->{'backend'}, 'alsa', 'the backend is relayed unchanged');
	is($data->{'device'}, 'hw:1,0', 'the device is relayed unchanged');
}

# --- a legitimate failure is a 200 with ok:false, never a number -------------
{
	my $engine = mock_engine('{"ok":false,"backend":"pipewire","error":"device is busy"}' . "\n");
	local $ENV{JAWNOS_AUDIO_ENGINE} = $engine;
	my ($status, $data) = Manager::studio_latency_engine('pipewire');
	is($status, 200, 'the engine ran, so the answer is 200');
	ok(!$data->{'ok'}, 'ok:false is relayed as false');
	is($data->{'error'}, 'device is busy', 'the engine error is relayed');
	ok(!exists $data->{'ms'}, 'a failure carries no number');
}

# --- garbage is a failure, not a crash -------------------------------------
{
	my $engine = mock_engine("this is not JSON\n");
	local $ENV{JAWNOS_AUDIO_ENGINE} = $engine;
	my ($status, $data) = Manager::studio_latency_engine('jack');
	ok($status >= 500, 'unparseable output is a server-side failure');
	ok(!$data->{'ok'}, 'and the payload says so');
	like($data->{'error'}, qr/did not return a measurement/, 'with a readable error');
	ok(!exists $data->{'ms'}, 'and never a number');
}

# --- a backend outside the four is refused before any process starts --------
{
	my $dir      = tempdir(CLEANUP => 1);
	my $sentinel = "$dir/ran";
	my $engine   = "$dir/jawn-audio";
	open(my $fh, '>', $engine) or die "$engine: $!";
	print {$fh} "#!/usr/bin/env perl\n";
	print {$fh} "open(my \$fh, '>', '$sentinel') or die;\nclose \$fh;\n";
	print {$fh} "print qq($contract\\n);\n";
	close $fh;
	chmod 0755, $engine or die "chmod $engine: $!";

	local $ENV{JAWNOS_AUDIO_ENGINE} = $engine;
	my ($status, $data) = Manager::studio_latency_engine('oss');
	is($status, 400, 'an unknown backend is a 400');
	ok(!$data->{'ok'}, 'and it is not a measurement');
	ok(!-e $sentinel, 'no engine process was started');

	my ($js_status, $js_data) = Manager::studio_latency_engine('javascript');
	is($js_status, 400, 'javascript is refused by the route');
	like($js_data->{'error'}, qr/measured in the browser/, 'and the reason names the browser');
	ok(!-e $sentinel, 'javascript starts no engine process either');
}

# --- a missing binary is 503 with the promised sentence --------------------
{
	local $ENV{JAWNOS_AUDIO_ENGINE} = "$root/perl/audio/definitely-not-here";
	my ($status, $data) = Manager::studio_latency_engine('alsa');
	is($status, 503, 'a missing engine is 503, not 500');
	is($data->{'error'}, 'the audio engine is not built on this machine',
		'and says so in the words the page shows');
	ok(!$data->{'ok'}, 'never a measurement');
}

# --- the action renders the same payload and status ------------------------
{
	package FakeStudioController;
	sub new    { my ($class, $backend) = @_; return bless { backend => $backend }, $class }
	sub param  { my ($self, $name) = @_; return $name eq 'backend' ? $self->{'backend'} : undef }
	sub render { my ($self, %args) = @_; $self->{'status'} = $args{'status'}; $self->{'json'} = $args{'json'}; return }
	package main;

	{
		my $engine = mock_engine("$contract\n");
		local $ENV{JAWNOS_AUDIO_ENGINE} = $engine;
		my $fake = FakeStudioController->new('alsa');
		Manager::action_44022($fake);
		is($fake->{'status'}, 200, 'the action uses the helper status');
		is($fake->{'json'}{'ms'}, 3.1667, 'and relays the number');
		is($fake->{'json'}{'backend'}, 'alsa', 'naming the backend');
	}
}

# --- the picker in the page and the help topic -----------------------------
my $js = read_file("$root/public/js/manager/studio.js");
like($js, qr/var studioLatencyBackends = \[ 'javascript', 'alsa', 'pipewire', 'jack' \];/,
	'studio.js names the four backends');
for my $backend (qw(javascript alsa pipewire jack)) {
	like($js, qr/\Q'$backend'\E/, "the picker knows $backend");
}
like($js, qr{url: '/manager/studio/latency'}, 'the picker posts to the route');
like($js, qr/type: 'POST'/, 'and it is a POST');
like($js, qr/data: \{ backend: backend \}/, 'the chosen backend is the only parameter');
like($js, qr/data\.ok === true && typeof data\.ms === 'number'/,
	'a number is shown only when the engine says ok');
like($js, qr/studioLatencyBackends\.indexOf\(backend\) < 0/,
	'an unknown value falls back to the browser probe');

my $controls = read_file("$root/public/js/manager/studio/06_controls.js");
like($controls, qr/#studio_latency_backend.*studioLatencyMeasure/,
	'choosing a backend runs the measurement');

my $markup = read_file("$root/templates/studio/markup.html.ep");
like($markup, qr/<select id="studio_latency_backend"/, 'the page has the picker');
for my $backend (qw(javascript alsa pipewire jack)) {
	like($markup, qr/<option value="\Q$backend\E"/, "the select offers $backend");
}
like($markup, qr/<option value="javascript" selected>/, 'javascript is the default');

my $help = read_file("$root/perl/help/topics_apps.pl");
my ($studio_topic) = $help =~ /(\$topic\{'studio'\} = \{.*?\n\t\};)/s;
ok($studio_topic, 'the studio help topic is found');
like($studio_topic, qr/backend picker/, 'and it explains the backend picker');
like($studio_topic, qr/ALSA, PipeWire or JACK/, 'naming the native choices in on-screen words');

done_testing();
