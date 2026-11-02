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

# The six the house asked for, in chip order. JawnOS is the queue the nightly
# agent reads. Uncategorized is not a seventh category - it is what a note with
# no category reads as, and it is what a new note is filed under until the
# person (or the Guide) chooses one.
our @NOTES_CATEGORY_CODES = qw(journal roadmap social shopping dreams jawnos);
our @NOTES_FILTER_CODES  = ('uncategorized', @NOTES_CATEGORY_CODES);

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

sub notes_category_keys { return @NOTES_CATEGORY_CODES; }
sub notes_category_filter_keys { return @NOTES_FILTER_CODES; }

sub notes_category_default { return 'uncategorized'; }

sub notes_status_keys { return @NOTES_STATUS_CODES; }
sub notes_status_default { return 'open'; }
sub notes_delete_marker { return $NOTES_DELETE_MARKER; }

# A row stores a code, never a label: the labels are core interface strings the
# template renders with subs::lang, so they translate without rewriting rows.
# Anything that is not one of the six (or Uncategorized) is refused, not guessed
# at.
sub notes_category_valid ($category) {
	$category = '' unless defined $category;
	$category = lc $category;
	$category =~ s/^\s+|\s+$//g;
	foreach my $code ( @NOTES_FILTER_CODES ) {
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
	return length $code ? 'notes.category.' . $code : '';
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

# The chips, in order, with their translated label and the translated label of
# the link that hands off to another app.
sub notes_category_list {
	my @list;
	foreach my $code ( @NOTES_FILTER_CODES ) {
		my $target = &notes_category_target($code);
		push @list, {
			code       => $code,
			label      => &subs::lang( &notes_category_label_key($code) ),
			target     => $target,
			open_label => $target ? &subs::lang("notes.open.$target") : '',
		};
	}
	return \@list;
}

# Every note row the app shows, newest first, with the category filled in the way
# the template reads it. The limit and order are the app's own, so a house with a
# long history opens as quickly as before.
sub notes_category_rows {
	my $rows = &subs::db_query(
		"select text, timestamp, uuid, app, category, status, ost from notes where coalesce(text, '') != '' and coalesce(ost, '') != ? order by timestamp desc limit 300",
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
	my %count = map { $_ => 0 } @NOTES_FILTER_CODES;
	my $total = 0;
	foreach my $row ( @{ $rows || [] } ) {
		$total++;
		my $code = &notes_category_effective( $row->{'category'}, $row->{'app'} );
		$count{$code}++ if length $code;
	}
	return ( \%count, $total );
}

1;
