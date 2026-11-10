# tests-for: lib/JawnOS/Domain/Generate.pm lib/JawnOS/Manager/Part14.pm lib/JawnOS/Manager/Part32.pm templates/apps/transaction/options.html.ep
# covers:    a model/option child started under, or deleted from, a running parent keeps that parent's model/options list in step

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json);
use Mojo::SQLite;

require JawnOS::Domain::Calendar;
require JawnOS::Domain::Generate;
require JawnOS::Manager::Part01;
require JawnOS::Manager::Part20;

# A parent appointment's model and options columns are the list its details
# view reads; source_uuid is only the link to the child session. A manually
# started app that attaches to a running parent must appear in that list, and
# deleting the child must take the entry with it. The helpers touch only an
# entry whose name is the child's app, so the other users of source_uuid (a
# purchase to its transaction, the two legs of a transfer, a browser tab) are
# left alone.

my ($fh, $dbfile) = tempfile('jawnos-source-follow-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table appointments (
	app text, uuid text, type text, timestamp text, server_time text,
	source_uuid text, model text, options text, seen text, stop_seen text,
	stop_timestamp text, duration text, app_uuid text, ost text,
	unit text, quantity text, project text, manufacturer text,
	device text, warranty text, pos text
)');
$db->query('create table settings (
	id integer primary key autoincrement,
	app text, setting text, value text, device text, subsetting text,
	server_time text, timestamp text, uuid text, ost text, browser_tab_id text
)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};

{
	no warnings 'redefine';
	local *Websocket::send = sub { return 1 };
	local *subs::source_header_printer = sub { return 1 };
	local *subs::construct_uuid = sub { return 'test-app-uuid' };
	local *subs::log_writer = sub { diag('log_writer: ' . ($_[0] // '')); return 1 };
	local *Manager::budget_runner = sub { return 1 };

	my $now    = 1_800_000_000_000;
	my $parent = 'parent-uuid-test';
	my $child  = 'child-uuid-test';
	$db->insert('appointments', {
		app         => 'dinner-test',
		uuid        => $parent,
		type        => 'start',
		timestamp   => $now - 60_000,
		server_time => $now - 60_000,
		seen        => 'yes',
		model       => '{"uuid":"model-a","name":"wine-test","quantity":1,"unit":"glass"}',
		options     => '[{"uuid":"option-a","name":"side-test","quantity":1,"unit":"plate"}]',
	});
	$db->insert('appointments', {
		app          => 'wine-test',
		uuid         => $child,
		type         => 'start',
		timestamp    => $now - 30_000,
		server_time  => $now - 30_000,
		source_uuid  => $parent,
	});

	# deleting the child leaves the parent's list
	ok(&subs::source_model_option_remove($parent, 'wine-test', $child, 'start'), 'the delete finds the parent');
	my $row = $db->query('select * from appointments where uuid = ?', $parent)->hash;
	is($row->{'model'}, undef, 'the model entry is gone');
	like($row->{'options'}, qr/side-test/, 'the other option is untouched');

	# a second live child of the same app holds the entry in place
	$db->query('update appointments set model = ? where uuid = ?',
		'{"uuid":"model-a","name":"wine-test"}', $parent);
	$db->insert('appointments', {
		app         => 'wine-test',
		uuid        => 'twin-child-test',
		type        => 'start',
		timestamp   => $now,
		server_time => $now,
		source_uuid => $parent,
	});
	ok(&subs::source_model_option_remove($parent, 'wine-test', $child, 'start'), 'the parent is still there');
	$row = $db->query('select * from appointments where uuid = ?', $parent)->hash;
	like($row->{'model'}, qr/wine-test/, 'the entry stays while a live child of that app remains');

	# starting an app that is an option of a running parent adds it
	ok(&subs::source_model_option_add($parent, 'option', {
		uuid => 'option-b', name => 'side-test', timestamp => $now, quantity => 2, unit => 'plate',
	}), 'the start finds the parent');
	$row = $db->query('select * from appointments where uuid = ?', $parent)->hash;
	my @side = grep { ($_->{'name'} // '') eq 'side-test' && ($_->{'uuid'} // '') eq 'option-b' }
		@{ decode_json($row->{'options'}) };
	is(scalar @side, 1, 'the started option is in the parent list');

	# the same catalog entry twice is still one row
	&subs::source_model_option_add($parent, 'option', {
		uuid => 'option-b', name => 'side-test', timestamp => $now, quantity => 2, unit => 'plate',
	});
	$row = $db->query('select * from appointments where uuid = ?', $parent)->hash;
	@side = grep { ($_->{'name'} // '') eq 'side-test' && ($_->{'uuid'} // '') eq 'option-b' }
		@{ decode_json($row->{'options'}) };
	is(scalar @side, 1, 'adding the same option twice keeps one entry');

	# a start that names a model replaces the parent's single model
	ok(&subs::source_model_option_add($parent, 'model', {
		uuid => 'model-b', name => 'wine-test', timestamp => $now, quantity => 2, unit => 'bottle',
	}), 'the started model finds the parent');
	$row = $db->query('select * from appointments where uuid = ?', $parent)->hash;
	my $model = decode_json($row->{'model'});
	is($model->{'uuid'}, 'model-b', 'the parent now names the running model');

	# adding a model/option to an appointment that has already ended writes a
	# closed record over the parent's span
	my $tea = 'tea-uuid-test';
	$db->insert('appointments', {
		app            => 'tea-test',
		uuid           => $tea,
		type           => 'stop',
		timestamp      => $now - 600_000,
		stop_timestamp => $now - 300_000,
		duration       => -300_000,
		server_time    => $now - 300_000,
		seen           => 'yes',
		stop_seen      => 'yes',
		options        => '[]',
	});
	&subs::source_appt_writer(
		{ name => 'cream-test', unit => 'splash', quantity => 1, characteristics => '[]' },
		{ app => 'tea-test', uuid => $tea, type => 'stop', duration => -300_000, timestamp => $now - 600_000 },
		'option'
	);
	my $cream = $db->query('select * from appointments where app = ?', 'cream-test')->hash;
	ok($cream && $cream->{'uuid'}, 'an option added to a stopped appointment is written');
	is($cream->{'type'}, 'stop', 'as a closed record');
	is(int($cream->{'timestamp'}), $now - 600_000, 'beginning with the parent');
	is(int($cream->{'stop_timestamp'}), $now - 300_000, 'and ending with it');
	is(int($cream->{'duration'}), -300_000, 'over the parent duration');
	is($cream->{'source_uuid'}, $tea, 'linked to the parent');

	# a purchase whose item matches a model keeps that model: it shared
	# source_uuid and the name, but it is not the parent's model session
	my $txn = 'transaction-uuid-test';
	$db->insert('appointments', {
		app         => 'store-test',
		uuid        => $txn,
		type        => 'transaction',
		timestamp   => $now,
		server_time => $now,
		model       => '{"uuid":"model-banana","name":"banana-test"}',
	});
	$db->insert('appointments', {
		app         => 'banana-test',
		uuid        => 'purchase-child-test',
		type        => 'purchase',
		timestamp   => $now,
		server_time => $now,
		source_uuid => $txn,
	});
	&subs::source_model_option_remove($txn, 'banana-test', 'purchase-child-test', 'purchase');
	$row = $db->query('select * from appointments where uuid = ?', $txn)->hash;
	like($row->{'model'}, qr/banana-test/, 'a purchase child does not clear the transaction model');
}

# The delete path detaches a child, and the start path attaches one, in the
# places the behaviour rides.
my $part32 = read_file(root() . '/lib/JawnOS/Manager/Part32.pm');
like($part32, qr/source_model_option_remove\(\$app->\{'source_uuid'\}, \$app->\{'app'\}, \$app->\{'uuid'\}, \$app->\{'type'\}\)/,
	'delete_app detaches the deleted child');
my $part14 = read_file(root() . '/lib/JawnOS/Manager/Part14.pm');
like($part14, qr/source_model_option_add\(\$source_link->\{'parent_uuid'\}, \$source_link->\{'table'\}/,
	'a start that attached a child updates the parent');

my $generate = read_file(root() . '/lib/JawnOS/Domain/Generate.pm');
like($generate, qr/&Manager::budget_runner\(\$done\{'app'\}\);\s*&subs::source_header_printer\(\[\$done\{'app'\}\]/,
	'a retroactive child refreshes the app budget and then rewrites its header');

my $options = read_file(root() . '/templates/apps/transaction/options.html.ep');
my ($option_cell) = $options =~ /(<td class="appointment_option_name.*?<\/td>)/s;
my $open_at = index($option_cell // '', 'appointment_option_open');
my $name_at = index($option_cell // '', '<b>');
ok($open_at >= 0 && $name_at > $open_at,
	'the open button anchors to the left of the option name');

done_testing();
