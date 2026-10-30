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
require "$root/help.pl";

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

done_testing();
