# tests-for: scripts/platform_probe.pl lib/JawnOS/Platform.pm
# covers:    the probe's two outputs (JSON and human) and its --check verdict.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);
use Test::More;

sub run_probe {
	my (@args) = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, 'scripts/platform_probe.pl', @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

my ($json_status, $json_out, $json_err) = run_probe('--json');
is($json_status, 0, 'the JSON probe exits 0');
my $data = eval { JSON::PP->new->decode($json_out) };
ok($data, 'the JSON probe is valid JSON') or diag($json_err);
is(ref $data, 'HASH', 'the JSON report is an object');
is($data->{'os'}, $^O, 'the report names this OS');
ok(exists $data->{'portable'}, 'the report carries portable mode');
ok(exists $data->{'capabilities'} || exists $data->{'modules'}, 'the report carries capabilities');
is(ref $data->{'modules'}, 'HASH', 'the module state is an object');
is(ref $data->{'tools'}, 'HASH', 'the tool state is an object');
is(ref $data->{'serial_devices'}, 'ARRAY', 'the serial list is an array');
ok(exists $data->{'missing_required'}, 'the report names missing required modules');

my ($text_status, $text_out) = run_probe();
is($text_status, 0, 'the human probe exits 0');
like($text_out, qr/^JawnOS platform probe/m, 'the human probe has a heading');
like($text_out, qr/^os: /m, 'the human probe names the OS');
like($text_out, qr/^transport: /m, 'the human probe names the transport');
like($text_out, qr/^modules:/m, 'the human probe lists modules');
like($text_out, qr/^tools:/m, 'the human probe lists tools');

my ($check_status) = run_probe('--check');
ok($check_status == 0 || $check_status == 1, '--check returns a verdict, not a crash');

done_testing();
