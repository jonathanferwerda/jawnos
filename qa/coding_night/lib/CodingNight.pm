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

use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();
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
		"coalesce(text, '') not like 'Nightly failed:%'",
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

# --- what the night works on ------------------------------------------------
# The queue is built from the lanes the house checked in Configure -> Plat -> QA
# (qa/lib/QaSetting.pm reads the same setting for this fenced runner).
#
#   notes       the top open JawnOS notes, exactly as before
#   security    new findings at or above `high` in the newest nightly audit's
#               report ($QA_ROOT/reports/security/<stamp>/report.json)
#   installers  the packages the newest installer check reports `missing`
#               ($QA_ROOT/reports/installers/<stamp>/report.json)
#
# A report-derived item is a task, not a row the app owns: it has no note uuid
# to mark completed, so the next report is what decides whether it is still
# there. The cap keeps one bad night from turning into twenty landings.

our $LANE_ITEM_MAX = 3;

our %SEVERITY_RANK = (critical => 4, high => 3, medium => 2, low => 1, info => 0);

sub lane_ids { return qw(notes security installers) }

# The newest finished run of a kind, newest by its UTC stamp. '' when the job
# has not run on this machine (or has not written a report yet).
sub newest_report_file {
	my ($qa_root, $kind) = @_;
	return '' unless defined $qa_root && length $qa_root && defined $kind && length $kind;
	my $dir = File::Spec->catdir($qa_root, 'reports', $kind);
	opendir(my $dh, $dir) or return '';
	my @stamps = sort { $b cmp $a }
		grep { /^\d{8}T\d{6}Z$/ && -d "$dir/$_" } readdir $dh;
	closedir $dh;
	return '' unless @stamps;
	my $file = "$dir/$stamps[0]/report.json";
	return -f $file ? $file : '';
}

sub read_report {
	my ($path) = @_;
	return undef unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	my $doc = eval { JSON::PP::decode_json($text) };
	return ref $doc eq 'HASH' ? $doc : undef;
}

sub _lanes_cap {
	my ($opt) = @_;
	my $max = $opt->{'max'};
	$max = $LANE_ITEM_MAX unless defined $max && $max =~ /^\d+$/;
	return $max;
}

sub security_items {
	my ($qa_root, %opt) = @_;
	my $doc = read_report( newest_report_file($qa_root, 'security') );
	return [] unless $doc && ref $doc->{'findings'} eq 'ARRAY';
	my $max = _lanes_cap(\%opt);
	my $floor = $SEVERITY_RANK{ $opt{'floor'} // 'high' } // $SEVERITY_RANK{'high'};
	my @rows = sort {
		($SEVERITY_RANK{ $b->{'severity'} // 'info' } // 0) <=> ($SEVERITY_RANK{ $a->{'severity'} // 'info' } // 0)
			|| ($a->{'id'} // '') cmp ($b->{'id'} // '')
			|| ($a->{'path'} // '') cmp ($b->{'path'} // '')
	} grep {
		!$_->{'known'}
			&& ($SEVERITY_RANK{ $_->{'severity'} // 'info' } // 0) >= $floor
	} @{ $doc->{'findings'} };
	my @out;
	for my $f ( @rows ) {
		last if @out >= $max;
		my $where = ($f->{'path'} // '') . (($f->{'line'} // 0) ? ':' . $f->{'line'} : '');
		my $id = ($f->{'id'} // 'finding') . ':' . ($where || '?');
		push @out, {
			id        => 'security:' . $id,
			source    => 'security',
			title     => 'Security: ' . ($f->{'title'} // $f->{'id'} // 'finding'),
			text      => join("\n",
				'The nightly security audit reports this finding:',
				'',
				'- id: ' . ($f->{'id'} // ''),
				'- severity: ' . ($f->{'severity'} // ''),
				'- area: ' . ($f->{'area'} // ''),
				'- where: ' . ($where || '(not named)'),
				'- evidence: ' . (($f->{'evidence'} // '') =~ /\S/ ? $f->{'evidence'} : '(none)'),
				'- suggested fix: ' . (($f->{'fix'} // '') =~ /\S/ ? $f->{'fix'} : '(none)'),
				'',
				'Fix it at the root cause. Add or update the test that would have caught it.',
				'`perl scripts/security_audit.pl --check` must stay clean for this finding:',
				'do not weaken the check and do not add an allowlist entry.',
			),
			timestamp => '',
			category  => 'security',
			status    => 'open',
		};
	}
	return \@out;
}

our @INSTALLER_SETS = (
	[ 'Perl module',      'modules',   'name' ],
	[ 'Debian package',   'debian',    'package' ],
	[ 'Arch package',     'arch',      'package' ],
	[ 'Android component','android',   'component' ],
	[ 'Android tool',     'toolchain', 'tool' ],
);

sub installer_items {
	my ($qa_root, %opt) = @_;
	my $doc = read_report( newest_report_file($qa_root, 'installers') );
	return [] unless $doc;
	my $max = _lanes_cap(\%opt);
	my @out;
	for my $set ( @INSTALLER_SETS ) {
		my ($kind, $key, $name_key) = @{$set};
		for my $row ( @{ ref $doc->{$key} eq 'ARRAY' ? $doc->{$key} : [] } ) {
			last if @out >= $max;
			next unless ($row->{'status'} // '') eq 'missing';
			my $name = $row->{$name_key} // '';
			next unless length $name;
			push @out, {
				id        => 'installers:' . $key . ':' . $name,
				source    => 'installers',
				title     => 'Installer: ' . $name . ' is missing upstream',
				text      => join("\n",
					'The nightly installer check reports that ' . lc($kind) . ' ' . $name
						. ' is no longer offered upstream, so a fresh install would fail.',
					'',
					'- reported as: ' . $kind,
					'- name: ' . $name,
					'- installed here: ' . (($row->{'installed'} // '') =~ /\S/ ? $row->{'installed'} : '(not installed)'),
					'- latest offered: ' . (($row->{'latest'} // '') =~ /\S/ ? $row->{'latest'} : '(none)'),
					'',
					'Update the installer list or the version pin to one the repository still offers,',
					'then run `perl scripts/jawnos_deps.pl --freshness` and make sure this row is gone.',
					'Change only the pin or list entry: do not silently skip the package.',
				),
				timestamp => '',
				category  => 'installers',
				status    => 'open',
			};
		}
		last if @out >= $max;
	}
	return \@out;
}

# The night's whole queue, in the order it is worked: notes first, then the
# security findings, then the installer gaps.
sub select_queue {
	my ($db, %opt) = @_;
	my @lanes = @{ ref $opt{'lanes'} eq 'ARRAY' ? $opt{'lanes'} : [] };
	my %on = map { $_ => 1 } @lanes;
	my @queue;
	if ($on{'notes'}) {
		my $notes = select_notes($db, limit => $opt{'limit'});
		push @queue, map { { %{$_}, source => 'notes' } } @{$notes};
	}
	push @queue, @{ security_items($opt{'qa_root'}, max => $opt{'lane_max'}) } if $on{'security'};
	push @queue, @{ installer_items($opt{'qa_root'}, max => $opt{'lane_max'}) } if $on{'installers'};
	return \@queue;
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

# --- where the night pushes -------------------------------------------------
# The house may name a fork instead of the checkout's upstream. The value is
# either `owner/name` or an https URL; empty means the checkout's own remote
# (origin here, fork for the Android app). The same rules live in
# lib/JawnOS/Domain/Records2.pm so the panel and the fenced runner agree; t/92
# asks both.
sub push_repo_default {
	my ($which) = @_;
	return (defined $which && $which eq 'app') ? $APP_REMOTE : 'origin';
}

sub push_repo_valid {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/^\s+|\s+$//g;
	return { ok => 1, value => '', kind => 'default' } unless length $value;
	return { ok => 0, error => 'A push repo cannot contain spaces.' }
		if $value =~ /\s/;
	return { ok => 0, error => 'A push repo cannot carry credentials (user or token@host).' }
		if $value =~ /\@/;

	if ($value =~ m{^https://([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::\d{1,5})?/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$}i) {
		my ($host, $owner, $name) = ($1, $2, $3);
		if ($owner !~ /^\.+$/ && $name !~ /^\.+$/) {
			return { ok => 1, value => $value, kind => 'url', host => $host, slug => "$owner/$name" };
		}
	}
	elsif ($value =~ m{^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?$}) {
		my ($owner, $name) = ($1, $2);
		if ($owner !~ /^\.+$/ && $name !~ /^\.+$/) {
			return { ok => 1, value => $value, kind => 'owner', slug => "$owner/$name" };
		}
	}
	return { ok => 0, error => 'Use owner/name or an https:// URL with owner/name.' };
}

sub push_repo_target {
	my ($value) = @_;
	return '' unless defined $value && length $value;
	return $value if $value =~ m{^https://}i;
	(my $slug = $value) =~ s/\.git$//;
	return "https://github.com/$slug.git";
}

sub push_repo_slug {
	my ($value) = @_;
	return '' unless defined $value && length $value;
	(my $slug = $value) =~ s/\.git$//;
	$slug =~ s{^https://[^/]+/}{}i;
	return $slug;
}

# Read the house setting and resolve it. A bad saved value is an error, never a
# silent fallback: the night must stop before it pushes anywhere unexpected.
sub push_target {
	my ($db, $which) = @_;
	$which = 'app' if defined $which && $which eq 'app';
	my $setting  = ($which eq 'app') ? 'coding_app_push_repo' : 'coding_push_repo';
	my $fallback = push_repo_default($which);
	my $raw = eval { QaSetting::read_setting($db, $setting) };
	$raw = '' unless defined $raw;
	my $check = push_repo_valid($raw);
	unless ($check->{'ok'}) {
		return {
			ok => 0, which => $which, setting => $setting, raw => $raw,
			value => $raw, target => $fallback, effective => $fallback,
			fallback => $fallback, error => $check->{'error'},
		};
	}
	my $value  = $check->{'value'};
	my $target = length $value ? push_repo_target($value) : $fallback;
	return {
		ok => 1, which => $which, setting => $setting, raw => $raw,
		value => $value, target => $target, effective => $target,
		fallback => $fallback,
		slug => length $value ? push_repo_slug($value) : '',
	};
}

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

# A repair attempt is the same note with the failure appended: id and title are
# kept so the agent log, accounting and the report stay aligned. It is always
# built from the ORIGINAL text, never from the previous attempt's, so the block
# cannot snowball. The block is capped - a suite log can be megabytes and the
# agent's context is not - and the instruction survives the cap.
sub repair_note {
	my (%a) = @_;
	my $note = $a{'note'} || {};
	my $max  = defined $a{'max'}     ? $a{'max'}     : 2;
	my $n    = defined $a{'attempt'} ? $a{'attempt'} : 1;
	my $cap  = defined $a{'cap'}     ? $a{'cap'}     : 4096;
	my @failing = @{ ref $a{'failing'} eq 'ARRAY' ? $a{'failing'} : [] };
	my $tail = defined $a{'tail'} ? $a{'tail'} : '';

	my $instruction = 'Fix the failure in this worktree. Do not start over, do not rewrite'
		. ' unrelated files, and do not weaken or delete a test to make it pass.';
	my $intro = "\n\n## The nightly suite failed (repair attempt $n of $max)\n\n"
		. "Failing tests:\n" . (@failing ? join("\n", @failing) : '(none named in the log)') . "\n\n"
		. "Last lines of the suite log:\n" . ($tail =~ /\S/ ? $tail : '(the log was empty)') . "\n\n";
	my $room = $cap - length($instruction) - 1;
	$room = 0 if $room < 0;
	$intro = substr($intro, 0, $room) . "\n" if length($intro) > $room;

	return {
		%{$note},
		text => ($note->{'text'} // '') . $intro . $instruction,
	};
}

# One line for every report that can carry a repair. The lane decides whether
# the second list is suite exits (repo) or build exits (app), so a reader is
# never told a Gradle build was a suite.
sub repair_summary {
	my ($run) = @_;
	return '' unless (($run->{'repair_attempts'} // 0) > 0);
	my $what = (($run->{'lane'} // '') eq 'app') ? 'build exits' : 'suite exits';
	return '- repairs: ' . $run->{'repair_attempts'} . ' (agent exits '
		. (join(', ', @{ $run->{'repair_exits'} || [] }) || '-')
		. ', ' . $what . ' ' . (join(', ', @{ $run->{'repair_suite_exits'} || [] }) || '-') . ")\n";
}

# --- the backup the night leaves behind -------------------------------------
# A tag is the whole recovery: it is a commit id, so a reset lands on exactly
# the tree the night started from. rollback.sh is the human path; the runner
# performs the same steps itself when a post-merge step fails.
sub _sh_quote {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/'/'"'"'/g;
	return "'$value'";
}

sub rollback_script {
	my (%a) = @_;
	my $tag     = $a{'tag'} // '';
	my $repo    = $a{'repo'} // '.';
	my $health  = $a{'health'} // '';
	my $restart = $a{'restart'} // 'scripts/restart.pl';
	my $reason  = 'rollback to ' . $tag;
	my $qtag     = _sh_quote($tag);
	my $qrepo    = _sh_quote($repo);
	my $qhealth  = _sh_quote($health);
	my $qrestart = _sh_quote($restart);
	my $qreason  = _sh_quote($reason);
	return <<"SH";
#!/bin/sh
# Generated by qa/coding_night/run.pl for $tag.
# Put main back on the tag this night started from, restart the house through
# scripts/restart.pl, and require HTTP 200 from the health route. It refuses if
# the tag is missing: a reset to a tag nobody can prove is worse than no reset.
set -u
TAG=$qtag
REPO=$qrepo
HEALTH=$qhealth
RESTART=$qrestart
if ! command -v git >/dev/null 2>&1; then
	echo "rollback refused: git is not on PATH" >&2
	exit 2
fi
cd "\$REPO" || { echo "rollback refused: cannot enter \$REPO" >&2; exit 2; }
if ! git rev-parse --verify --quiet "refs/tags/\$TAG" >/dev/null 2>&1; then
	echo "rollback refused: tag \$TAG is missing in \$REPO" >&2
	exit 2
fi
git reset --hard "\$TAG" || { echo "rollback failed: git reset --hard \$TAG" >&2; exit 1; }
if [ ! -f "\$RESTART" ]; then
	echo "rollback reset \$TAG, but \$RESTART is missing - RESTART THE HOUSE BY HAND" >&2
	exit 1
fi
if ! perl "\$RESTART" --reason $qreason; then
	echo "ROLLBACK RESTART FAILED: main is on \$TAG but \$RESTART was refused - RESTART THE HOUSE BY HAND" >&2
	exit 1
fi
if [ -n "\$HEALTH" ]; then
	if ! perl -MHTTP::Tiny -e 'my \$u=shift; my \$d=time+60; while(1){ my \$r=HTTP::Tiny->new(verify_SSL=>0,timeout=>10)->get(\$u); exit 0 if \$r->{status}==200; last if time>=\$d; sleep 2 } exit 1' "\$HEALTH"; then
		echo "rollback restarted on \$TAG, but \$HEALTH is not 200" >&2
		exit 1
	fi
fi
echo "rolled back to \$TAG and healthy"
exit 0
SH
}

sub write_rollback_script {
	my ($dir, %a) = @_;
	return (undef, 'no directory for rollback.sh') unless defined $dir && length $dir;
	my $path = File::Spec->catfile($dir, 'rollback.sh');
	open(my $fh, '>', $path) or return (undef, "could not write $path: $!");
	my $text = rollback_script(%a);
	my $wrote = print {$fh} $text;
	close $fh;
	return (undef, "could not write $path") unless $wrote;
	chmod 0755, $path;
	return ($path, undef);
}

# A cheap copy of what a publish can overwrite: the staged APKs and the
# app_release.json beside them. The APKs are gitignored blobs, so a bad stage is
# not recoverable from git history.
sub releases_backup {
	my ($repo, $dest) = @_;
	return { ok => 0, error => 'no repository for the release backup' }
		unless defined $repo && length $repo;
	my $dir = File::Spec->catdir($repo, 'releases');
	return { ok => 1, dir => $dest, files => [] } unless -d $dir;
	make_path($dest);
	opendir(my $dh, $dir) or return { ok => 0, error => "cannot read $dir: $!" };
	my @names = sort grep { /\.apk$/ && -f File::Spec->catfile($dir, $_) } readdir $dh;
	closedir $dh;
	push @names, 'app_release.json' if -f File::Spec->catfile($dir, 'app_release.json');
	my @copied;
	for my $name (@names) {
		my $src = File::Spec->catfile($dir, $name);
		my $to  = File::Spec->catfile($dest, $name);
		copy($src, $to)
			or return { ok => 0, error => "could not back up $src: $!", dir => $dest, files => \@copied };
		push @copied, $name;
	}
	return { ok => 1, dir => $dest, files => \@copied };
}

sub releases_restore {
	my ($repo, $backup) = @_;
	return { ok => 0, error => 'no release backup to restore' }
		unless ref $backup eq 'HASH' && $backup->{'ok'};
	my $dir = File::Spec->catdir($repo // '', 'releases');
	make_path($dir);
	my %keep = map { $_ => 1 } @{ $backup->{'files'} || [] };
	my @current;
	if (opendir(my $dh, $dir)) {
		@current = grep { /\.apk$/ || $_ eq 'app_release.json' } readdir $dh;
		closedir $dh;
	}
	for my $name (@current) {
		next if $keep{$name};
		my $path = File::Spec->catfile($dir, $name);
		unlink $path if -f $path;
	}
	my @restored;
	for my $name (@{ $backup->{'files'} || [] }) {
		copy(File::Spec->catfile($backup->{'dir'}, $name), File::Spec->catfile($dir, $name))
			or return { ok => 0, error => "could not restore $name: $!", restored => \@restored };
		push @restored, $name;
	}
	return { ok => 1, restored => \@restored };
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
		$md .= '- push target: `' . ($run->{'push_target'} // 'origin') . "`\n";
		$md .= '- agent exit: ' . ($run->{'agent_exit'} // '-') . "\n";
		$md .= '- suite exit: ' . ($run->{'suite_exit'} // '-') . "\n";
		$md .= repair_summary($run);
		$md .= '- pushed: ' . ($run->{'pushed'} ? 'yes' : 'no')
			. ' · merged: ' . ($run->{'merged'} ? 'yes' : 'no')
			. ' · restarted: ' . ($run->{'restarted'} ? 'yes' : 'no')
			. ' · health 200: ' . ($run->{'health_ok'} ? 'yes' : 'no')
			. ' · note completed: ' . ($run->{'marked_completed'} ? 'yes' : 'no') . "\n";
		$md .= '- rollback tag: `' . ($run->{'rollback_tag'} // '') . "`"
			. ' · rolled back: ' . ($run->{'rolled_back'} // 'no');
		if (($run->{'rolled_back'} // 'no') eq 'yes') {
			$md .= ' · rollback restart: '
				. (defined $run->{'rollback_restart_ok'} ? ($run->{'rollback_restart_ok'} ? 'ok' : 'FAILED') : 'not attempted')
				. ' · rollback health 200: '
				. (defined $run->{'rollback_health_ok'} ? ($run->{'rollback_health_ok'} ? 'yes' : 'no') : 'not checked');
		}
		$md .= "\n";
		if (($run->{'rolled_back'} // '') eq 'yes' && defined $run->{'rollback_restart_ok'} && !$run->{'rollback_restart_ok'}) {
			$md .= "\n> **ROLLBACK RESTART FAILED.** Main was reset to `" . ($run->{'rollback_tag'} // '')
				. "` but scripts/restart.pl refused. The live house may still be running the bad code: restart it by hand now.\n";
		}
		if (($run->{'lane'} // '') eq 'app') {
			$md .= '- jawnos fast-forwarded: ' . ($run->{'ff_jawnos'} ? 'yes' : 'no')
				. ' · staged: ' . ($run->{'staged'} ? 'yes' : 'no')
				. ' · publish: ' . ($run->{'publish'} // 'not attempted')
				. ' · releases restored: ' . ($run->{'releases_restored'} ? 'yes' : 'no') . "\n";
		}
		$md .= '- warning: ' . $run->{'warning'} . "\n" if $run->{'warning'};
		$md .= '- ' . $run->{'error'} . "\n" if $run->{'error'};
		$md .= "\n";
	}
	return $md;
}

1;
