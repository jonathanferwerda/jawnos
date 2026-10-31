use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# M4 (docs/leaving-termux.md): the host app is com.jawnos. Its Java package is
# com.jawnos.app, so a component reads com.jawnos/.app.X (relative to the
# installed package) and an intent action com.jawnos.app.*. Every call site now
# asks for those names through these three functions instead of spelling a
# package, so a device still on the old fork keeps answering its own names until
# it is migrated.

is(subs::app_package(), 'com.jawnos', 'the host app is com.jawnos');
is(subs::app_action('JAWN_WAKE'), 'com.jawnos.app.JAWN_WAKE',
	'an action is the app package plus .app.');
is(subs::app_component('JawnWakeReceiver'), 'com.jawnos/.app.JawnWakeReceiver',
	'a component is the package, a slash and the relative class');
is(subs::app_action(undef), undef, 'no name, no action');
is(subs::app_component(''), undef, 'no class, no component');

{
	local $ENV{'JAWNOS_APP_PACKAGE'} = 'com.termux';
	is(subs::app_package(), 'com.termux', 'the fork still spells its own package');
	is(subs::app_action('JAWN_NOTIFY'), 'com.termux.app.JAWN_NOTIFY',
		'and its actions follow it, because they were named after the package');
	is(subs::app_component('JawnBleService'), 'com.termux/.app.JawnBleService',
		'and so do its components');
}

# The rename is finished on the tree side: no call site may hardcode the old
# package again. Docs are allowed to talk about it.
my @sources = (
	"$FindBin::Bin/../Manager.pl",
	"$FindBin::Bin/../subroutines.pl",
	"$FindBin::Bin/../scripts/jawn-bt",
	"$FindBin::Bin/../scripts/phone_wake.pl",
);
for my $file (@sources) {
	open(my $fh, '<', $file) or die "$file: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	unlike($text, qr/com\.termux\.app\./, "$file names no com.termux.app.* action");
	unlike($text, qr{com\.termux/\.app\.}, "$file names no com.termux/.app.* component");
}

done_testing();
