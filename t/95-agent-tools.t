# tests-for: qa/coding_night/lib/CodingEdit.pm
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../qa/lib", "$FindBin::Bin/../qa/coding_night/lib", "qa/lib", "qa/coding_night/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use CodingEdit;

# The agent has no shell. These checks pin the two ways it may look at the tree
# (read/grep) and the parser rule that a reply followed by prose is still a
# reply - both were found by a real run that refused to guess.

# --- a JSON object followed by prose ----------------------------------------
{
	my $reply = '{"done":true,"note":"no change"} I hope that helps.';
	my ($p, $e) = CodingEdit::parse_model_response($reply);
	is($e, undef, 'trailing prose does not make the object unparseable');
	ok($p->{'done'}, 'the done flag survives');

	my $two = '{"done":true}{"done":false}';
	($p, $e) = CodingEdit::parse_model_response($two);
	is($e, undef, 'the first balanced object is used');
	ok($p->{'done'}, 'and it is the first one');
}

# --- a read/grep request is a tool turn, not an edit -------------------------
{
	my ($p, $e) = CodingEdit::parse_model_response('{"read":["lib/a.pm"]}');
	is($e, undef, 'a read request parses');
	is_deeply($p->{'read'}, ['lib/a.pm'], 'the paths are carried');
	ok(!@{ $p->{'edits'} }, 'a read request is not an edit');

	($p, $e) = CodingEdit::parse_model_response('```json' . "\n" . '{"grep":"notes_category"}' . "\n" . '```');
	is($e, undef, 'a fenced grep parses');
	is($p->{'grep'}, 'notes_category', 'the pattern is carried');
}

# --- read_tools: bounded, inside the worktree, read-only ---------------------
{
	my $root = tempdir(CLEANUP => 1);
	make_path("$root/lib", "$root/.secrets");
	write_file("$root/lib/a.pm", "package A;\nsub notes_category_rows { 1 }\n");
	write_file("$root/.secrets/key", "do not show this\n");
	write_file("$root/big.txt", 'x' x 9000);

	my $out = CodingEdit::read_tools($root, { read => ['lib/a.pm'] });
	like($out, qr/sub notes_category_rows/, 'a requested file is returned');
	like($out, qr/END FILE lib\/a\.pm/, 'the block is closed');

	$out = CodingEdit::read_tools($root, { read => ['../etc/passwd'] });
	like($out, qr/refused/, 'a parent-directory path is refused');

	$out = CodingEdit::read_tools($root, { read => ['.secrets/key'] });
	like($out, qr/refused/, 'a protected path is refused');
	unlike($out, qr/do not show/, 'and its content never appears');

	$out = CodingEdit::read_tools($root, { read => ['big.txt'] });
	like($out, qr/truncated/, 'a large file is truncated');
	cmp_ok(length($out), '<=', 14000, 'the tool result is bounded');

	$out = CodingEdit::read_tools($root, { read => ['nope.pm'] });
	like($out, qr/could not be read|not found/, 'a missing file is reported, not fatal');

	$out = CodingEdit::read_tools($root, { grep => 'notes_category_rows' });
	like($out, qr/lib\/a\.pm/, 'grep names the file');
	like($out, qr/1 hit/, 'grep counts its hits');

	# A phrase is not always a valid regex. An unmatched parenthesis used to be
	# reported as "0 hits", which a real run read as "the function is gone" and
	# then re-defined a function that was still there (v0.1.1810).
	write_file("$root/lib/b.js", "function budgetLight(app) {\n\treturn app;\n}\n");
	$out = CodingEdit::read_tools($root, { grep => 'function budgetLight(' });
	like($out, qr/lib\/b\.js/, 'an invalid regex still finds its literal phrase');
	like($out, qr/matched literally/, 'and says it fell back to a literal match');
	unlike($out, qr/ERROR/, 'the fallback is not reported as an error');

	$out = CodingEdit::read_tools($root, { grep => 'budgetLight\\(app\\)' });
	like($out, qr/lib\/b\.js/, 'a valid regex is still a regex');
	unlike($out, qr/matched literally/, 'the literal note is only for a bad pattern');

	$out = CodingEdit::read_tools($root, { grep => 'nothing_matches_this_phrase' });
	like($out, qr/0 hit/, 'a miss is still a miss');
	unlike($out, qr/ERROR/, 'a miss is not an error');
}

done_testing();
