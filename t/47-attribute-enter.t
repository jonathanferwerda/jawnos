use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

# The appointment's Register panel draws a blank row for each attribute kind
# (model, option, option_category, subcategory) and saves a row from its
# field's change event. Pressing Enter never fired that event: a desk browser
# does not blur a plain text input for Enter, and the JawnOS soft keyboard only
# dispatches the key event. So a model or option name typed and then confirmed
# with Enter was never written - it looked like the panel did nothing.

my $js = read_file("$FindBin::Bin/../public/js/manager/attributes.js");
my $soft = read_file("$FindBin::Bin/../public/js/manager/soft_keyboard.js");
my $template = read_file("$FindBin::Bin/../templates/pos/attributes.html.ep");

like($template, qr/<input class="att name" type="text" name="name"/,
	'the new model/option row carries an att name field');
like($template, qr/<input class="char" char_input="name"/,
	'a new characteristic carries a char name field');

my ($handler) = $js =~ /(\$\(document\)\.on\('keydown', '\.att, \.char'.*?\n\}\);)/s;
ok(defined $handler, 'Enter is bound to the register fields');
like($handler, qr/e\.key !== 'Enter' && e\.keyCode !== 13/,
	'Enter is recognised by name and key code');
like($handler, qr/textarea, select, input\[type="checkbox"\]/,
	'a textarea, select or checkbox keeps its own Enter');
like($handler, qr/\$\(this\)\.blur\(\)/,
	'Enter leaves the field, which fires the change that saves it');

like($js, qr/\$\(document\)\.on\('change', '\.att',/,
	'the save still rides the change event');
like($soft, qr/\$\(el\)\.trigger\(\$\.Event\('keydown', \{ key: 'Enter', keyCode: 13/,
	'the soft keyboard sends Enter through the same handler');

done_testing;
