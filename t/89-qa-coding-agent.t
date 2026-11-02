use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../qa/coding_night/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Find ();
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use JSON::PP;

require CodingContext;
require CodingEdit;

# The 06:00 agent (qa/coding_night/agent.pl).
#
# Every test that runs the agent uses a temp worktree and a fixture context
# directory. No real model is called: the "model" is a fixture responder, a
# small Perl file returning { call => sub { ... } }. The one live read is the
# real help registry, which is checked without writing or calling anything.

my $repo  = abs_path("$FindBin::Bin/..");
my $agent = "$repo/qa/coding_night/agent.pl";

# --- fixtures ---------------------------------------------------------------

sub fixture_context {
	my (%a) = @_;
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/docs", "$dir/qa");
	write_file("$dir/AGENTS.md", <<'MD');
# AGENTS.md - fixture rules

RULE 1 - Stop and ask after 3 attempts.
Every behaviour change ships with a test. Run `prove -l t` before the commit.
The finishing routine - ALWAYS run it: bump -> commit -> push -> restart.
The old notes used to live at /home/qa/jawnos/lib/JawnOS.pm.
ssh password: hunter2
API_KEY=sk-live-123
secret = topsecret
credential: cred-abc
signatorial=deadbeef
ticket=123e4567-e89b-12d3-a456-426614174000
the host keys live in .secrets/fixture-ssh.txt
config.json holds {"private": "fixture-config-value"}
MD
	my $body = "Deep notes start.\n"
		. "-----BEGIN RSA PRIVATE KEY-----\n"
		. "MIIEowIBAAKCAQEA-fixture-body-must-not-survive\n"
		. "-----END RSA PRIVATE KEY-----\n"
		. ("filler line for truncation\n" x 1200)
		. "TAIL-MARKER-MUST-NOT-BE-SENT\n";
	write_file("$dir/docs/AGENTS-notes.md", $body);
	write_file("$dir/qa/README.md", "# QA\n\nRun prove -l t.\n");
	return $dir;
}

sub fixture_worktree {
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/perl", "$dir/public/js/manager", "$dir/database");
	write_file("$dir/perl/thing.pl", "use strict;\nprint \"old\\n\";\n");
	write_file("$dir/public/js/manager/thing.js", "var thing = 1;\n");
	write_file("$dir/database/jawnos.db", "this is not a database\n");
	write_file("$dir/config.json", "{\"private\":\"value\"}\n");
	return $dir;
}

sub write_responder {
	my ($path, $source) = @_;
	write_file($path, $source);
	return $path;
}

sub run_agent {
	my (%a) = @_;
	my @args = @{ $a{'args'} || [] };
	my $pid = open(my $fh, '-|');
	die "fork: $!" unless defined $pid;
	if (!$pid) {
		chdir $a{'worktree'} or exit 127;
		$ENV{'JAWNOS_NOTE_ID'}    = $a{'id'}    // 'note-fixture';
		$ENV{'JAWNOS_NOTE_TITLE'} = $a{'title'} // 'A fixture note';
		$ENV{'JAWNOS_NOTE_TEXT'}  = $a{'text'}  // 'Change the fixture file.';
		$ENV{'RESP_LOG'} = $a{'log'} if defined $a{'log'};
		open(STDERR, '>&', \*STDOUT);
		exec($^X, $agent, @args);
		exit 127;
	}
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return (($? >> 8), $out);
}

sub snapshot {
	my ($dir) = @_;
	my %files;
	File::Find::find({ no_chdir => 1, wanted => sub {
		return unless -f $File::Find::name;
		my $path = $File::Find::name;
		open(my $fh, '<:raw', $path) or return;
		local $/;
		$files{$path} = <$fh> // '';
		close $fh;
	} }, $dir);
	return \%files;
}

# --- redaction --------------------------------------------------------------
my $secrets = <<'FIX';
this line stays
password: hunter2
PASSPHRASE = correct-horse
API_KEY=sk-live-123
api key: abcd1234
secret = topsecret
credential: cred-abc
signatorial=deadbeef
ticket=123e4567-e89b-12d3-a456-426614174000
the host keys live in .secrets/ssh.txt
the live ticket lives in .shots/ticket.txt
config.json holds {"port": 3000, "private": "cfg-value"}
downloads.json lists /tmp/a-download
the server key is server.pem
Cookie: president=abcdef
Authorization: Bearer abcdefghijklmnop
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA-fixture-body-must-not-survive
-----END RSA PRIVATE KEY-----
FIX

my ($redacted, $redaction_count) = CodingContext::redact_text($secrets);
like($redacted, qr/this line stays/, 'ordinary prose survives redaction');
for my $needle (qw(hunter2 correct-horse sk-live-123 abcd1234 topsecret cred-abc
	deadbeef 123e4567 president=abcdef Bearer abcdefghijklmnop MIIEow
	.ssh ssh.txt .shots ticket.txt config.json cfg-value downloads.json server.pem)) {
	unlike($redacted, qr/\Q$needle\E/, "the fixture secret '$needle' does not survive");
}
unlike($redacted, qr/BEGIN RSA PRIVATE KEY/, 'the PEM header is gone');
cmp_ok($redaction_count, '>=', 15, 'each secret line is counted');

my ($value_note, $value_count) = CodingContext::redact_values(
	"Fix the password field in the login form.\npassword: hunter2\n");
like($value_note, qr/Fix the password field/, 'a note that talks about a password field survives');
unlike($value_note, qr/hunter2/, 'a pasted password value does not');
is($value_count, 1, 'one value was redacted');

# --- truncation -------------------------------------------------------------
my $long = 'a' x (CodingContext::max_doc_bytes() + 500);
my ($kept, $kept_bytes, $truncated, $original_bytes) = CodingContext::truncate_text($long);
ok($truncated, 'a document over the cap is truncated');
is($kept_bytes, CodingContext::max_doc_bytes(), 'exactly the cap is kept');
is($original_bytes, length($long), 'the original size is reported');
is(length($kept), CodingContext::max_doc_bytes(), 'the kept text is the cap for ASCII');

my $wide = "\x{00e9}" x 12000;    # 2 bytes each in UTF-8
my ($wkept, $wbytes, $wtrunc) = CodingContext::truncate_text($wide);
ok($wtrunc, 'a multibyte document is truncated too');
cmp_ok($wbytes, '<=', CodingContext::max_doc_bytes(), 'the truncation does not exceed the cap in bytes');
ok(!utf8::is_utf8($wkept) || length($wkept) <= 12000, 'the kept text is on a character boundary');

# --- absolute home paths become repository-relative -------------------------
my $absolute = CodingContext::relativize('see /home/qa/jawnos/lib/JawnOS.pm and /home/qa/.config');
unlike($absolute, qr{/home/}, 'no absolute home path survives relativize');
like($absolute, qr{\./lib/JawnOS\.pm}, 'a repository path becomes relative to the repo');

# --- the assembled context and the dry run ----------------------------------
my $ctx = fixture_context();
my $wt  = fixture_worktree();
my $before = snapshot($wt);

my ($dry_rc, $dry_out) = run_agent(
	worktree => $wt,
	args     => [ '--dry-run', '--context-dir', $ctx ],
	title    => 'Fix the thing',
	text     => 'The app is wrong; make it right.',
);
is($dry_rc, 0, 'a dry run exits 0');
like($dry_out, qr/RULE 1 - Stop and ask after 3 attempts/, 'the project rules are in the prompt');
like($dry_out, qr/Every behaviour change ships with a test/, 'the testing rule is in the prompt');
like($dry_out, qr/TRUNCATED/, 'a truncated document is declared in the prompt');
unlike($dry_out, qr/TAIL-MARKER-MUST-NOT-BE-SENT/, 'the part past the cap was not sent');
unlike($dry_out, qr/hunter2|sk-live-123|topsecret|cred-abc|deadbeef|123e4567|MIIEow|fixture-ssh|fixture-config-value/,
	'no fixture secret reaches the prompt');
like($dry_out, qr/===== SYSTEM PROMPT =====/, 'the dry run prints the prompt');
like($dry_out, qr/help topic: none matched/, 'a context without a help registry says so');
like($dry_out, qr/planned calls/, 'the dry run prints the call plan');

my ($system_part) = $dry_out =~ /===== SYSTEM PROMPT =====\n(.*?)\n===== USER MESSAGE/s;
ok(defined $system_part, 'the system prompt has a boundary');
unlike($system_part // '', qr{/home/}, 'the system prompt carries no absolute home path');

is_deeply(snapshot($wt), $before, 'a dry run writes nothing');

# --- the help topic the note names ------------------------------------------
my $registry = CodingContext::help_registry($repo);
ok(!$registry->{'error'}, 'the real help registry loads');
is(CodingContext::help_topic_for('The Chat app drops LoRa messages', $registry->{'topics'}),
	'chat', 'a note that names Chat picks the chat topic');
is(CodingContext::help_topic_for('Budget screen totals are wrong', $registry->{'topics'}),
	'budget', 'a note that names Budget picks the budget topic');
is(CodingContext::help_topic_for('something entirely unrelated', $registry->{'topics'}),
	undef, 'a note that names no app picks no topic');

# The real AGENTS.md, not just the fixture: its rules are the ones a coding
# agent here has to follow, so the assembled prompt must carry them.
my $real = CodingContext::assemble(context_dir => $repo, note_text => 'Chat');
like($real->{'system'}, qr/Every behaviour change ships with a test/,
	"the repository's own testing rule is in the prompt");
like($real->{'system'}, qr/RULE 1[^\n]*Stop and ask after 3 attempts/,
	'the repository rule about three attempts is in the prompt');
like($real->{'system'}, qr/TRUNCATED/, 'the real deep notes are declared truncated');
unlike($real->{'system'}, qr{/home/}, 'the real system prompt carries no absolute home path');
is($real->{'help_topic'}, 'chat', 'the real assembly picks the chat topic');

# --- no model is exit 3 ------------------------------------------------------
my ($nomodel_rc, $nomodel_out) = run_agent(
	worktree => $wt,
	args     => [ '--context-dir', $ctx ],
	text     => 'Change the file.',
);
is($nomodel_rc, 3, 'no Coding model is exit 3');
like($nomodel_out, qr/no Coding model is configured/i, 'the reason is printed');
is(read_file("$wt/perl/thing.pl"), "use strict;\nprint \"old\\n\";\n",
	'no model changed nothing');

# --- path rejection ----------------------------------------------------------
my @bad_paths = (
	'../escape.txt', '/tmp/jawn-agent-escape.txt', '.secrets/ssh.txt',
	'.git/config', '.shots/ticket.txt', '.president/control', 'releases/x.apk',
	'database/jawnos.db', 'database/jawnos.db-wal', 'config.json',
	'downloads.json', 'big.png', 'key.pem', "a/../../b",
);
unlink '/tmp/jawn-agent-escape.txt';
unlink "$wt/../escape.txt";
for my $path (@bad_paths) {
	my $r = CodingEdit::apply_edits($wt, [ { path => $path, content => "x\n" } ], { bytes => 0 });
	ok(!$r->{'ok'}, "the path '$path' is refused");
}
ok(!-e '/tmp/jawn-agent-escape.txt', 'an absolute path did not write outside the worktree');
ok(!-e "$wt/../escape.txt", 'a parent path did not write beside the worktree');
is(read_file("$wt/database/jawnos.db"), "this is not a database\n", 'the database was not touched');

SKIP: {
	my $outside = tempdir(CLEANUP => 1);
	skip 'symlinks are not available here', 2 unless eval { symlink($outside, "$wt/link") };
	my ($abs, $why) = CodingEdit::resolve($wt, 'link/out.txt');
	ok(!defined $abs, 'a symlinked directory is refused');
	like($why // '', qr/symlink/, 'the reason names the symlink');
}

# --- the byte budget ---------------------------------------------------------
my $too_big = 'x' x (CodingEdit::max_changed_bytes() + 1);
my $big = CodingEdit::apply_edits($wt, [ { path => 'big.txt', content => $too_big } ], { bytes => 0 });
ok(!$big->{'ok'}, 'a write over the byte budget is refused');
like(join(' ', @{ $big->{'errors'} || [] }), qr/budget/, 'the refusal names the budget');
ok(!-e "$wt/big.txt", 'the over-budget file was not written');

my $near = CodingEdit::apply_edits($wt, [ { path => 'near.txt', content => 'y' x 10 } ],
	{ bytes => CodingEdit::max_changed_bytes() - 5 });
ok(!$near->{'ok'}, 'the budget is cumulative across turns, not per turn');
ok(!-e "$wt/near.txt", 'the cumulative refusal wrote nothing');

# --- a fixture model makes the expected edit ---------------------------------
my $edit_resp = write_responder("$ctx/responder-edit.pl", <<'RESP');
+{
	call => sub {
		my ($system, $messages, $turn) = @_;
		require JSON::PP;
		return JSON::PP::encode_json({
			edits => [ { path => 'perl/thing.pl', content => "use strict;\nprint \"new\\n\";\n" } ],
			done  => 1,
			note  => 'changed the message',
		});
	},
}
RESP

my ($edit_rc, $edit_out) = run_agent(
	worktree => $wt,
	args     => [ '--context-dir', $ctx, '--responder', $edit_resp, '--max-turns', '3' ],
);
is($edit_rc, 0, 'a fixture model edit exits 0');
is(read_file("$wt/perl/thing.pl"), "use strict;\nprint \"new\\n\";\n", 'the fixture edit landed');
like($edit_out, qr/checks pass/, 'the Perl check passed');

# --- a check failure is fed back, then fixed ---------------------------------
write_file("$wt/perl/thing.pl", "use strict;\nprint \"old\\n\";\n");
my $fix_resp = write_responder("$ctx/responder-fix.pl", <<'RESP');
my $calls = 0;
+{
	call => sub {
		my ($system, $messages, $turn) = @_;
		$calls++;
		require JSON::PP;
		if ($turn == 1) {
			return JSON::PP::encode_json({
				edits => [ { path => 'perl/thing.pl', content => "use strict;\nsub broken {\n" } ],
				done  => 0,
			});
		}
		my $observation = $messages->[-1]->{'content'} // '';
		die "the check failure was not fed back\n" unless $observation =~ /Checks: FAIL/;
		return JSON::PP::encode_json({
			edits => [ { path => 'perl/thing.pl', content => "use strict;\nsub fixed { return 1 }\n1;\n" } ],
			done  => 1,
		});
	},
}
RESP

my ($fix_rc, $fix_out) = run_agent(
	worktree => $wt,
	args     => [ '--context-dir', $ctx, '--responder', $fix_resp, '--max-turns', '3' ],
);
is($fix_rc, 0, 'the model can fix a failing check and finish');
like($fix_out, qr/checks FAIL/, 'the first turn failed its check');
is(read_file("$wt/perl/thing.pl"), "use strict;\nsub fixed { return 1 }\n1;\n",
	'the corrected file is the one on disk');

# --- a unified diff is accepted ----------------------------------------------
write_file("$wt/perl/thing.pl", "use strict;\nprint \"old\\n\";\n");
my $diff_resp = write_responder("$ctx/responder-diff.pl", <<'RESP');
+{
	call => sub {
		require JSON::PP;
		my $diff = "--- a/perl/thing.pl\n+++ b/perl/thing.pl\n@@ -1,2 +1,2 @@\n"
			. " use strict;\n-print \"old\\n\";\n+print \"diffed\\n\";\n";
		return JSON::PP::encode_json({ diff => $diff, done => 1, note => 'a diff' });
	},
}
RESP

my ($diff_rc, $diff_out) = run_agent(
	worktree => $wt,
	args     => [ '--context-dir', $ctx, '--responder', $diff_resp, '--max-turns', '3' ],
);
is($diff_rc, 0, 'a unified diff exits 0');
is(read_file("$wt/perl/thing.pl"), "use strict;\nprint \"diffed\\n\";\n", 'the diff applied');

# --- the turn cap -------------------------------------------------------------
my $log = "$ctx/turns.log";
my $loop_resp = write_responder("$ctx/responder-loop.pl", <<'RESP');
my $calls = 0;
+{
	call => sub {
		my ($system, $messages, $turn) = @_;
		$calls++;
		if (my $log = $ENV{'RESP_LOG'}) {
			open(my $fh, '>>', $log) or die $!;
			print $fh "call $calls\n";
			close $fh;
		}
		require JSON::PP;
		return JSON::PP::encode_json({
			edits => [ { path => 'notes.txt', content => "turn $calls\n" } ],
			done  => 0,
		});
	},
}
RESP

my ($loop_rc) = run_agent(
	worktree => $wt,
	args     => [ '--context-dir', $ctx, '--responder', $loop_resp, '--max-turns', '2' ],
	log      => $log,
);
is($loop_rc, 1, 'a model that never finishes exits 1 at the turn cap');
my @calls = grep { /\S/ } split /\n/, (eval { read_file($log) } // '');
is(scalar @calls, 2, 'the turn cap is the number of model calls, no more');

# --- usage and environment ----------------------------------------------------
my ($bad_rc) = run_agent(
	worktree => $wt,
	args     => [ '--context-dir', "$ctx/nowhere" ],
);
is($bad_rc, 2, 'a missing main checkout is exit 2');

my ($unknown_rc) = run_agent(
	worktree => $wt,
	args     => [ '--nonsense' ],
);
is($unknown_rc, 2, 'an unknown argument is a usage failure');

done_testing();
