# tests-for: lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Backup.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Part17.pm lib/JawnOS/Controller/manager_misc9.pm
# covers:    The Studio's saved pedalboard library is one library for the house.
#            A local save lands on the house row (`warranty_device()`), the
#            reads prefer that row, the sync digest treats it as a trigger and
#            the merge keeps it house-wide. `pedal_zoom` and every other setting
#            the protected `studio` app holds stay local to the machine.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root   = repo_root();
my $name   = read_file("$root/lib/JawnOS/Domain/Name.pm");
my $backup = read_file("$root/lib/JawnOS/Domain/Backup.pm");
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
my $part17 = read_file("$root/lib/JawnOS/Manager/Part17.pm");
my $studio_controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");

# The source of one `sub`, from its `sub NAME` line up to the next one.
sub sub_source {
	my ($src, $wanted) = @_;
	my ($body) = $src =~ /(^sub\s+\Q$wanted\E\b.*?)(?=^sub\s+|\z)/ms;
	return defined $body ? $body : '';
}

# Collapse whitespace so an assertion reads the code, not its line breaks.
sub flat {
	my ($text) = @_;
	$text =~ s/\s+/ /g;
	return $text;
}

my $helper  = flat(sub_source($name, 'studio_shared_setting'));
my $merge_helper = flat(sub_source($name, 'studio_pedalboards_merge'));
my $setter  = flat(sub_source($name, 'setting_setter'));
my $grabber = flat(sub_source($name, 'setting_grabber'));
my $multi   = flat(sub_source($name, 'settings_grabber'));
my $durable = flat(sub_source($backup, 'durable_settings_where'));
my $merge   = flat($part17);
my $studio_action = flat(sub_source($studio_controller, 'action_28412'));

# --- the helper exists, is narrow, and is mapped ----------------------------
ok(length $helper, 'Name.pm defines studio_shared_setting');
like(
	$helper,
	qr/\$app eq 'studio' && \$setting eq 'pedalboards'/,
	'the helper matches exactly studio/pedalboards'
);
unlike($helper, qr/pedal_zoom/, 'pedal_zoom is deliberately not shared');

# --- the per-board merge ----------------------------------------------------
# The page saves the whole list, so the write gate must union it with the house
# row by board name; a later `used` stamp is the copy that wins.
ok(length $merge_helper, 'Name.pm defines studio_pedalboards_merge');
like(
	$merge_helper,
	qr/my \$used = \(defined \$entry->\{'used'\}[\s\S]{0,240}?\$entry->\{'used'\} \+ 0 : 0/,
	'a board\'s own used stamp is the comparison'
);
like(
	$merge_helper,
	qr/if \(!\$held \|\| \$event > \$held_event/,
	'the newer event for a name replaces the older one'
);
like(
	$merge_helper,
	qr/return \[ sort \{ \(\$b->\{'used'\} <=> \$a->\{'used'\}\) \|\| \(\$a->\{'name'\} cmp \$b->\{'name'\}\) \} values %board \];/,
	'the merged library is newest-used first, then by name'
);
my $merged = subs::studio_pedalboards_merge(
	[ { name => 'Alpha', used => 100, chain => [ { name => 'distortion' } ] }, { name => 'Beta', used => 50 } ],
	[ { name => 'Alpha', used => 90, chain => [] }, { name => 'Gamma', used => 300 } ]
);
is(scalar @{$merged || []}, 3, 'two libraries merge by board name');
is($merged->[0]->{'name'}, 'Gamma', 'the newest board comes first');
my %merged_by = map { $_->{'name'} => $_ } @{$merged || []};
is($merged_by{'Alpha'}->{'used'}, 100, 'the newer copy of Alpha wins');
is_deeply($merged_by{'Alpha'}->{'chain'}, [ { name => 'distortion' } ], 'and it brings its chain');
is_deeply(subs::studio_pedalboards_merge(undef, []), [], 'an empty library is a valid answer');
is(subs::studio_pedalboards_merge(undef, undef), undef, 'no library at all is not a list');

require JawnOS::Domain::Loader;
ok(subs::provides('studio_shared_setting'), 'the domain loader provides the new helper');
ok(subs::provides('studio_pedalboards_merge'), 'and the per-board merger');
like(
	$loader,
	qr/JawnOS::Domain::Name'\s+for\s+qw\([^)]*\bstudio_shared_setting\b/s,
	'studio_shared_setting is mapped to Domain::Name'
);
like(
	$loader,
	qr/JawnOS::Domain::Name'\s+for\s+qw\([^)]*\bstudio_pedalboards_merge\b/s,
	'studio_pedalboards_merge is mapped to Domain::Name'
);

# --- a local save lands on the house row ------------------------------------
like(
	$setter,
	qr/\$dev = &warranty_device\(\) if !\$sync && &studio_shared_setting\(\$app, \$setting\)/,
	'setting_setter sends a local studio-shared write to warranty_device()'
);
like(
	$setter,
	qr/&studio_pedalboards_merge\(/,
	'setting_setter merges a pedalboard write with the house row'
);
like(
	$setter,
	qr/\$settings->\{'server_time'\} = &rightNow\(\);/,
	'a changed merged library is stamped with this write, not the peer row time'
);
like(
	$setter,
	qr/if \(defined \$old_encoded && \$old_encoded eq \$encoded\)/,
	'an unchanged library is not written again'
);
like(
	$setter,
	qr/ref \$new_list ne 'ARRAY'/,
	'a malformed incoming library never wipes a good one'
);

# --- a read with no device asks the house row -------------------------------
like(
	$grabber,
	qr/my \$studio_house = \(&studio_shared_setting\(\$app, \$settings->\{'setting'\}\) && !\$device_defined\)/,
	'setting_grabber asks the house row for a studio-shared setting'
);
like(
	$grabber,
	qr/\$settings->\{'device'\} = &warranty_device\(\) if \$warranty_house \|\| \$studio_house/,
	'the studio-shared read uses warranty_device()'
);

# --- settings_grabber overlays the house row --------------------------------
like($multi, qr/\(\$app \/\/ ''\) eq 'studio'/, 'settings_grabber looks at app studio');
like(
	$multi,
	qr/&db_raw\('select value from settings where app=\? and device=\? and setting=\?', 'studio', &warranty_device\(\), 'pedalboards'\)/,
	'settings_grabber reads the house pedalboards row'
);
like(
	$multi,
	qr/\$returner->\{'pedalboards'\} = \$house->\[-1\]->\{'value'\}/,
	'the house row wins for pedalboards in settings_grabber'
);

# --- the digest treats the shared library as a sync trigger -----------------
like(
	$durable,
	qr/or \(app = 'studio' and setting = 'pedalboards'\)/,
	'durable_settings_where lets the studio library start a sync'
);
unlike($durable, qr/studio.*pedal_zoom/s, 'the rest of studio stays out of the digest');

# --- the merge lets the shared row through, house-wide ----------------------
like(
	$merge,
	qr/my \$studio_setting = \(\(\$r->\{'app'\} \/\/ ''\) eq 'studio'\)/,
	'Part17 names a studio setting for the shared flag'
);
like(
	$merge,
	qr/my \$studio_shared = \(\$studio_setting eq 'pedalboards'\) \? 1 : 0/,
	'Part17 flags only pedalboards as shared'
);
like(
	$merge,
	qr/!\$cards_shared && !\$clothesline_shared && !\$studio_shared/,
	'Part17 lets the studio library past the protected-app guard'
);
like(
	$merge,
	qr/scalar @\{\$time_check\} == 0 \|\| \$heal \|\| \$studio_shared/,
	'Part17 considers an older peer row so its boards can still merge'
);

# --- an older library migrates onto the house row when Studio opens ---------
# The setting was per-device before this change. The Studio page publishes what
# it already shows once, but never overwrites a house row that is already there.
like(
	$studio_action,
	qr/if \(defined \$settings->\{'pedalboards'\} && length \$settings->\{'pedalboards'\}\)/,
	'the Studio page checks for a local library to publish'
);
like(
	$studio_action,
	qr/&subs::setting_grabber\(\{ app => 'studio', setting => 'pedalboards', device => &subs::warranty_device\(\) \}\)/,
	'it asks the house row before writing'
);
like(
	$studio_action,
	qr/if \(!defined \$house \|\| !length \$house\)/,
	'and writes only when the house row is absent'
);
like(
	$studio_action,
	qr/\$settings = &subs::settings_grabber\(\{ app => 'studio' \}\) if \$data->\{'settings'\};/,
	'a save answers with the house library after the merge'
);

# --- a delete is a tombstone, not an absence --------------------------------
my $tomb = subs::studio_pedalboards_merge(
	[ { name => 'Gone', used => 100, chain => [ { name => 'delay' } ] } ],
	[ { name => 'Gone', deleted => 200 } ]
);
is($tomb->[0]->{'name'}, 'Gone', 'the deleted name stays in the library');
ok(exists $tomb->[0]->{'deleted'}, 'as a tombstone');
is($tomb->[0]->{'deleted'}, 200, 'with its delete stamp');
my $revived = subs::studio_pedalboards_merge(
	[ { name => 'Gone', deleted => 200 } ],
	[ { name => 'Gone', used => 300, chain => [ { name => 'drive' } ] } ]
);
ok(!exists $revived->[0]->{'deleted'}, 'a save after the delete revives the board');
is($revived->[0]->{'used'}, 300, 'at its new save time');
is_deeply($revived->[0]->{'chain'}, [ { name => 'drive' } ], 'with the new chain');
like($merge_helper, qr/my \$deleted = /, 'the merger reads a tombstone stamp');
like($merge_helper, qr/\$event = defined \$deleted \? \$deleted : \$used;/,
	'the later event wins');
like($merge_helper, qr/\$event == \$held_event && defined \$deleted && !defined \$held->\{'deleted'\}/,
	'a delete wins a tie against a live board');

done_testing();
