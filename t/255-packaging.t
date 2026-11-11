# tests-for: packaging/ jawn perl/President.pl
# covers:    the packaging manifests. deps.json is the one dependency list; the
#            Debian control and the AUR PKGBUILD must agree with it, the tree
#            installs under /usr/share/jawnos, the writable store is
#            /var/lib/jawnos via JAWNOS_STORE_DIR, and every module the app
#            loads is either a distro package or a named vendored dist.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JSON::PP ();

my $root = "$FindBin::Bin/..";

sub read_file {
	my ($file) = @_;
	open(my $fh, '<', "$root/$file") or die "read $file: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

# --- the manifest drives both files -----------------------------------------
my $check = `$^X "$root/packaging/render_deps.pl" --check 2>&1`;
is($? >> 8, 0, 'the Debian and AUR dependency lists match deps.json')
	or diag($check);

my $deps = JSON::PP->new->decode(read_file('packaging/deps.json'));
is(ref $deps->{'modules'}, 'HASH', 'deps.json has a module map');
is(ref $deps->{'tools'}, 'HASH', 'deps.json has a tool map');

# --- every module the tree loads is accounted for ---------------------------
my $source = read_file('scripts/jawnos_deps.pl');
my ($block) = $source =~ /my \@modules = qw\((.*?)\);/s;
my @modules = split ' ', (defined $block ? $block : '');
ok(scalar @modules > 20, 'the dependency checker names the module set');

for my $module (@modules) {
	ok($deps->{'modules'}{$module}, "$module is in the packaging manifest");
}

# The Dockerfile/README loads these outside @modules; they are part of the
# packaged runtime too.
for my $module (qw(DBI IO::Pty WebService::Ollama Email::Sender Text::Unidecode Clone Compress::Zlib SQL::Abstract::Pg URI::db Crypt::Blowfish FreezeThaw YAML::XS)) {
	ok($deps->{'modules'}{$module}, "$module is in the packaging manifest");
}

# --- the tool list covers the checker's commands ----------------------------
my ($tools_block) = $source =~ /my \@tools = \((.*?)\n\);/s;
my @commands = (defined $tools_block ? $tools_block : '') =~ /cmd\s*=>\s*'([^']+)'/g;
ok(scalar @commands > 10, 'the dependency checker names the tool set');
for my $command (@commands) {
	# cpanm is the checker's self-install path, not a runtime tool: a packaged
	# install never runs it (the vendors are fetched at build time).
	next if $command eq 'cpanm';
	ok($deps->{'tools'}{$command}, "$command is in the packaging manifest");
}

# --- OS packages first; vendor only where the distro has nothing ------------
ok($deps->{'modules'}{'Minion'}{'deb'}, 'Debian packages Minion');
ok(!defined $deps->{'modules'}{'Minion'}{'arch'}, 'Arch does not, so it is vendored');
ok(!defined $deps->{'modules'}{'Mojo::IOLoop::ReadWriteFork'}{'deb'},
	'Debian does not package ReadWriteFork, so it is vendored');
is($deps->{'modules'}{'Crypt::KeyDerivation'}{'provided_by'}, 'CryptX',
	'CryptX-provided names add no package');
ok($deps->{'modules'}{'Digest::SHA'}{'core'}, 'core Perl needs no package');

# --- the layouts ------------------------------------------------------------
my $control = read_file('packaging/debian/control');
like($control, qr/^Architecture: all$/m, 'the Debian package is architecture all');
like($control, qr/^Depends:.*libmojolicious-perl/ms, 'Debian depends on the distro Mojolicious');
like($control, qr/^Depends:.*libdbd-sqlite3-perl/ms, 'and the distro DBD::SQLite');
unlike($control, qr/^Depends:.*libmojo-sqlite-perl.*\n.*libmojo-sqlite-perl/ms,
	'no duplicate dependency names');

my $pkgbuild = read_file('packaging/aur/PKGBUILD');
like($pkgbuild, qr/^arch=\('any'\)$/m, 'the AUR package is any-arch');
like($pkgbuild, qr/^license=\('BSD-2-Clause'\)$/m, 'and carries the licence');
like($pkgbuild, qr/^depends=\([^)]*'perl-mojolicious'/ms, 'AUR depends on Mojolicious');
like($pkgbuild, qr/packaging\/vendor\/fetch\.sh arch/, 'AUR fetches its vendored set');
unlike($pkgbuild, qr/sha256sums=\('SKIP'\)/,
	'the AUR package does not build an unpinned tarball');
like($pkgbuild, qr/pin the release tarball with updpkgsums/,
	'and prepare() says how to pin it');
like($pkgbuild, qr/\$\{sha256sums\[0\]\}" = "SKIP"/,
	'prepare() fails closed while the checksum is still SKIP');

is($deps->{'modules'}{'Net::IMAP::Client'}{'version'}, '0.9511',
	'the vendored IMAP client is pinned to the tested release');

my $install = read_file('packaging/debian/jawnos.install');
like($install, qr/^perl\s/m, 'the Debian package ships the service layer');
like($install, qr/^database\s/m, 'and the factory seed and schema');
like($install, qr/^public\s/m, 'and the front end');
for my $line (split /\n/, $install) {
	my ($source) = split /\s+/, $line;
	next unless defined $source && length $source;
	ok(-e "$root/$source", "the install source $source exists");
}

my $service = read_file('packaging/debian/jawnos.service');
like($service, qr/^WorkingDirectory=\/usr\/share\/jawnos$/m, 'the unit runs from the read-only tree');
like($service, qr/^Environment=JAWNOS_STORE_DIR=\/var\/lib\/jawnos$/m,
	'and writes to the store');
like($service, qr/^Environment=JAWNOS_PACKAGED=1$/m,
	'and skips the dependency installer');
like($service, qr/^Environment=JAWNOS_DEVICE=server$/m,
	'and seeds a server, not a desktop');
like($service, qr{^StandardOutput=append:/var/lib/jawnos/\.local/state/jawnos/jawn-stdout\.log$}m,
	'and writes the supervisor log where jawn seeds it');
like($service, qr{^ExecStartPre=/usr/bin/systemd-tmpfiles --create /usr/lib/tmpfiles\.d/jawnos\.conf$}m,
	'and recreates the store/state dirs before starting');
like($service, qr/^EnvironmentFile=-\/etc\/jawnos\/jawnos\.env$/m,
	'with a package-owned environment file');
like($service, qr/^ExecStart=\/usr\/bin\/perl \/usr\/share\/jawnos\/jawn$/m,
	'and starts jawn from the tree');

my $wrapper = read_file('packaging/common/jawn.wrapper');
like($wrapper, qr/JAWNOS_STORE_DIR:=\/var\/lib\/jawnos/, 'the launcher defaults the store');
like($wrapper, qr/JAWNOS_PACKAGED:=1/, 'and marks the install packaged');
like($wrapper, qr/cd \/usr\/share\/jawnos/, 'and runs from the read-only tree');

like(read_file('jawn'), qr/JAWNOS_PACKAGED/,
	'first run skips the dependency installer when packaged');

my $president = read_file('perl/President.pl');
my $inc = index($president, 'unshift @INC, "$dir/../lib"');
my $minion = index($president, 'use Minion;');
ok($inc >= 0 && $minion >= 0 && $inc < $minion,
	'President puts lib/ on @INC before use Minion (a vendored Minion must be found)');

like(read_file('packaging/debian/jawnos.postinst'), qr/adduser .* jawn/s,
	'postinst creates the service user');
like(read_file('packaging/debian/jawnos.postrm'), qr{__pycache__},
	'postrm clears the runtime Python cache so dpkg can remove the tree');
like(read_file('packaging/debian/jawnos.env'), qr/^JAWNOS_DEVICE=server$/m,
	'the environment file seeds a server');
like(read_file('packaging/debian/jawnos.postinst'), qr{/var/lib/jawnos},
	'postinst creates the store');
like(read_file('packaging/README.md'), qr/JAWNOS_STORE_DIR/,
	'the packaging README explains the store');
like(read_file('packaging/README.md'), qr/yay -S jawnos/,
	'and how the AUR package is installed');

ok(-x "$root/packaging/build_deb.sh", 'build_deb.sh is executable');
ok(-x "$root/packaging/vendor/fetch.sh", 'fetch.sh is executable');
ok(-x "$root/packaging/debian/rules", 'debian/rules is executable');

done_testing();
