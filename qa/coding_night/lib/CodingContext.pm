package CodingContext;

# The system context the 06:00 coding agent is given, and the fence around it.
#
# The documents are the ones a coding agent here actually needs: the project
# rules (AGENTS.md), the deep notes, the QA suite's README, and the help topic
# for the app the note names. They are gitignored, so they are read from the
# main checkout (`$HOME/jawnos` or --context-dir), never from the worktree the
# agent is editing - a branch must not get to describe itself.
#
# Every document passes through redact_text(): a line that matches the secret
# pattern is replaced, whole. Truncation happens after redaction and is always
# declared in the prompt, so a model is never told a partial rulebook is the
# whole one. Paths in the prompt are repository-relative: an instruction that
# names a home directory is an instruction that stops being true on the phone.

use strict;
use warnings;

use Encode ();
use File::Spec ();

our $VERSION = '1';

# Per document. docs/AGENTS-notes.md is ~190 KB; the rules are the first 20 KB
# of anything and a model that can read more than this is not the point.
our $MAX_DOC_BYTES = 20 * 1024;

# The note itself gets more room than a document, and is redacted with the
# narrower value pattern: "add a password field" is a task, "password=hunter2"
# is a secret.
our $MAX_NOTE_BYTES = 40 * 1024;

# One match withholds the whole line. Over-redacting a sentence is cheap;
# under-redacting a line is a credential in a model provider's logs.
our $SECRET_LINE = qr{
	pass(?:word|phrase|wd)
	| api[\s_-]?key
	| apikey
	| \bsecret\b
	| credential
	| signatorial
	| \.secrets(?:/|\b)
	| \.shots/
	| (?:config|downloads)\.json
	| \btokens?\b
	| \bbearer\b
	| \bcookie\b
	| (?:private|BEGIN|END)[\s-]*key
	| \.pem\b
	| ticket \s* [=:]? \s* [0-9a-f]{8}-[0-9a-f]{4}
}ix;

# A pasted value, not a discussion of one. Used for the note text, so a note
# that says "the password field is empty" survives and a note that carries
# "password: hunter2" does not.
our $SECRET_VALUE = qr{
	(?:
		(?:password|passphrase|secret|token|api[\s_-]?key|credential|signatorial)
		\s*[:=]\s*[^\s"']+
	  | BEGIN[\s-]+(?:[A-Z0-9]+[\s-]+)*PRIVATE\s+KEY
	  | \bBearer\s+[A-Za-z0-9._~+/=-]{12,}
	  | ticket\s*=\s*[0-9a-f]{8}-[0-9a-f-]{20,}
	)
}ix;

# The four documents, in the order a reader needs them: rules first, then the
# history that explains them, then the suite the change has to pass.
our @DOCUMENTS = (
	{ rel => 'AGENTS.md',             label => 'project rules' },
	{ rel => 'docs/AGENTS-notes.md',  label => 'deep notes (data model, flows, history)' },
	{ rel => 'qa/README.md',          label => 'the QA suite' },
);

# Absolute home paths in the documentation are rewritten before the model sees
# them: the worktree is somewhere else, and a rule that names /home/<user>/jawnos
# is a rule that stops being true on the next machine. `~/...` is left alone - a
# home-relative path is not absolute - but the repository itself becomes `.`.
sub relativize {
	my ($text) = @_;
	return '' unless defined $text;
	$text =~ s{/home/[^/\s]+/jawnos(?=/|$)}{.}g;
	$text =~ s{/home/[^/\s]+}{~}g;
	$text =~ s{~/jawnos(?=/|$)}{.}g;
	return $text;
}

sub max_doc_bytes { return $MAX_DOC_BYTES }
sub max_note_bytes { return $MAX_NOTE_BYTES }

# Replace every line that matches the secret pattern. Returns ($text, $count).
# A PEM block is withheld whole: matching only its BEGIN line would leave the
# base64 body, which is the part that is actually the key.
sub redact_text {
	my ($text) = @_;
	$text = '' unless defined $text;
	my @in = split /\n/, $text, -1;
	my @out;
	my $redacted = 0;
	my $pem = 0;
	for my $line (@in) {
		if ($line =~ /BEGIN[\s-]+(?:[A-Z0-9]+[\s-]+)*PRIVATE\s+KEY/) {
			$pem = 1;
			$redacted++;
			push @out, '[redacted: a private key block was withheld]';
			next;
		}
		if ($pem) {
			$redacted++;
			$pem = 0 if $line =~ /END[\s-]+(?:[A-Z0-9]+[\s-]+)*PRIVATE\s+KEY/;
			push @out, '[redacted: a private key block was withheld]';
			next;
		}
		if ($line =~ $SECRET_LINE) {
			$redacted++;
			push @out, '[redacted: a line matched the secret pattern]';
			next;
		}
		push @out, $line;
	}
	return (join("\n", @out), $redacted);
}

# Redact only pasted secret values, leaving ordinary prose alone. Returns
# ($text, $count).
sub redact_values {
	my ($text) = @_;
	$text = '' unless defined $text;
	my $count = 0;
	$text =~ s{$SECRET_VALUE}{ $count++; '[redacted]' }giex;
	return ($text, $count);
}

# Cut a string to at most $cap UTF-8 bytes on a character boundary. Returns
# (text, kept_bytes, was_truncated, original_bytes).
sub truncate_text {
	my ($text, $cap) = @_;
	$text = '' unless defined $text;
	$cap = $MAX_DOC_BYTES unless defined $cap && $cap =~ /^\d+$/;
	my $bytes = length Encode::encode('UTF-8', $text);
	return ($text, $bytes, 0, $bytes) if $bytes <= $cap;
	my ($kept, $used) = ('', 0);
	for my $char (split //, $text) {
		my $b = length Encode::encode('UTF-8', $char);
		last if $used + $b > $cap;
		$kept .= $char;
		$used += $b;
	}
	return ($kept, $used, 1, $bytes);
}

sub slurp {
	my ($path) = @_;
	return undef unless defined $path && -f $path;
	open(my $fh, '<:raw', $path) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	defined $text or return undef;
	my $decoded = eval { Encode::decode('UTF-8', $text, Encode::FB_DEFAULT()) };
	return defined $decoded ? $decoded : $text;
}

# The help registry is ordinary data: loading help.pl requires only its topic
# parts. A failure is reported, never fatal - the rules are what matter.
sub help_registry {
	my ($context_dir) = @_;
	my $file = File::Spec->catfile($context_dir, 'perl', 'help.pl');
	return { topics => {}, error => 'the main checkout has no perl/help.pl' } unless -f $file;
	my $ok = eval { require $file; 1 };
	return { topics => {}, error => _trim($@ || 'the help registry did not load') } unless $ok;
	no strict 'refs';
	my $topics = \%{'help::topic'};
	return { topics => (ref $topics eq 'HASH' ? $topics : {}), error => undef };
}

# The topic for the app a note names. A topic matches by its id or its `app`
# field, as a whole word in the note, preferring the longest name and the title.
sub help_topic_for {
	my ($text, $topics) = @_;
	return undef unless ref $topics eq 'HASH' && %{$topics};
	my $hay = _words($text);
	my %score;
	for my $id (sort keys %{$topics}) {
		my $topic = $topics->{$id};
		next unless ref $topic eq 'HASH';
		my @names = ($id);
		push @names, $topic->{'app'} if defined $topic->{'app'} && length $topic->{'app'};
		my %seen;
		for my $name (@names) {
			my $word = _words($name);
			next if length($word) < 3 || $seen{$word}++;
			next unless $hay =~ /(?<![a-z0-9])\Q$word\E(?![a-z0-9])/;
			my $s = 10 * length $word;
			$s += 100 if defined $topic->{'app'} && $topic->{'app'} eq $name;
			$score{$id} = $s if !defined $score{$id} || $score{$id} < $s;
		}
	}
	return undef unless %score;
	my ($best) = sort { $score{$b} <=> $score{$a} || $a cmp $b } keys %score;
	return $best;
}

sub render_help_topic {
	my ($id, $topic) = @_;
	return '' unless ref $topic eq 'HASH';
	my $text = 'Help topic: ' . $id . "\n";
	$text .= 'Title: ' . $topic->{'title'} . "\n" if defined $topic->{'title'} && length $topic->{'title'};
	$text .= 'App: ' . $topic->{'app'} . "\n" if defined $topic->{'app'} && length $topic->{'app'};
	$text .= 'Summary: ' . $topic->{'summary'} . "\n" if defined $topic->{'summary'} && length $topic->{'summary'};
	my $body = ref $topic->{'body'} eq 'ARRAY' ? $topic->{'body'} : [];
	$text .= "\n" . join("\n\n", @{$body}) . "\n" if @{$body};
	my $steps = ref $topic->{'steps'} eq 'ARRAY' ? $topic->{'steps'} : [];
	if (@{$steps}) {
		my $i = 0;
		$text .= "\nSteps:\n";
		$text .= (++$i) . '. ' . $_ . "\n" for @{$steps};
	}
	$text .= "\nSteering for this app: " . $topic->{'prompt'} . "\n"
		if defined $topic->{'prompt'} && length $topic->{'prompt'};
	return $text;
}

# Assemble the system prompt. %opt:
#   context_dir => the main checkout (required)
#   note_text   => the note, for picking the help topic
#   app_text    => title + text, for picking the help topic (defaults to note_text)
#   documents   => optional [ { rel, label }, ... ] instead of @DOCUMENTS
# Returns { system, documents => [...], help_topic => id|undef, warnings => [...] }.
sub assemble {
	my (%opt) = @_;
	my $dir = $opt{'context_dir'} or die "CodingContext: no context_dir\n";
	my @documents;
	my @warnings;
	my $specs = ref $opt{'documents'} eq 'ARRAY' ? $opt{'documents'} : \@DOCUMENTS;

	for my $spec (@{$specs}) {
		my $rel = $spec->{'rel'};
		my $path = File::Spec->catfile($dir, split m{/}, $rel);
		my $raw = slurp($path);
		if (!defined $raw) {
			push @warnings, "$rel is not in the main checkout; it was not sent";
			push @documents, {
				rel => $rel, label => $spec->{'label'}, present => 0,
				bytes => 0, kept => 0, truncated => 0, redacted => 0, text => '',
				error => 'not found in the main checkout',
			};
			next;
		}
		my ($redacted, $count) = redact_text($raw);
		$redacted = relativize($redacted);
		my ($kept, $kept_bytes, $truncated, $original_bytes) = truncate_text($redacted, $MAX_DOC_BYTES);
		push @documents, {
			rel => $rel, label => $spec->{'label'}, present => 1,
			bytes => $original_bytes, kept => $kept_bytes,
			truncated => $truncated, redacted => $count, text => $kept,
		};
	}

	my $help = help_registry($dir);
	my $help_id;
	my $help_text = '';
	if ($help->{'error'}) {
		push @warnings, 'the help registry was not available: ' . $help->{'error'};
	}
	else {
		my $app_text = defined $opt{'app_text'} ? $opt{'app_text'} : ($opt{'note_text'} // '');
		$help_id = help_topic_for($app_text, $help->{'topics'});
		if (defined $help_id) {
			my $rendered = render_help_topic($help_id, $help->{'topics'}->{$help_id});
			my ($hred, $hcount) = redact_text($rendered);
			$hred = relativize($hred);
			my ($hkept, $hbytes, $htrunc, $horig) = truncate_text($hred, $MAX_DOC_BYTES);
			push @documents, {
				rel => 'help:' . $help_id, label => 'the help topic for the app the note names',
				present => 1, bytes => $horig, kept => $hbytes,
				truncated => $htrunc, redacted => $hcount, text => $hkept,
			};
			$help_text = $hkept;
		}
		else {
			push @warnings, 'no help topic matched the app the note names';
		}
	}

	my $system = _system_prompt(\@documents, $help_id, \@warnings);
	return {
		system     => $system,
		documents  => \@documents,
		help_topic => $help_id,
		warnings   => \@warnings,
		help_text  => $help_text,
	};
}

# The note that goes to the model as the user message.
sub note_message {
	my ($note) = @_;
	$note ||= {};
	my $body = $note->{'text'} // '';
	my ($redacted, $redactions) = redact_values($body);
	my ($kept, $kept_bytes, $truncated, $original) = truncate_text($redacted, $MAX_NOTE_BYTES);
	my $text = "## The note\n";
	$text .= 'id: ' . ($note->{'id'} // '') . "\n";
	$text .= 'title: ' . ($note->{'title'} // '') . "\n";
	$text .= "text:\n" . $kept . "\n";
	$text .= "\n[the note was truncated at $MAX_NOTE_BYTES bytes; $kept_bytes of $original were sent]\n" if $truncated;
	$text .= "\n[secret-looking values in the note were redacted; $redactions value(s)]\n" if $redactions;
	return ($text, { redactions => $redactions, truncated => $truncated, bytes => $kept_bytes });
}

sub describe_documents {
	my ($docs) = @_;
	my @lines;
	for my $doc ( @{ ref $docs eq 'ARRAY' ? $docs : [] } ) {
		my $line = '  ' . $doc->{'rel'};
		if (!$doc->{'present'}) {
			$line .= ' - not in the main checkout (not sent)';
		}
		elsif ($doc->{'truncated'}) {
			$line .= ' - TRUNCATED: first ' . $doc->{'kept'} . ' of ' . $doc->{'bytes'} . ' bytes';
		}
		else {
			$line .= ' - ' . $doc->{'bytes'} . ' bytes';
		}
		$line .= ', ' . $doc->{'redacted'} . ' line(s) redacted' if $doc->{'redacted'};
		push @lines, $line;
	}
	return join("\n", @lines);
}

# ---------------------------------------------------------------------------

sub _trim {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return substr($text, 0, 300);
}

sub _words {
	my ($text) = @_;
	$text = '' unless defined $text;
	my $low = lc $text;
	$low =~ s/[^a-z0-9]+/ /g;
	$low =~ s/^\s+|\s+$//g;
	return $low;
}

sub _system_prompt {
	my ($documents, $help_id, $warnings) = @_;
	my $p = <<'HEAD';
You are the JawnOS Coding agent. You are run by the 06:00 QA coding nightly, one
note at a time, inside a fresh git worktree checked out from origin/main.

The current directory is the repository root of that worktree. Every path you
write is repository-relative and must stay inside it. The nightly runs the QA
suite, bumps the version, commits, pushes, merges and restarts after you exit
0; you do not do any of those things.

## How you answer

Reply with EXACTLY ONE JSON object and no prose around it. Choose one shape:

1. Whole files (preferred for small files and new files):
   {"edits":[{"path":"perl/example.pl","content":"...the whole file..."}],"done":false,"note":"why"}
2. A unified diff (preferred for a small change in a large file):
   {"diff":"--- a/perl/example.pl\n+++ b/perl/example.pl\n@@ -1,3 +1,3 @@\n ...","done":false,"note":"why"}
3. Finished:
   {"done":true,"note":"what changed and why, in one or two sentences"}

Set "done":true in the same object as your last edit when that edit completes
the work. If a check failed, reply with the next edit that fixes it. If you
already finished and have nothing further to change, reply with shape 3 alone.

## Edit rules

- Only repository-relative paths inside the worktree. Absolute paths, "..",
  symlinks, control characters and anything that resolves outside the worktree
  are refused; a refused turn writes nothing at all.
- Never write .git/, .secrets/, .shots/, .president/, releases/, signatorials/,
  database/*.db, config.json, downloads.json, *.pem, or a binary file.
- At most 262144 changed bytes across the whole run. A turn that would exceed
  the budget is refused and nothing is written.
- Change only what the note needs. Do not reformat, rename or delete files the
  note does not name, and do not touch another agent's work in the tree.
- When behaviour changes, add or update the test in t/ in the same edit. A
  defect you find but do not fix gets a TODO test naming the file and line,
  never a test that asserts the broken behaviour.
- Perl must pass `perl -c`; JavaScript must pass `node --check`. The nightly
  runs those on every file you touched and feeds a failure back to you.
- Do not bump the version, commit, push or restart. The nightly does that.
- If you cannot find a file after three attempts, stop and say what you tried
  in "note"; never invent a path or keep guessing.
- Never print a secret (key, token, password) in an edit or in a note.

## Context

HEAD

	$p .= "These documents come from the main checkout, not from this worktree. They are "
		. "repository-relative and are the rules that apply to this repository.\n\n";

	for my $doc ( @{ ref $documents eq 'ARRAY' ? $documents : [] } ) {
		next unless $doc->{'present'};
		$p .= '### ' . $doc->{'rel'} . ' (' . $doc->{'label'} . ")\n";
		$p .= '[TRUNCATED: this document is ' . $doc->{'bytes'} . ' bytes; only the first '
			. $doc->{'kept'} . " bytes are included below. The rest was not sent.]\n"
			if $doc->{'truncated'};
		$p .= '[REDACTED: ' . $doc->{'redacted'}
			. " line(s) matched the secret pattern and were withheld.]\n"
			if $doc->{'redacted'};
		my $body = $doc->{'text'};
		$p .= $body;
		$p .= "\n" unless $body =~ /\n$/;
		$p .= "\n";
	}

	my @missing = map { $_->{'rel'} } grep { !$_->{'present'} } @{ ref $documents eq 'ARRAY' ? $documents : [] };
	if (@missing) {
		$p .= '### Not available' . "\n"
			. 'The main checkout did not have: ' . join(', ', @missing) . ".\n"
			. 'Do not guess their contents.' . "\n\n";
	}

	if (defined $help_id) {
		$p .= "The help topic above was chosen because the note names its app. Keep the "
			. "button labels and hints it describes true if you change that app.\n\n";
	}
	else {
		$p .= "No help topic matched the app the note names; do not invent help text for it.\n\n";
	}

	return $p;
}

1;
