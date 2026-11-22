package subs;

# Held notices inside one away period: what arrived while the person was gone
# and was not urgent enough to speak. vacation_status() counts these; the Away
# card's fuller review lists them. The list is the complement of the keep list in
# the vacation policy, read from the same setting the notice gate reads, so a
# notice the gate held is exactly a notice this module returns.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

# The review is bounded: a long trip can collect thousands of notices, and the
# card is a glance, not an inbox. The count reported is the number listed.
our $VACATION_NOTICE_LIMIT = 100;
our @VACATION_NOTICE_KEEP = qw(security customs phone access gate box_office);

# Private helpers are file-scoped coderefs, not named subs: every named sub in
# this folder is checked against the Loader map (t/91), and only the two public
# names belong in it.
my $_notice_number = sub ($v) {
	return undef unless defined $v && $v =~ /^\s*\d+(?:\.\d+)?\s*$/;
	return 0 + $v;
};

# The keep list is whatever the policy says. A missing or malformed setting
# reads as the house defaults, never as an error: the card must render.
my $_notice_keep = sub {
	my $settings = eval { &vacation_settings() };
	$settings = {} unless ref $settings eq 'HASH';
	my $policy = $settings->{'policy'};
	$policy = {} unless ref $policy eq 'HASH';
	my $keep_apps = $policy->{'keep_apps'};
	$keep_apps = {} unless ref $keep_apps eq 'HASH';
	my $keep = $keep_apps->{'notifications'};
	return { map { $_ => 1 } @VACATION_NOTICE_KEEP } unless ref $keep eq 'ARRAY';
	return { map { $_ => 1 } grep { defined $_ && length $_ } @{$keep} };
};

# The notices that were held between $from and $to (half-open: $to is not
# included, the same boundary vacation_status() uses). A missing table reads as
# no notices rather than a broken card.
#
# %opt: limit => N (capped at $VACATION_NOTICE_LIMIT)
sub vacation_held_notices($from, $to, %opt) {
	my $start = $_notice_number->($from);
	my $end   = $_notice_number->($to);
	return { count => 0, notices => [] }
		unless defined $start && defined $end && $end > $start;

	my $limit = $_notice_number->($opt{'limit'});
	$limit = $VACATION_NOTICE_LIMIT unless defined $limit && $limit > 0;
	$limit = int($limit);
	$limit = $VACATION_NOTICE_LIMIT if $limit > $VACATION_NOTICE_LIMIT;

	my $keep = $_notice_keep->();

	# $limit is already an integer we made, so it is safe to interpolate; the
	# two boundaries stay bound parameters.
	my $rows = eval {
		&db_query(
			'select uuid, app, title, message, timestamp from notifications'
			. ' where cast(timestamp as integer) >= cast(? as integer)'
			. ' and cast(timestamp as integer) < cast(? as integer)'
			. " order by cast(timestamp as integer) desc limit $limit",
			$start, $end
		)->hashes;
	} || [];
	# ->hashes is a Mojo::Collection on this stack and an arrayref on older
	# ones; @{} works over both, so iterate without a ref test.

	my @notices;
	foreach my $row (@{$rows}) {
		next unless ref $row eq 'HASH';
		my $app = defined $row->{'app'} ? $row->{'app'} : '';
		# An empty app is house news, not an app's non-urgent notice, so keep it.
		next if length $app && $keep->{$app};
		push @notices, {
			uuid      => (defined $row->{'uuid'}      ? $row->{'uuid'}      : ''),
			app       => $app,
			title     => (defined $row->{'title'}     ? $row->{'title'}     : ''),
			message   => (defined $row->{'message'}   ? $row->{'message'}   : ''),
			timestamp => (defined $row->{'timestamp'} ? $row->{'timestamp'} : ''),
		};
	}

	return { count => scalar @notices, notices => \@notices };
}

# Convenience for a caller that only wants the number, same boundary rules.
sub vacation_notice_count($from, $to) {
	my $held = &vacation_held_notices($from, $to);
	return $held->{'count'} || 0;
}

1;
