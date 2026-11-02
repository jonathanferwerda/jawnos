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

# --- the two lanes ----------------------------------------------------------
# A note about the Android app is built in the app checkout, not here: this
# worktree has no AndroidManifest, no gradlew and no APK to publish, so asking
# it to fix a status bar is asking the wrong repository. A keyword from the
# app's own vocabulary, or an explicit app tag, selects that lane.
our @APP_KEYWORDS = (
	'android', 'apk', 'app', 'termux', 'status bar', 'navigation bar',
	'soft keyboard', 'ime', 'webview', 'wakelock', 'vibrate',
);

our $DEFAULT_APP_DIR = '/home/jawn/jawnos-app/termux-app';
our $APP_BASE_BRANCH = 'jawnos';
our $APP_REMOTE      = 'fork';
our $APP_JAVA_HOME   = '/usr/lib/jvm/java-17-openjdk';

sub app_keywords    { return [ @APP_KEYWORDS ] }
sub app_base_branch { return $APP_BASE_BRANCH }
sub app_remote      { return $APP_REMOTE }
sub app_java_home   { return $APP_JAVA_HOME }

sub app_repo_dir {
	my ($given) = @_;
	$given = $ENV{'JAWNOS_APP_DIR'} if !defined($given) || !length($given);
	$given = $DEFAULT_APP_DIR       if !defined($given) || !length($given);
	return $given;
}

sub app_lane_env {
	my ($app_dir) = @_;
	return {
		JAWNOS_APP_LANE => '1',
		JAWNOS_APP_DIR  => app_repo_dir($app_dir),
	};
}

# The app worktree carries its own directory: it must never share work/ with
# this repository's worktrees, and a failed app build leaves the tree behind.
sub plan_app_paths {
	my ($root, $stamp, $n) = @_;
	$root  = '' unless defined $root;
	$stamp = '' unless defined $stamp;
	$n     = 1  unless defined $n && $n =~ /^\d+$/;
	return {
		worktree => File::Spec->catdir($root, 'work-app', "$stamp-$n"),
		branch   => "qa/nightly-$stamp-$n",
	};
}

# True when the note belongs to the Android app. An explicit tag (tag/tags/
# lane, or an [app] marker) wins; otherwise a whole-word keyword from the app's
# vocabulary is enough. "app" is deliberately broad: a note that only says
# "app" is more likely about the Android shell than about a server app, and the
# keyword list is the one a person can reason about.
sub is_app_note {
	my ($note) = @_;
	$note ||= {};

	for my $key (qw(tag tags lane app_lane)) {
		my $value = $note->{$key};
		my @tags = ref $value eq 'ARRAY' ? @{$value} : (defined $value ? ($value) : ());
		for my $tag (@tags) {
			next unless defined $tag;
			my $clean = lc $tag;
			$clean =~ s/^\s+|\s+$//g;
			return 1 if $clean eq 'app' || $clean eq 'android' || $clean eq 'app-lane';
		}
	}

	my $text = join(' ',
		$note->{'title'} // '', $note->{'text'} // '', $note->{'category'} // '');
	return 1 if $text =~ /(?:^|\s)[\#\[]\s*app(?:\s*\]|(?=\s|$))/i;

	# Hyphens and underscores are word separators here: "soft-keyboard",
	# "navigation_bar" and "status bar" are the same phrase.
	my $hay = lc $text;
	$hay =~ s/[-_]+/ /g;
	for my $keyword (@APP_KEYWORDS) {
		my $re = join '\s+', map { quotemeta } split /\s+/, $keyword;
		return 1 if $hay =~ /(?<![a-z0-9])$re(?![a-z0-9])/;
	}
	return 0;
}

# The build the app lane validates with. JAVA_HOME is explicit because a
# systemd unit has none and the app's Gradle files want the JDK 17 the box has.
sub app_build_command { return [ './gradlew', '--max-workers=4', ':app:assembleDebug' ] }

# Bump versionCode by one and the versionName patch by one. The app repo's own
# rule is that every APK change is a version change; this is that rule applied
# to the worktree only. Returns ({versionCode, versionName, path}, undef) or
# (undef, reason) and writes nothing on a reason.
sub bump_app_version {
	my ($worktree) = @_;
	my $path = File::Spec->catfile($worktree // '', 'app', 'build.gradle');
	return (undef, 'app/build.gradle is not in the worktree') unless -f $path;
	open(my $fh, '<:raw', $path) or return (undef, "$path could not be read: $!");
	local $/;
	my $text = <$fh>;
	close $fh;
	return (undef, "$path is empty") unless defined $text && length $text;

	$text =~ /(^[ \t]*versionCode[ \t]+)(\d+)/m
		or return (undef, 'app/build.gradle has no versionCode');
	my $code = $2 + 1;
	$text =~ s/(^[ \t]*versionCode[ \t]+)\d+/$1$code/m;

	$text =~ /(^[ \t]*versionName[ \t]+")(\d+)\.(\d+)\.(\d+)(")/m
		or return (undef, 'app/build.gradle has no major.minor.patch versionName');
	my $name = "$2.$3." . ($4 + 1);
	$text =~ s/(^[ \t]*versionName[ \t]+")\d+\.\d+\.\d+(")/$1$name$2/m;

	open(my $out, '>:raw', $path) or return (undef, "$path could not be written: $!");
	my $wrote = print {$out} $text;
	close $out;
	return (undef, "$path could not be written") unless $wrote;
	return ({ versionCode => $code, versionName => $name, path => $path }, undef);
}

# The newest APK a Gradle debug build left in the worktree, or undef.
sub app_apk {
	my ($worktree) = @_;
	return undef unless defined $worktree && length $worktree;
	my @found = grep { -f $_ } glob("$worktree/app/build/outputs/apk/*/*.apk");
	return undef unless @found;
	@found = sort { (stat($b))[9] <=> (stat($a))[9] } @found;
	return $found[0];
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
		$md .= '- lane: ' . ($run->{'lane'} // 'repo')
			. (($run->{'app_repo'} // '') ? ' (`' . $run->{'app_repo'} . '`)' : '') . "\n";
		$md .= '- layers: ' . ($run->{'layers'} // '') . "\n";
		$md .= '- status: ' . ($run->{'status'} // 'unknown') . "\n";
		$md .= '- agent exit: ' . ($run->{'agent_exit'} // '-') . "\n";
		$md .= '- suite exit: ' . ($run->{'suite_exit'} // '-') . "\n";
		$md .= '- pushed: ' . ($run->{'pushed'} ? 'yes' : 'no')
			. ' · merged: ' . ($run->{'merged'} ? 'yes' : 'no')
			. ' · restarted: ' . ($run->{'restarted'} ? 'yes' : 'no')
			. ' · health 200: ' . ($run->{'health_ok'} ? 'yes' : 'no')
			. ' · note completed: ' . ($run->{'marked_completed'} ? 'yes' : 'no') . "\n";
		if (($run->{'lane'} // '') eq 'app') {
			$md .= '- jawnos fast-forwarded: ' . ($run->{'ff_jawnos'} ? 'yes' : 'no')
				. ' · staged: ' . ($run->{'staged'} ? 'yes' : 'no')
				. ' · publish: ' . ($run->{'publish'} // 'not attempted') . "\n";
		}
		$md .= '- warning: ' . $run->{'warning'} . "\n" if $run->{'warning'};
		$md .= '- ' . $run->{'error'} . "\n" if $run->{'error'};
		$md .= "\n";
	}
	return $md;
}

1;
