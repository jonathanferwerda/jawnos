# tests-for: lib/JawnOS/Domain/Remotes.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Routes/manager_embedded.pm perl/watch.pl
# covers:    the IR remote store: validation, the settings row it lives on,
#            named delete, replay frame shape, the learn frame, the /watch/ir
#            capture route on the arm listener and the five manager route rows.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;

for my $name (qw(
	remote_store_read remote_store_add remote_store_delete remote_send remote_learn_start
)) {
	subs::preload($name);
}

my $EDT  = 'microcontroller';
my $CHIP = 'chipA';
my $KEY  = "$EDT|remotes|$CHIP";

# The settings row the store lives on, and the writes it made.
my (%settings, @writes);
my $grab = sub {
	my ($q) = @_;
	my $key = join('|', map { defined $q->{$_} ? $q->{$_} : '' } qw(app setting subsetting));
	return $settings{$key};
};
my $set = sub {
	my ($q) = @_;
	my $key = join('|', map { defined $q->{$_} ? $q->{$_} : '' } qw(app setting subsetting));
	$settings{$key} = $q->{'value'};
	push @writes, $q;
	return 1;
};

subtest 'add validates the name and the sequence, then saves the capture' => sub {
	%settings = ();
	@writes   = ();
	local *subs::setting_grabber = $grab;
	local *subs::setting_setter = $set;
	local *subs::rightNow = sub { 1700000000000 };

	my @bad_name = ('', '   ', 'x' x 61);
	my @label    = ('an empty name', 'a whitespace-only name', 'a name over 60 characters');
	for my $i (0 .. $#bad_name) {
		my $r = subs::remote_store_add({
			edt => $EDT, chip_id => $CHIP, pin => 15,
			seq => '400,1200', name => $bad_name[$i],
		});
		ok(!$r->{'ok'}, "$label[$i] is refused");
		ok($r->{'error'}, "$label[$i] names the reason");
	}

	my $bad_seq = subs::remote_store_add({
		edt => $EDT, chip_id => $CHIP, pin => 15,
		seq => 'abc,def', name => 'television',
	});
	ok(!$bad_seq->{'ok'}, 'a sequence that is not numbers is refused');
	ok($bad_seq->{'error'}, 'and names the reason');

	my $good = subs::remote_store_add({
		edt => $EDT, chip_id => $CHIP, pin => 15,
		seq => '400,1200,400', name => '  television power  ',
	});
	ok($good->{'ok'}, 'a good capture is accepted');
	is($good->{'name'}, 'television power', 'the name is trimmed');

	my $read = subs::remote_store_read($EDT, $CHIP);
	is($read->{'television power'}->{'seq'}, '400,1200,400', 'remote_store_read returns the sequence');
	is($read->{'television power'}->{'pin'}, 15, 'and the pin as a number');
	ok($read->{'television power'}->{'learned_at'}, 'and a learned_at stamp');

	is(scalar @writes, 1, 'one settings write');
	is($writes[0]->{'app'}, $EDT, 'written under the board class');
	is($writes[0]->{'setting'}, 'remotes', 'under the remotes setting');
	is($writes[0]->{'subsetting'}, $CHIP, 'keyed by the chip');
	my $written = eval { decode_json($writes[0]->{'value'}) } || {};
	is($written->{'television power'}->{'seq'}, '400,1200,400',
		'the JSON handed to setting_setter round-trips through remote_store_read');
	is(scalar keys %{$written}, 1, 'only the added entry is in the row');

	my $no_chip = subs::remote_store_add({ edt => $EDT, pin => 15, seq => '1', name => 'x' });
	ok(!$no_chip->{'ok'}, 'a capture with no chip is refused');

	my $bad_pin = subs::remote_store_add({
		edt => $EDT, chip_id => $CHIP, pin => 30, seq => '1', name => 'x',
	});
	ok(!$bad_pin->{'ok'}, 'a pin outside 0..29 is refused');

	my $pending = subs::remote_store_add({
		edt => $EDT, chip_id => $CHIP, pin => 7, seq => '100,200',
		name => 'learning', pending => 1,
	});
	ok($pending->{'ok'}, 'a capture can be stored as pending');
	my $after = subs::remote_store_read($EDT, $CHIP);
	is($after->{'learning'}->{'pending'}, 1, 'the pending flag rides the entry');
};

subtest 'delete removes only the named entry' => sub {
	%settings = ();
	@writes   = ();
	local *subs::setting_grabber = $grab;
	local *subs::setting_setter = $set;
	local *subs::rightNow = sub { 1700000000000 };

	subs::remote_store_add({ edt => $EDT, chip_id => $CHIP, pin => 4,  seq => '100,200', name => 'one' });
	subs::remote_store_add({ edt => $EDT, chip_id => $CHIP, pin => 5,  seq => '300,400', name => 'two' });

	my $deleted = subs::remote_store_delete({ edt => $EDT, chip_id => $CHIP, name => 'one' });
	ok($deleted->{'ok'}, 'the named entry is deleted');

	my $read = subs::remote_store_read($EDT, $CHIP);
	ok(!exists $read->{'one'}, 'the deleted entry is gone');
	ok(exists $read->{'two'}, 'the other entry is untouched');
	is($read->{'two'}->{'seq'}, '300,400', 'and still carries its sequence');

	my $unknown = subs::remote_store_delete({ edt => $EDT, chip_id => $CHIP, name => 'nope' });
	ok(!$unknown->{'ok'}, 'deleting an unknown name is refused');
	ok($unknown->{'error'}, 'and names the reason');
};

subtest 'send refuses an unknown name and writes the IR frame' => sub {
	%settings = ();
	@writes   = ();
	my @frames;
	$settings{$KEY} = encode_json({
		'television power' => { seq => '400,1200,400', pin => 15, app => '', learned_at => 1 },
	});
	local *subs::setting_grabber = $grab;
	local *subs::setting_setter = $set;
	local *subs::device_ws_write_frame = sub {
		my ($chip_id, $frame) = @_;
		push @frames, [ $chip_id, $frame ];
		return 1;
	};
	local *subs::random_string_creator = sub { 'ir-uuid' };
	local *subs::rightNow = sub { 1700000000000 };

	my $unknown = subs::remote_send({ edt => $EDT, chip_id => $CHIP, name => 'nope' });
	ok(!$unknown->{'ok'}, 'an unknown remote is refused');
	ok($unknown->{'error'}, 'and names the reason');
	is(scalar @frames, 0, 'no frame is written for an unknown name');

	my $sent = subs::remote_send({
		edt => $EDT, chip_id => $CHIP, name => 'television power', appt_uuid => 'apt-1',
	});
	ok($sent->{'ok'}, 'a known remote is sent');
	is($sent->{'pin'}, 15, 'the reply states the pin');
	is($sent->{'name'}, 'television power', 'and the name');
	is($sent->{'sent'}, 1, 'the socket write is reported');

	is(scalar @frames, 1, 'one frame is written');
	is($frames[0]->[0], $CHIP, 'the frame names the board');
	my $frame = $frames[0]->[1];
	is($frame->{'t'}, 'cmd', 'it is a command frame');
	is($frame->{'component'}, 'ir', 'with the IR component');
	is($frame->{'pin'}, 15, 'the stored pin');
	is($frame->{'code'}, '400,1200,400', 'the exact stored sequence');
	is($frame->{'when'}, 'now', 'asked to play now');
	is($frame->{'appt_uuid'}, 'apt-1', 'the appointment rides the frame');
	is($frame->{'uuid'}, 'ir-uuid', 'a fresh uuid is attached');
};

subtest 'learn_start validates the pin and the window and writes the learn frame' => sub {
	my @frames;
	local *subs::device_ws_write_frame = sub {
		my ($chip_id, $frame) = @_;
		push @frames, [ $chip_id, $frame ];
		return 1;
	};

	for my $pin (-1, 30, 'x') {
		my $r = subs::remote_learn_start({ edt => $EDT, chip_id => $CHIP, pin => $pin, ms => 5000 });
		ok(!$r->{'ok'}, "pin '$pin' is refused");
		ok($r->{'error'}, "pin '$pin' names the reason");
	}
	for my $ms (499, 10001) {
		my $r = subs::remote_learn_start({ edt => $EDT, chip_id => $CHIP, pin => 4, ms => $ms });
		ok(!$r->{'ok'}, "ms '$ms' is refused");
	}
	my $no_chip = subs::remote_learn_start({ edt => $EDT, pin => 4, ms => 5000 });
	ok(!$no_chip->{'ok'}, 'a learn with no chip is refused');
	is(scalar @frames, 0, 'invalid requests write no frame');

	my $started = subs::remote_learn_start({ edt => $EDT, chip_id => $CHIP, pin => 4, ms => 5000 });
	ok($started->{'ok'}, 'a valid learn starts');
	is($started->{'sent'}, 1, 'and reports the socket write');
	is(scalar @frames, 1, 'one learn frame');
	is($frames[0]->[0], $CHIP, 'to the board');
	is($frames[0]->[1]->{'t'}, 'learn', 'the frame is a learn');
	is($frames[0]->[1]->{'pin'}, 4, 'on the asked pin');
	is($frames[0]->[1]->{'ms'}, 5000, 'for the asked window');

	@frames = ();
	subs::remote_learn_start({ edt => $EDT, chip_id => $CHIP, pin => 4 });
	is($frames[0]->[1]->{'ms'}, 5000, 'the window defaults to 5000 ms');
};

subtest 'the route rows exist and each action is named for its id' => sub {
	require JawnOS::Routes::manager_embedded;

	my @embedded = JawnOS::Routes::manager_embedded->routes;
	my %by = map { $_->[1] . ' ' . $_->[2] => $_ } @embedded;
	my @want = (
		[ 'get',  '/manager/embedded/remotes' ],
		[ 'post', '/manager/embedded/remote_learn' ],
		[ 'post', '/manager/embedded/remote_save' ],
		[ 'post', '/manager/embedded/remote_send' ],
		[ 'post', '/manager/embedded/remote_delete' ],
	);
	for my $w ( @want ) {
		my $row = $by{ $w->[0] . ' ' . $w->[1] };
		ok($row, "$w->[1] has a route row");
		next unless $row;
		is($row->[3], 'action_' . $row->[0], "$w->[1] names its action after its id");
	}

	# The rows are only real if the controller defines the sub they name.
	my $embedded_src = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_embedded.pm");
	for my $row ( @want ) {
		my $r = $by{ $row->[0] . ' ' . $row->[1] };
		like($embedded_src, qr/^sub \Q$r->[3]\E\b/m, "$r->[3] exists in manager_embedded.pm");
	}
};

subtest 'the capture route rides the arm listener, where a board posts' => sub {
	# A board POSTs its IR capture to its homebase's ARM port, so /watch/ir
	# belongs in watch.pl beside /watch/switch and /watch/time. A Manager-only
	# route row would answer on a listener the board never dials.
	my $watch_pl = read_file("$FindBin::Bin/../perl/watch.pl");
	like($watch_pl, qr{^post '/watch/ir' => sub}m, '/watch/ir is served by watch.pl');
	like($watch_pl, qr{my \$raw = \$c->req->body}, 'the capture is read as a JSON body');
	like($watch_pl, qr{remote_store_add}, 'and stored on the board remotes');
};

subtest 'the HTTP fallback dials the board route that exists' => sub {
	# The board's local web server serves /relay (it accepts component=ir with
	# the code in `code`); there is no /ir route, so dialling one only ever
	# produced a 404 for a board with no /device/ws socket.
	my $remotes = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Remotes.pm");
	like($remotes, qr{'/relay'}, 'remote_send_http posts to /relay');
	unlike($remotes, qr{'/ir'}, 'and not to a route the board does not serve');
};

done_testing();
