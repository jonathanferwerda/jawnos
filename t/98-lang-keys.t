# tests-for: perl/language.pl perl/language/*.pl
# tests-for: public/js/manager/sound.js public/js/manager/taskbar_sound.js public/js/manager/taskbar_edit.js public/js/manager/power.js
# tests-for: public/js/manager/manager/10_appointment_edit.js templates/apps/controller.html.ep lib/JawnOS/Domain/WeatherAutomation.pm
# covers:    literal keys and the maps that build labels at runtime resolve to labels

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Find qw(find);
use File::Slurp qw(read_file);
use Test::More;
use JawnOSTest;

# A label is a catalog key. When the key is not in language.pl, translate()
# falls back to the key itself, so a page prints "keyboard" or
# "power_screen_off" where a word belongs. The start menu's keyboard icon was
# exactly that. This walks every page, template and domain call site and checks
# the literal keys, then the maps that build a key at runtime: the sound level
# map, the Leave menu, the taskbar's label maps and the weather measure catalog.
# A value that is English text is translated on demand and is not a key; only a
# key-shaped value has to exist.

my $root    = root();
my $catalog = $language::catalog{'en'};

sub looks_like_key {
	my ($value) = @_;
	return 0 unless defined $value;
	return $value =~ /^[a-z][a-z0-9]*(?:[._][a-z0-9]+)+$/ ? 1 : 0;
}

my @missing;
my $uses = 0;

find(
	{
		no_chdir => 1,
		wanted   => sub {
			my $path = $File::Find::name;
			if (-d $path) {
				$File::Find::prune = 1 if $path =~ m{/(?:\.git|\.worktrees|\.pio|build|language)\z};
				return;
			}
			return unless $path =~ /\.(?:pl|pm|ep)\z/;
			open(my $fh, '<:encoding(UTF-8)', $path) or return;
			my $line = 0;
			while (<$fh>) {
				$line++;
				while (/(?<![\w:])&?(?:subs::)?lang\(\s*(['"])([^'"]+)\1\s*[,)]/g) {
					my $key = $2;
					# An interpolated or concatenated argument is not a key yet.
					next if $key =~ /[\$\@\{\}]/;
					$uses++;
					next if exists $catalog->{$key};
					(my $rel = $path) =~ s{^\Q$root\E/+}{};
					push @missing, "$rel:$line $key";
				}
			}
			close $fh;
		},
	},
	map { "$root/$_" } qw(templates lib perl)
);

is_deeply(\@missing, [], 'every literal subs::lang key has an English catalog entry');
cmp_ok($uses, '>', 300, 'the scan sees the pages and templates that draw labels');

# templates/apps/power.html.ep labels each system power button with
# lang('power_' . $action), and power_actions() can offer these five.
my @power_missing = grep { !length($catalog->{$_} // '') }
	map { "power_$_" } qw(restart shutdown sleep screen_off logout);
is_deeply(\@power_missing, [], 'every power action button has a label');

# public/js/manager/sound.js and its taskbar widget build jawnosT(keys[level])
# from a map whose values are core labels, not English words.
my @sound_values;
for my $file (qw(public/js/manager/sound.js public/js/manager/taskbar_sound.js)) {
	my $js = read_file("$root/$file");
	my ($body) = $js =~ /var keys = \{([^}]*)\};/;
	ok(defined $body, "$file has the sound level map");
	push @sound_values, $body =~ /['"]([^'"]+)['"]/g if defined $body;
}
cmp_ok(scalar(@sound_values), '>=', 10, 'both sound level maps are read');
my %seen_sound;
my @sound_missing = grep { !exists $catalog->{$_} } grep { !$seen_sound{$_}++ } @sound_values;
is_deeply(\@sound_missing, [], 'every sound level map value has a label');

# The Leave dialog builds its buttons from a map of labels. Every one is a core
# key, including Screen off and Log out, so a missing entry would print the key.
my $leave_js = read_file("$root/public/js/manager/manager/10_appointment_edit.js");
my ($leave_body) = $leave_js =~ /function jawnosLeaveMenu\((.*?)\n\}/s;
ok(defined $leave_body, 'the Leave menu is found');
my @leave_labels = $leave_body =~ /label:\s*'([^']+)'/g;
cmp_ok(scalar(@leave_labels), '>=', 6, 'the Leave menu labels are read');
is_deeply([ grep { !looks_like_key($_) } @leave_labels ], [],
	'every Leave menu label is a core key');
my %seen_leave;
my @leave_missing = grep { !exists $catalog->{$_} } grep { !$seen_leave{$_}++ } @leave_labels;
is_deeply(\@leave_missing, [], 'every Leave menu label has a catalog entry');

# The taskbar's position menu and widget hints are read through jawnosT. Their
# values may be English text, but a key-shaped value has to be a real key.
my $taskbar_js = read_file("$root/public/js/manager/taskbar_edit.js");
my @taskbar_labels;
push @taskbar_labels, $1 =~ /['"]([^'"]+)['"]/g while $taskbar_js =~ /var labels = \{([^}]*)\};/g;
push @taskbar_labels, $taskbar_js =~ /hint:\s*'([^']+)'/g;
cmp_ok(scalar(@taskbar_labels), '>=', 7, 'the taskbar label maps are read');
is_deeply([ grep { looks_like_key($_) && !exists $catalog->{$_} } @taskbar_labels ], [],
	'every key-shaped taskbar label has a catalog entry');

# The weather automation labels its measures through jawnosT too. The catalog is
# English text today, and this keeps a key-shaped label honest if one is added.
my @weather_labels = map { $_->{'label'} // '' } @{ subs::weather_measure_catalog() };
cmp_ok(scalar(@weather_labels), '>', 10, 'the weather measure catalog is read');
is_deeply([ grep { !length } @weather_labels ], [], 'every weather measure has a label');
is_deeply([ grep { looks_like_key($_) && !exists $catalog->{$_} } @weather_labels ], [],
	'every key-shaped weather measure label has a catalog entry');

# The Power app's sleep types are the same kind of map: English today, keys if
# they are ever changed to them.
my $power_js = read_file("$root/public/js/manager/power.js");
my ($sleep_body) = $power_js =~ /var powerSleepLabels = \{([^}]*)\};/;
ok(defined $sleep_body, 'the Power app sleep label map is found');
my @sleep_labels = defined $sleep_body ? $sleep_body =~ /['"]([^'"]+)['"]/g : ();
cmp_ok(scalar(@sleep_labels), '>=', 4, 'the Power app sleep labels are read');
is_deeply([ grep { looks_like_key($_) && !exists $catalog->{$_} } @sleep_labels ], [],
	'every key-shaped sleep label has a catalog entry');

# A key-shaped jawnosT() literal in the scripts has to name a real key; an
# English sentence is the on-demand path and is left alone.
my @js_missing;
my $js_uses = 0;
find(
	{
		no_chdir => 1,
		wanted   => sub {
			my $path = $File::Find::name;
			if (-d $path) {
				$File::Find::prune = 1 if $path =~ m{/(?:\.git|\.worktrees)\z};
				return;
			}
			return unless $path =~ /\.js\z/;
			open(my $fh, '<:encoding(UTF-8)', $path) or return;
			my $line = 0;
			while (<$fh>) {
				$line++;
				while (/jawnosT\(\s*(['"])([^'"]+)\1\s*[,)]/g) {
					my $key = $2;
					next unless looks_like_key($key);
					$js_uses++;
					next if exists $catalog->{$key};
					(my $rel = $path) =~ s{^\Q$root\E/+}{};
					push @js_missing, "$rel:$line $key";
				}
			}
			close $fh;
		},
	},
	"$root/public/js"
);

is_deeply(\@js_missing, [], 'every key-shaped jawnosT literal has an English catalog entry');
cmp_ok($js_uses, '>', 30, 'the scan sees the scripts that draw labels');

done_testing();
