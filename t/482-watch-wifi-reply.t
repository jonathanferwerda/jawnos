# tests-for: lib/JawnOS/Domain/Say.pm perl/watch.pl lib/JawnOS/Domain/Loader.pm
# covers:    A watch on WiFi with no BLE bridge collects its answer from
#           /watch/reply. watch_reply parks the words as soon as a clip that
#           arrived over WiFi has an answer, and watch_reply_wifi adds the
#           rendered WAV id when Piper finishes. The poll hands the text over
#           once and the id once (together when both are ready), clears the
#           entry, refuses one older than the window, and keeps two watches
#           apart. The route is authorized like the clip route and is in the
#           loader map, so a worker that only serves the poll can load Say.pm.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JSON::PP qw(encode_json);

use JawnOSTest;

require(root() . '/lib/JawnOS/Domain/Say.pm');

my $root = root();

ok(subs::provides('watch_pending_reply_put'), 'the parking helper is in the domain loader');
ok(subs::provides('watch_pending_reply_take'), 'the taking helper is in the domain loader');

my $tmp = tempdir(CLEANUP => 1);
{
	no warnings 'redefine';
	local *subs::home = sub {
		my $p = shift // '';
		$p =~ s{^~(?=/|$)}{$tmp};
		return $p;
	};

	# the words arrive first, and are handed over exactly once
	subs::watch_pending_reply_put({ chip_id => 'watch-a' }, text => 'Hello there.');
	my $one = subs::watch_pending_reply_take('watch-a');
	is($one->{'text'}, 'Hello there.', 'the parked words are handed over');
	ok(!$one->{'id'}, 'with no audio id before Piper has rendered');
	my $again = subs::watch_pending_reply_take('watch-a');
	ok($again->{'wait'} && !$again->{'text'}, 'a second poll does not repeat the words');

	# the id follows, is handed over once, and clears the entry
	subs::watch_pending_reply_put({ chip_id => 'watch-a' }, id => 'abc123', base => 'https://house:3000');
	my $audio = subs::watch_pending_reply_take('watch-a');
	is($audio->{'id'}, 'abc123', 'the rendered WAV id is handed over');
	is($audio->{'base'}, 'https://house:3000', 'with the base the watch fetches from');
	ok(subs::watch_pending_reply_take('watch-a')->{'wait'}, 'and it is cleared after one fetch');

	# both halves ready together: the watch gets them in one response
	subs::watch_pending_reply_put({ chip_id => 'watch-b' }, text => 'Both ready.');
	subs::watch_pending_reply_put({ chip_id => 'watch-b' }, id => 'def456', base => 'https://house:3000');
	my $both = subs::watch_pending_reply_take('watch-b');
	is($both->{'text'}, 'Both ready.', 'text and id can arrive together');
	is($both->{'id'}, 'def456', 'and neither is left behind');

	# a stale entry is not a live turn
	my $old_file = subs::watch_pending_reply_file('watch-old');
	write_file($old_file, encode_json({ ts => subs::rightNow() - 200000, text => 'Stale.' }));
	ok(subs::watch_pending_reply_take('watch-old')->{'wait'}, 'an entry older than the window is refused');
	ok(!-e $old_file, 'and removed');

	# one watch never sees another's answer
	subs::watch_pending_reply_put({ chip_id => 'watch-c' }, text => 'For C.');
	ok(subs::watch_pending_reply_take('watch-d')->{'wait'}, 'another chip sees nothing');
	is(subs::watch_pending_reply_take('watch-c')->{'text'}, 'For C.', 'and its own answer is still there');
}

# ------------------------------------------------------------ the wiring
my $say = read_file("$root/lib/JawnOS/Domain/Say.pm");
like($say, qr/\$meta->\{'peer_ip'\}[\s\S]{0,240}?watch_pending_reply_put\(\$meta, text => \$text\)/,
	'a clip that arrived over WiFi parks its reply for the poll');
like($say, qr/device_reply_wav\(\$text\)[\s\S]{0,400}?watch_pending_reply_put\([\s\S]{0,120}?id => \$id/,
	'the rendered WAV id is parked when Piper finishes');

my $watch = read_file("$root/perl/watch.pl");
like($watch, qr/get '\/watch\/reply' =>/, 'the watch reply route exists');
like($watch, qr/embeddedAuthorizer[\s\S]{0,200}?watch_pending_reply_take/,
	'and is authorized like the clip route before it hands anything over');

done_testing();
