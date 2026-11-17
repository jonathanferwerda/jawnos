# tests-for: lib/JawnOS/Controller/store_misc.pm lib/JawnOS/Manager/Part29.pm perl/watch.pl perl/Music.pl lib/JawnOS/Controller/box_office_misc.pm public/js/gate.js lib/JawnOS/Controller/manager_configure2.pm
# covers:    Request data never reaches a shell or eval sink, and a value handed to encode_json keeps the keys that follow it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);

# A security audit found five places where request data was interpolated into a
# shell command (or, in gate.js, into eval). The assertions below are source
# guards: they fail if the dangerous shape comes back. They do not start the app.

my $root = abs_path("$FindBin::Bin/..");

sub source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "open $rel: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $watch = source('perl/watch.pl');
unlike($watch, qr/`\s*\(echo \$secret\)/,
	'watch chat_grabber does not pipe the request secret through a shell');
like($watch, qr/MIME::Base64::decode_base64\(\$secret\)/,
	'watch decodes the request secret in Perl');

my $box = source('lib/JawnOS/Controller/box_office_misc.pm');
unlike($box, qr/`\s*echo "\$secret"/,
	'box office does not put the ticket token in a double-quoted shell string');
like($box, qr/decode_base64\(\$secret/,
	'box office decodes the ticket token in Perl');

my $music = source('perl/Music.pl');
unlike($music, qr/`vlc \$track`/,
	'music does not interpolate the track into a vlc shell command');
unlike($music, qr/`play \$track`/,
	'music does not interpolate the track into a play shell command');
like($music, qr/system\('vlc', \$track_name\)/,
	'music runs vlc in list form with the raw name');
like($music, qr/system\('play', \$track_name\)/,
	'music runs play in list form with the raw name');

my $gate = source('public/js/gate.js');
unlike($gate, qr/\beval\s*\(\s*JSON\.parse/,
	'gateKeeper parses the debriefer without eval');
like($gate, qr/var d = JSON\.parse\(response\.debriefer\)/,
	'gateKeeper uses JSON.parse directly');

my $conf = source('lib/JawnOS/Controller/manager_configure2.pm');
unlike($conf, qr/`timeout \$timeout ping -c 1 \$ip`/,
	'ping does not interpolate a raw host');
unlike($conf, qr/`timeout \$timeout ping -c 1 \$ip_address`/,
	'ping does not interpolate a raw derived address');
like($conf, qr/"timeout \$timeout ping -c 1 " \. &subs::shell_quote\(\$ip\)/,
	'ping quotes the host');
like($conf, qr/"timeout \$timeout ping -c 1 " \. &subs::shell_quote\(\$ip_address\)/,
	'ping quotes the derived address');
like($conf, qr/\Q[0-9., ]+\E/,
	'ping accepts only address/range/list characters');


# --- a value handed to encode_json keeps the keys that follow it ------------
# Mojo::JSON's encode_json has no prototype, so `key => encode_json $x,` is a
# list operator that reads only its first argument: every key after it is
# dropped from the hash and never written. The call is parenthesised instead.
# lib/JawnOS/Manager/Part31.pm:791 records the first time this bit the house -
# a relay quietly lost its uuid - so the shape is guarded, not just fixed.

# How deep the brackets are after $text, ignoring anything quoted.
sub bracket_depth {
	my ($text) = @_;
	my ($depth, $quote) = (0, undef);
	for my $ch (split //, $text) {
		if (defined $quote) { $quote = undef if $ch eq $quote; next; }
		if ($ch eq q{'} || $ch eq q{"}) { $quote = $ch; next; }
		$depth++ if $ch =~ /[\(\[\{]/;
		$depth-- if $ch =~ /[\)\]\}]/;
	}
	return $depth;
}

# True when the call's argument list ends before the comma on this line: a
# closer that was opened before the call comes back. `eval { return
# encode_json $x } || undef,` closes the eval block, not the argument list, so
# it is not this bug. `encode_json &subs::f(),` and `encode_json [ $file ],`
# close only their own brackets and stay in the list.
sub call_leaves_the_list {
	my ($line, $at) = @_;
	my $start = bracket_depth(substr($line, 0, $at));
	my ($depth, $quote) = ($start, undef);
	for my $ch (split //, substr($line, $at + length 'encode_json')) {
		if (defined $quote) { $quote = undef if $ch eq $quote; next; }
		if ($ch eq q{'} || $ch eq q{"}) { $quote = $ch; next; }
		return 0 if $ch eq q{,} && $depth == $start;   # this comma ends the element
		$depth++ if $ch =~ /[\(\[\{]/;
		if ($ch =~ /[\)\]\}]/) { $depth--; return 1 if $depth < $start; }
	}
	return 0;
}

# Every source line that hands a bare value to encode_json with another element
# after it in the same list, as file:line: line.
sub bare_encode_json_calls {
	my @found;
	for my $rel (@_) {
		open(my $fh, '<', "$root/$rel") or next;
		my @lines = <$fh>;
		close $fh;
		chomp @lines;
		for my $i (0 .. $#lines) {
			my $line = $lines[$i];
			next if $line =~ /^\s*#/;
			next unless $line =~ /=>\s*encode_json\s/;      # a hash key, bare call
			next if $line =~ /=>\s*encode_json\s*\(/;       # already parenthesised
			my $at = index($line, 'encode_json');
			next if call_leaves_the_list($line, $at);
			my $hit = 0;
			if ($line =~ /,\s*$/) {
				# A trailing comma is harmless when the next line closes the
				# list; it is this bug only when another key follows.
				my $next = '';
				for my $j ($i + 1 .. $#lines) {
					next unless $lines[$j] =~ /\S/;
					$next = $lines[$j];
					last;
				}
				$hit = 1 unless $next =~ /^\s*[\}\]\)]/;
			}
			# The same list written on one line: a key follows the comma.
			$hit = 1 if $line =~ /=>\s*encode_json\s+[^,]+,\s*[A-Za-z_'"]+\s*=>/;
			push @found, "$rel:" . ($i + 1) . ": $line" if $hit;
		}
	}
	return @found;
}

my @sources = map { s{^\Q$root/\E}{}r } (
	glob("$root/lib/JawnOS/Controller/*.pm"),
	glob("$root/lib/JawnOS/Manager/*.pm"),
	glob("$root/lib/JawnOS/Domain/*.pm"),
	glob("$root/lib/JawnOS/*.pm"),
	glob("$root/perl/*.pl"),
	glob("$root/scripts/*.pl")
);
my @bare = bare_encode_json_calls(@sources);
is_deeply(\@bare, [], 'no Perl source hands a bare value to encode_json with keys after it')
	or diag(join "\n", @bare);

done_testing();
