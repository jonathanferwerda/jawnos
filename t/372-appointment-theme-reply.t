# tests-for: lib/JawnOS/Domain/Contrast.pm lib/JawnOS/Manager/Part14.pm public/js/manager/manager/09_app_back.js
# covers:    a start/stop press carries the new theme back in its own reply, so the desk repaints even when the websocket push is missed; the press still sends the same bundle to every other screen.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;
use JawnOSTest;

# A press that moves the active theme used to leave its own screen waiting for
# the websocket console frame. A socket that was asleep (or slow to reconnect)
# dropped it, so the header changed but the room did not until a reload. The
# reset reply already carries the header for exactly this reason; it now carries
# the theme bundle too. Every other open manager still gets the push, and the
# client's signature check turns the duplicate into a no-op.

# --- the push returns the very bundle it sends ------------------------------
# Stubbed so the test reads the contract, not the house's current theme. Load the
# lazy domain module first: its own subs would otherwise replace the stubs.

&subs::contrast_ink('#000000');

my (@sent, @native, $payload);
{
	no warnings 'redefine';
	local *subs::icon_set_forget = sub { 1 };
	local *subs::theme_state = sub {
		my $bundle = {
			slug => 'geek', appointment => 1,
			font => 'Inter, system-ui, sans-serif', accent => '#3ee37c',
		};
		return (1, 'geek', '#101812', $bundle, 'geek', 1);
	};
	local *subs::icon_set = sub { 'outline_dark' };
	local *subs::cursor_set = sub { 'outline' };
	local *subs::cursor_size = sub { 32 };
	local *subs::cursor_css = sub { 'CURSOR-CSS' };
	local *subs::texture_name = sub { 'fabric' };
	local *subs::misc_setting = sub { '' };
	local *subs::corner_radius = sub { 10 };
	local *subs::theme_signature = sub { 'SIGNATURE' };
	local *subs::native_theme_record = sub { push @native, $_[0] };
	local *Websocket::console_command = sub {
		my ($cmd, @args) = @_;
		return { cmd => $cmd, args => \@args };
	};
	local *Websocket::send = sub { push @sent, [ @_ ] };

	$payload = &subs::appointment_theme_push();
}

ok(ref $payload eq 'HASH', 'appointment_theme_push returns the bundle it pushed');
is($payload->{'background'}, '#101812', 'the reply carries the paint');
is($payload->{'appointment'}, 1, 'and the flag that says a running appointment owns the desk');
is($payload->{'icon_set'}, 'outline_dark', 'the effective icon cut travels with it');
is($payload->{'cursor_set'}, 'outline', 'so does the cursor set');
is($payload->{'cursor_css'}, 'CURSOR-CSS', 'and the cursor sheet');
is($payload->{'texture'}, 'fabric', 'so does the material');
is($payload->{'font'}, 'Inter, system-ui, sans-serif', 'and the face');
is($payload->{'corner'}, '10px', 'and the corner');
is($payload->{'accent'}, '#3ee37c', 'and the accent');
is($payload->{'signature'}, 'SIGNATURE', 'the signature still lets a duplicate push be a no-op');

# --- the websocket push and the native record are unchanged -----------------

is(scalar @sent, 1, 'the push still goes to the socket');
is($sent[0]->[0], 'server', 'on the server channel');
is($sent[0]->[1]->{'console'}->{'cmd'}, 'jawnosThemeBundleApply',
	'as the theme bundle command');
is_deeply($sent[0]->[1]->{'console'}->{'args'}->[0], $payload,
	'the pushed bundle is the same one the reply returns');
is(scalar @native, 1, 'the native surfaces still get their record');
is($native[0]->{'theme'}, 'geek', 'with the theme slug');
is($native[0]->{'background'}, '#101812', 'and the same paint');

# --- the reset reply carries it --------------------------------------------

my $root = repo_root();
my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");

like($part14, qr/if \(\$theme_movement =~ \/\^\(\?:start\|stop\|record\|cancel\|resume\|pause\|delay\)\$\//,
	'every movement that can move the theme is considered');
like($part14, qr/my \$theme = &subs::appointment_theme_push\(\);/,
	'manager_reset takes the bundle the push sent');
like($part14, qr/\$returner->\{'theme'\} = \$theme if \$theme;/,
	'and puts it in the reply');

# --- the press applies it in place -----------------------------------------

my $js = read_file("$root/public/js/manager/manager/09_app_back.js");

like($js, qr/if \(response && response\['theme'\] && typeof jawnosThemeBundleApply === 'function'\) \{\s*jawnosThemeBundleApply\(response\['theme'\]\);\s*\}/s,
	'the press applies the reply bundle at once');
my ($reset_success) = $js =~ /success: function\(response\) \{(.*?)\n\t\t\},/s;
ok($reset_success, 'the reset success handler is one block');
unlike($reset_success // '', qr/location\.reload|appWindowOpener|appointmentGrabber/,
	'the theme lands without a reload or a window re-render, so Music and Studio keep their state');

done_testing();
