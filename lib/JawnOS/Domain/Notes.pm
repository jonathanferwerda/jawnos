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

# The six the house asked for, in chip order. Journal is the default because a
# note with no other home is a day's thought; JawnOS is the queue the nightly
# agent reads.
our @NOTES_CATEGORY_CODES = qw(journal roadmap social shopping dreams jawnos);

sub notes_category_keys { return @NOTES_CATEGORY_CODES; }

sub notes_category_default { return 'journal'; }

# A row stores a code, never a label: the labels are core interface strings the
# template renders with subs::lang, so they translate without rewriting rows.
# Anything that is not one of the six is refused, not guessed at.
sub notes_category_valid ($category) {
	$category = '' unless defined $category;
	$category = lc $category;
	$category =~ s/^\s+|\s+$//g;
	foreach my $code ( @NOTES_CATEGORY_CODES ) {
		return $code if $category eq $code;
	}
	return '';
}

# What a row reads as. A draft - the half-typed Notes field of an appointment,
# stored in this same table under that appointment's app name (app_draft) - is
# not a note the person filed, so it belongs to no category. A note typed before
# categories existed, with no app of its own, is a journal note.
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
	foreach my $code ( @NOTES_CATEGORY_CODES ) {
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
		"select text, timestamp, uuid, app, category from notes where coalesce(text, '') != '' order by timestamp desc limit 300"
	)->hashes;
	foreach my $row ( @{$rows} ) {
		$row->{'category'} = &notes_category_effective( $row->{'category'}, $row->{'app'} );
	}
	return $rows;
}

# The number beside each chip, over the same rows the list shows. The total is
# the All chip; a draft counts toward the total and toward no category.
sub notes_category_counts ($rows) {
	my %count = map { $_ => 0 } @NOTES_CATEGORY_CODES;
	my $total = 0;
	foreach my $row ( @{ $rows || [] } ) {
		$total++;
		my $code = &notes_category_effective( $row->{'category'}, $row->{'app'} );
		$count{$code}++ if length $code;
	}
	return ( \%count, $total );
}

1;
