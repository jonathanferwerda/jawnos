#!/usr/bin/env perl
# The help registry: plain-language descriptions of every app, feature, device
# and cross-cutting function, keyed by a topic id. A topic is
#
#   title    - what the reader sees as the heading
#   category - 'apps' | 'features' | 'functions' | 'devices'
#   summary  - one line, used in the index and in hover enrichments
#   body     - an arrayref of paragraphs (plain text; the template escapes it)
#   steps    - an optional arrayref of how-to steps, shown as an ordered list
#   related  - an arrayref of other topic ids worth reading next
#   app      - optional: the app name whose window this topic explains, so the
#              template can offer an "Open" button
#   prompt   - optional: extra steering handed to the Help agent for this topic,
#              on top of the entry itself
#
# Help has two tiers, and only this one is written by hand:
#
#   tier 1  this registry - prose for a person navigating the program. Translated
#           on demand; audited by t/11-help.t and scripts/help_audit.pl.
#   tier 2  generated - `perl scripts/agent_help.pl <app>` derives the technical
#           brief from the tree: sources, routes, tables, settings, the tests
#           that claim them, and the source files' own notes. Never hand-write a
#           tier-2 fact and never translate it: anything derivable from code is
#           derived, or it becomes a lie with a date on it. The rationale (why a
#           thing is this way) stays in the comments and docs/AGENTS-notes.md.
#
# The registry is deliberately data, not code: adding a topic is adding a key.
# Topics are matched case-insensitively and tolerate spaces or hyphens where the
# key has underscores, so help("Start Menu"), help("start-menu") and
# help("start_menu") all resolve.

package help;

use strict;
no warnings;
use Mojo::Util qw(xml_escape);

# The date every topic is considered vetted as of, unless it carries its own
# `verified`. The auditor compares this against the git history of the app's
# files: anything that changed since is reported as possibly stale.
our $verified_default = '2026-10-12';

# ---- topics: the registry itself lives in parts under perl/help/ ------------
# One assignment per topic, required in reading order. %topic is an ordinary
# hash, so the order here changes nothing but how the source reads: catalogue()
# and search() sort their own keys. Adding a topic means adding an entry to the
# part its category belongs to (apps, features, functions, devices).
our %topic = ();

my $help_parts_dir = __FILE__;
$help_parts_dir =~ s{[/\\][^/\\]+$}{} or $help_parts_dir = '.';

require "$help_parts_dir/help/topics_apps.pl";
require "$help_parts_dir/help/topics_web.pl";
require "$help_parts_dir/help/topics_people.pl";
require "$help_parts_dir/help/topics_business.pl";
require "$help_parts_dir/help/topics_mail.pl";
require "$help_parts_dir/help/topics_configure.pl";
require "$help_parts_dir/help/topics_features.pl";
require "$help_parts_dir/help/topics_functions.pl";
require "$help_parts_dir/help/topics_devices.pl";

# ---- live docs: values a page reads when it is drawn ------------------------
# A live doc is still ordinary help text, but it may carry a placeholder written
# {{live:name}}. Only a name in this table is filled; every value is a
# no-argument sub returning a plain string. There is deliberately no eval and no
# string interpolation here, so a token can never run code or reach anything a
# person did not add to this file by hand. A name that is not listed is left on
# the page exactly as written, so a misspelling is visible and harmless.
our $live_ollama_memo;
our %live_token = (
	version => sub {
		my $v = subs::provides('jawn_version') ? eval { &subs::jawn_version() } : undef;
		# A bare `require help.pl` (the auditor, a one-liner) has no subroutines.pl
		# loaded, so fall back to the same file the app reads.
		if (!defined $v || $v !~ /\S/) {
			$v = eval {
				my $fh;
				open $fh, '<', './VERSION' or die;
				local $/;
				<$fh>;
			};
			$v = '' unless defined $v;
			$v =~ s/\s+$//;
		}
		return (defined $v && $v =~ /\S/) ? $v : 'unknown';
	},
	machine => sub {
		my $v = eval { &subs::machine_name() };
		$v = eval { &subs::device_setter() } if !defined $v || $v !~ /\S/;
		return (defined $v && $v =~ /\S/) ? $v : 'unknown';
	},
	now => sub {
		my $ms = eval { &subs::rightNow() };
		return 'unknown' unless defined $ms && $ms =~ /^\d+$/;
		my @t = localtime(int($ms / 1000));
		return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
			$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
	},
	ollama => sub {
		# A connect probe, not a shelled command and not a model fetch: the local
		# API is asked once a minute at most, because one help page may be drawn
		# many times in a row.
		my $now = time;
		return $live_ollama_memo->{'value'}
			if $live_ollama_memo && $live_ollama_memo->{'at'} > $now - 60;
		my $up = 0;
		eval {
			require IO::Socket::INET;
			my $sock = IO::Socket::INET->new(
				PeerHost => '127.0.0.1', PeerPort => 11434,
				Proto => 'tcp', Timeout => 0.3
			);
			if ($sock) { $up = 1; close $sock; }
		};
		my $value = $up ? 'running' : 'not running';
		$live_ollama_memo = { at => $now, value => $value };
		return $value;
	},
	models => sub {
		my @roles = qw/help_assistant eval_assistant visual_assistant
			text_to_image_assistant text_to_audio_assistant
			text_to_video_assistant coding_assistant transcription_assistant/;
		my $n = eval {
			my $s = &subs::settings_grabber({ app => 'mail', settings => [ @roles ] }) || {};
			scalar grep { defined $s->{$_} && $s->{$_} =~ /\S/ } @roles;
		};
		return defined $n ? "$n" : 'unknown';
	},
	languages => sub {
		my $n = eval {
			my $l = &language::translation_languages();
			ref $l eq 'ARRAY' ? scalar @{$l} : undef;
		};
		return defined $n ? "$n" : 'unknown';
	},
	topics => sub { return scalar keys %topic },
	crew => sub {
		my $n = eval {
			return 'unavailable' unless defined &crew::abilities;
			my $a = &crew::abilities();
			return ref $a eq 'ARRAY' ? scalar @{$a}
				: ref $a eq 'HASH' ? scalar keys %{$a}
				: 'unavailable';
		};
		return (defined $n && length $n) ? $n : 'unavailable';
	},
);

# ---- live docs: runnable examples ------------------------------------------
# A topic may carry `examples`, each in one of two fixed shapes:
#
#   { open => 'app', app => 'music' }   opens that app's window
#   { configure => 'plat' }             opens Configure on that tab
#
# The tab names below are the tab ids the Configure window itself uses, so an
# example travels the same path as a press on that tab. Nothing else is
# accepted: no URL, no shell, no path.
our %example_configure_tab = (
	me    => [ 'me_settings', 'Me' ],
	enc   => [ 'restore_list', 'Enc' ],
	system => [ 'system_setting_lister', 'Sys' ],
	misc  => [ 'misc_setting', 'Misc' ],
	plat  => [ 'plat_setting', 'Plat' ],
	app   => [ 'appointment_list_grabber', 'App' ],
	dev   => [ 'device_lister', 'Dev' ],
	tun   => [ 'tunnel_lister', 'Tun' ],
	pseud => [ 'pseudonym_setting_lister', 'Pseud' ],
	store => [ 'store_setting_lister', 'Store' ],
);

# Keyboard shortcuts, keyed by the topic they belong to. Each row is
# [ keys, action ]. They live beside the prose but in one list, so an app\'s own
# Help page and the aggregated cheat sheet are always the same words. The
# desktop keys are the 'keyboard_shortcuts' entry; every other key is an app's
# own. Keep the actions in the imperative, and name keys as they are printed on
# the keyboard (Super, Ctrl, Alt, Shift).
our %shortcuts = (
	'keyboard_shortcuts' => [
		[ 'Super+Left', 'Fit the front window to the left half of the screen' ],
		[ 'Super+Right', 'Fit the front window to the right half' ],
		[ 'Super+Up', 'Maximise the front window, or restore it if it is already maximised' ],
		[ 'Super+Down', 'Minimise the front window' ],
		[ 'Super+Q', 'Close the front window' ],
		[ 'Super+Ctrl+Left / Right / Up / Down', 'Nudge the front window a little in that direction' ],
		[ 'Super+Shift', 'Open the app switcher; keep Super held, press Left or Right to choose, then release Super' ],
		[ 'Ctrl+Alt', 'Open or close the start menu' ],
		[ 'F1', 'Open Help for the window in focus, or for the control under the pointer' ],
		[ 'Enter', 'Press the highlighted button in a dialog box' ],
		[ 'Escape', 'Cancel the dialog box, or leave the mode you are in' ]
	],
	'folders' => [
		[ 'Ctrl+A', 'Select every item in the listing' ],
		[ 'Ctrl+C', 'Copy the selection' ],
		[ 'Ctrl+X', 'Cut the selection' ],
		[ 'Ctrl+V', 'Paste into the folder on screen' ],
		[ 'Ctrl+L', 'Type a path instead of browsing to it' ],
		[ 'Alt+Left', 'Go back to the folder visited before this one' ],
		[ 'Alt+Right', 'Go forward again' ],
		[ 'Enter', 'Open the selected item' ],
		[ 'F2', 'Rename the one selected item' ],
		[ 'Delete', 'Move the selection to the Recycle Bin' ],
		[ 'Shift+Delete', 'Shred the selection for good' ],
		[ 'Arrow keys', 'Walk the listing' ],
		[ 'Shift+Arrow', 'Extend the selection from the last click' ],
		[ 'Home / End', 'Jump to the first or last item' ],
		[ 'A letter or name', 'Jump to the first item whose name starts with what you type' ],
		[ 'Escape', 'Clear the selection, or stop editing the path' ]
	],
	'gallery' => [
		[ 'Left / Right', 'Show the previous or next picture in the viewer' ],
		[ 'Escape', 'Close the viewer' ]
	],
	'marker' => [
		[ 'Ctrl+Z', 'Undo the last stroke' ],
		[ 'Ctrl+Shift+Z', 'Redo' ],
		[ 'Ctrl+Y', 'Redo' ],
		[ '+ or =', 'Zoom in' ],
		[ '- or _', 'Zoom out' ],
		[ '0', 'Fit the whole board in the window' ]
	],
	'music' => [
		[ 'Space', 'Play or pause' ],
		[ 'Left', 'Previous track' ],
		[ 'Right', 'Next track' ],
		[ 'Up', 'Next chapter' ],
		[ 'Down', 'Previous chapter' ],
		[ 'F', 'Full screen the player' ],
		[ 'Arrows on an EQ band', 'Raise or lower that band; Home returns it to flat' ]
	],
	'synth' => [
		[ "A W S E D F T G Y H U J K O L P ; '", 'Play the chromatic scale from the current octave, with Keys on' ],
		[ 'Z', 'Down an octave' ],
		[ 'X', 'Up an octave' ]
	],
	'studio' => [
		[ 'Delete / Backspace', 'Remove the selected take' ],
		[ 'S', 'Split the selected take at the playhead' ]
	],
	'terminal' => [
		[ 'Ctrl+C', 'Interrupt the running command' ],
		[ 'Ctrl+D', 'End input' ],
		[ 'Ctrl+Z', 'Suspend the foreground job' ],
		[ 'Ctrl+L', 'Clear the screen' ],
		[ 'Tab / Shift+Tab', 'Complete forward or backward' ],
		[ 'Ctrl + a letter', 'Send that letter\'s usual control code to the shell' ],
		[ 'Up / Down in the Commands box', 'Recall an earlier or later command' ],
		[ 'Function and navigation keys', 'Sent to the running program as a terminal expects' ]
	],
	'ide' => [
		[ 'Tab', 'Insert two spaces in the code editor' ]
	],
	'notes' => [
		[ 'Enter', 'Save the note on a desk; Shift+Enter makes a new line (on a phone Enter makes the new line)' ]
	],
	'chat' => [
		[ 'Enter', 'Send the message in the composer' ]
	],
	'market' => [
		[ 'Enter', 'Add the typed item, or find the typed barcode' ]
	],
	'help_app' => [
		[ 'Enter', 'Ask the Guide the question in the composer' ]
	],
	'search' => [
		[ 'Up / Down', 'Move through the results' ],
		[ 'Enter', 'Open the chosen result' ],
		[ 'Escape', 'Close the result list' ]
	]
);

# The cheat sheet's order: the desktop keys first, then the apps as a person
# would look for them. Any topic with rows but not named here follows in key
# order, so adding a new app cannot silently drop it from the sheet.
our @shortcut_order = qw(
	keyboard_shortcuts folders gallery marker music synth studio terminal ide
	notes chat market help_app search
);

# Resolve a loose topic name to a canonical key. Case is folded and spaces or
# hyphens become underscores, so callers can be forgiving about what they pass.
sub key {
	my ($id) = @_;
	return '' unless defined $id && length $id;
	$id = lc $id;
	$id =~ s/[\s\-]+/_/g;
	$id =~ s/^_+|_+$//g;
	return $id;
}

sub get {
	my ($id) = @_;
	return $topic{ help::key($id) };
}

# ---- first run ------------------------------------------------------------
# The welcome tour is shown once per install. The flag is a settings row whose
# absence means first run; it lives in __president, one of the protected
# (machine-local) apps, so it belongs to this database rather than to a
# browser's localStorage. Reading it without a device matches any row, which is
# what keeps it per install when a person uses more than one browser.
sub welcome_seen {
	my $row = eval {
		&subs::db_query(
			'select value from settings where app = ? and setting = ? order by server_time desc limit 1',
			'__president', 'welcome_tour'
		)->hashes->[0];
	};
	return (ref $row eq 'HASH' && defined $row->{'value'} && length $row->{'value'}) ? 1 : 0;
}

sub welcome_mark {
	my $value = shift;
	$value = &subs::rightNow() unless defined $value && length $value;
	eval {
		&subs::setting_setter({
			app => '__president', setting => 'welcome_tour', value => $value,
			device => &subs::device_setter()
		});
	};
	return 1;
}

# One live value, or 'unavailable' when it cannot be read. Kept private so the
# only public way into the registry is render_live below.
sub _live_value {
	my ($name) = @_;
	my $sub = $live_token{$name};
	return 'unavailable' unless $sub;
	my $value = eval { $sub->() };
	return (defined $value && length $value) ? $value : 'unavailable';
}

# Fill the live placeholders in one piece of help text and return HTML-ready
# text. The whole string is escaped first, exactly as the template used to do;
# a recognised token is then replaced with its value, which is escaped too so a
# machine name or a version can never become markup. An unknown token is left
# verbatim. The template prints the result with <%== %> precisely because the
# escaping has already happened here.
sub render_live {
	my ($text) = @_;
	return '' unless defined $text && length $text;
	my $html = xml_escape($text);
	$html =~ s{\{\{live:([a-z][a-z0-9_]*)\}\}}{
		my $name = $1;
		exists $live_token{$name} ? xml_escape(_live_value($name)) : "{{live:$name}}"
	}ge;
	return $html;
}

# Resolve one runnable example to the values the template and help.js use, or
# undef when it is not one of the two shapes above. The label is the app's own
# topic title (a proper name) or the Configure tab's printed name, so the
# template can put the existing "Open" label in front of it.
sub example {
	my ($spec) = @_;
	return undef unless ref $spec eq 'HASH';
	if (($spec->{'open'} // '') eq 'app') {
		my $app = $spec->{'app'} // '';
		return undef unless $app =~ /^[a-z][a-z0-9_]*$/;
		return { kind => 'app', value => $app, label => ($topic{$app}{'title'} || $app) };
	}
	if (defined $spec->{'configure'}) {
		my $tab = $spec->{'configure'} // '';
		return undef unless $tab =~ /^[a-z][a-z0-9_]*$/;
		my ($id, $label) = @{ $example_configure_tab{$tab} || [ $tab, $tab ] };
		return undef unless $id =~ /^[a-z][a-z0-9_]*$/;
		return { kind => 'configure', value => $id, label => 'Configure: ' . $label };
	}
	return undef;
}

# The whole catalogue as plain records, for the index and for search.
sub catalogue {
	my @out;
	foreach my $id (sort keys %topic) {
		my $t = $topic{$id};
		push @out, {
			id => $id,
			title => $t->{'title'},
			category => $t->{'category'},
			summary => $t->{'summary'},
			app => $t->{'app'}
		};
	}
	return @out;
}

# The keyboard rows belonging to one topic, as [ keys, action ] pairs.
sub shortcuts_for {
	my ($id) = @_;
	$id = help::key($id);
	return @{ $shortcuts{$id} || [] };
}

# Every topic that carries shortcuts, in the sheet's reading order, grouped for
# the cheat sheet. $skip drops one topic (the sheet calls with its own id so the
# desktop keys are not printed twice).
sub shortcut_sheet {
	my ($skip) = @_;
	$skip = help::key($skip) if defined $skip && length $skip;
	my @ids;
	my %seen;
	foreach my $id ( @shortcut_order, sort keys %shortcuts ) {
		next if $seen{$id}++;
		next unless $shortcuts{$id} && @{ $shortcuts{$id} };
		next if defined $skip && $id eq $skip;
		next unless $topic{$id};
		push @ids, $id;
	}
	return map { {
		id => $_,
		title => $topic{$_}{'title'},
		rows => $shortcuts{$_}
	} } @ids;
}

# Simple case-insensitive substring search over the title, summary, body and
# steps.
sub search {
	my ($q) = @_;
	return () unless defined $q && length $q;
	my $needle = lc $q;
	my @out;
	foreach my $id (sort keys %topic) {
		my $t = $topic{$id};
		my $hay = join ' ', ($t->{'title'} // ''), ($t->{'summary'} // ''), @{ $t->{'body'} // [] }, @{ $t->{'steps'} // [] };
		$hay .= ' ' . join ' ', map { @{$_} } @{ $shortcuts{$id} || [] };
		if (lc($hay) =~ /\Q$needle\E/) {
			push @out, { id => $id, title => $t->{'title'}, category => $t->{'category'}, summary => $t->{'summary'}, app => $t->{'app'} };
		}
	}
	return @out;
}

# The material an AI guide should read about a topic: everything the reader can
# see here, plus any steering the topic carries.
sub briefing {
	my ($id) = @_;
	my $t = help::get($id);
	return '' unless $t;
	my @lines;
	push @lines, 'Title: ' . ($t->{'title'} // '');
	push @lines, 'Summary: ' . ($t->{'summary'} // '');
	foreach my $p ( @{ $t->{'body'} // [] } ) { push @lines, $p; }
	if (@{ $t->{'steps'} // [] }) {
		push @lines, 'Steps: ' . join(' | ', @{ $t->{'steps'} });
	}
	if (@{ $shortcuts{$id} || [] }) {
		push @lines, 'Keyboard shortcuts: ' . join('; ', map { $_->[0] . ' = ' . $_->[1] } @{ $shortcuts{$id} });
	}
	push @lines, 'Steering: ' . $t->{'prompt'} if $t->{'prompt'};
	return join "\n", @lines;
}

# ---- code-aware helpers (the auditor and the guide both use these) ---------

# The files that back a topic: any it names explicitly, plus the conventional
# spots for its app. Only paths that exist are returned, so a moved file surfaces
# as a missing one the auditor can complain about when it was listed explicitly.
sub resolve_files {
	my ($id) = @_;
	my $t = help::get($id) or return ();
	my %seen;
	my @out;
	my $add = sub {
		my $p = shift;
		return unless defined $p && length $p;
		return unless -e $p;
		return if $seen{$p}++;
		push @out, $p;
	};
	# A big script is a short index plus a folder of parts; hand the guide the
	# same rules the bundle route uses, so a hint that moved into a part is
	# still an on-screen control the inventory can see.
	my $add_source = sub {
		my $p = shift;
		return unless defined $p && length $p;
		$add->($p);
		return unless $p =~ /\.js$/;
		(my $dir = $p) =~ s{\.js$}{};
		$add->($_) foreach sort grep { -f } glob("$dir/*.js");
	};
	foreach my $p ( @{ $t->{'templates'} || [] } ) { $add_source->($p); }
	my $a = $t->{'app'};
	if ($a) {
		$add_source->($_) foreach (
			"templates/apps/$a.html.ep",
			"templates/$a.html.ep",
			"public/js/manager/$a.js",
			"public/js/$a.js",
		);
	}
	return @out;
}

# The on-screen controls a topic's files declare, taken from their `hint="..."`
# literals. Interpolated hints (the ones with <, >, { or }) are skipped: only a
# fixed label is something the auditor can match a step against.
sub hints {
	my @files = @_;
	my %h;
	foreach my $f (@files) {
		next unless -e $f;
		open my $fh, '<', $f or next;
		local $/;
		my $body = <$fh>;
		close $fh;
		next unless defined $body;
		while ($body =~ /hint="([^"<>{}]+)"/g) { $h{$1} = 1; }
	}
	return sort keys %h;
}

# A machine-generated inventory of an app, handed to the guide alongside the
# hand-written entry. It is built from the code, so it stays current even when
# the prose lags - and the guide is told to prefer it when the two disagree.
sub inventory {
	my ($id) = @_;
	my $t = help::get($id) or return '';
	my @files = help::resolve_files($id);
	my @h = help::hints(@files);
	my $v = $t->{'verified'} || $verified_default;
	my @lines;
	push @lines, 'CURRENT UI (generated from the code - trust this over the prose if the two disagree):';
	push @lines, '  source files: ' . (@files ? join(', ', @files) : '(none resolved)');
	push @lines, '  on-screen controls (from the code): ' . (@h ? join(', ', @h) : '(none found)');
	push @lines, '  hand-written entry last vetted: ' . ($v || 'never') . '.';
	return join "\n", @lines;
}

# Check every topic against the tree. Returns a list of [severity, topic, message]
# where severity is one of 'error' (blocking), 'stale' (the code moved on), or
# 'warn'/'info' (advisory).
sub audit {
	my %ids = map { $_ => 1 } keys %topic;
	my @out;
	foreach my $id (sort keys %topic) {
		my $t = $topic{$id};
		foreach my $r ( @{ $t->{'related'} || [] } ) {
			push @out, [ 'error', $id, "related '$r' has no topic" ] unless $ids{ help::key($r) };
		}
		foreach my $p ( @{ $t->{'templates'} || [] } ) {
			push @out, [ 'error', $id, "listed template '$p' is missing" ] unless -e $p;
		}
		my @files = help::resolve_files($id);
		if ($t->{'app'} && !@files) {
			push @out, [ 'warn', $id, "no source files resolved for app '$t->{'app'}' - add a templates list" ];
		}
		if ($t->{'controls'}) {
			my %h = map { $_ => 1 } help::hints(@files);
			foreach my $c ( @{ $t->{'controls'} } ) {
				push @out, [ 'error', $id, "control '$c' is no longer an on-screen hint in the app" ] unless $h{$c};
			}
		}
		my $v = $t->{'verified'} || $verified_default;
		if ($v && @files) {
			open my $fh, '-|', 'git', 'log', '--oneline', "--since=$v", '--', @files or next;
			my @commits = <$fh>;
			close $fh;
			push @out, [ 'stale', $id, "source changed since it was vetted on $v (" . scalar(@commits) . ' commit(s))' ] if @commits;
		}
	}
	# app templates with no topic at all
	foreach my $f ( sort glob('templates/apps/*.html.ep') ) {
		(my $base = $f) =~ s{.*/}{};
		$base =~ s{\.html\.ep$}{};
		my $found = 0;
		foreach my $id (keys %topic) { if (($topic{$id}->{'app'} || '') eq $base) { $found = 1; last; } }
		push @out, [ 'info', '(orphan)', "templates/apps/$base.html.ep has no topic" ] unless $found;
	}
	return @out;
}

# The catalogue and rules the acting guide is given. Kept here with the rest of
# the help content so the vocabulary lives in one place.
# ---- runtime (learned) verbs ----------------------------------------------
# Beyond the built-in tools, a verb can be added at runtime: one row in the
# __president/guide_verbs setting names a closed primitive and the parameters to
# run it with. A row is data, and settings already sync across the mesh, so a
# verb added on one machine is understood by all of them. The primitives are the
# only things a learned verb can do, so a runtime verb can never reach past them.
sub learned_verbs {
	my $raw = eval { &subs::setting_grabber({ app => '__president', setting => 'guide_verbs', device => 'all' }) } || '';
	my $rows = eval { Mojo::JSON::decode_json($raw) } || [];
	$rows = [] unless ref $rows eq 'ARRAY';
	my @out;
	foreach my $v ( @{$rows} ) {
		next unless ref $v eq 'HASH';
		next unless ($v->{'name'} // '') =~ /^[a-z][a-z0-9_]{1,40}$/;
		next unless ($v->{'primitive'} // '') =~ /^(?:say|open_app|set_setting|run_command|toggle|stage|find|play_music)$/;
		push @out, $v;
	}
	return \@out;
}

# The learned verbs as prompt lines, shaped like the built-in ones.
sub learned_tool_lines {
	my $lines = '';
	foreach my $v ( @{ &learned_verbs() } ) {
		my @args = sort keys %{ $v->{'args'} || {} };
		my $ex = '{"action":"' . $v->{'name'} . '"' . join('', map { ',"' . $_ . '":"..."' } @args) . '}';
		my $gap = ' ' x (length($ex) < 46 ? (46 - length($ex)) : 2);
		$lines .= '  ' . $ex . $gap . ($v->{'desc'} // 'a learned command you may run') . "\n";
	}
	return $lines;
}

# Every verb the guide may pick: the built-in ones plus the learned ones. Used
# for the allow-list here and by the remote channel, so both understand alike.
sub live_verb_names {
	my %names = map { $_->{'name'} => 1 } grep { !$_->{'planned'} } @gb::guide_tools;
	$names{ $_->{'name'} } = 1 for @{ &learned_verbs() };
	return \%names;
}

sub actions_prompt {
	# The action lines are generated from @gb::guide_tools (see gb.pl), so a tool is
	# declared once and offered here automatically once it is live (not `planned`).
	# $only, when given, is a hashref of tool names to offer: the remote channel has
	# its own executor that runs only a few of these verbs, so it must not offer the
	# rest - a model told it could "find" when nothing can run a find simply did
	# nothing at all. $with_page offers the page verb; it is given only on a turn
	# that carries the attached window's form, so no other associate sees it.
	my ($only, $with_page) = @_;
	# The Confirmation Requirement (the Confirm tick in the Guide's associate
	# panel, stored as a setting so it is the same on every machine): off means
	# a proposed appointment is saved as it is made, so promote and discard are
	# not offered and create says it writes straight in.
	my $confirm_setting = &subs::setting_grabber({ app => '__president', setting => 'guide_confirm', device => 'all' });
	my $auto_save = (defined $confirm_setting && $confirm_setting eq 'off');
	my $header = "You are the JawnOS Guide. You can explain things, and you can operate the screen\nfor the person. Reply with EXACTLY ONE JSON object and nothing else - no prose\naround it. Choose one action:\n\n";
	my $lines = '';
	foreach my $t ( @gb::guide_tools ) {
		next if $t->{'planned'};
		next if $t->{'name'} eq 'page' && !$with_page;
		next if $only && ref $only eq 'HASH' && !$only->{ $t->{'name'} };
		next if $auto_save && ($t->{'name'} eq 'promote' || $t->{'name'} eq 'discard');
		my $desc = $t->{'desc'};
		if ($auto_save && $t->{'name'} eq 'create') {
			$desc = 'make the appointment and save it right away: the Confirmation Requirement is off, so create writes it straight in - do not ask for a yes and there is nothing to promote';
		}
		if ($auto_save && $t->{'name'} eq 'update') {
			$desc = 'change an appointment that already exists, named by "app" (add "title" when you know it). "delay" pushes it later by the length the person said; "when" moves it to a named moment instead; "duration" sets how long it lasts; "notes" replaces the note. Give only the fields that change. The Confirmation Requirement is off, so the change is saved the moment it is made - do not ask for a yes and there is nothing to promote';
		}
		my $ex = $t->{'example'} || ('{"action":"' . $t->{'name'} . '"}');
		# pad to the shared column, but never let a long example swallow the gap
		my $gap = ' ' x (length($ex) < 46 ? (46 - length($ex)) : 2);
		$lines .= '  ' . $ex . $gap . $desc . "\n";
	}
	# runtime verbs are added on every invocation: they are the person's own
	# commands (and the Coding agent's), understood on every machine
	$lines .= &learned_tool_lines();
	my $create_rule = $auto_save
		? "- To make an appointment, use create - the Confirmation Requirement is off, so it is saved the moment it is made. Do not ask the person to confirm and do not call promote; say briefly that it is saved."
		: "- To make an appointment, use create - it only stages a proposal. Tell the person what you staged and ask them to confirm; call promote only once they agree, and never say it is saved before promote returns. Use discard if they decline.";
	my $update_rule = $auto_save
		? "- To change an appointment that already exists (\"delay email test by 5 minutes\", \"make it last 10 minutes\", \"move it to tomorrow at 3pm\"), use update and name it by app. The Confirmation Requirement is off, so the change is saved the moment it is made - do not ask and do not call promote; say briefly what changed."
		: "- To change an appointment that already exists (\"delay email test by 5 minutes\", \"make it last 10 minutes\", \"move it to tomorrow at 3pm\"), use update and name it by app. It only stages the change - tell the person what will change and call promote only once they agree; call discard if they decline. Never say it is changed before promote returns.";
	my $rules = <<"TXT";
Rules:
- Navigate, search, make media and change appointments (update). Never delete, send or
  pay, and never change anything else.
- Choose only from the actions listed above; there is no other verb here.
- When the person names a photo, a record or an app to show them, use find first,
  then open what the result points at. If find returns an app, pass that exact app
  name to open_gallery - do not hand open_gallery a free-text name instead.
- The moment an OBSERVATION shows the thing they asked to see or do is now on
  screen, STOP and reply with done - for example
  {"action":"done","text":"Here are the photos."}. Do not follow a success with a
  question; the task is finished, so say so briefly and stop.
- If a search turns up nothing, say so or ask a short question - do not keep
  searching the same way.
- Read the OBSERVATION lines in the conversation to see what each action did
  before choosing the next one.
- The conversation may hold several USER lines. The earlier ones are history you
  have already handled - each is followed by the ANSWERED: note of what you said.
  Act only on the newest USER line; never answer an earlier turn again.
- For "when did I last see/do X", use find and answer from its last date - do not
  guess a date.
- To read a value they keep in their own records - a phone number, an email, an
  address or a note - use lookup with the words they named. It never returns a
  password or a credential. Use it before filling a page with that value.
$create_rule
$update_rule
- If the person says "undo that" or "put it back", use undo to reverse your last
  appointment change.
- To stop what the app has running ("stop email test", "stop it in 10 minutes",
  "stop it at 5pm"), use stop. It acts at once - say briefly what you stopped.
- To delete one of the app's appointments ("delete the email test one that's coming
  up", "delete the one from yesterday around 3:30pm", "delete the one a week from
  now"), use delete, naming it with "which" (upcoming or last) or "when". It stages
  the delete, so tell the person which one and call promote only once they agree.
- When a schedule could not be read, the question names a token. Ask what is unclear,
  then use schedule with that token and the person's clarified words (for example
  "every third Saturday of the month"). It writes the repeat appointments or bills;
  do not invent dates yourself.
- "Where was I" and "when did I last see X" are different questions. For a place
  at a time, use where_when with an absolute date. For a record or photo, use find.
- For "show me <place> on a map", use show_place - it works offline from the
  places we have measured, so an odd name is matched against the things named for it.
- For "how far did I walk" use measure with measure "walk"; for a weight goal use
  measure with measure "weight". Do not guess a number - always take it from measure.
- To translate words or a phrase, use translate with "text" and the language the
  person named in "to". To translate what is on screen, use translate_page. If they
  ask which languages are offered, use translate_languages; never invent a language
  that is not in its list.
- When a PAGE ON SCREEN block is given, you are attached to that window and may use
  page to read it and fill it. Use the exact field keys (f1, f2) and button keys (b1)
  from that block. Read what you need first (a page read, or find, lookup, measure
  and where_when for the value), then fill. Take values only from the conversation,
  the person's own records or the page itself - never invent one. Leave a password
  field alone, and never press a send, pay or delete button. After a fill, say what
  you filled and stop unless the person asked for the form to be sent.
- If the person asks you to fill in a form but no PAGE ON SCREEN block is given, say
  they can add you to that window with the small assistant button in its title bar,
  beside the question mark.
- To play or watch anything (a song, an artist, an album, a show or its
  episodes), use play_music with the person's own words; it plays every match as
  a list. Set "shuffle":1 when they ask for a shuffle or a surprise. Do not
  reach for find or open_gallery when the thing is to be watched or listened to.
- To make an image, a sound or a video, use generate with "kind" (image, audio
  or video) and a full, self-contained "prompt". Set "app" to the appointment it
  is for only when you are sure of it - if the person did not say which
  appointment, or the room holds more than one, ask which before you generate;
  with no "app" the media waits in the Camera pool to be filed. It is slow, so
  say what you are making rather than making several at once.
- Keep every text field short and in plain, everyday words.
TXT
	return $header . $lines . "\n" . $rules;
}

# The Coding agent's prompt: the JawnOS Guide's self-healing half. It reads and
# writes the repo, runs the release routine and ships - one JSON action per turn,
# from @gb::coding_tools. Kept deliberately narrow: every verb is a fixed, safe
# operation, so the model can never reach a shell it was not handed.
sub coding_prompt {
	my $header = "You are the JawnOS Coding agent. You fix and ship the JawnOS code itself.\n"
		. "The repository is at ~/jawnos; every path you give is relative to it.\n"
		. "Reply with EXACTLY ONE JSON object and nothing else - no prose around it.\n"
		. "Choose one action:\n\n";
	my $lines = '';
	foreach my $t ( @gb::coding_tools ) {
		my $ex = $t->{'example'} || ('{"action":"' . $t->{'name'} . '"}');
		my $gap = ' ' x (length($ex) < 62 ? (62 - length($ex)) : 2);
		$lines .= '  ' . $ex . $gap . $t->{'desc'} . "\n";
	}
	my $rules = <<'TXT';
Rules:
- Work in small steps: read the file you are about to change first, then write it
  whole, then run "perl -c <file>" (or a test) to check it before you commit.
- Use agent for a self-contained investigation or a scoped edit. It cannot ship:
  you still bump, commit, push and restart. Never ask a subagent to spawn
  another.
- Never commit code that failed its check. Fix it and check again.
- When you change behaviour, add or update the tests in t/ and run "prove -l t"
  before you commit. A defect you find but do not fix gets a TODO test naming the
  file and line, never a test that asserts the broken behaviour.
- The finishing routine is: bump, then commit with a short message, then push,
  then restart. Do each as its own action, in that order. Commit as the subject
  "v<version> - <summary>" once bumped.
- To give the Guide a new command without a code change, use learn: it saves a
  runtime verb to the shared setting, so the Guide and every machine pick it up
  at once.
- If you cannot find a file, or the right place for one, after three attempts,
  stop and say what you tried; never invent a path or keep guessing.
- Only ever change the files the task needs. A commit stages only the files you
  wrote, so never sweep in unrelated work that was already in the tree.
- Treat the person's data as private; never print secrets (keys, tokens).
- Write plain, everyday, factual text. Do not narrate; act.
- When the work is done and shipped, reply with done and one short sentence.
- When AGENTS.md is quoted below, follow it: it is the map of this codebase.
TXT
	return $header . $lines . "\n" . $rules;
}

# The error watch's prompt: the same Coding agent, but it cannot ship. Its write
# stages a whole file for a person to look over and apply from the IDE's fixing
# panel; bump, commit, push and restart are not offered here, and it is told so.
sub coding_propose_prompt {
	my $header = "You are the JawnOS Coding agent, watching the running system for errors.\n"
		. "A fault was caught: an error in the log, or a Guide turn that did not land. Diagnose it and propose one small, complete fix.\n"
		. "You cannot ship: \"write\" stages the whole file for a person to review and apply later;\n"
		. "it does not change the repo. Do not ask for bump, commit, push or restart - they do not exist here.\n"
		. "The repository is at ~/jawnos; every path you give is relative to it. A check command runs against\n"
		. "the tree as it is, not against your staged file, so use it to look around, not to validate a change.\n"
		. "Reply with EXACTLY ONE JSON object and nothing else - no prose around it.\n"
		. "Choose one action:\n\n";
	my $lines = '';
	my %allowed = map { $_ => 1 } qw/list read run write say done/;
	foreach my $t ( @gb::coding_tools ) {
		next unless $allowed{ $t->{'name'} };
		my $ex = $t->{'example'} || ('{"action":"' . $t->{'name'} . '"}');
		my $gap = ' ' x (length($ex) < 62 ? (62 - length($ex)) : 2);
		$lines .= '  ' . $ex . $gap . $t->{'desc'} . "\n";
	}
	my $rules = <<'TXT';
Rules:
- Read the file you are about to change first; write the whole file, not a diff.
- Diagnose from the error text and the code. Keep the fix minimal, and in the
  codebase's own style.
- If the fault is not a code fix (no disk space, a permission, a network outage,
  a missing device), write nothing: reply with say and one short sentence saying
  why.
- If you cannot find the file after three attempts, say what you tried; never
  invent a path.
- Write plain, everyday, factual text. Do not narrate; act.
- When the fix is staged, reply with done and one short sentence naming the
  file(s) and what changed.
TXT
	return $header . $lines . "\n" . $rules;
}

1;
