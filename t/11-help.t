# tests-for: perl/help.pl templates/apps/
# covers:    The help registry (help.pl).

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# The help registry (help.pl). The in-app Guide, the help index and the auditor
# all trust this data, so its internal links and its file references must hold.

my $root = JawnOSTest::root();
require "$root/perl/help.pl";

my %topic = %help::topic;
cmp_ok(scalar(keys %topic), '>', 50, 'the registry has topics');

my %allowed = map { $_ => 1 } qw(apps features functions devices);

my @problems;
for my $id (sort keys %topic) {
	my $topic = $topic{$id};
	my $label = "topic '$id'";

	push @problems, "$label has no title"
		unless defined $topic->{title} && length $topic->{title};
	push @problems, "$label has no summary"
		unless defined $topic->{summary} && length $topic->{summary};
	push @problems, "$label has category '" . ($topic->{category} // '') . "'"
		unless $allowed{$topic->{category} || ''};
	push @problems, "$label body is not a paragraph list"
		unless ref $topic->{body} eq 'ARRAY';

	for my $related (@{ $topic->{related} || [] }) {
		push @problems, "$label links to unknown topic '$related'"
			unless $topic{$related};
	}
	for my $file (@{ $topic->{templates} || [] }) {
		push @problems, "$label names missing file '$file'"
			unless -e "$root/$file";
	}

	# Resolution is what the Guide and the index call; every key must resolve.
	my $got = eval { help::get($id) };
	push @problems, "$label does not resolve through help::get"
		unless ref $got eq 'HASH' && defined $got->{title};
}

is_deeply(\@problems, [], 'the help registry is internally consistent')
	or diag(join("\n", @problems));

# A topic is matched case-insensitively and tolerates spaces or hyphens where
# the key has underscores.
my $topic = help::get('start menu');
ok(ref $topic eq 'HASH', 'a topic resolves from a spaced name');
is($topic->{title}, 'The start menu', 'the resolved topic is the start menu');
is(help::get('start-menu')->{title}, $topic->{title}, 'a hyphenated name resolves the same');
is(help::get('Start_Menu')->{title}, $topic->{title}, 'case and underscores resolve the same');
ok(!defined help::get('definitely-not-a-topic'), 'an unknown topic does not resolve');

# --- every app page is explained, or a named gap -----------------------------
# help::audit() reports an app page with no topic as INFO, and the push runs the
# audit without --all, so an orphan page is invisible: it is neither an error nor
# in anybody's to-do list. This names the gaps instead, so a new app cannot
# arrive without either a topic carrying `app => <name>` or a deliberate entry
# below. A page resolves when some topic's app field matches it; a topic that
# lists the page in templates but not in its app field does not count, because
# the Open button and the file resolution both key off the app.
my %known_gap = map { $_ => 1 } qw(
	account coding_chat project
	app_details app_file app_measure_details app_measures app_transaction
	appointment_header appointment_stats budget_current_information edit_app evaluation_controls
	evaluation_report gallery_album gallery_home ide_files information
	inventory_info people_person
);
# account and project have no route that renders them (nothing includes or
# redirects to either page), so there is nothing to explain yet. coding_chat is
# a chatbox other apps mount, named by the `ide` topic's templates list. The rest
# are fragments of an app's page, explained by that app's topic.

my @orphans;
for my $file (sort glob("$root/templates/apps/*.html.ep")) {
	(my $base = $file) =~ s{.*/}{};
	$base =~ s{\.html\.ep$}{};
	next if grep { ($topic{$_}->{'app'} || '') eq $base } keys %topic;
	push @orphans, $base;
}

my @new_gaps = grep { !$known_gap{$_} } @orphans;
is_deeply(\@new_gaps, [], 'no app page is without a help topic unless it is a known gap')
	or diag('write a topic with app => <name>, or add to %known_gap with a reason: '
		. join(', ', @new_gaps));

my %is_orphan = map { $_ => 1 } @orphans;
my @closed = grep { !$is_orphan{$_} } sort keys %known_gap;
note(scalar(@closed) . ' known gap(s) now have a topic - prune %known_gap: ' . join(', ', @closed))
	if @closed;

done_testing();
