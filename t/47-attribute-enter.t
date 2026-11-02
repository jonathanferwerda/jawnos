# tests-for: lib/JawnOS.pm lib/JawnOS/Controller/ lib/JawnOS/Manager.pm lib/JawnOS/Manager/ lib/JawnOS/Routes.pm lib/JawnOS/Routes/ perl/Manager.pl public/css/manager.css public/js/manager/attributes.js public/js/manager/attributes/ public/js/manager/soft_keyboard.js public/js/manager/soft_keyboard/ templates/appointment_wrapper.html.ep templates/pos/attributes.html.ep
# covers:    The appointment's Register panel draws a blank row for each attribute kind (model, option, option_category, su...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The appointment's Register panel draws a blank row for each attribute kind
# (model, option, option_category, subcategory). It used to save only from the
# field's change event: a desk browser does not blur a plain text input for
# Enter, and the JawnOS soft keyboard dispatches the key event only, so a name
# typed and confirmed with Enter was never written.
#
# The panel is also the audit's subject: its fields were unlabeled, its parts
# floated with <br>, and the register rows carried the same generic model /
# option class names as the transaction selectors, so the wrapper's pink,
# lightgreen and lightblue painted both. The tests below pin the roads that
# replaced that: a direct save shared by change, Enter and the Add/Save
# buttons, and a labeled, themed container.

my $js = js_source('public/js/manager/attributes.js');
my $soft = js_source('public/js/manager/soft_keyboard.js');
my $template = read_file("$FindBin::Bin/../templates/pos/attributes.html.ep");
my $wrapper = read_file("$FindBin::Bin/../templates/appointment_wrapper.html.ep");
my $css = read_file("$FindBin::Bin/../public/css/manager.css");
my $manager = manager_source();

# --- the fields exist --------------------------------------------------------
like($template, qr/<input class="att name" type="text" name="name"/,
	'the new model/option row carries an att name field');
like($template, qr/<input class="char" char_input="name"/,
	'a new characteristic carries a char name field');

# --- saving does not depend on a blur ----------------------------------------
like($js, qr/function attributeSave\(att\)/,
	'the row save is a function the three roads can share');
like($js, qr/\$\(document\)\.on\('change', '\.att', function\(\) \{\s*attributeSave\(/s,
	'a change still saves the row');
like($js, qr/\$\(document\)\.on\('click', '\.attribute_add, \.attribute_save'/,
	'the Add and Save buttons save the row');
like($js, qr/if \(\$\(this\)\.is\('\.char'\)\) \{ \$\(this\)\.trigger\('change'\); \}\s*else \{ attributeSave\(/s,
	'Enter saves directly instead of relying on a blur');
like($js, qr/att\.data\('att_saving'\) \|\| att\.data\('att_saved'\)/,
	'a save in flight, or a row already added, cannot be inserted twice');
like($js, qr/ac\.data\('char_saving'\) \|\| ac\.data\('char_saved'\)/,
	'a characteristic is guarded the same way');
like($soft, qr/\$\(el\)\.trigger\(\$\.Event\('keydown', \{ key: 'Enter', keyCode: 13/,
	'the soft keyboard sends Enter through the same handler');

# --- the container is labeled and themed ------------------------------------
like($template, qr/attribute_label/, 'fields carry a visible label, not only a placeholder');
like($template, qr/inputmode="decimal"/, 'numeric fields ask for a numeric keyboard');
like($template, qr/class="attribute_add att_add_button"/, 'the new row has an explicit Add button');
like($template, qr/class="attribute_save"/, 'an existing row has an explicit Save button');
unlike($template, qr/foreach my \$a \(/, 'the row loop no longer shadows the app variable');
like($manager, qr/template => 'pos\/attributes',\s*att => \$att,\s*app => \$app/s,
	'the template is rendered with an app variable, not a shadowing a');
my @wrong_render = grep { /pos\/attributes/ && /a => \$app/ } split /\n/, $manager;
is(scalar @wrong_render, 0, 'no render site still passes a => $app');
unlike($template, qr/class="tiny_thumb delete_characteristic"[^>]*uuid=[^>]*uuid=/s,
	'the characteristic delete button no longer carries uuid twice');
unlike($js, qr/\.next\(\)\.remove\(\)/,
	'deleting a characteristic no longer eats the next node (there is no separator now)');
unlike($wrapper, qr/\.model\s*\{[^}]*pink/s, 'the wrapper no longer paints the model class');
unlike($wrapper, qr/\.option\s*\{[^}]*lightgreen/s, 'the wrapper no longer paints the option class');
unlike($css, qr/\.register_model\s*\{[^}]*pink/s, 'the register model is no longer pink');
unlike($css, qr/\.subcategory\s*\{[^}]*red/s, 'the register subcategory is no longer red');
like($css, qr/\.attribute_section/, 'the fields are laid out in labeled sections');
like($css, qr/var\(--panel\)/, 'the cards use the theme, not a fixed colour');
like($css, qr/\.attribute_label/, 'the container style defines the visible field label');
like($css, qr/\.attribute_default_controls/, 'the default pickers get a responsive grid');

done_testing;
