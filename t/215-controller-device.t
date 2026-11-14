# tests-for: perl/President.pl
# covers:    A `controller` device (a 1.8 GB handheld launcher and call gateway) rests
#           at two main workers with no autoscale growth, starts no alarm/watch/
#           teletype server, and runs none of the resident background loops that
#           would otherwise add another ~16 MB PSS copy of the ~76 MB tree each.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Every resident loop is a full copy of the ~76 MB Perl app (~16 MB PSS), and
# seventeen of them cost a controller ~273 MB of its 1.8 GB. The loops skipped
# here are passes a launcher/call gateway never runs, so leaving them off buys
# back the memory without changing what the device is for.

my $src = read_file(repo_root() . '/perl/President.pl');
my $workers = read_file(repo_root() . '/lib/JawnOS/Domain/Workers.pm');

# main worker pool: two resting workers, and no +2 growth for a controller
like($workers, qr/\$device eq 'controller' \? 2/,
	'a controller rests at two main workers');

my ($autoscale) = $src =~ /(&server_process\('\.\/perl\/Manager\.pl'.*?&worker_pool_options\('main'\)\).*?;)/s;
ok($autoscale, 'the main pool still takes its range through one call');
like($autoscale, qr/&worker_pool_options\('main'\)/,
	'the pool range is the configured or default one');
my ($max_rule) = $workers =~ /(sub worker_pool_defaults \{.*?return \(\$min, \$max\);)/s;
ok($max_rule, 'the ceiling rule is declared in the worker-pool helper');
like($max_rule, qr/\$device eq 'mobile' \|\| \$device eq 'controller'/,
	'the default ceiling consults the controller and mobile device');
like($max_rule, qr/\$min : \$min \+ 2/,
	'a controller rests at its count; a desktop grows by two');

# A controller gate is `unless ($device eq 'controller') { ... }` indented one
# level out from what it wraps, and its closer is a lone tab + brace. Read a
# registration as gated only if that opener reaches it without crossing a closer.
sub gated_by_controller {
	my ($name) = @_;
	return $src =~ /unless \(\$device eq 'controller'\) \{(?:(?!\n\t\}\n).)*?name => '\Q$name\E'/s;
}

my @skipped = (
	'app release sync',
	'slow loops',
	'house levels',
	'ble adopt scan',
	'ollama serve',
	'Minion Worker',
	'evaluation schedules',
	'evaluation dispatch',
);

for my $name ( @skipped ) {
	ok(gated_by_controller($name), "$name is skipped inside a controller gate");
}

# The alarm pre-fork server is not a named loop but the same memory rule applies.
ok(gated_by_controller('Pro Alarm Server'), 'the alarm pre-fork server is skipped for a controller');

# The loops a controller keeps must not have slipped inside a gate.
ok(!gated_by_controller('whisper server'), 'the whisper server loop still runs on every device');
ok(!gated_by_controller('device mdns sync'), 'the mDNS loop still runs on every device');

my $gates = () = $src =~ /unless \(\$device eq 'controller'\) \{/g;
is($gates, 9, 'nine controller gates: eight loops plus the alarm pool');

done_testing();
