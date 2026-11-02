package CodingNight;

# The 06:00 coding nightly's rules, kept out of the runner so the tests can
# ask them without a git repository: which notes are in the queue, what the
# worktree and branch are called, which layers a changed file list needs, and
# how the configured agent line becomes an argv.
#
# The notes are read through a `mode=ro` URI. A note is in this queue only when
# it is filed under JawnOS, still open, and not tombstoned - the same row the
# panel shows a person as work left to do.

use strict;
use warnings;

use File::Spec;
use Text::ParseWords qw(shellwords);

require QaSetting;

our $VERSION = '1';

sub clamp_limit        { return QaSetting::clamp_note_limit($_[0]) }

# The two names a night's work carries. <stamp> is a run stamp (one per run),
# <n> is the note's place in that run's queue. The branch is what is pushed and
# merged; the worktree is where the agent and the suite work.
sub plan_paths {
	my ($root, $stamp, $n) = @_;
	$root  = '' unless defined $root;
	$stamp = '' unless defined $stamp;
	$n     = 1  unless defined $n && $n =~ /^\d+$/;
	return {
		worktree => File::Spec->catdir($root, 'work', "$stamp-$n"),
		branch   => "qa/nightly-$stamp-$n",
	};
}

sub notes_columns {
	my ($db) = @_;
	my $rows = QaSetting::sqlite_json($db, "select name from pragma_table_info('notes')", allow_error => 1);
	my %cols;
	for my $row ( @{ ref $rows eq 'ARRAY' ? $rows : [] } ) {
		my $name = $row->{'name'} // '';
		$cols{$name} = 1 if length $name;
	}
	return \%cols;
}

# The top open JawnOS notes, newest first, at most `limit` of them. `completed`
# is a state, not a deletion: a completed note stays in the list but never in
# this queue. An older row with no status reads as open.
sub select_notes {
	my ($db, %opt) = @_;
	my $limit = clamp_limit($opt{'limit'});
	die "CodingNight: no database at $db\n" unless defined $db && -f $db;

	my $cols = notes_columns($db);
	die "CodingNight: $db has no notes table\n" unless $cols->{'uuid'};

	my @where = (
		"coalesce(text, '') != ''",
		"coalesce(ost, '') != 'deleting'",
		"lower(coalesce(category, '')) = 'jawnos'",
	);
	push @where, "lower(coalesce(status, 'open')) != 'completed'" if $cols->{'status'};
	push @where, "lower(coalesce(completed, '')) not in ('1','on','yes','true')" if $cols->{'completed'};

	my @sel = qw(uuid text timestamp category);
	push @sel, 'status' if $cols->{'status'};

	my $sql = 'select ' . join(', ', @sel) . ' from notes'
		. ' where ' . join(' and ', @where)
		. ' order by timestamp desc, rowid desc limit ' . $limit;

	my $rows = QaSetting::sqlite_json($db, $sql);
	my @out;
	for my $row ( @{ ref $rows eq 'ARRAY' ? $rows : [] } ) {
		my $body = $row->{'text'} // '';
		my ($title) = $body =~ /^\s*(\S[^\n]*)/;
		$title = '' unless defined $title;
		$title =~ s/\s+/ /g;
		$title = substr($title, 0, 90);
		push @out, {
			id        => $row->{'uuid'} // '',
			title     => $title,
			text      => $body,
			timestamp => $row->{'timestamp'} // '',
			category  => $row->{'category'} // 'jawnos',
			status    => $row->{'status'} // 'open',
		};
	}
	return \@out;
}

# l2 (the database) and l3 (a browser) are only worth their minutes when the
# change can reach a route, a template or a script. A change to qa/ itself, a
# test or the firmware is served by l0 and l1.
sub layers_for_files {
	my ($files) = @_;
	$files = [] unless ref $files eq 'ARRAY';
	for my $file (@{$files}) {
		next unless defined $file && length $file;
		return 'l0,l1,l2,l3' if $file =~ m{^templates/}i;
		return 'l0,l1,l2,l3' if $file =~ m{^public/js/}i;
		return 'l0,l1,l2,l3' if $file =~ m{^lib/JawnOS/(?:Controller|Routes)(?:/|\.pm$)}i;
		return 'l0,l1,l2,l3' if $file =~ m{^perl/[^/]+\.pl$}i;
	}
	return 'l0,l1';
}

# The hook: `JAWNOS_CODING_AGENT` (or the saved `qa_coding_agent` setting) is a
# command line, split the way a shell would split it and then exec'd with no
# shell - so a path with spaces or a quoted argument survives, and nothing in
# the value can become a second command.
sub agent_command {
	my ($line) = @_;
	return undef unless defined $line;
	$line =~ s/^\s+|\s+$//g;
	return undef unless length $line;
	my @argv = eval { shellwords($line) };
	return undef unless @argv;
	return [ @argv ];
}

sub note_env {
	my ($note) = @_;
	$note ||= {};
	return {
		JAWNOS_NOTE_ID    => ($note->{'id'} // ''),
		JAWNOS_NOTE_TITLE => ($note->{'title'} // ''),
		JAWNOS_NOTE_TEXT  => ($note->{'text'} // ''),
	};
}

sub report_markdown {
	my ($rep) = @_;
	$rep ||= {};
	my $md = '# JawnOS coding nightly ' . ($rep->{'stamp'} // '') . "\n\n";
	$md .= '- generated: ' . ($rep->{'generated'} // '') . "\n";
	$md .= '- dry run: ' . ($rep->{'dry_run'} ? 'yes' : 'no') . "\n";
	$md .= '- notes per night: ' . ($rep->{'limit'} // '') . "\n";
	$md .= '- agent: ' . (($rep->{'agent'} // '') || '(not configured)') . "\n";
	$md .= '- result: **' . ($rep->{'ok'} ? 'PASS' : 'ATTENTION') . "**\n\n";

	my $runs = $rep->{'runs'} || [];
	if (!@{$runs}) {
		$md .= "No note was worked on.\n";
		return $md;
	}
	$md .= "## Notes\n\n";
	for my $run ( @{$runs} ) {
		$md .= '### ' . ($run->{'n'} // '?') . '. ' . ($run->{'title'} // '(untitled)') . "\n\n";
		$md .= '- note: `' . ($run->{'note_id'} // '') . "`\n";
		$md .= '- branch: `' . ($run->{'branch'} // '') . "`\n";
		$md .= '- worktree: `' . ($run->{'worktree'} // '') . "`\n";
		$md .= '- layers: ' . ($run->{'layers'} // '') . "\n";
		$md .= '- status: ' . ($run->{'status'} // 'unknown') . "\n";
		$md .= '- agent exit: ' . ($run->{'agent_exit'} // '-') . "\n";
		$md .= '- suite exit: ' . ($run->{'suite_exit'} // '-') . "\n";
		$md .= '- pushed: ' . ($run->{'pushed'} ? 'yes' : 'no')
			. ' · merged: ' . ($run->{'merged'} ? 'yes' : 'no')
			. ' · restarted: ' . ($run->{'restarted'} ? 'yes' : 'no')
			. ' · health 200: ' . ($run->{'health_ok'} ? 'yes' : 'no')
			. ' · note completed: ' . ($run->{'marked_completed'} ? 'yes' : 'no') . "\n";
		$md .= '- ' . $run->{'error'} . "\n" if $run->{'error'};
		$md .= "\n";
	}
	return $md;
}

1;
