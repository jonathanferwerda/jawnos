package subs;

# Notes: the category a note is filed under. Kept here rather than in the route
# so the controller, the template and the tests all ask the same question - what
# category does this row read as - instead of each carrying its own list.
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Mojo::JSON qw(decode_json encode_json);

# The six the app ships with, in chip order. They are not a hardcoded list any
# more: the house's categories live in one setting, and this is what a house that
# has never edited them reads. JawnOS is the queue the nightly agent reads.
# Uncategorized is not a seventh category - it is what a note with no category
# reads as, and what a new note is filed under until someone chooses one.
our @NOTES_DEFAULT_CATEGORY_CODES = qw(journal roadmap social shopping dreams jawnos);

# The category list is a setting, so the house sync carries it to every machine
# (the merge stores a peer's row under the local device class, which is how a
# normal setting travels). The value is a JSON array of { code, label? }; a
# built-in whose label is not overridden keeps its translated core label, and a
# custom category carries its literal label. The memo is short because a peer can
# change the list through sync at any moment; it keeps a list render from asking
# the settings table once per row.
our $NOTES_CATEGORY_SETTING     = 'notes_categories';
our $NOTES_CATEGORY_SETTING_APP = 'notes';
our $NOTES_CATEGORY_SETTING_TTL = 5;
my $notes_categories_memo;

# The two states a note the Coding agent works from can be in. A new note is
# open; the agent marks it completed when the work behind it is done. Completed
# notes stay in the list wearing the mark - they are done, not hidden.
our @NOTES_STATUS_CODES = qw(open completed);

# A deleted note keeps its row so a peer that still holds it learns it is gone.
# The marker is the project's delete word (`deleting`, the state an appointment
# wears while its tombstone is written) stored in `ost`, which is otherwise the
# row's original stamp: a peer's merge copies the whole row, so the marked row
# outranks the stale copy by its newer server_time and the read path hides it
# everywhere.
our $NOTES_DELETE_MARKER = 'deleting';

sub notes_categories_default {
	return [ map { { code => $_ } } @NOTES_DEFAULT_CATEGORY_CODES ];
}

# The configured list, normalized. A missing or unreadable setting is the shipped
# six; a setting that parses to an empty array is the person having removed every
# category, and must not be read as "the setting is missing".
sub notes_categories_config {
	my $now = time;
	if ( $notes_categories_memo && $notes_categories_memo->{'at'} > $now - $NOTES_CATEGORY_SETTING_TTL ) {
		return $notes_categories_memo->{'list'};
	}
	# A probe/test holder may not carry the settings table at all. Catch that and
	# any transient read error here: the shipped six stand in for one short memo
	# window rather than dying inside a list render.
	my $raw = eval { &subs::setting_grabber({ app => $NOTES_CATEGORY_SETTING_APP, setting => $NOTES_CATEGORY_SETTING }) };
	my $list;
	if ( defined $raw && length $raw ) {
		my $parsed = eval { decode_json($raw) };
		if ( ref $parsed eq 'ARRAY' ) {
			$list = [];
			my %seen;
			foreach my $entry ( @{$parsed} ) {
				last if @{$list} >= 40;
				next unless ref $entry eq 'HASH';
				my $code = $entry->{'code'} // '';
				next unless $code =~ /^[a-z0-9_]{1,32}$/;
				next if $code eq 'uncategorized' || $seen{$code}++;
				my $label = $entry->{'label'} // '';
				$label =~ s/[[:cntrl:]]//g;
				$label =~ s/^\s+|\s+$//g;
				$label = substr( $label, 0, 40 ) if length($label) > 40;
				push @{$list}, length $label ? { code => $code, label => $label } : { code => $code };
			}
		}
	}
	$list = &notes_categories_default() unless defined $list;
	$notes_categories_memo = { at => $now, list => $list };
	return $list;
}

sub notes_categories_forget {
	undef $notes_categories_memo;
	return 1;
}

# The translated core label for one of the shipped six, or '' for a custom
# category. This is what tells a caller whether a label is a translation key or
# a literal the person typed.
sub notes_category_builtin_default ($code) {
	return '' unless defined $code && length $code;
	foreach my $builtin ( @NOTES_DEFAULT_CATEGORY_CODES ) {
		return &subs::lang("notes.category.$code") if $code eq $builtin;
	}
	return '';
}

# Save the whole list. The caller sends what the screen shows: rows it kept carry
# their code, rows it added carry no code. A kept code must still be in the list
# (a peer may have removed it), and a new row gets a fresh opaque code so a later
# rename cannot orphan its notes. Deleting a category needs no note rewrite: a
# stored code that is no longer configured reads as Uncategorized.
sub notes_categories_store ($entries) {
	return ( 0, &subs::ui('The category list could not be read.') ) unless ref $entries eq 'ARRAY';
	# Validate against the list the database holds, not a memo another worker may
	# have written a moment before this save. A stale memo would refuse a category
	# that was just added, or re-add one that was just removed.
	&notes_categories_forget();
	my $current = &notes_categories_config();
	my %current = map { $_->{'code'} => 1 } @{$current};
	my ( @out, %seen_code, %seen_label );
	my $uncategorized = lc &subs::lang('notes.category.uncategorized');
	foreach my $entry ( @{$entries} ) {
		last if @out >= 40;
		next unless ref $entry eq 'HASH';
		my $code = $entry->{'code'} // '';
		# A non-empty code names a row the screen believes exists. A code that is
		# malformed or no longer configured is a stale screen, not a new category:
		# treating it as new would silently fork a renamed or removed one.
		if ( length $code && $code !~ /^[a-z0-9_]{1,32}$/ ) {
			return ( 0, &subs::ui('That category is no longer there. Reopen the list and try again.') );
		}
		my $label = defined $entry->{'label'} ? $entry->{'label'} : '';
		$label =~ s/[[:cntrl:]]//g;
		$label =~ s/^\s+|\s+$//g;
		$label = substr( $label, 0, 40 );
		if ( length $code ) {
			return ( 0, &subs::ui('That category is no longer there. Reopen the list and try again.') )
				unless $current{$code};
			return ( 0, &subs::ui('That category is listed twice.') ) if $seen_code{$code}++;
		}
		else {
			return ( 0, &subs::ui('Give the new category a name.') ) unless length $label;
			my $fresh = 'c' . lc &subs::random_string_creator(8);
			$fresh = 'c' . lc &subs::random_string_creator(8) while $current{$fresh} || $seen_code{$fresh};
			$code = $fresh;
		}
		my $default = &notes_category_builtin_default($code);
		if ( !length $label ) {
			return ( 0, &subs::ui('Give the category a name.') ) unless length $default;
			push @out, { code => $code };
		}
		elsif ( length $default && $label eq $default ) {
			push @out, { code => $code };
		}
		else {
			push @out, { code => $code, label => $label };
		}
		my $effective = length $label ? $label : $default;
		my $key = lc $effective;
		return ( 0, &subs::ui('Two categories cannot share a name.') ) if $seen_label{$key}++;
		return ( 0, &subs::ui('That name belongs to Uncategorized.') ) if $key eq $uncategorized;
		$seen_code{$code} = 1;
	}
	my $written = eval {
		&subs::setting_setter({
			app     => $NOTES_CATEGORY_SETTING_APP,
			setting => $NOTES_CATEGORY_SETTING,
			value   => encode_json(\@out),
		});
		1;
	};
	unless ($written) {
		return ( 0, &subs::ui('The category list could not be saved.') );
	}
	&notes_categories_forget();
	return ( 1, '' );
}

sub notes_category_keys { return map { $_->{'code'} } @{ &notes_categories_config() }; }
sub notes_category_filter_keys { return ( 'uncategorized', &notes_category_keys() ); }

sub notes_category_default { return 'uncategorized'; }

sub notes_status_keys { return @NOTES_STATUS_CODES; }
sub notes_status_default { return 'open'; }
sub notes_delete_marker { return $NOTES_DELETE_MARKER; }

# A row stores a code, never a label. The labels are either a translated core
# string (the shipped six) or a literal the person typed (a custom category), and
# the code stays put across a rename, so the notes never have to be rewritten.
# Anything not in the configured list (or Uncategorized) is refused, not guessed
# at; a note still pointing at a deleted category reads as Uncategorized.
sub notes_category_valid ($category) {
	$category = '' unless defined $category;
	$category = lc $category;
	$category =~ s/^\s+|\s+$//g;
	foreach my $code ( &notes_category_filter_keys() ) {
		return $code if $category eq $code;
	}
	return '';
}

# A row stores a code, never a label; the same rule as a category.
sub notes_status_valid ($status) {
	$status = '' unless defined $status;
	$status = lc $status;
	$status =~ s/^\s+|\s+$//g;
	foreach my $code ( @NOTES_STATUS_CODES ) {
		return $code if $status eq $code;
	}
	return '';
}

# What a row reads as. A row written before the column existed has no status,
# and an open note is the honest reading of that.
sub notes_status_effective ($status) {
	my $valid = &notes_status_valid($status);
	return length $valid ? $valid : &notes_status_default();
}

# What a row reads as. A draft - the half-typed Notes field of an appointment,
# stored in this same table under that appointment's app name (app_draft) - is
# not a note the person filed, so it belongs to no category. A note with no
# category of its own is uncategorized; the old journal backfill still shows in
# the rows it stamped, but nothing new is silently called a journal note.
sub notes_category_effective ($category, $app) {
	my $valid = &notes_category_valid($category);
	return $valid if length $valid;
	$app = '' unless defined $app;
	return '' if length $app && $app ne 'notes';
	return &notes_category_default();
}

sub notes_category_label_key ($category) {
	my $code = &notes_category_valid($category);
	return '' unless length $code;
	return 'notes.category.uncategorized' if $code eq 'uncategorized';
	return length( &notes_category_builtin_default($code) ) ? 'notes.category.' . $code : '';
}

# The label a category wears on screen: the translated core string for a shipped
# category whose name was left alone, the literal override when it was renamed,
# or the custom category's own words.
sub notes_category_label ($category) {
	my $code = &notes_category_valid($category);
	return '' unless length $code;
	return &subs::lang('notes.category.uncategorized') if $code eq 'uncategorized';
	foreach my $entry ( @{ &notes_categories_config() } ) {
		next unless $entry->{'code'} eq $code;
		my $override = $entry->{'label'} // '';
		return $override if length $override;
		my $default = &notes_category_builtin_default($code);
		return length $default ? $default : $code;
	}
	return $code;
}

sub notes_status_label_key ($status) {
	my $code = &notes_status_valid($status);
	return length $code ? 'notes.status.' . $code : '';
}

sub notes_status_list {
	return [ map { { code => $_, label => &subs::lang( &notes_status_label_key($_) ) } } @NOTES_STATUS_CODES ];
}

# The app a category hands off to. Journal and JawnOS stay in Notes: the first
# is written here, the second is the queue the nightly agent reads.
sub notes_category_target ($category) {
	my %target = ( roadmap => 'store', shopping => 'market', social => 'people', dreams => 'handbook' );
	return $target{ &notes_category_valid($category) } || '';
}

# The chips, in order, with their resolved label, the label the shipped six
# would keep if left untouched (so the editor can send "no override"), and the
# translated label of the link that hands off to another app.
sub notes_category_list {
	my @list;
	my $uncategorized = &subs::lang('notes.category.uncategorized');
	push @list, {
		code          => 'uncategorized',
		label         => $uncategorized,
		target        => '',
		open_label    => '',
		default_label => $uncategorized,
		custom        => 0,
	};
	foreach my $entry ( @{ &notes_categories_config() } ) {
		my $code = $entry->{'code'};
		my $target = &notes_category_target($code);
		my $default = &notes_category_builtin_default($code);
		push @list, {
			code          => $code,
			label         => &notes_category_label($code),
			target        => $target,
			open_label    => $target ? &subs::lang("notes.open.$target") : '',
			default_label => $default,
			custom        => length($default) ? 0 : 1,
		};
	}
	return \@list;
}

# Every note row the app shows, newest first, with the category filled in the way
# the template reads it. The limit and order are the app's own, so a house with a
# long history opens as quickly as before.
sub notes_category_rows {
	my $rows = &subs::db_query(
		"select text, timestamp, server_time, uuid, app, category, status, ost from notes where coalesce(text, '') != '' and coalesce(ost, '') != ? order by timestamp desc limit 300",
		$NOTES_DELETE_MARKER
	)->hashes;
	foreach my $row ( @{$rows} ) {
		$row->{'category'} = &notes_category_effective( $row->{'category'}, $row->{'app'} );
		$row->{'status'}   = &notes_status_effective( $row->{'status'} );
	}
	return $rows;
}

# A tombstoned row is still the row (a peer must see it), but the app never
# shows it again.
sub notes_tombstoned ($ost) {
	return (defined $ost && $ost eq $NOTES_DELETE_MARKER) ? 1 : 0;
}

# Deleting a note marks its row rather than removing it: ost becomes the project
# delete marker (`deleting`) and server_time moves to now, so the row outranks a
# stale peer's copy and rides the generic sync with the deletion. A repeat delete
# is a no-op.
sub notes_tombstone ($uuid) {
	return 0 unless defined $uuid && length $uuid;
	my $row = &subs::db_select('notes', ['uuid', 'ost'], { uuid => $uuid })->hash;
	return 0 unless $row && $row->{'uuid'};
	return 1 if &notes_tombstoned($row->{'ost'});
	&subs::db_update('notes', {
		ost         => $NOTES_DELETE_MARKER,
		server_time => &subs::rightNow(),
	}, { uuid => $uuid });
	return 1;
}

# The number beside each chip, over the same rows the list shows. The total is
# the All chip; a draft counts toward the total and toward no category.
sub notes_category_counts ($rows) {
	my %count = map { $_ => 0 } &notes_category_filter_keys();
	my $total = 0;
	foreach my $row ( @{ $rows || [] } ) {
		$total++;
		my $code = &notes_category_effective( $row->{'category'}, $row->{'app'} );
		$count{$code}++ if length $code;
	}
	return ( \%count, $total );
}

# The line a note shows in the list. A note is what the person wrote; the list
# shows a heading, so a long note does not fill the window and push the next one
# out of sight. This is the honest cut: one line, whole words, and no model
# needed. The Guide replaces it with a real heading when a model is configured;
# this is what the list reads when there is none (or the model cannot answer).
sub notes_header_fallback ($text) {
	$text = '' unless defined $text;
	# A heading is one line: every run of whitespace, a newline included, is one
	# space, and the cut lands on a word boundary.
	$text =~ s/\s+/ /g;
	$text =~ s/^ | $//g;
	return '' unless length $text;
	my $max_chars = 60;
	my $max_words = 12;
	my @words = split / /, $text;
	return $text if @words <= $max_words && length($text) <= $max_chars;
	my @kept;
	my $chars = 0;
	foreach my $word ( @words ) {
		last if @kept >= $max_words;
		my $add = @kept ? 1 + length($word) : length($word);
		last if $chars + $add > $max_chars;
		push @kept, $word;
		$chars += $add;
	}
	# One word longer than the line is cut rather than dropped.
	@kept = ( substr( $words[0], 0, $max_chars ) ) unless @kept;
	return join ' ', @kept;
}

# A model's answer is a sentence far more often than it is a heading. Take the
# first non-empty line, drop the markup, quotes and trailing full stop a model
# likes to add, then cut it to the same one-line budget as the fallback, so the
# list can never be pushed aside by a chatty answer.
sub notes_header_clean ($text) {
	$text = '' unless defined $text;
	my ($line) = grep { /\S/ } split /\r\n?|\n/, $text;
	$line = '' unless defined $line;
	$line =~ s/^\s+|\s+$//g;
	$line =~ s/^(?:\#{1,6}\s*|[-*+>\s]+)//;
	$line =~ s/^(?:header|heading|title)\s*[:\-]\s*//i;
	$line =~ s/[*_`]//g;
	$line =~ s/<[^>]*>//g;
	$line =~ s/^[\x{201C}\x{201D}\x{2018}\x{2019}"']+//;
	$line =~ s/[\x{201C}\x{201D}\x{2018}\x{2019}"']+$//;
	$line =~ s/\.+$//;
	return &notes_header_fallback($line);
}

1;
