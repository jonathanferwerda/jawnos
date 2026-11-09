# tests-for: templates/embedded/body.html.ep public/js/manager/embedded.js public/js/manager/embedded/02_board_pins.js perl/help/topics_configure.pl
# covers:    The Embedded board view reads what a board actually has, draws its
#            configured parts and the pins that look wired, and attaches a
#            discovered pin to an appointment in one more press. Failures are
#            shown in place, never in an alert box.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $read = sub { scalar read_file("$root/$_[0]") };

# --- the panel offers one press to read the board --------------------------
my $body = $read->('templates/embedded/body.html.ep');
like($body, qr/id="embedded_board_read"/, 'the board view has a read button');
like($body, qr/id="embedded_board_pins"/, 'and a place for what it finds');
like($body, qr/&subs::ui\('Read the board'\)/, 'the button says what it does, translatably');
like($body, qr/&subs::ui\('Ask the board what it is wired for and which pins it can see'\)/,
	'with a hint in the same words');
my $read_at = index($body, 'id="embedded_board_read"');
my $gpio_at = index($body, q~<% if ($view eq 'gpio') { %>~);
ok($read_at > $gpio_at, 'the button sits in the GPIO view');
my $before = substr($body, ($read_at - 800 < 0 ? 0 : $read_at - 800), 800);
like($before, qr/\$edt eq 'microcontroller'/, 'and only a board is offered it');

# --- the script calls both fixed routes -----------------------------------
my $js = js_source('public/js/manager/embedded.js');
like($js, qr{url: '/manager/embedded/board_pins'}, 'the read route is called');
like($js, qr{url: '/manager/embedded/board_pins_attach'}, 'and the attach route');
like($js, qr/var chip_id = embeddedChipId\(\)/, 'the read asks the panel for its chip id');
like($js, qr/chip_id: chip_id/, 'and sends it');
like($js, qr/edt: 'microcontroller'/, 'the read names a board');
like($js, qr/dataType: 'json'/, 'both answers are read as JSON');
ok(index($js, q{url: '/manager/embedded/board_pins'}) < index($js, q{url: '/manager/embedded/board_pins_attach'}),
	'the read is defined before the attach');

# --- the found section says what the board has ----------------------------
like($js, qr/function embeddedBoardText\(text\)/, 'one helper carries the labels');
like($js, qr/jawnosT\(text\)/, 'and it is jawnosT');
like($js, qr/report\.components/, 'the found section reads the configured parts');
like($js, qr/report\.probe/, 'and the probed pins');
like($js, qr/embeddedBoardText\('switched to ground'\)/, 'a grounded pin is in plain words');
like($js, qr/embeddedBoardText\('tied high'\)/, 'so is a pin tied high');
like($js, qr/embeddedBoardText\('unclear'\)/, 'and an unknown one');
like($js, qr/embeddedBoardText\('configured'\)/, 'the summary counts the configured parts');
like($js, qr/embeddedBoardText\('pins free'\)/, 'the free pins');
like($js, qr/embeddedBoardText\('looked wired'\)/, 'and the pins that look wired');
like($js, qr/embeddedBoardText\('\(no appointment\)'\)/, 'an unwired part says so');

# --- a discovered pin attaches with one more press ------------------------
like($js, qr/'relay', 'led', 'servo', 'button', 'switch', 'pot'/, 'the part list offers the pin types');
like($js, qr/pin_kind === 'grounded'/, 'a grounded pin defaults to a button');
like($js, qr/analog/, 'an analog-looking pin defaults to a pot');
like($js, qr/class="embedded_board_attach"/, 'each discovered pin has an attach button');
like($js, qr/embeddedBoardText\('Attach'\)/, 'labelled translatably');
like($js, qr/\.embedded_board_attach/, 'and its press is handled');
like($js, qr/pin: pin,/, 'the attach carries the pin');
like($js, qr/component: component,/, 'the chosen part');
like($js, qr/app: app,/, 'and the appointment');
like($js, qr/inverted: '',/, 'with the backend\'s remaining fields');
like($js, qr/movement: ''/, 'kept explicit');
like($js, qr/row\.replaceWith/, 'an accepted attach replaces its row');
like($js, qr/embeddedBoardText\('Attached'\)/, 'with a confirmation line');

# --- a failure is text in place, never a dialog ---------------------------
like($js, qr/response && response\.error/, 'the returned error is shown');
like($js, qr/embeddedBoardText\('Could not read the board'\)/, 'a failed read says so');
like($js, qr/embeddedBoardText\('Attach failed'\)/, 'a failed attach says so');
unlike($js, qr{^[^/]*\balert\s*\(}m, 'and no alert box is opened');

# --- the help topic explains the flow in the on-screen words --------------
my $help = $read->('perl/help/topics_configure.pl');
my ($topic) = $help =~ /(\$topic\{'embedded'\} = \{.*?\n\t\};)/s;
ok($topic, 'the embedded topic is one block');
like($topic, qr/Read the board/, 'the topic names the button');
like($topic, qr/press Attach/, 'and the attach press');
like($topic, qr/configured for, how many pins are free/, 'it says what the read shows');

done_testing();
