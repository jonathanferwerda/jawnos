# tests-for: lib/JawnOS/Domain/Resolve.pm lib/JawnOS/Manager/Part33.pm lib/JawnOS/Manager/Part30.pm lib/JawnOS/Controller/sesh_check.pm lib/JawnOS/Controller/manager_misc2.pm
# covers:    a live session's warranty slides on each approved request instead
#            of lapsing at a fixed deadline; an expired warranty is never
#            revived; and a paired-device session is minted with the forever
#            warranty rather than the short password/passkey login span.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();

sub source_of {
	my ($file) = @_;
	return scalar read_file("$root/$file");
}

sub extract_sub {
	my ($file, $name) = @_;
	my $src = source_of($file);
	my ($body) = $src =~ /(sub \Q$name\E(?:\s*\([^)]*\))?\s*\{.*?\n\})/s;
	return $body;
}

my $body = extract_sub('lib/JawnOS/Domain/Resolve.pm', 'session_warranty_slide');
ok($body, 'Resolve.pm defines session_warranty_slide');
{
	no warnings 'redefine';
	eval $body;
	is($@, '', 'the helper compiles') or diag($@);
}

SKIP: {
	skip 'session_warranty_slide did not compile', 5 unless defined &main::session_warranty_slide;

	is(main::session_warranty_slide(1_000, 100, 950), 1_050, 'a live session earns a fresh span');
	is(main::session_warranty_slide(1_000, 100, 1_001), 1_000, 'an expired warranty is never revived');
	is(main::session_warranty_slide(1_000, undef, 950), 1_000, 'a session minted without a span keeps its deadline');
	is(main::session_warranty_slide(1_000, 0, 950), 1_000, 'a zero span changes nothing');
	is(main::session_warranty_slide(undef, 100, 950), undef, 'no warranty means no slide');
}

my $part33 = source_of('lib/JawnOS/Manager/Part33.pm');
my $calls = () = $part33 =~ /session_warranty_slide/g;
cmp_ok($calls, '>=', 2, 'authentication_passer slides on both the fast and full paths');

my $device_mint = extract_sub('lib/JawnOS/Manager/Part30.pm', 'device_session_mint');
ok($device_mint, 'Part30 defines device_session_mint');
like($device_mint, qr/forever_warranty/, 'a paired-device session gets the forever warranty');
unlike($device_mint, qr/login_warranty/, 'a paired-device session does not borrow the short login span');

like(source_of('lib/JawnOS/Controller/sesh_check.pm'), qr/warranty_span/, 'the password/peer login stores its span');
like(source_of('lib/JawnOS/Controller/manager_misc2.pm'), qr/warranty_span/, 'the passkey login stores its span');

done_testing();
