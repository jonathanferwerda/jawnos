# tests-for: lib/JawnOS/Domain/Crypt.pm lib/JawnOS/Domain/People.pm lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Manager/Part11.pm lib/JawnOS/Manager/Part35.pm lib/JawnOS/Manager/Core2_worker_boot.pm perl/hooks.pl lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Domain/Backup.pm lib/JawnOS/Domain/Records.pm lib/JawnOS/Manager/Part17.pm lib/JawnOS/Controller/sesh_check.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Controller/manager_mail2.pm lib/JawnOS/Controller/manager_configure.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Controller/manager_misc3.pm scripts/security_audit.pl
# covers:    The sixth audit pass: a peer signature binds the body and recipient,
#           the nonce is claimed atomically, the ws token is short and bound, a
#           websocket upgrade checks Origin, GET mutations are checked, an empty
#           grant is visitor, and a quoted backtick command actually runs.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

sub source { return read_file(root() . '/' . $_[0]) }

# --- the signed message covers the body and the recipient -------------------
is( subs::peer_sign_message('POST', '/x?y=1', 123, 'abcdefgh', 'deadbeef', 'house.example'),
	"POST\n/x?y=1\n123\nabcdefgh\ndeadbeef\nhouse.example",
	'the v2 message is method, path, stamp, nonce, body digest, audience');

# --- an empty grant is visitor, not trust -----------------------------------
{
	package FakeC;
	sub new { my ($class, $key) = @_; return bless { key => $key }, $class }
	sub stash { my ($s, $k) = @_; return $k eq 'peer_verified_key' ? $s->{key} : undef }
	package main;
}
my $row = { uuid => 'u1', signatorial => 's1', grant_scope => '', grant_expires => 0 };
my $c = FakeC->new('u1');
ok(subs::peer_allows($c, $row, 'visitor'), 'an empty grant still reaches visitor');
ok(!subs::peer_allows($c, $row, 'resident'), 'but not resident');
ok(!subs::peer_allows($c, $row, 'trusted'), 'and not trusted');
$row->{grant_scope} = undef;
ok(subs::peer_allows($c, $row, 'visitor'), 'a missing grant is visitor too');
ok(!subs::peer_allows($c, $row, 'resident'), 'and not resident');
$row->{grant_scope} = 'none';
ok(!subs::peer_allows($c, $row, 'visitor'), 'a none grant is refused');
$row->{grant_scope} = 'trusted';
ok(subs::peer_allows($c, $row, 'trusted'), 'a trusted grant reaches trusted');
$row->{grant_expires} = 1;
$row->{grant_scope} = 'trusted';
ok(!subs::peer_allows($c, $row, 'visitor'), 'an expired grant is refused');

# --- the proved key is either half of the row's identity -------------------
# Which half the gate proved depends on how the caller was found: a direct
# roster row is proved by its uuid, a machine the hub listed in another row's
# `mirrors` blob only by its signatorial. Comparing `uuid || signatorial`
# refused the mirror-proved caller whose row also had a uuid, even with the
# grant the person had set - that was CloudSync's "that peer is not trusted
# for cloud sync" on a phone and a Dev whose grants were already trusted.
{
	my $mirror = { uuid => 'row-uuid', signatorial => 'mirror-sig', grant_scope => 'trusted', grant_expires => 0 };
	ok(subs::peer_allows(FakeC->new('mirror-sig'), $mirror, 'trusted'),
		'a signatorial proved through a mirror reaches the row');
	ok(subs::peer_allows(FakeC->new('row-uuid'), $mirror, 'trusted'),
		'and so does the row uuid');
	ok(!subs::peer_allows(FakeC->new('someone-else'), $mirror, 'trusted'),
		'an unrelated key is still refused');
	$mirror->{grant_scope} = 'visitor';
	ok(!subs::peer_allows(FakeC->new('mirror-sig'), $mirror, 'trusted'),
		'and the grant still decides what the row may do');
}

# --- the signature binds body and audience ----------------------------------
my $crypt = source('lib/JawnOS/Domain/Crypt.pm');
like($crypt, qr/X-Peer-Sig-Version', '2'/, 'the signer announces v2');
like($crypt, qr/X-Peer-Body-Sha256/, 'and the body digest');
like($crypt, qr/X-Peer-Audience/, 'and the host it is addressed to');
like($crypt, qr/return 0 unless \(\$c->req->headers->header\('X-Peer-Sig-Version'\) \/\/ ''\) eq '2'/, 'the verifier requires v2');
like($crypt, qr/secure_compare\(\$body_sha, &sha256_hex\(\$c->req->body \/\/ ''\)\)/, 'the verifier recomputes the body digest');
like($crypt, qr/\$aud_norm eq \$here/, 'and checks the recipient');
like($crypt, qr/insert or ignore into cache \(uuid, context/, 'the nonce is claimed atomically');
like($crypt, qr/\$claim->rows/, 'and a duplicate claim is refused');

# --- the websocket token is short-lived and bound ---------------------------
my $part35 = source('lib/JawnOS/Manager/Part35.pm');
like($part35, qr/warranty => '\+12h'/, 'the ws token is no longer a week-long session');
like($part35, qr/\$auth\{'_ws_remote'\}/, 'the token is bound to the minting address');
like($part35, qr/\$from eq \(\$c->tx->remote_address \/\/ ''\)/, 'and the handshake must come from it');
like(source('lib/JawnOS/Manager/Core2_worker_boot.pm'), qr/app->sessions->secure\(1\)/, 'the session cookie is Secure');

# --- a websocket upgrade checks Origin, and GET mutations are covered -------
my $hooks = source('perl/hooks.pl');
like($hooks, qr/%csrf_get = map \{ \$_ => 1 \} qw\(/, 'the mutating GET routes are named');
for my $path (qw(/manager/delete_ticket /manager/suspend_ticket /manager/renew_ticket /manager/reinstate_ticket /manager/watch/set_proxy /manager/say_it)) {
	like($hooks, qr/\Q$path\E/, "$path is in the GET mutation list");
}
like($hooks, qr{header\('Upgrade'\)}, 'the hook looks at the Upgrade header');
like($hooks, qr{/websocket/i}, 'and recognises a websocket handshake');
like($hooks, qr/ws: refused upgrade/, 'a foreign Origin is refused');

# --- an empty grant is visitor in the policy and the insert ------------------
like(source('lib/JawnOS/Domain/People.pm'), qr/\$grant = 'visitor' if \$grant eq '';/, 'the policy defaults to visitor');
my $part11 = source('lib/JawnOS/Manager/Part11.pm');
like($part11, qr/\$remote_machine->\{'privilege'\} \/\/= 'peer';/, 'a discovered peer is not a citizen');
like($part11, qr/\$remote_machine->\{'grant_scope'\} \/\/= 'visitor';/, 'and starts at visitor');
my $mig = source('lib/JawnOS/Domain/Migrations.pm');
like($mig, qr/grant_scope_v2/, 'a one-time marker guards the migration');
like($mig, qr/update remote_machines set grant_scope = 'trusted'/, 'existing keyed peers are grandfathered once');

# --- a quoted backtick command now runs as one string -----------------------
for my $rel (qw(
	lib/JawnOS/Controller/manager_configure5.pm
	lib/JawnOS/Domain/Backup.pm
	lib/JawnOS/Domain/Records.pm
	lib/JawnOS/Manager/Part17.pm
	lib/JawnOS/Controller/sesh_check.pm
	lib/JawnOS/Controller/manager_configure2.pm
	lib/JawnOS/Controller/manager_mail2.pm
	lib/JawnOS/Controller/manager_configure.pm
	lib/JawnOS/Controller/manager_misc5.pm
	lib/JawnOS/Controller/manager_misc3.pm
)) {
	my $src = source($rel);
	my $code = join q{}, grep { !/^\s*#/ } split /^/m, $src;
	like($src, qr/`\$[A-Za-z_]\w*`/, "$rel runs the command variable");
	unlike($code, qr/`[^`]*[[:space:]]`[[:space:]]*\./, "$rel does not concatenate a backtick command");
}
like(source('scripts/security_audit.pl'), qr/perl\.shell\.concat/, 'the audit names backtick concatenation');

done_testing();
