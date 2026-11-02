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
#
# Cost is a design constraint, not a detail. docs/AGENTS-notes.md is ~190 KB and
# sending its first 20 KB spends most of a turn on sections the note never
# mentions. So the notes are split on their markdown headings and only the 3-4
# sections the note scores against are sent, behind a one-line index of every
# title (so the model can ask for one). The order is fixed for prefix caching:
# the byte-identical core (rules + generated index + repo sha) first, then the
# retrieved sections, then the note (the user message), then the help topic
# last. Nothing the note changes may appear before the core.

use strict;
use warnings;

use Encode ();
use File::Spec ();
use JSON::PP ();

our $VERSION = '2';

# Per flat document. The rules are the first 20 KB of anything and a model that
# can read more than this is not the point.
our $MAX_DOC_BYTES = 20 * 1024;

# docs/AGENTS-notes.md is retrieved section by section: at most this many bytes
# of selected sections, and at most this many sections.
our $MAX_NOTES_BYTES = 6 * 1024;
our $MAX_NOTES_SECTIONS = 4;

# The generated repository index (qa/coding_night/agent-index.md) replaces the
# full qa/README.md, so it gets a real budget - but a bounded one.
our $MAX_INDEX_BYTES = 16 * 1024;

# One line of heading titles is what makes retrieval askable instead of a
# guess. Titles are compressed (a date or a trailing aside is not part of the
# name) so every section can be listed, and the line is still capped so a
# document with hundreds of headings cannot undo the saving it exists to make.
our $MAX_HEADING_INDEX_BYTES = 6 * 1024;

# Words that carry no retrieval signal. Kept short: a stopword common to every
# section would rank them all equally and win nothing.
our %STOPWORD = map { $_ => 1 } qw(
	the and for with that this from into over under when what where which have
	has had was were are will would should could than then them they its not but
	all any can may must our your you his her their there does did doing fix add
	made make change new old use used using file files line lines code work works
	need needs please also only just same out off too very each other such
);

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

# The documents a repo note gets, in a reader's order: rules first, then the
# history that explains them, then the suite the change has to pass. When the
# generated repository index exists it replaces the QA README (see assemble).
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
sub max_notes_bytes { return $MAX_NOTES_BYTES }
sub max_notes_sections { return $MAX_NOTES_SECTIONS }
sub max_index_bytes { return $MAX_INDEX_BYTES }

# UTF-8 bytes, not characters: the cap the provider bills and the log records.
sub text_bytes {
	my ($text) = @_;
	return 0 unless defined $text;
	return length Encode::encode('UTF-8', $text);
}

# The one estimate everything reports, so the numbers agree: ~4 bytes a token.
sub est_tokens {
	my ($bytes) = @_;
	return 0 unless defined $bytes && $bytes =~ /^\d+$/;
	return int($bytes / 4);
}

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

# --- section retrieval -------------------------------------------------------

# Split a markdown document on its level 1-3 headings. The text before the first
# heading is the preamble; a heading keeps the line it is on, so a selected
# section is a slice of the original bytes and reads as the document does.
# Returns a list of { title, level, text, bytes } in document order.
sub split_sections {
	my ($text) = @_;
	$text = '' unless defined $text;
	my @marks;
	while ($text =~ /^(#{1,3})[ \t]+(.+?)[ \t]*\r?$/mg) {
		push @marks, { pos => $-[0], level => length $1, title => $2 };
	}
	unless (@marks) {
		my $whole = $text;
		$whole =~ s/^\s+|\s+$//g;
		return ({ title => '(whole document)', level => 0,
			text => $whole, bytes => text_bytes($whole) });
	}
	my @sections;
	my $pre = substr($text, 0, $marks[0]->{'pos'});
	$pre =~ s/^\s+|\s+$//g;
	push @sections, { title => '(preamble)', level => 0, text => $pre, bytes => text_bytes($pre) }
		if length $pre;
	for my $i (0 .. $#marks) {
		my $start = $marks[$i]->{'pos'};
		my $end = $i < $#marks ? $marks[$i + 1]->{'pos'} : length $text;
		my $body = substr($text, $start, $end - $start);
		$body =~ s/\s+$//;
		push @sections, {
			title => $marks[$i]->{'title'}, level => $marks[$i]->{'level'},
			text => $body, bytes => text_bytes($body),
		};
	}
	return @sections;
}

# The distinct words worth scoring: lowercase, alphanumeric, three characters or
# more, stopwords out, in first-seen order so the result is deterministic.
sub _terms {
	my ($text) = @_;
	my %seen;
	my @terms;
	for my $word (split / /, _words($text)) {
		next if length($word) < 3;
		next if $STOPWORD{$word};
		next if $seen{$word}++;
		push @terms, $word;
	}
	return @terms;
}

# Path-like and filename-like strings the note mentions. A note that names
# public/js/manager/chat.js is asking about that file's section, not about the
# word "chat" in every section.
sub _file_names {
	my ($text) = @_;
	$text = '' unless defined $text;
	my %seen;
	my @names;
	while ($text =~ m{([\w.@+-]+(?:/[\w.@+-]+)+|[\w-]+\.(?:p[lm]|t|js|ep|css|sql|md|ino|json|html))\b}g) {
		my $name = $1;
		$name =~ s{^\./}{};
		push @names, $name unless $seen{$name}++;
	}
	return @names;
}

# Rank every section against the note. A heading hit is worth 6 (a heading says
# what the section is about), a body hit 1 capped at 5 (one long section must
# not win on repetition), a whole path the note names 40 and a bare basename 15.
# Ties break on document order, so the same note always selects the same
# sections.
sub score_sections {
	my ($sections, $note_text) = @_;
	my @terms = _terms($note_text);
	my @names = _file_names($note_text);
	my @scored;
	for my $i (0 .. $#{$sections}) {
		my $s = $sections->[$i];
		my $low = lc($s->{'text'} // '');
		my $heading = lc($s->{'title'} // '');
		my $score = 0;
		for my $term (@terms) {
			$score += 6 if $heading =~ /(?<![a-z0-9])\Q$term\E(?![a-z0-9])/;
			my $hits = () = $low =~ /(?<![a-z0-9])\Q$term\E(?![a-z0-9])/g;
			$score += $hits > 5 ? 5 : $hits;
		}
		for my $name (@names) {
			my $base = $name;
			$base =~ s{.*/}{};
			if (index($low, lc $name) >= 0) { $score += 40 }
			elsif (length $base && index($low, lc $base) >= 0) { $score += 15 }
		}
		push @scored, { %{$s}, index => $i, score => $score };
	}
	return @scored;
}

# Pick at most $max sections, in at most $cap bytes. Forced sections (the data
# model/schema/sync set, when the note names a table or an app) are taken first;
# the rest are filled by score. The selected sections are emitted in document
# order - a model reads a document forwards - and a section that would overflow
# the budget is skipped, unless it is the only one, in which case it is cut and
# the cut is declared. Returns ([selected], used_bytes).
sub select_sections {
	my (%a) = @_;
	my $cap = $a{'cap'} // $MAX_NOTES_BYTES;
	my $max = $a{'max'} // $MAX_NOTES_SECTIONS;
	my @scored = score_sections($a{'sections'} || [], $a{'note_text'} // '');
	my @ranked = sort {
		$b->{'score'} <=> $a->{'score'} || $a->{'index'} <=> $b->{'index'}
	} @scored;

	my %pick;
	if ($a{'force'}) {
		for my $s (grep { $_->{'title'} =~ /(?:data\s*model|schema|sync)/i } @ranked) {
			last if keys %pick >= $max;
			$pick{ $s->{'index'} } = $s;
		}
	}
	for my $s (@ranked) {
		last if keys %pick >= $max;
		next if $pick{ $s->{'index'} };
		$pick{ $s->{'index'} } = $s;
	}

	my (@out, $used);
	$used = 0;
	for my $s (sort { $a->{'index'} <=> $b->{'index'} } values %pick) {
		my $room = $cap - $used;
		last if $room < 120;
		if ($s->{'bytes'} > $room) {
			my ($kept, $bytes) = truncate_text($s->{'text'}, $room);
			push @out, { %{$s}, text => $kept, bytes => $bytes, cut => 1 };
			$used += $bytes;
			last;
		}
		push @out, { %{$s}, cut => 0 };
		$used += $s->{'bytes'};
	}
	return (\@out, $used);
}

# All the section titles, on one line. Cheap, and it is what turns a sectioned
# document into a document the model can ask about instead of a cut one. A
# heading's date or trailing aside is dropped: it is not the name, and the full
# heading is still there when the section itself is selected.
sub _index_title {
	my ($title) = @_;
	my $x = defined $title ? $title : '';
	$x =~ s/\s*\((?:19|20)\d\d[^)]*\)//g;
	$x =~ s/\s*\([^)]{0,40}\)\s*$//;
	$x =~ s/\s+/ /g;
	$x =~ s/^\s+|\s+$//g;
	$x = substr($x, 0, 64) . '...' if length($x) > 64;
	return length $x ? $x : $title;
}

sub heading_index_line {
	my ($rel, $sections) = @_;
	return '' unless ref $sections eq 'ARRAY' && @{$sections};
	my @titles = map { _index_title($_->{'title'}) } @{$sections};
	my $count = scalar @titles;
	my $line = $rel . ' sections (' . $count . '): ' . join(' | ', @titles);
	if (text_bytes($line) > $MAX_HEADING_INDEX_BYTES) {
		my ($cut) = truncate_text($line, $MAX_HEADING_INDEX_BYTES - 60);
		$line = $cut . ' ... (' . $count . ' sections in total)';
	}
	return $line;
}

# The table names the schema declares. Used only to decide whether the note is
# talking about the database (and so whether the data model sections are forced
# into the selection); a missing schema is simply no table names.
sub _table_names {
	my ($dir) = @_;
	my $sql = slurp(File::Spec->catfile($dir, 'database', 'schema.sql'));
	return () unless defined $sql;
	my %seen;
	return grep { !$seen{$_}++ }
		($sql =~ /CREATE\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+"?([A-Za-z_][A-Za-z0-9_]*)/gi);
}

sub names_table_or_app {
	my ($dir, $text, $help_id) = @_;
	return 1 if defined $help_id;
	my $hay = _words($text);
	for my $table (_table_names($dir)) {
		my $word = lc $table;
		return 1 if $hay =~ /(?<![a-z0-9])\Q$word\E(?![a-z0-9])/;
	}
	return 0;
}

# The generated index (another agent writes it) is consumed if it is there and
# ignored if it is not: the context must never depend on a file that may not
# exist. Only its five named sections are sent, in file order, capped whole.
sub load_index {
	my ($dir) = @_;
	my $rel = 'qa/coding_night/agent-index.md';
	my $path = File::Spec->catfile($dir, split m{/}, $rel);
	my $raw = slurp($path);
	return undef unless defined $raw && length $raw;
	my ($text, $count) = redact_text($raw);
	$text = relativize($text);
	my @all = split_sections($text);
	my @wanted = grep {
		$_->{'level'} == 2 && $_->{'title'} =~ /^(?:routes|helpers|tables|apps|firmware)$/i
	} @all;
	return undef unless @wanted;
	my (@kept, $used);
	$used = 0;
	for my $s (@wanted) {
		my $room = $MAX_INDEX_BYTES - $used;
		last if $room < 120;
		if ($s->{'bytes'} > $room) {
			my ($kept, $bytes) = truncate_text($s->{'text'}, $room);
			push @kept, { %{$s}, text => $kept, bytes => $bytes, cut => 1 };
			$used += $bytes;
			last;
		}
		push @kept, { %{$s}, cut => 0 };
		$used += $s->{'bytes'};
	}
	my $body = join("\n\n", map { $_->{'text'} } @kept);
	my $truncated = ($used >= $MAX_INDEX_BYTES || grep { $_->{'cut'} } @kept) ? 1 : 0;
	$body .= "\n\n[TRUNCATED: " . scalar(@kept) . ' of ' . scalar(@wanted)
		. ' index section(s) were sent, in at most ' . $MAX_INDEX_BYTES . ' bytes.]'
		if $truncated;
	return {
		rel => $rel, label => 'generated repository index',
		present => 1, bytes => text_bytes($text), kept => text_bytes($body),
		truncated => $truncated, declared => $truncated, redacted => $count, text => $body,
		sections => [ map { { title => $_->{'title'}, bytes => $_->{'bytes'}, cut => $_->{'cut'} } } @kept ],
		sections_total => scalar @all,
	};
}

# A short sha pins the core to the tree the documents describe. A missing git or
# a directory that is not a checkout is not an error - the line is just left out.
sub repo_sha {
	my ($dir) = @_;
	return undef unless defined $dir && length $dir && -d "$dir/.git";
	my $pid = open(my $fh, '-|', 'git', '-C', $dir, 'rev-parse', '--short', 'HEAD');
	return undef unless $pid;
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return undef unless $? == 0;
	$out =~ s/\s+//g;
	return length $out ? $out : undef;
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
#   note_text   => the note, for retrieval and for picking the help topic
#   app_text    => title + text, for picking the help topic (defaults to note_text)
#   documents   => optional [ { rel, label }, ... ] instead of @DOCUMENTS
# The order is fixed: the core (rules, then the generated index, then the repo
# sha) is byte-identical for every note; the retrieved sections follow; the help
# topic is returned for the caller to place after the note. Returns
# { system, documents, help_topic, help_text, sections, context_bytes,
#   context_est_tokens, repo, index, warnings }.
sub assemble {
	my (%opt) = @_;
	my $dir = $opt{'context_dir'} or die "CodingContext: no context_dir\n";
	my @warnings;
	my $repo_lane = !(ref $opt{'documents'} eq 'ARRAY');
	my $specs = $repo_lane ? \@DOCUMENTS : $opt{'documents'};
	my $note_text = $opt{'note_text'} // '';

	my $help = help_registry($dir);
	my $help_id;
	if ($help->{'error'}) {
		push @warnings, 'the help registry was not available: ' . $help->{'error'};
	}
	else {
		my $app_text = defined $opt{'app_text'} ? $opt{'app_text'} : $note_text;
		$help_id = help_topic_for($app_text, $help->{'topics'});
		push @warnings, 'no help topic matched the app the note names'
			unless defined $help_id;
	}

	# A note that names a table or an app always gets the data model history,
	# whatever it scores: "why is sync behind" is answered by the schema, not
	# by the section that happens to mention sync most often.
	my $force = names_table_or_app($dir, $note_text, $help_id);

	my (@core, @retrieved);
	for my $spec (@{$specs}) {
		my $rel = $spec->{'rel'};
		my $path = File::Spec->catfile($dir, split m{/}, $rel);
		my $raw = slurp($path);
		if (!defined $raw) {
			push @warnings, "$rel is not in the main checkout; it was not sent";
			my $missing = {
				rel => $rel, label => $spec->{'label'}, present => 0,
				bytes => 0, kept => 0, truncated => 0, redacted => 0, text => '',
				error => 'not found in the main checkout',
			};
			if ($rel eq 'AGENTS.md') { push @core, $missing } else { push @retrieved, $missing }
			next;
		}
		my ($redacted, $count) = redact_text($raw);
		$redacted = relativize($redacted);
		my $original = text_bytes($redacted);
		my $doc = $rel eq 'docs/AGENTS-notes.md'
			? _sectioned_document(
				rel => $rel, label => $spec->{'label'}, text => $redacted,
				bytes => $original, redacted => $count, note_text => $note_text,
				force => $force,
			)
			: _flat_document(
				rel => $rel, label => $spec->{'label'}, text => $redacted,
				bytes => $original, redacted => $count,
				abbreviate => ($rel eq 'AGENTS.md' ? 1 : 0),
				shell_only => ($rel eq 'AGENTS.md' ? 1 : 0),
			);
		if ($rel eq 'AGENTS.md') { push @core, $doc } else { push @retrieved, $doc }
	}

	# The generated index is core: it is built from the tree, not from the note,
	# so it is the same bytes for every note (and every turn). It stands in for
	# the full qa/README.md; when it is absent the README is what the model gets.
	my $index_doc;
	my $sha;
	if ($repo_lane) {
		$index_doc = load_index($dir);
		@retrieved = grep { ($_->{'rel'} // '') ne 'qa/README.md' } @retrieved
			if $index_doc;
		$sha = repo_sha($dir);
	}
	push @core, $index_doc if $index_doc;

	# The help topic belongs to the app the note names, so it is the last thing
	# the model reads - never part of the cacheable prefix.
	my $help_doc;
	my $help_text = '';
	if (defined $help_id) {
		my $rendered = render_help_topic($help_id, $help->{'topics'}->{$help_id});
		my ($hred, $hcount) = redact_text($rendered);
		$hred = relativize($hred);
		my ($hkept, $hbytes, $htrunc, $horig) = truncate_text($hred, $MAX_DOC_BYTES);
		$help_doc = {
			rel => 'help:' . $help_id, label => 'the help topic for the app the note names',
			present => 1, bytes => $horig, kept => $hbytes,
			truncated => $htrunc, redacted => $hcount, text => $hkept,
		};
		$help_text = $hkept;
	}

	my $system = _system_prompt(
		core => \@core, retrieved => \@retrieved, sha => $sha,
		index => ($index_doc ? 1 : 0),
	);

	my @documents = (@core, @retrieved, ($help_doc ? $help_doc : ()));
	my $system_bytes = text_bytes($system);
	return {
		system     => $system,
		documents  => \@documents,
		help_topic => $help_id,
		help_text  => $help_text,
		help_doc   => $help_doc,
		warnings   => \@warnings,
		repo       => $sha,
		index      => ($index_doc ? 1 : 0),
		context_bytes      => $system_bytes,
		context_est_tokens => est_tokens($system_bytes),
		sections   => _accounting_sections(\@core, \@retrieved, $help_doc),
	};
}

# A document that is sent whole (capped): the rules, the QA README, a help
# topic. The same shape every document has, so the prompt renderer and the
# accounting do not special-case it.
#
# AGENTS.md is a map as well as a rulebook, and it is over the cap. When that
# happens, drop the prose paragraphs that carry no rule and keep the normative
# ones - a paragraph is kept or dropped whole, so no sentence is left dangling -
# then cap the result. Both the drop and the cut are declared in the prompt.
# Sections that only teach commands this agent cannot run. The nightly Coding
# agent has no shell: it edits files and replies with JSON, and the nightly
# commits, pushes and restarts for it. Sending it the restart protocol, the APK
# store, the firmware staging or the browser checks buys nothing and, because the
# document is capped, costs it rules it can act on.
our @SHELL_ONLY_SECTIONS = (
	'Run & restart',
	'Web interface',
	'App releases (the APK store)',
	'Firmware / OTA (stage every build)',
	'Next up (deferred)',
);

# Remove those sections whole (a heading and its body, up to the next H2).
sub drop_sections {
	my ($text, $titles) = @_;
	my %drop = map { $_ => 1 } @{$titles};
	$text = '' unless defined $text;
	my @out;
	my $dropping = 0;
	my @dropped;
	for my $line (split /\n/, $text, -1) {
		if ($line =~ /^##\s+(.+?)\s*$/) {
			my $title = $1;
			$dropping = $drop{$title} ? 1 : 0;
			push @dropped, $title if $dropping;
			next if $dropping;
		}
		next if $dropping;
		push @out, $line;
	}
	return (join("\n", @out), \@dropped);
}

sub _flat_document {
	my (%a) = @_;
	my $text = $a{'text'};
	my $abbreviated = 0;
	my $dropped;
	if ($a{'shell_only'}) {
		my ($short, $titles) = drop_sections($text, \@SHELL_ONLY_SECTIONS);
		if (@$titles && length $short < length $text) {
			$text   = $short;
			$dropped = $titles;
		}
	}
	if ($a{'abbreviate'} && text_bytes($text) > $MAX_DOC_BYTES) {
		my $short = abbreviate_rules($text);
		if (length $short && text_bytes($short) < text_bytes($text)) {
			$text = $short;
			$abbreviated = 1;
		}
	}
	my ($kept, $kept_bytes, $truncated) = truncate_text($text, $MAX_DOC_BYTES);
	return {
		rel => $a{'rel'}, label => $a{'label'}, present => 1,
		bytes => $a{'bytes'}, kept => $kept_bytes,
		truncated => $truncated, abbreviated => $abbreviated,
		dropped => $dropped,
		redacted => $a{'redacted'}, text => $kept,
	};
}

# Keep the paragraphs that state a rule: a heading, a bullet or numbered item,
# a table header, or a modal verb. Everything else is description, and the deep
# notes repeat it.
sub abbreviate_rules {
	my ($text) = @_;
	$text = '' unless defined $text;
	my @kept;
	for my $para (split /\n\s*\n/, $text) {
		my $normative = 0;
		for my $line (split /\n/, $para) {
			next unless length $line;
			$normative = 1
				if $line =~ /^\s*#{1,6}\s/
				|| $line =~ /^\s*(?:[-*]|\d+[.)])\s/
				|| $line =~ /^\s*\|/
				|| $line =~ /\b(?:always|never|must|shall|do\ not|don't|rule|required)\b/i;
		}
		push @kept, $para if $normative;
	}
	return join("\n\n", @kept);
}

# The deep notes: every heading title on one cheap line, then the 3-4 sections
# this note scores best against. The selected sections are in document order and
# their total is capped, so the document costs a fixed few KB however large it
# grows. A cut or an omission is declared in the text.
sub _sectioned_document {
	my (%a) = @_;
	my @all = split_sections($a{'text'});
	my ($picked) = select_sections(
		sections => \@all, note_text => $a{'note_text'}, force => $a{'force'},
		cap => $MAX_NOTES_BYTES, max => $MAX_NOTES_SECTIONS,
	);
	my $index_line = heading_index_line($a{'rel'}, \@all);
	my $body = $index_line;
	$body .= "\n\n" . join("\n\n", map { $_->{'text'} } @{$picked}) if @{$picked};
	my $cut = grep { $_->{'cut'} } @{$picked};
	my $omitted = scalar(@all) - scalar(@{$picked});
	my $truncated = ($cut || $omitted) ? 1 : 0;
	if ($truncated) {
		$body .= "\n\n[TRUNCATED: " . scalar(@{$picked}) . ' of ' . scalar(@all)
			. ' section(s) were selected, in at most ' . $MAX_NOTES_BYTES
			. ' bytes; the rest of the ' . $a{'bytes'}
			. ' byte document was not sent. The heading index above names every section.]';
	}
	return {
		rel => $a{'rel'}, label => $a{'label'}, present => 1,
		bytes => $a{'bytes'}, kept => text_bytes($body),
		truncated => $truncated, redacted => $a{'redacted'}, text => $body,
		heading_index => $index_line,
		sections => [ map {
			{ title => $_->{'title'}, bytes => $_->{'bytes'},
			  score => $_->{'score'}, cut => $_->{'cut'} }
		} @{$picked} ],
		sections_total => scalar @all,
	};
}

# Per-document and per-section bytes/tokens, the same numbers the log and the
# run report print. Estimate is always bytes/4 (est_tokens).
sub _accounting_sections {
	my ($core, $retrieved, $help_doc) = @_;
	my @out;
	for my $doc (@{$core}, @{$retrieved}, ($help_doc ? $help_doc : ())) {
		next unless ref $doc eq 'HASH' && $doc->{'present'};
		my $entry = {
			name => $doc->{'rel'}, bytes => $doc->{'kept'},
			est_tokens => est_tokens($doc->{'kept'}),
		};
		if (ref $doc->{'sections'} eq 'ARRAY' && @{$doc->{'sections'}}) {
			$entry->{'sections'} = [ map {
				{ title => $_->{'title'}, bytes => $_->{'bytes'},
				  est_tokens => est_tokens($_->{'bytes'}) }
			} @{$doc->{'sections'}} ];
		}
		push @out, $entry;
	}
	return \@out;
}

# One line for the agent log, the runner's stdout and the report.md. Both the
# agent and the runner call this, so the numbers cannot drift apart.
sub context_summary {
	my ($acc) = @_;
	return '' unless ref $acc eq 'HASH';
	my $bytes = $acc->{'context_bytes'} // 0;
	my $tokens = defined $acc->{'context_est_tokens'}
		? $acc->{'context_est_tokens'} : est_tokens($bytes);
	my @parts;
	for my $s (@{ ref $acc->{'sections'} eq 'ARRAY' ? $acc->{'sections'} : [] }) {
		next unless ref $s eq 'HASH';
		push @parts, ($s->{'name'} // '?') . ' ' . ($s->{'bytes'} // 0);
	}
	my $line = 'context: ' . $bytes . ' bytes (~' . $tokens . ' est tokens)';
	$line .= '; ' . join(', ', @parts) if @parts;
	if (ref $acc->{'reply_bytes'} eq 'ARRAY' && @{ $acc->{'reply_bytes'} }) {
		$line .= '; replies: ' . join('/', map { defined $_ ? $_ : 0 } @{ $acc->{'reply_bytes'} })
			. ' bytes';
	}
	return $line;
}

# Read back what an agent run logged: one ACCOUNTING line and one REPLY line per
# turn. The runner uses this rather than re-deriving the numbers, so the report
# cannot disagree with the agent.
sub read_agent_log {
	my ($path) = @_;
	my ($acc, @replies);
	return (undef, []) unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return (undef, []);
	while (my $line = <$fh>) {
		chomp $line;
		if ($line =~ /^ACCOUNTING\s+(\{.*\})\s*$/) {
			my $decoded = eval { JSON::PP::decode_json($1) };
			$acc = $decoded if ref $decoded eq 'HASH';
			next;
		}
		if ($line =~ /^REPLY\s+(\{.*\})\s*$/) {
			my $decoded = eval { JSON::PP::decode_json($1) };
			push @replies, $decoded if ref $decoded eq 'HASH';
		}
	}
	close $fh;
	return ($acc, \@replies);
}

# The help topic goes after the note, not into the system prompt: it is derived
# from the note and must not sit in the prefix that is reused for every turn.
sub help_block {
	my ($context) = @_;
	return '' unless ref $context eq 'HASH';
	my $id = $context->{'help_topic'};
	my $text = defined $context->{'help_text'} ? $context->{'help_text'} : '';
	if (!defined $id || !length $text) {
		return "\n## Help topic\nNo help topic matched the app the note names; "
			. "do not invent help text for it.\n";
	}
	return "\n## The help topic for the app the note names\n"
		. 'It was chosen because the note names its app. Keep the button labels and '
		. "hints it describes true if you change that app.\n\n" . $text;
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
		elsif (ref $doc->{'sections'} eq 'ARRAY' && @{ $doc->{'sections'} }) {
			my $picked = scalar @{ $doc->{'sections'} };
			$line .= ' - ' . $doc->{'bytes'} . ' bytes; ' . $picked . ' of '
				. ($doc->{'sections_total'} // '?') . ' section(s) selected, '
				. $doc->{'kept'} . ' bytes sent';
			$line .= ' (TRUNCATED)' if $doc->{'truncated'};
		}
		elsif ($doc->{'abbreviated'}) {
			$line .= ' - ABBREVIATED to its normative paragraphs; first ' . $doc->{'kept'}
				. ' of ' . $doc->{'bytes'} . ' bytes sent';
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
	my (%a) = @_;
	my @core = @{ $a{'core'} || [] };
	my @retrieved = @{ $a{'retrieved'} || [] };
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
- When behaviour changes, add or update the test in t/ in the same edit, and
  give the file a `# tests-for: <space-separated source paths>` header naming
  what it pins: t/93-test-map.t reads that map and scripts/tests_for.pl uses
  it. A defect you find but do not fix gets a TODO test naming the file and
  line, never a test that asserts the broken behaviour. A test must not call
  bare `prove -l t`; the nightly runs scripts/run_tests.pl instead.
- A browser script over ~550 lines is an index plus numbered NN_slug.js parts.
  A new or renamed part MUST be named in the index's
  `/* [[js-split]] ... [[/js-split]] */` manifest, or t/63-js-parts.t fails.
  A script in a lazy app needs its bundle entry in %manager_app_scripts and,
  when core code calls it before the chunk loads, in %manager_app_entry /
  %manager_toggle_apps in lib/JawnOS/Manager/Core1_tables_hooks.pm; a helper
  used by core pages belongs in the core bundle, not a lazy chunk.
- Perl must pass `perl -c`; JavaScript must pass `node --check`. The nightly
  runs those on every file you touched and feeds a failure back to you.
- Do not bump the version, commit, push or restart. The nightly does that.
- If you cannot find a file after three attempts, stop and say what you tried
  in "note"; never invent a path or keep guessing.
- Never print a secret (key, token, password) in an edit or in a note.

## How to look things up

This repository keeps generated indexes so that nobody has to read it to find
something. Read what this prompt carries before you grep - it answers "what
exists" and "where does it live".

You have no shell, so the two commands a person uses are not available to you:
`perl scripts/where.pl <name>` (a symbol, a route, a help topic or a file, to the
line) and `perl scripts/agent_help.pl <app>` (an app's sources, routes, tables,
settings and the tests that claim them). When a note needs an answer the index does
not carry, say so in "note" instead of guessing from a grep.

Grep is for what the indexes cannot know: free text, a string literal, a comment, a
value that is not a name. A symbol, a route path, a table or a help topic is not.

## Core context

HEAD

	$p .= 'repo: ' . ($a{'sha'} // '(unknown)') . "\n\n";

	# Only name the generated index when it was actually sent: telling the model
	# about a document it does not have is how it starts guessing at its contents.
	if ($a{'index'}) {
		$p .= "The compact index is in the core context below "
			. "(`qa/coding_night/agent-index.md`): every app with its file and route count, "
			. "every table with its columns, the route modules and the firmware sketches. "
			. "Read it before you grep.\n\n";
	}
	$p .= "These documents come from the main checkout, not from this worktree. They are "
		. "repository-relative and are the rules that apply to this repository.\n\n";
	$p .= _render_doc($_) for @core;

	if (@retrieved) {
		$p .= "## Retrieved context\n\n"
			. "The deep notes are sent by section, chosen for this note. The one-line heading "
			. "index above names every section: if the one you need was not selected, say so "
			. "in \"note\" and the change will be attempted from what is here.\n\n";
		$p .= _render_doc($_) for @retrieved;
	}

	my @missing = map { $_->{'rel'} } grep { !$_->{'present'} } @core, @retrieved;
	if (@missing) {
		$p .= '### Not available' . "\n"
			. 'The main checkout did not have: ' . join(', ', @missing) . ".\n"
			. "Do not guess their contents.\n\n";
	}

	$p .= "The help topic for the app the note names, when there is one, follows the "
		. "note itself.\n\n";

	return $p;
}

# One document, as the prompt prints it. A sectioned document declares its own
# truncation (it has a heading index above the selected sections); a flat one
# declares a byte cut here, so a partial rulebook is never read as the whole one.
sub _render_doc {
	my ($doc) = @_;
	my $p = '### ' . $doc->{'rel'} . ' (' . $doc->{'label'} . ")\n";
	return $p . "This document is not in the main checkout; it was not sent.\n\n"
		unless $doc->{'present'};
	if ($doc->{'abbreviated'}) {
		$p .= '[ABBREVIATED: this ' . $doc->{'bytes'} . ' byte document was reduced to its '
			. 'normative paragraphs; the first ' . $doc->{'kept'} . " bytes of that are below.]\n";
	}
	if ($doc->{'dropped'} && @{ $doc->{'dropped'} }) {
		$p .= '[DROPPED: sections about commands this agent cannot run: '
			. join('; ', @{ $doc->{'dropped'} }) . ".]\n";
	}
	elsif ($doc->{'truncated'} && !$doc->{'heading_index'} && !$doc->{'declared'}) {
		$p .= '[TRUNCATED: this document is ' . $doc->{'bytes'} . ' bytes; only the first '
			. $doc->{'kept'} . " bytes are included below. The rest was not sent.]\n";
	}
	$p .= '[REDACTED: ' . $doc->{'redacted'}
		. " line(s) matched the secret pattern and were withheld.]\n"
		if $doc->{'redacted'};
	my $body = $doc->{'text'} // '';
	$p .= $body;
	$p .= "\n" unless $body =~ /\n$/;
	$p .= "\n";
	return $p;
}

1;
