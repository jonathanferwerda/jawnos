# tests-for: public/js/manager/windows.js public/js/manager/windows/01_storage.js public/js/manager/manager/09_app_back.js lib/JawnOS/Controller/manager_misc.pm
# covers:    A window is addressed by its timestamp (window_<timestamp>,
#            window_contents_<timestamp>, little_window_<timestamp>). A restore
#            opens the whole desk in one pass, so Date.now() alone could give
#            several windows the same id; closeWindow() then took the wrong one
#            down. The open path now mints a monotonic, unused stamp, and the one
#            server action that renders two windows together gives them two stamps.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempfile);
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $core    = read_file("$root/public/js/manager/windows.js");
my $storage = read_file("$root/public/js/manager/windows/01_storage.js");
my $back    = read_file("$root/public/js/manager/manager/09_app_back.js");
my $media   = read_file("$root/lib/JawnOS/Controller/manager_misc.pm");

like( $core, qr/function jawnosWindowTimestamp\(requested\)/, 'there is one window-timestamp minter' );
like( $core, qr/stamp <= jawnosLastWindowStamp/, 'a same-tick stamp steps past the last one' );
like( $core, qr/getElementById\('window_' \+ stamp\)/, 'a stamp already on the page is skipped' );
like( $storage, qr/timestamp = jawnosWindowTimestamp\(timestamp\)/, 'every generic open passes through the minter' );
like( $storage, qr/appWindowOpener\(i, jawnosWindowTimestamp\(\), v\)/, 'restore asks for a fresh stamp per window' );
unlike( $storage, qr/var timestamp = Date\.now\(\);/, 'the unused restore timestamp is gone' );
like( $back, qr/timestamp = jawnosWindowTimestamp\(\)/, 'a centre view with no timestamp asks for one' );
like( $media, qr/win_stamp \+ 1/, 'the media claim gives its second window its own stamp' );

my ($helper) = $core =~ m{// \[\[window-timestamp\]\](.*?)// \[\[/window-timestamp\]\]}s;
ok( defined $helper && $helper =~ /function jawnosWindowTimestamp/, 'the minter is marked for the runtime check' );

my $node = qx{command -v node 2>/dev/null};
chomp $node;

SKIP: {
	skip 'node is not installed', 1 unless $node && defined $helper;

	my $script = <<"JS";
var taken = {};
var document = { getElementById: function (id) { return taken[id] ? {} : null; } };
$helper
function fail(message) { console.error(message); process.exit(1); }
var a = jawnosWindowTimestamp(1000);
var b = jawnosWindowTimestamp(1000);
if (b !== a + 1) { fail('two windows opened in one tick shared a stamp: ' + a + '/' + b); }
var c = jawnosWindowTimestamp();
if (!(c > b)) { fail('a later open went backwards: ' + b + ' then ' + c); }
taken['window_' + (c + 1)] = 1;
var d = jawnosWindowTimestamp(c + 1);
if (d !== c + 2) { fail('an id already on the page was reused: ' + d); }
var e = jawnosWindowTimestamp('not-a-number');
if (!(e > d)) { fail('a bad request did not fall back to a fresh stamp: ' + e); }
process.exit(0);
JS

	my ($fh, $file) = tempfile( SUFFIX => '.js', UNLINK => 1 );
	print {$fh} $script;
	close $fh;
	my $rc = system($node, $file);
	is( $rc, 0, 'the minter keeps stamps distinct in a single tick' );
}

done_testing();
