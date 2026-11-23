# tests-for: lib/JawnOS/Manager/Part35.pm templates/embedded/body.html.ep public/js/manager/embedded.js
# covers:    A T-Deck's Embedded panel exposes the GPS and LoRa mesh choices it
#            applies itself. The controls save like every other embedded_setting
#            and push a fresh Now Me; now_me carries the raw tokens with defaults.
#            Neither section renders for a watch or a board. No new JavaScript is
#            needed: the generic .embedded_setting change handler already posts the
#            setting and calls embeddedNowMePush() when push="now_me" is present.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $p35  = read_file("$root/lib/JawnOS/Manager/Part35.pm");
my $tpl  = read_file("$root/templates/embedded/body.html.ep");
my $js   = read_file("$root/public/js/manager/embedded.js");

# --- now_me carries the deck's GPS / mesh choices ----------------------------
my ($teletype) = $p35 =~ /(\n\tif \(\$edt eq 'teletype'\) \{.*?\n\t\})/s;
ok($teletype, 'the now_me teletype block was found');

my %params = (
	gps_enabled           => 'on',
	gps_constellation     => 'gps_glonass',
	gps_rate              => '1',
	lora_frequency        => '433.0',
	lora_spreading_factor => '9',
	lora_bandwidth        => '125.0',
	lora_tx_power         => '22',
);
for my $key ( sort keys %params ) {
	like($teletype, qr/\$params->\{$key\}\s*=/, "now_me sends $key");
	like($teletype, qr/\$params->\{$key\}\s*=.*?\/\/\s*'\Q$params{$key}\E'/,
		"now_me defaults $key to $params{$key}");
}

# --- the panel marks every control as a pushing embedded_setting -------------
my @settings = qw(
	gps_enabled gps_constellation gps_rate
	lora_frequency lora_spreading_factor lora_bandwidth lora_tx_power
);
for my $setting (@settings) {
	like($tpl, qr/class="embedded_setting"[^>]*setting="\Q$setting\E"[^>]*push="now_me"[^>]*chip_id="/,
		"$setting is an embedded_setting that pushes now_me with a chip_id");
	like($tpl, qr/class="embedded_setting"[^\n]*setting="\Q$setting\E"[^\n]*edt="/,
		"$setting also carries the edt the save route reads");
}

# --- only a T-Deck renders the GPS and LoRa mesh sections --------------------
# The guard nests other <% if/foreach/unless %> blocks, so scan template chunks
# to find the brace matching the guard rather than the first close.
my $guard = "if (\$edt eq 'teletype') {";
my $start = index($tpl, $guard);
ok($start >= 0, 'the template guards the hardware sections on a T-Deck');

my $region = '';
if ($start >= 0) {
	my $pos   = $start + length($guard);
	my $depth = 1;
	while ($pos < length($tpl)) {
		my $open = index($tpl, '<%', $pos);
		last if $open < 0;
		my $close = index($tpl, '%>', $open + 2);
		last if $close < 0;
		my $code = substr($tpl, $open + 2, $close - $open - 2);
		if ($code =~ /\{\s*$/ && $code !~ /^\s*[#=]/) {
			$depth++;
		}
		elsif ($code =~ /^\s*\}\s*$/) {
			$depth--;
			last if $depth == 0;
		}
		$pos = $close + 2;
	}
	$region = substr($tpl, $start, $pos - $start) if $depth == 0;
}
ok(length($region), 'the T-Deck guard closes over a region');

like($region, qr/&subs::ui\('GPS'\)/, 'the guard encloses the GPS heading');
like($region, qr/&subs::ui\('LoRa mesh'\)/, 'the guard encloses the LoRa mesh heading');
like($region, qr/&subs::ui\(q\{The radio must match this board's band\.\}\)/,
	'and the hardware-band note');
for my $setting (@settings) {
	like($region, qr/setting="\Q$setting\E"/, "$setting lives inside the T-Deck guard");
}

# --- the generic handler still makes the controls work without new JS --------
like($js, qr/\$\(document\)\.on\('change', '\.embedded_setting', function/,
	'the generic embedded_setting change handler is present');
like($js, qr|url: '/manager/embedded/setting'|,
	'it posts to the embedded setting route');
like($js, qr/if \(\$\(el\)\.attr\('push'\)\) \{ embeddedNowMePush\(\); \}/,
	'and a push="now_me" control asks for a fresh Now Me');

done_testing();
