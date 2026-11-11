# tests-for: lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Domain/Log.pm lib/JawnOS/Controller/manager_misc7.pm templates/handbook/handbook.html.ep templates/appointment_details.html.ep
# covers:    A note belongs to a session, not to one app: the same uuid can be
#            written on three app rows and only one carries the ciphertext, so
#            the reader asks by uuid and decrypts with the session's key. What it
#            returns is drawn raw, so it passes the article allowlist (a stored
#            <script> or onerror= never reaches the browser), and the log reader
#            marks every row sharing a uuid that has notes so the icon shows.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;
use JawnOSTest;

# The domain layer is lazy: load the real definitions before the stubs below, or
# a later load would replace the stub.
subs::preload('note_retriever');
subs::preload('article_html_clean');

# The smallest stand-in for a Mojo::SQLite::Results row list.
package FakeRows;
sub new {
	my ($class, $hashes) = @_;
	return bless { hashes => $hashes || [] }, $class;
}
sub hashes { $_[0]->{'hashes'} }

package main;

my ($rows, @selects, @decrypts);

# note_retriever reads db_select and note_decrypter through the package, so a
# local glob replaces them for the call and records what it asked.
sub _run {
	my ($uuid, $suds) = @_;
	@selects = ();
	@decrypts = ();
	local *subs::db_select = sub {
		push @selects, [@_];
		return FakeRows->new($rows);
	};
	local *subs::note_decrypter = sub {
		my ($secret, $value, $ost) = @_;
		push @decrypts, [ $secret, $value, $ost ];
		return '' unless defined $value && length $value;
		return "first note\nsecond line" if $value eq 'cipher-note';
		return 'safe <img src="/images/x.png" onerror="alert(1)"><script>alert(2)</script>' if $value eq 'cipher-bad';
		return "plain $value";
	};
	return &subs::note_retriever($uuid, $suds);
}

# The live shape: one uuid on three app rows, only the programming row holding
# the ciphertext. The caller names no app at all - it has the uuid.
$rows = [
	{ start_notes => '', notes => '', end_notes => '', ost => undef },
	{ start_notes => '', notes => 'cipher-note', end_notes => '', ost => 'ost-123' },
	{ start_notes => '', notes => '', end_notes => '', ost => undef },
];

my $notes = _run('shared-uuid', 'SUDS');

# (a) the reader asks by uuid, never by app, and finds the note although the
# caller could not say which app owns it.
is(scalar @selects, 1, 'one query for the session');
is($selects[0]->[0], 'appointments', 'it reads appointments');
is_deeply($selects[0]->[2], { uuid => 'shared-uuid' }, 'the query filters by uuid alone, with no app');
ok(!exists $selects[0]->[2]->{'app'}, 'no app is in the filter');
is_deeply($selects[0]->[1], [qw(start_notes notes end_notes ost)], 'it selects the encrypted fields and the timestamp it decrypts with');
like($notes, qr/first note<br>second line/, 'the note from the sibling app row comes back');
unlike($notes, qr/^<br>|<br>$/, 'the empty rows leave no stray separators');

# (b) the row's ost reaches note_decrypter with the session key.
is(scalar @decrypts, 1, 'only the non-empty ciphertext is decrypted');
is($decrypts[0]->[0], 'SUDS', 'the session key is used');
is($decrypts[0]->[1], 'cipher-note', 'the stored ciphertext is passed');
is($decrypts[0]->[2], 'ost-123', 'the row ost is passed to note_decrypter');

# Identical text on two rows is joined once.
$rows = [
	{ notes => 'cipher-note', ost => 'ost-123' },
	{ notes => 'cipher-note', ost => 'ost-123' },
];
my $deduped = _run('shared-uuid', 'SUDS');
is(($deduped =~ /first note/g), 1, 'identical notes are not repeated');

# (c) the raw-drawn result is passed through the article allowlist, so a stored
# payload arrives as inert markup.
$rows = [ { notes => 'cipher-bad', ost => undef } ];
my $clean = _run('shared-uuid', 'SUDS');
like($clean, qr/safe/, 'the note text survives');
unlike($clean, qr/onerror/i, 'an onerror attribute is stripped');
unlike($clean, qr/<script/i, 'a script tag is dropped');
unlike($clean, qr/alert\(2\)/, 'a script element content is dropped too');

# Empty and undefined sessions are handled without a query.
@selects = ();
is(&subs::note_retriever(undef, 'SUDS'), '', 'an undefined uuid returns empty');
is(&subs::note_retriever('', 'SUDS'), '', 'an empty uuid returns empty');
is(scalar @selects, 0, 'neither asks the database');
$rows = [ { notes => '', ost => undef } ];
is(_run('empty-uuid', 'SUDS'), '', 'a session with no note returns empty, not markup');

# (d) the log reader marks every row sharing a uuid that has notes; the route
# passes the session's key; the handbook uses the new signature.
my $root = repo_root();
my $log = read_file("$root/lib/JawnOS/Domain/Log.pm");
like($log, qr/select distinct uuid from appointments where uuid in \(\$placeholders\) and \(length\(notes\)>0 or length\(start_notes\)>0 or length\(end_notes\)>0\)/,
	'the log reader asks once which uuids in the view have notes');
like($log, qr/\$uuid_has_notes\{\$_->\{'uuid'\}\} = 1 foreach @\{ \$rows->hashes \};/,
	'it records the uuids, not the note text');
like($log, qr/\$a->\{'notes'\} = 'redacted' if \$a->\{'uuid'\} && \$uuid_has_notes\{\$a->\{'uuid'\}\};/,
	'every row sharing the uuid is marked, so the notes icon shows');

my $route = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
like($route, qr/my \$notekeeper = &subs::note_retriever\(\$uuid, &subs::session_suds\(\$c\) \|\| &subs::suds_grabber\(\)\);/,
	'the note_retriever route passes the session key');
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc7.pm");
like($routes, qr{\[25901, 'get', '/manager/note_retriever', 'action_25901'\]},
	'the route keeps its /manager/ path, behind the session gate');

my $handbook = read_file("$root/templates/handbook/handbook.html.ep");
like($handbook, qr/&subs::note_retriever\(\$app->\{'uuid'\}, &subs::session_suds\(\$c\) \|\| &subs::suds_grabber\(\)\)/,
	'the handbook calls the reader with the new signature');

done_testing();
