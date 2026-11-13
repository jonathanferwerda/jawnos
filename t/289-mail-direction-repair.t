# tests-for: lib/JawnOS/Domain/People.pm lib/JawnOS/Domain/Loader.pm scripts/mail_direction_repair.pl
# covers:    the direction the phone's message store recorded in an sms
#           appointment note, and the repair tool that reads it back.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();

# The store's own type is the first word of the note, followed by a colon and the
# body. A body that merely begins with the word is not a type.
is( &subs::mail_direction_from_note('Sent: hello'), 'sent', 'Sent: is outgoing' );
is( &subs::mail_direction_from_note('Inbox: hello'), 'inbox', 'Inbox: is incoming' );
is( &subs::mail_direction_from_note('Received: hello'), 'inbox', 'Received: is incoming' );
is( &subs::mail_direction_from_note('Recieved: hello'), 'inbox', 'the old misspelling is incoming too' );
is( &subs::mail_direction_from_note('Draft: hello'), 'draft', 'Draft: keeps its own status' );
is( &subs::mail_direction_from_note('  Inbox:  hello'), 'inbox', 'leading space is allowed' );
is( &subs::mail_direction_from_note('Sent hello'), undef, 'a body that starts with Sent is not a type' );
is( &subs::mail_direction_from_note('no direction here'), undef, 'a note with no type has no direction' );
is( &subs::mail_direction_from_note(''), undef, 'an empty note has no direction' );
is( &subs::mail_direction_from_note(undef), undef, 'a missing note has no direction' );

my $script = read_file("$root/scripts/mail_direction_repair.pl");
like( $script, qr/--duplicates/, 'the repair can clear the duplicate imports' );
like( $script, qr/--seal-plain/, 'and seal a legacy plain sms body' );
like( $script, qr/--thread-duplicates/, 'and collapse a chat-send / import duplicate' );
like( $script, qr/--same-window/, 'with a window that keeps separate sends apart' );
like( $script, qr/\$norm_phone/, 'the appointment join normalizes a leading country code' );
like( $script, qr/\$wanted_phones\{ \$norm_phone->/, 'and matches the mailbox number the same way' );
like( $script, qr/my \@exact = grep/, 'an appointment prefers the row at its own timestamp' );
like( $script, qr/my \@exact = grep/, 'an appointment prefers the row at its own timestamp' );
like( $script, qr/my \$own = \$note_type\{/, 'a window cannot borrow a row whose own note disagrees' );
like( $script, qr/\^call from:/, 'a screened call transcript is read as incoming' );
like( $script, qr/same-event duplicates/, 'the same message filed in both directions is collapsed' );
like( $script, qr/records_mailbox_tombstone\(\$dup\)/, 'the spare copy is tombstoned' );
like( $script, qr/records_mailbox_tombstone\(\$r\)/, 'the duplicate pass uses the records tombstone' );
like( $script, qr/records_mailbox_repair_date\(\$r->\{'uuid'\}, \$fix\)/, 'and its date repair' );
like( $script, qr/mail_direction_from_note/, 'the direction comes from the appointment note' );
like( $script, qr/eq 'ignored'/, 'a row the person ignored is never rewritten' );
like( $script, qr/JAWNOS_ROOT/, 'the tool can name the tree that holds the live database' );

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like( $loader, qr/\bmail_direction_from_note\b/, 'the helper is in the domain loader' );

done_testing();
