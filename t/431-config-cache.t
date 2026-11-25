# tests-for: lib/JawnOS/Domain/File.pm
# covers:    config_reader must not keep serving a cached config.json snapshot
#            after the file has changed. The cache row lives in the database and
#            cache_get does not check its warranty, so a controller whose
#            config.json gained archive_dir kept reading the old copy and held
#            its automatic sync ("no archive card") until the row was deleted by
#            hand. The cached copy is now keyed to the file it was built from.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Spec ();
use File::Slurp qw(read_file write_file);
use JSON::PP ();
use JawnOS::Platform::Paths ();
use JawnOSTest;

# Load the real definition before the test touches the cache.
subs::preload('config_reader');

my $JSON = JSON::PP->new->canonical(1);
my $store = sandbox();
my $path = JawnOS::Platform::Paths::config_path(root => $subs::install_dir);
isnt($path, File::Spec->catfile(root(), 'config.json'),
	'the live config.json is never the one under test');
# The fork runner gives a test its own install dir but no config.json; seed the
# sandbox's file so the test starts from a realistic config.
write_file($path, read_file(File::Spec->catfile($store, 'config.json'))) unless -e $path;

sub write_config {
	my ($extra) = @_;
	my $config = eval { $JSON->decode(read_file($path)) } || {};
	$config->{$_} = $extra->{$_} for keys %{ $extra || {} };
	write_file($path, $JSON->encode($config));
}

# A cold read caches the sandbox config, which has no archive_dir.
subs::cache_delete({ app => '__president', context => 'config' });
my $cold = subs::config_reader();
is(ref $cold, 'HASH', 'a cold read returns a config');
ok(!defined $cold->{'archive_dir'}, 'the sandbox config starts without an archive_dir');

# The file changes after the cache was written (exactly what a provisioning
# step or a hand edit does). The next read must see the new key.
write_config({ archive_dir => "$store/media/SD" });
my $warm = subs::config_reader();
is($warm->{'archive_dir'}, "$store/media/SD",
	'a config.json that changed after the cache was written is read from the file');

# An unchanged file still rides the cache: a sentinel written into the cached
# snapshot comes back, proving the read did not rebuild it again.
my $cached = subs::cache_get({ app => '__president', context => 'config' });
is(ref $cached, 'HASH', 'the rebuilt config was cached');
$cached->{'sentinel'} = 'kept';
subs::cache_set({ app => '__president', context => 'config', warranty => '-10m' }, $cached);
my $again = subs::config_reader();
is($again->{'sentinel'}, 'kept', 'an unchanged file is served from the cache');
is($again->{'archive_dir'}, "$store/media/SD", 'and still carries the file value');

done_testing();
