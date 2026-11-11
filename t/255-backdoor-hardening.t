# tests-for: lib/JawnOS/Manager/Part33.pm lib/JawnOS/Domain/House2.pm lib/JawnOS/Manager/Part12.pm lib/JawnOS/Domain/Embedded2.pm lib/JawnOS/Manager/Part35.pm lib/JawnOS/Controller/mail_ws.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Controller/sesh_check.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Controller/manager_misc2.pm lib/JawnOS/Controller/manager_misc3.pm lib/JawnOS/Controller/manager_misc4.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Controller/manager_misc10.pm lib/JawnOS/Controller/manager_misc11.pm lib/JawnOS/Controller/manager_misc13.pm lib/JawnOS/Controller/manager_misc14.pm lib/JawnOS/Controller/manager_market.pm lib/JawnOS/Controller/manager_clock.pm perl/Music/04_music_websockets.pl scripts/security_audit.pl
# covers:    The backdoor audit's three hardenings: base64 never rides a shell,
#           every privileged peer route needs a pinned key, and a password login
#           can no longer claim the peer rail to mint itself a citizen ticket.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Find qw(find);
use RepoSource qw(repo_root);

my $root = repo_root();
my %lines;

sub slurp {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "open $rel: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

# Every source line under lib/ and perl/, with its path and a per-file copy for
# lookback. A guard can put its pubkey check on the line above the call.
sub source_lines {
	my @out;
	for my $tree (qw(lib perl)) {
		find({
			no_chdir => 1,
			wanted => sub {
				my ($path) = @_;
				return unless -f $path && $path =~ /\.(?:pm|pl)$/;
				open(my $fh, '<', $path) or die "open $path: $!";
				my @text = <$fh>;
				close $fh;
				$lines{$path} = \@text;
				push @out, [ $path, $_, $text[ $_ - 1 ] ] for 1 .. scalar @text;
			},
		}, "$root/$tree");
	}
	return @out;
}

my @source = source_lines();

# --- 1. no base64 through a shell -------------------------------------------
# The ticket and embedded rails decoded base64 with `echo "$row" | base64`; a
# value holding $(...) ran as the service user. MIME::Base64 does the same work
# in-process, and BSD base64 has no -w 0, so the shell form was not portable
# either. Only the comment that records the old shape may mention it.
my @shell_b64 = grep {
	my $text = $_->[2];
	$text !~ /^\s*#/ && $text =~ /`[^`]*base64[^`]*`/
} @source;
is(scalar @shell_b64, 0, 'no source interpolates a value into a shell base64 command')
	or diag(join "\n", map { $_->[0] . ':' . $_->[1] . ': ' . $_->[2] } @shell_b64);

for my $spec (
	[ 'lib/JawnOS/Manager/Part33.pm',              'decode_base64($secretive' ],
	[ 'lib/JawnOS/Domain/House2.pm',               'decode_base64($secret' ],
	[ 'lib/JawnOS/Manager/Part12.pm',              'decode_base64($secretive' ],
	[ 'lib/JawnOS/Domain/Embedded2.pm',            'decode_base64($rauth' ],
	[ 'lib/JawnOS/Controller/manager_embedded.pm', 'decode_base64($auth' ],
	[ 'lib/JawnOS/Manager/Part35.pm',              'encode_base64($auth' ],
	[ 'lib/JawnOS/Controller/mail_ws.pm',          'encode_base64($secret' ],
) {
	like(slurp($spec->[0]), qr/\Q$spec->[1]\E/, "$spec->[0] does base64 in Perl");
}

# --- 2. a peer route needs a pinned key --------------------------------------
# peer_verify's trust-on-first-contact is for the handshake that enrols a
# machine, not for the rails that deploy, restart, read the database, drive the
# keyboard or hand out tickets. Every other call site must name a pinned key.
my %allow = (
	# the definition, the strict wrapper and the app rail (key-matched)
	'lib/JawnOS/Domain/Crypt.pm'   => 1,
	'lib/JawnOS/Manager/Part30.pm' => 1,
	# the address directory records a first boot before a key can be pinned
	'perl/AddressDirectory.pl'     => 1,
);

my @unguarded;
for my $row (@source) {
	my ($path, $num, $text) = @{$row};
	next if $text =~ /^\s*#/;
	next unless $text =~ /peer_verify\(\$c/;
	next if $text =~ /sub\s+peer_verify/;
	next if $allow{$path};
	# The remote_auth_test handshake is where a machine is introduced and its
	# offered key is pinned; that one signed call is the TOFU door.
	next if $path =~ m{/manager_misc14\.pm$} && $text =~ /\$cand/;
	my $from = $num > 7 ? $num - 7 : 1;
	my $near = join '', @{ $lines{$path} }[ $from - 1 .. $num - 1 ];
	next if $near =~ /pubkey/;
	push @unguarded, "$path:$num: $text";
}
is(scalar @unguarded, 0, 'every privileged peer_verify names a pinned pubkey')
	or diag(join "\n", @unguarded);

# --- 3. a password login is not a peer session -------------------------------
my $sesh = slurp('lib/JawnOS/Controller/sesh_check.pm');
like($sesh, qr/\$peer_proved = 0;/, 'the login starts with no peer proof');
like($sesh, qr/\$peer_row->\{'pubkey'\} && &subs::peer_verify_strict/, 'a key must already be pinned');
like($sesh, qr/&subs::peer_allows\(\$c, \$peer_row, 'resident'\)/, 'and the row must still grant a house session');
like($sesh, qr/\$peer_proved = 1;/, 'only that signed, granted login proves a peer');
unlike($sesh, qr/my \$peer_login =/, 'neighbour/remote_timestamp no longer mints a peer by itself');
like($sesh, qr/\$c->session\('privilege' => \(\$peer_proved \? 'resident' : 'guest'\)\)/,
	'an unproved login stays a guest, not a resident peer');

# --- 4. the audit keeps the shell-base64 rule --------------------------------
like(slurp('scripts/security_audit.pl'), qr/perl\.shell\.base64/,
	'the audit keeps the shell-base64 rule');

done_testing();
