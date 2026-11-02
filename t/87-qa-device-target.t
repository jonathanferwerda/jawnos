# tests-for: lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Resolve.pm lib/JawnOS/Manager/Part28.pm perl/President.pl perl/subroutines.pl qa/device_target.pl qa/systemd/jawnos-qa-ux.service qa/systemd/jawnos-qa.service
# covers:    Configure -> Plat -> QA names the machine that runs the nightly suite.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Cwd qw(abs_path);
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use DBI;

# Configure -> Plat -> QA names the machine that runs the nightly suite. The
# rules are what keep a phone out of the role, keep a wrong choice from
# silently disarming the house, and let the panel and the systemd timer read the
# same setting. The install path is exercised dry only: a test must never
# install a package on the machine it runs on.
#
# The domain module is loaded on its own (the same lazy module the app requires
# on the first call) rather than booting subroutines.pl, so this test fails for
# a defect in the QA helpers and not for unrelated work in another part of the
# tree. The loader mapping is checked statically below.
my $root = abs_path("$FindBin::Bin/..");
require JawnOS::Domain::Remote;

no warnings 'redefine', 'once';
*subs::machine_name = sub { 'qa-test-host' };
*subs::home = sub {
	my $path = shift // '';
	$path =~ s{^~}{/tmp/qa-home};
	return $path;
};

# --- eligibility --------------------------------------------------------------
my $self = 'f' x 24;
my @rows = (
	{ uuid => 'u-lap',   signatorial => 'a' x 24, device => 'computer', hostname => 'laptop' },
	{ uuid => 'u-table', signatorial => 'b' x 24, device => 'server',   hostname => 'table' },
	{ uuid => 'u-phone', signatorial => 'c' x 24, device => 'mobile',   hostname => 'phone' },
	{ uuid => 'u-tab',   signatorial => 'd' x 24, device => 'tablet',   hostname => 'pad' },
	{ uuid => 'u-old',   signatorial => 'e' x 24, device => '',         hostname => 'old' },
	{ uuid => 'u-self',  signatorial => $self,    device => 'computer', hostname => 'me' },
);

ok(subs::qa_device_kind_eligible('computer'), 'a computer is eligible');
ok(subs::qa_device_kind_eligible('server'),   'a server is eligible');
ok(!subs::qa_device_kind_eligible('mobile'),  'a phone is not eligible');
ok(!subs::qa_device_kind_eligible('tablet'),  'a tablet is not eligible');
ok(!subs::qa_device_kind_eligible(''),        'an unknown kind is not eligible');

my $offered = subs::qa_target_machines({ rows => \@rows, self => $self });
is_deeply([ map { $_->{'hostname'} } @{$offered} ], [ 'laptop', 'table' ],
	'only computer and server rows are offered, and never this machine');
ok(!grep({ ($_->{'device'} || '') !~ /^(?:computer|server)$/ } @{$offered}),
	'no phone or tablet reaches the picker');

# --- readiness names what is missing -----------------------------------------
my $base = {
	which => sub {
		my ($name) = @_;
		return '' if $name eq 'mkosi';
		return "/usr/bin/$name";
	},
	file_exists => sub { 1 },
	repo => '/srv/jawnos',
	home => '/home/tester',
	install => {},
};
my $r = subs::qa_readiness($base);
ok(ref $r eq 'HASH' && $r->{'ok'}, 'the readiness payload answers');
ok($r->{'ready'}, 'the nightly is ready when every required tool is present');
ok((grep { $_ eq 'mkosi' } @{ $r->{'missing'} || [] }),
	'the payload names mkosi, which is missing');
ok(!(grep { $_ eq 'mkosi' } @{ $r->{'missing_required'} || [] }),
	'mkosi is named as an optional (artefact) tool, not a nightly blocker');
is(scalar(@{ $r->{'checks'} || [] }), 12, 'every readiness check is reported');
my @unlabelled = grep { !length($_->{'label'} || '') } @{ $r->{'checks'} };
is_deeply(\@unlabelled, [], 'every check carries a readable label');

my $blocked = subs::qa_readiness({
	%{$base},
	which => sub {
		my ($name) = @_;
		return '' if $name eq 'prove' || $name eq 'mkosi';
		return "/usr/bin/$name";
	},
});
ok(!$blocked->{'ready'}, 'a missing prove leaves the nightly unready');
ok((grep { $_ eq 'prove' } @{ $blocked->{'missing_required'} || [] }),
	'a missing required tool is named in missing_required');

# --- saving and reading the choice -------------------------------------------
my %store;
my $setter = sub { $store{'value'} = $_[0]; };
my $grabber = sub { $store{'value'} };

my $save = subs::qa_nightly_save('b' x 24, { rows => \@rows, self => $self, device_kind => 'computer', setter => $setter });
ok($save->{'ok'}, 'an eligible server can be chosen');
is($store{'value'}, 'b' x 24, 'the signatorial is what is written');
is(subs::qa_nightly_device({ grabber => $grabber }), 'b' x 24,
	'the saved choice reads back through the same setting');

my $local = subs::qa_nightly_save('', { rows => \@rows, self => $self, device_kind => 'computer', setter => $setter });
ok($local->{'ok'}, 'this machine is a valid choice');
is($store{'value'}, '', 'this machine is stored as the empty local fallback');
is(subs::qa_nightly_device({ grabber => $grabber }), '',
	'the local fallback reads back as an empty choice');

my $phone_local = subs::qa_nightly_save('', { rows => \@rows, self => $self, device_kind => 'mobile', setter => $setter });
ok(!$phone_local->{'ok'}, 'a phone cannot choose itself as the nightly machine');

my $bad = subs::qa_nightly_save('c' x 24, { rows => \@rows, self => $self, device_kind => 'computer', setter => $setter });
ok(!$bad->{'ok'}, 'a phone cannot be chosen');
like($bad->{'error'} || '', qr/computer or server/i, 'the refusal names the eligible kinds');
is($store{'value'}, '', 'a refused save changes nothing');

is(subs::qa_nightly_clean(' ' . ('B' x 24) . ' '), 'b' x 24, 'a stored value is trimmed and lower-cased');
is(subs::qa_nightly_clean('not-a-machine'), '', 'a value that is not a signatorial reads as no choice');

my $remote_source = read_file("$root/lib/JawnOS/Domain/Remote.pm");
my @house_rows = ($remote_source =~ /setting => 'qa_nightly_device', device => 'all'/g);
ok(scalar(@house_rows) >= 2,
	'the choice is written and read as a house setting every machine sees');

# --- the install guard and the dry run ---------------------------------------
my $phone = subs::qa_install_guard('c' x 24, { rows => \@rows, self => $self });
ok(!$phone->{'ok'}, 'install refuses a phone');
like($phone->{'error'} || '', qr/computer or server/i, 'the install refusal says why');

my $unknown = subs::qa_install_guard('9' x 24, { rows => \@rows, self => $self });
ok(!$unknown->{'ok'}, 'install refuses a signatorial that is not on the roster');

my $server = subs::qa_install_guard('b' x 24, { rows => \@rows, self => $self });
ok($server->{'ok'}, 'install accepts an eligible server');
ok(!$server->{'target'}->{'local'}, 'the server is a remote target');

my $here = subs::qa_install_guard('', { rows => \@rows, self => $self });
ok($here->{'ok'} && $here->{'target'}->{'local'}, 'the empty choice is this machine');

my $dry = subs::qa_install_local({
	%{$base},
	which => sub {
		my ($name) = @_;
		return '' if $name eq 'mkosi';
		return "/usr/bin/$name";
	},
	dry_run => 1,
});
ok($dry->{'ok'}, 'the dry install answers');
ok($dry->{'dry_run'}, 'the dry install says it was a dry run');
is($dry->{'state'}, 'planned', 'a dry install only plans');
my @steps = @{ $dry->{'steps'} || [] };
ok((grep { ($_->{'key'} || '') eq 'mkosi' && !$_->{'manual'} } @steps),
	'mkosi gets an install step');
ok((grep { $_->{'manual'} } @steps), 'the checkout/AVD are named as manual where they are missing');

# --- the nightly timer reads the same setting --------------------------------
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Remote.*qa_readiness/, 'the loader maps the readiness helper');
like($loader, qr/JawnOS::Domain::Remote.*qa_install_local/, 'the loader maps the install helper');
my $unit = read_file("$root/qa/systemd/jawnos-qa.service");
like($unit, qr{ExecCondition=/usr/bin/perl /home/jawn/jawnos/qa/device_target\.pl},
	'the nightly unit asks whether this machine is the chosen one');
my $ux_unit = read_file("$root/qa/systemd/jawnos-qa-ux.service");
like($ux_unit, qr{ExecCondition=.*device_target\.pl},
	'the UX night follows the same choice');
is(system($^X, '-c', "$root/qa/device_target.pl"), 0, 'the nightly reader compiles');
my $helper = read_file("$root/qa/device_target.pl");
like($helper, qr/qa_nightly_device/, 'the reader looks for the panel\'s setting');
like($helper, qr/exit 1/, 'an unchosen machine is a skip');

# Run the reader against a throwaway tree: the choice is read from the
# database, this machine's identity from its file, and the result is the exit
# code systemd uses.
my $sqlite3 = `command -v sqlite3 2>/dev/null`;
chomp $sqlite3 if defined $sqlite3;
if ($sqlite3 && length $sqlite3) {
	my $sandbox = tempdir(CLEANUP => 1);
	make_path("$sandbox/qa", "$sandbox/database");
	my $script = read_file("$root/qa/device_target.pl");
	open(my $out, '>', "$sandbox/qa/device_target.pl") or die $!;
	print $out $script;
	close $out;

	my $db = DBI->connect("dbi:SQLite:dbname=$sandbox/database/jawnos.db", '', '',
		{ RaiseError => 1, PrintError => 0 });
	$db->do("create table settings (app text, setting text, device text, value text, server_time text)");

	my $identity = sub {
		my ($sig) = @_;
		open(my $fh, '>', "$sandbox/.jawnos_signatorial_id") or die $!;
		print $fh "$sig\n";
		close $fh;
	};
	my $choose = sub {
		my ($value) = @_;
		$db->do("delete from settings");
		$db->do("insert into settings (app, setting, device, value, server_time) values (?,?,?,?,?)",
			undef, '__president', 'qa_nightly_device', 'all', $value, '1000');
	};
	my $run = sub {
		local $ENV{'HOME'} = $sandbox;
		my $rc = system($^X, "$sandbox/qa/device_target.pl");
		return $rc == -1 ? 255 : ($rc >> 8);
	};

	my $mine = 'b' x 24;
	$identity->($mine);

	$choose->('');
	is($run->(), 0, 'no choice keeps the local fallback running');

	$choose->($mine);
	is($run->(), 0, 'the chosen machine runs its suite');

	$choose->('a' x 24);
	is($run->(), 1, 'another machine is skipped');

	$db->disconnect;
}
else {
	pass('sqlite3 is not installed; the reader run is skipped');
}

# --- the install uses the existing authenticated rail ------------------------
my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure2.pm");
like($controller, qr/remote_command_send\(\{/,
	'the panel install delegates to the peer-verified remote-command rail');
like($controller, qr/qa_install_guard\(/, 'the install action guards eligibility first');
my $remote = read_file("$root/lib/JawnOS/Manager/Part28.pm");
like($remote, qr/qa_install_local/,
	'the target runs the install through its own remote-command executor');

done_testing();
