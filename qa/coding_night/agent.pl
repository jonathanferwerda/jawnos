#!/usr/bin/perl

# qa/coding_night/agent.pl - the command JAWNOS_CODING_AGENT points at.
#
#   perl qa/coding_night/agent.pl --dry-run
#   perl qa/coding_night/agent.pl --max-turns 6
#
# The runner starts it with cwd = a fresh worktree and
# JAWNOS_NOTE_ID / JAWNOS_NOTE_TITLE / JAWNOS_NOTE_TEXT in the environment. It
# assembles the coding context from the main checkout (`$HOME/jawnos` or
# --context-dir), reads the configured Coding model exactly as the Coding app
# does server-side, and edits the worktree through the model's JSON replies.
#
# The context is assembled for a cacheable prefix (core rules and the generated
# index first, retrieved note sections next, the note and then the help topic
# last), the deep notes are retrieved by section rather than truncated, and a
# reply over 64 KB is a failed turn. The agent logs an ACCOUNTING line and one
# REPLY line per turn so the nightly's report can carry the cost.
#
# Exit codes:
#   0  the worktree changed and its Perl/JavaScript passed the checks
#   1  the note could not be attempted: a model error, a refused edit, a
#      failing check after the last turn, or no change at all
#   2  usage or environment: no worktree, no main checkout, no note
#   3  no Coding model is configured - the nightly's "no agent" state
#
# --dry-run prints the assembled prompt, the documents and the call plan and
# writes nothing. It exits 0 even when no model is configured, the way the
# runner's own --dry-run reports a queue it will not touch.
#
# Nothing here bumps, commits, pushes or restarts: the runner does those, and
# only after qa/run.pl is green.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Cwd qw(abs_path getcwd);
use Encode ();
use JSON::PP ();

require CodingContext;
require CodingEdit;

my %opt = (
	dry_run     => 0,
	max_turns   => 12,
	context_dir => undef,
	worktree    => undef,
	responder   => undef,
	model       => undef,
);
my @argv = @ARGV;
while (my $arg = shift @argv) {
	if ($arg eq '--dry-run')          { $opt{'dry_run'} = 1; next }
	if ($arg eq '--max-turns')        { $opt{'max_turns'} = shift @argv; next }
	if ($arg =~ /^--max-turns=(.*)$/) { $opt{'max_turns'} = $1; next }
	if ($arg eq '--context-dir')      { $opt{'context_dir'} = shift @argv; next }
	if ($arg =~ /^--context-dir=(.*)$/) { $opt{'context_dir'} = $1; next }
	if ($arg eq '--worktree')         { $opt{'worktree'} = shift @argv; next }
	if ($arg =~ /^--worktree=(.*)$/)  { $opt{'worktree'} = $1; next }
	if ($arg eq '--responder')        { $opt{'responder'} = shift @argv; next }
	if ($arg =~ /^--responder=(.*)$/) { $opt{'responder'} = $1; next }
	if ($arg eq '--model')            { $opt{'model'} = shift @argv; next }
	if ($arg =~ /^--model=(.*)$/)     { $opt{'model'} = $1; next }
	if ($arg eq '--help' || $arg eq '-h') { usage(); exit 0 }
	print STDERR "qa/coding_night/agent.pl: unknown argument: $arg\n";
	exit 2;
}

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $max_turns = $opt{'max_turns'};
$max_turns = 12 unless defined $max_turns && $max_turns =~ /^\d+$/;
$max_turns = 1  if $max_turns < 1;
$max_turns = 20 if $max_turns > 20;

# --- the note the runner handed us ------------------------------------------
my $note = {
	id    => $ENV{'JAWNOS_NOTE_ID'}    // '',
	title => $ENV{'JAWNOS_NOTE_TITLE'} // '',
	text  => $ENV{'JAWNOS_NOTE_TEXT'}  // '',
};
unless (length $note->{'id'} || length $note->{'title'} || length $note->{'text'}) {
	print STDERR "qa/coding_night/agent.pl: no note in the environment"
		. " (JAWNOS_NOTE_ID, JAWNOS_NOTE_TITLE, JAWNOS_NOTE_TEXT)\n";
	exit 2;
}

# --- the worktree and the main checkout --------------------------------------
my $root = abs_path($opt{'worktree'} || getcwd());
unless (defined $root && -d $root) {
	print STDERR "qa/coding_night/agent.pl: the worktree is not a directory\n";
	exit 2;
}

my $context_dir = $opt{'context_dir'};
my $app_lane = $ENV{'JAWNOS_APP_LANE'} ? 1 : 0;
if (!defined $context_dir || !length $context_dir) {
	$context_dir = $app_lane
		? ($ENV{'JAWNOS_APP_DIR'} || (($ENV{'HOME'} // '') . '/jawnos-app/termux-app'))
		: (($ENV{'HOME'} // '') . '/jawnos');
}
$context_dir = abs_path($context_dir) if defined $context_dir && length $context_dir;
unless (defined $context_dir && -d $context_dir && -f "$context_dir/AGENTS.md") {
	print STDERR "qa/coding_night/agent.pl: no main checkout with AGENTS.md at "
		. (defined $context_dir ? $context_dir : '(no HOME)') . "\n";
	exit 2;
}

# The hook must work on a worktree. Editing the main checkout directly would
# put a 06:00 change on whatever branch the person is using, so refuse it
# outside a dry run (a dry run writes nothing and is safe anywhere).
if (!$opt{'dry_run'} && abs_path($root) eq abs_path($context_dir)) {
	print STDERR "qa/coding_night/agent.pl: refusing to edit the main checkout;"
		. " the hook must run with cwd = the fresh worktree\n";
	exit 2;
}

# --- context (the important part) -------------------------------------------
# The app lane reads the Android app's own AGENTS.md (and its fork delta list),
# never this repository's: an APK change follows the app repo's rules.
my @app_documents = (
	{ rel => 'AGENTS.md', label => 'the Android app rules' },
	{ rel => 'JAWNOS.md', label => 'the app fork delta list' },
	{ rel => 'README.md', label => 'the app README' },
);
my $context = CodingContext::assemble(
	context_dir => $context_dir,
	note_text   => $note->{'text'} . "\n" . $note->{'title'},
	($app_lane ? (documents => \@app_documents) : ()),
);
my ($note_message, $note_info) = CodingContext::note_message($note);

# The help topic is placed after the note in the user message, not in the system
# prompt: it is derived from the note and must not sit in the cached prefix.
my $help_block  = CodingContext::help_block($context);
my $note_bytes  = CodingContext::text_bytes($note_message);
my $help_bytes  = CodingContext::text_bytes($help_block);
my $context_bytes = ($context->{'context_bytes'} // 0) + $note_bytes + $help_bytes;
my $accounting = {
	context_bytes      => $context_bytes,
	context_est_tokens => CodingContext::est_tokens($context_bytes),
	system_bytes       => ($context->{'context_bytes'} // 0),
	sections           => $context->{'sections'} || [],
	repo               => $context->{'repo'},
	index              => ($context->{'index'} ? 1 : 0),
	reply_cap          => CodingEdit::max_reply_bytes(),
};

# --- the model, read the way the Coding app reads it ------------------------
# server-side POST /manager/coding/heal takes
#   setting_grabber({ app => 'mail', setting => 'coding_assistant' })
# plus the role's fallback and thinking level, and calls
#   subs::evaluation_model_call_with_fallback (Ai2.pm).
# We use the same three settings and the same helper; there is no second
# provider configuration in this file.
my ($model, $fallback, $thinking, $model_why) = resolve_model(
	context_dir => $context_dir,
	model       => $opt{'model'},
	responder   => $opt{'responder'},
);

if ($opt{'dry_run'}) {
	print "qa/coding_night agent dry run - no model call, no file is written\n";
	print '  note: ' . ($note->{'id'} || '(no id)') . ' ' . ($note->{'title'} || '(untitled)') . "\n";
	print '  worktree root: ' . $root . "\n";
	print '  context from: ' . $context_dir
		. ($app_lane ? ' (the Android app checkout)' : ' (the main checkout)') . "\n";
	if (defined $model && length $model) {
		print "  model: $model (Configure -> Platform -> Coding)"
			. ($model_why ? " - $model_why" : '') . "\n";
	}
	else {
		print '  model: (not readable: ' . ($model_why || 'no model is configured') . ")\n";
		print "         the real run would exit 3 and change nothing\n";
	}
	print '  max turns: ' . $max_turns . " (a model error or the cap is a failed note)\n";
	print "  planned calls: up to $max_turns editing turn(s); each is one JSON reply\n";
	print '  changed-byte budget: ' . CodingEdit::max_changed_bytes() . " bytes for the run\n";
	print "  context:\n" . CodingContext::describe_documents($context->{'documents'}) . "\n";
	print '  reply cap: ' . CodingEdit::max_reply_bytes() . " bytes a turn (over it is a failed turn)\n";
	print '  ' . CodingContext::context_summary($accounting) . "\n";
	print '  help topic: ' . (defined $context->{'help_topic'} ? $context->{'help_topic'} : 'none matched') . "\n";
	if ($note_info->{'redactions'}) {
		print '  note: ' . $note_info->{'redactions'} . " value(s) redacted\n";
	}
	print '  note: truncated at ' . CodingContext::max_note_bytes() . " bytes\n" if $note_info->{'truncated'};
	print '  warning: ' . $_ . "\n" for @{ $context->{'warnings'} || [] };
	print 'ACCOUNTING ' . JSON::PP::encode_json($accounting) . "\n";
	print "\n===== SYSTEM PROMPT =====\n" . $context->{'system'} . "\n";
	print "===== USER MESSAGE (turn 1) =====\n" . $note_message . $help_block . "\n";
	print "This is turn 1 of at most $max_turns.\n";
	print "Reply with the first JSON object.\n";
	exit 0;
}

unless (defined $model && length $model) {
	print STDERR "qa/coding_night/agent.pl: no Coding model is configured (Configure -> Platform -> Coding);"
		. ' ' . ($model_why || 'the setting is empty') . ".\n";
	print STDERR "qa/coding_night/agent.pl: nothing was changed.\n";
	exit 3;
}

my $responder = $opt{'responder'};
if (defined $responder && length $responder) {
	my $spec = do $responder;
	unless (ref $spec eq 'HASH' && ref $spec->{'call'} eq 'CODE') {
		print STDERR "qa/coding_night/agent.pl: the responder $responder did not return { call => sub {...} }"
			. ' (' . ($@ || $! || 'unknown error') . ")\n";
		exit 2;
	}
	$responder = $spec->{'call'};
}
else {
	$responder = undef;
}

print 'qa/coding_night agent: note ' . ($note->{'id'} || '?') . ' "' . ($note->{'title'} || 'untitled') . "\"\n";
print "qa/coding_night agent: model $model" . ($model_why ? " ($model_why)" : '') . "\n";
print 'qa/coding_night agent: worktree ' . $root . "\n";
print 'qa/coding_night agent: ' . CodingContext::context_summary($accounting) . "\n";
print 'ACCOUNTING ' . JSON::PP::encode_json($accounting) . "\n";

my @messages = (
	{ role => 'user', content => $note_message . $help_block
		. "\nBefore editing you may ask to see the tree: reply {\"read\":[\"path\",...]} (at most 3 files) "
		. "or {\"grep\":\"regex\"}; you will get the contents in the next turn. Do not guess paths.\n"
		. "This is turn 1 of at most $max_turns.\n"
		. "Reply with the first JSON object.\n" },
);
my $state = { bytes => 0 };
my $tool_turns = 0;
my $files_changed = 0;
my $checks_ok = 1;
my $finished = 0;
my $last_error = '';

for my $turn (1 .. $max_turns) {
	my ($reply, $err) = call_model(
		responder  => $responder,
		model      => $model,
		fallback   => $fallback,
		thinking   => $thinking,
		system     => $context->{'system'},
		messages   => \@messages,
		turn       => $turn,
	);
	if (defined $err) {
		print STDERR "qa/coding_night agent: the model call failed on turn $turn: $err\n";
		$last_error = "the model call failed on turn $turn: $err";
		last;
	}

	# The reply's own size is part of the account, and a reply over the cap is a
	# failed turn: it is logged by its edges and never parsed or applied.
	my $reply_bytes = CodingEdit::reply_bytes($reply);
	my $over_cap = $reply_bytes > CodingEdit::max_reply_bytes() ? 1 : 0;
	print 'REPLY ' . JSON::PP::encode_json({
		turn => $turn, bytes => $reply_bytes, over_cap => $over_cap,
	}) . "\n";
	if ($over_cap) {
		print "turn $turn: the reply is $reply_bytes bytes, over the "
			. CodingEdit::max_reply_bytes() . "-byte cap; nothing was written\n";
		print "----- BEGIN RAW REPLY (first 200 bytes) -----\n"
			. substr($reply, 0, 200) . "\n----- END RAW REPLY -----\n";
		print "----- BEGIN RAW REPLY (last 200 bytes) -----\n"
			. substr($reply, -200) . "\n----- END RAW REPLY -----\n";
		$last_error = "turn $turn: the reply was $reply_bytes bytes, over the cap";
		push @messages, { role => 'user', content =>
			"The last reply was $reply_bytes bytes, over the " . CodingEdit::max_reply_bytes()
			. "-byte cap, so nothing was written. Reply with ONE JSON object only; if the "
			. "change is large, send part of it and set \"done\":false until the last turn.\n" };
		next;
	}

	my ($parsed, $perr) = CodingEdit::parse_model_response($reply);

	# A read/grep request is a tool turn, not an edit: resolve it, hand the
	# contents back, and let the model edit with evidence instead of guessing.
	if (!$perr && ((ref $parsed->{'read'} eq 'ARRAY' && @{ $parsed->{'read'} })
		|| (defined $parsed->{'grep'} && length $parsed->{'grep'}))) {
		push @messages, { role => 'assistant', content => $reply };
		if ($tool_turns >= 6) {
			print "turn $turn: tool budget spent; asking for an edit\n";
			push @messages, { role => 'user', content =>
				'You have used the read budget. Make the edit now with what you have; '
				. 'one JSON object, and no more read/grep requests.\n' };
			next;
		}
		$tool_turns++;
		my $tool = CodingEdit::read_tools($root, $parsed);
		print "turn $turn: tool turn (" . length($tool) . " bytes back)\n";
		push @messages, { role => 'user', content => $tool };
		next;
	}

	push @messages, { role => 'assistant', content => $reply };

	if (defined $perr) {
		# Keep the exact bytes in the runner's agent log before any refusal: a
		# rejected turn has to be debuggable without guessing what the model sent.
		print "turn $turn: raw reply follows (unusable: $perr)\n";
		print "----- BEGIN RAW REPLY -----\n$reply\n----- END RAW REPLY -----\n";
		print "turn $turn: unusable reply ($perr); nothing was written\n";
		$last_error = "turn $turn: $perr";
		push @messages, { role => 'user', content =>
			"The last reply could not be used: $perr. Nothing was written.\n"
			. "Reply with EXACTLY ONE JSON object: {\"edits\":[...],\"done\":false,\"note\":\"...\"},"
			. " {\"diff\":\"...\",\"done\":false}, or {\"done\":true,\"note\":\"...\"}.\n" };
		next;
	}

	my $result = { ok => 1, applied => [], errors => [], bytes => $state->{'bytes'} };
	# A reply may carry both whole-file edits and per-file diffs (the model does
	# this when a new test file accompanies a patch). Apply both in the turn; a
	# failure anywhere marks the turn refused and the nightly never commits it.
	my @parts;
	push @parts, CodingEdit::apply_edits($root, $parsed->{'edits'}, $state)
		if ref $parsed->{'edits'} eq 'ARRAY' && @{ $parsed->{'edits'} };
	push @parts, CodingEdit::apply_diff($root, $parsed->{'diff'}, $state)
		if defined $parsed->{'diff'} && length $parsed->{'diff'};
	for my $part (@parts) {
		$result->{'ok'} = 0 unless $part->{'ok'};
		push @{ $result->{'applied'} }, @{ $part->{'applied'} || [] };
		push @{ $result->{'errors'} }, @{ $part->{'errors'} || [] };
		$result->{'bytes'} = $part->{'bytes'} if defined $part->{'bytes'};
	}

	if (!$result->{'ok'}) {
		$checks_ok = 0;
		$last_error = 'turn ' . $turn . ': ' . join('; ', @{ $result->{'errors'} || [] });
		print "turn $turn: refused - " . join('; ', @{ $result->{'errors'} || [] }) . "\n";
		push @messages, { role => 'user', content =>
			'NOTHING WAS WRITTEN. The edit was refused:' . "\n- "
			. join("\n- ", @{ $result->{'errors'} || [ 'unknown reason' ] })
			. "\nOnly repository-relative paths inside the worktree are allowed, the run has a "
			. CodingEdit::max_changed_bytes() . "-byte budget, and binary files are refused.\n"
			. "Reply with a corrected JSON object (turn " . ($turn + 1) . " of at most $max_turns).\n" };
		next;
	}

	my @paths = map { $_->{'path'} } @{ $result->{'applied'} || [] };
	$files_changed += scalar @paths;
	my $checks = @paths
		? CodingEdit::check_files($root, \@paths)
		: { ok => 1, failures => [], skipped => [] };
	$checks_ok = $checks->{'ok'} ? 1 : 0;

	my $summary = @paths
		? (scalar(@paths) . ' file(s): ' . join(', ', @paths) . ' (' . $state->{'bytes'} . ' bytes total)')
		: 'no edit';
	print "turn $turn: $summary; checks " . ($checks_ok ? 'pass' : 'FAIL') . "\n";

	if ($checks_ok && $parsed->{'done'}) {
		$finished = 1;
		print 'qa/coding_night agent: done - ' . ($parsed->{'note'} || 'no note given') . "\n";
		last;
	}

	my $observation = 'Turn ' . $turn . " result.\n";
	$observation .= @paths
		? 'Applied: ' . join(', ', map { $_->{'path'} . ' (+' . $_->{'bytes'} . ' bytes)' } @{ $result->{'applied'} })
		: 'No file was changed in that turn.';
	$observation .= "\nRun total: $state->{'bytes'} of " . CodingEdit::max_changed_bytes() . " bytes.\n";
	if ($checks_ok) {
		$observation .= "Checks: PASS.\n";
	}
	else {
		$observation .= "Checks: FAIL - fix this before finishing.\n";
		for my $failure ( @{ $checks->{'failures'} || [] } ) {
			$observation .= '  ' . $failure->{'path'} . ' (exit ' . $failure->{'exit'} . "):\n"
				. _indent($failure->{'output'}) . "\n";
		}
	}
	$observation .= 'Skipped: ' . join('; ', @{ $checks->{'skipped'} }) . "\n" if @{ $checks->{'skipped'} || [] };
	$observation .= $parsed->{'done'}
		? "You said done, but the checks did not pass, so the note is not finished.\n"
		: "If the work is complete, reply {\"done\":true,\"note\":\"...\"} now. Otherwise reply with the next edit.\n";
	$observation .= 'This is turn ' . ($turn + 1) . " of at most $max_turns.\n";
	$last_error = "turn $turn: the checks did not pass" unless $checks_ok;
	$last_error = "turn $turn: the model has not finished" if $checks_ok;
	push @messages, { role => 'user', content => $observation };
}

unless ($finished) {
	print STDERR 'qa/coding_night agent: the note was not finished'
		. ($last_error ? " ($last_error)" : '') . ".\n";
	if (!$files_changed) {
		print STDERR "qa/coding_night agent: no file was changed; the note stays open.\n";
	}
	exit 1;
}

if (!$files_changed) {
	print STDERR "qa/coding_night agent: the model finished without changing a file;"
		. " the note stays open.\n";
	exit 1;
}

print 'qa/coding_night agent: ' . $files_changed . ' file(s) changed, '
	. $state->{'bytes'} . " bytes, checks pass\n";
exit 0;

# ---------------------------------------------------------------------------

sub resolve_model {
	my (%a) = @_;
	if (defined $a{'responder'} && length $a{'responder'}) {
		return (defined $a{'model'} && length $a{'model'} ? $a{'model'} : 'fixture:responder',
			undef, undef, 'a fixture responder is in use');
	}
	my $boot = "$a{'context_dir'}/perl/subroutines.pl";
	return (undef, undef, undef, 'the main checkout has no perl/subroutines.pl')
		unless -f $boot;
	# The app layer requires its siblings cwd-relative (`./perl/gb.pl`), so the
	# load happens from the main checkout, then the worktree cwd is restored.
	# Every edit path here is absolute, so nothing else depends on the cwd.
	my $cwd = getcwd();
	my $ok = 0;
	my $load_error = '';
	if (chdir $a{'context_dir'}) {
		# The loaded file re-defines a few subs it shares with its siblings; the
		# warnings are an artifact of a standalone load, not a problem.
		local $SIG{'__WARN__'} = sub {
			warn $_[0] unless $_[0] =~ /^Subroutine .* redefined\b/;
		};
		$ok = eval { require $boot; 1 };
		$load_error = $@ || '';
		chdir $cwd;
	}
	else {
		$load_error = 'could not enter the main checkout: ' . $!;
	}
	return (undef, undef, undef, 'the app settings did not load: ' . _trim($load_error || 'unknown error'))
		unless $ok;
	unless (eval { &subs::provides('ai_chat_parts_with_fallback') }) {
		return (undef, undef, undef,
			'the app does not provide subs::ai_chat_parts_with_fallback; the Coding helper moved');
	}
	# A nightly must be silent: say_it() otherwise forks and speaks the
	# model's stand-down notices out loud.
	{
		no warnings 'once';
		$subs::say_quiet = 1;
	}

	my $primary = $a{'model'};
	if (!defined $primary || !length $primary) {
		$primary = eval { &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' }) } || '';
	}
	my $fallback = eval { &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant_fallback' }) } || '';
	my $thinking = eval { &subs::ai_role_thinking('coding_assistant') } || '';
	my $why = length $primary ? undef : 'the coding_assistant setting is empty';
	return ($primary, $fallback, $thinking, $why);
}

sub call_model {
	my (%a) = @_;
	if (ref $a{'responder'} eq 'CODE') {
		my $text = eval { $a{'responder'}->($a{'system'}, $a{'messages'}, $a{'turn'}) };
		return (undef, 'the responder died: ' . _trim($@)) if $@;
		return (defined $text && length $text ? $text : undef,
			(defined $text && length $text) ? undef : 'the responder returned nothing');
	}
	my ($parts, $err) = &subs::ai_chat_parts_with_fallback(
		$a{'model'},
		$a{'fallback'},
		[ { role => 'system', content => $a{'system'} }, @{ $a{'messages'} } ],
		$a{'thinking'},
	);
	return (undef, $err) if $err;
	my $text = join '', map { $_->{'text'} // '' }
		grep { ($_->{'type'} // '') eq 'text' } @{ $parts || [] };
	return (length $text ? $text : undef,
		length $text ? undef : 'the model returned no readable text');
}

sub _indent {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\r//g;
	$text = substr($text, 0, 2000) . "\n... [trimmed]" if length $text > 2000;
	$text =~ s/^/  /mg;
	return $text;
}

sub _trim {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return substr($text, 0, 300);
}

sub usage {
	print <<'TXT';
qa/coding_night/agent.pl - implement one JawnOS note in a worktree.

The 06:00 runner (qa/coding_night/run.pl) starts this with cwd = a fresh
worktree and JAWNOS_NOTE_ID / JAWNOS_NOTE_TITLE / JAWNOS_NOTE_TEXT in the env.

  --dry-run             print the prompt, context and call plan; write nothing
  --max-turns N         editing turns before the note is a failure (1..20, default 6)
  --context-dir DIR     the main checkout the rules are read from ($HOME/jawnos)
  --worktree DIR        the tree to edit (the current directory)
  --model NAME          override the configured Coding model, for a manual run
  --responder FILE      a fixture model: a Perl file returning { call => sub }

Exit: 0 changed and checked, 1 not finished, 2 usage/environment, 3 no model.
TXT
}
