# tests-for: lib/JawnOS/Manager/Part28.pm
# covers:    A spoken "play" names an album or a track, not just a bag of words:
#            an album query plays only that album in order, a song query starts
#            its album at that song, and an artist-only query still plays the
#            artist. The library is a folder walk, so the fixtures are paths.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib", "t/lib";
use Test::More;
no warnings 'once';

require JawnOS::Manager::Part28;

# A Music window's URL is only read for its port; the resolver itself never
# touches the request.
package FakeC;
sub req { return bless {}, 'FakeReq' }
package FakeReq;
sub url { return bless {}, 'FakeUrl' }
package FakeUrl;
sub base { return bless {}, 'FakeBase' }
package FakeBase;
sub port { return 3000 }
package main;

# Give help_music_file a fixture library in place of the live folder walk. The
# other stubs are the house helpers it calls while assembling the request.
sub play {
	my ($q, @files) = @_;
	my $c = bless {}, 'FakeC';
	no warnings 'redefine';
	local *Manager::music_search = sub { return { files => [@files] } };
	local *Manager::misc_setting_list = sub { return {} };
	local *Manager::music_machine_settings = sub { return { music_location => '/music' } };
	local *Manager::help_media_revealed = sub { return 0 };
	local *Manager::media_unlock_device = sub { return '' };
	local *subs::settings_grabber = sub { return {} };
	local *subs::setting_grabber = sub { return 30 };
	return Manager::help_music_file($c, $q, 0);
}

my $root = '/music';

# Ben Folds Five, two albums, in walk order.
my @whatever = (
	"$root/Ben Folds Five/Whatever and Ever Amen/01 One Angry Dwarf and 200 Solemn Faces.mp3",
	"$root/Ben Folds Five/Whatever and Ever Amen/02 Kate.mp3",
	"$root/Ben Folds Five/Whatever and Ever Amen/03 Battle of Who Could Care Less.mp3",
	"$root/Ben Folds Five/Whatever and Ever Amen/04 Brick.mp3",
	"$root/Ben Folds Five/Whatever and Ever Amen/05 Song for the Dumped.mp3",
);
my @messner = (
	"$root/Ben Folds Five/The Unauthorized Biography of Reinhold Messner/01 Narrative Song.mp3",
	"$root/Ben Folds Five/The Unauthorized Biography of Reinhold Messner/02 Army.mp3",
	"$root/Ben Folds Five/The Unauthorized Biography of Reinhold Messner/03 Your Most Valuable Possession.mp3",
);
my @acdc = (
	"$root/AC&DC/Back in Black/01 Hells Bells.mp3",
	"$root/AC&DC/Back in Black/02 Shoot to Thrill.mp3",
);
my @all = (@whatever, @messner, @acdc);

# --- an artist only is still every track by that artist --------------------
my $r = play('Ben Folds Five', @all);
is($r->{'found'}, 8, 'an artist-only query finds all eight Ben Folds Five tracks');
is_deeply([ sort @{ $r->{'files'} } ], [ sort(@whatever, @messner) ],
	'and it does not lose an album or pull in another artist');

# --- an album plays only that album, in album order ------------------------
$r = play('Ben Folds Five Whatever and Ever Amen', @all);
is_deeply($r->{'files'}, \@whatever,
	'an artist and album query returns only that album, in order');
is($r->{'same_order'}, 1, 'and keeps its order in the player');

$r = play('whatever & ever amen', @all);
is_deeply($r->{'files'}, \@whatever,
	'a bare album title is enough when it is unambiguous, and "&" means "and"');

$r = play('BEN FOLDS FIVE - WHATEVER, AND EVER AMEN!', @all);
is_deeply($r->{'files'}, \@whatever,
	'case and punctuation do not hide the album');

# --- a song starts its album at that track ---------------------------------
$r = play('Ben Folds Five Army', @all);
is_deeply($r->{'files'}, [ $messner[1], $messner[2] ],
	'a song query puts the song first and carries on through its album');
is($r->{'file'}, $messner[1], 'and names the song as the file to start');
is($r->{'same_order'}, 1, 'with the order preserved');

$r = play('brick', @all);
is_deeply($r->{'files'}, [ $whatever[3], $whatever[4] ],
	'a bare, unique song title also starts at that song and continues');

# --- a lone file is not an album: the old single-file answer stays ---------
my @loose = ("$root/Loose/Only Song.mp3");
$r = play('Only Song', @loose);
is_deeply($r->{'files'}, \@loose, 'a track with no album behind it is played alone');

# --- two albums with one title are not guessed between ---------------------
my @hits_a = ("$root/Artist A/Greatest Hits/01 First.mp3");
my @hits_b = ("$root/Artist B/Greatest Hits/01 Second.mp3");
$r = play('Greatest Hits', @hits_a, @hits_b);
is_deeply([ sort @{ $r->{'files'} } ], [ sort(@hits_a, @hits_b) ],
	'two albums sharing a title keep the broader answer instead of a guess');

done_testing();
