use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Find;
use File::Slurp qw(read_file);
use Mojo::Template;

# The big pages are composed from partials now (apps/video/{style,markup,script},
# security/{padlock,...}, terminal/{style,body}, ...), so two things must hold or
# a page dies at render time with nothing in `perl -c` to catch it:
#
#   1. every template compiles the way the renderer compiles it;
#   2. every `<%= include 'x' %>` names a template that exists.
#
# A missing partial is a 500 on that page alone, which is exactly the kind of
# break a full-suite pass would otherwise miss.

my $root = "$FindBin::Bin/..";
my @templates;
find(sub { push @templates, $File::Find::name if -f && /\.ep$/ }, "$root/templates");
@templates = sort @templates;
cmp_ok(scalar @templates, '>', 200, 'found the template tree');

my (@parse_bad, @include_bad);
for my $file (@templates) {
	(my $rel = $file) =~ s{^\Q$root/templates/\E}{};
	my $src = read_file($file);
	$src = '' unless defined $src;

	my $ok = eval { Mojo::Template->new(vars => 1)->name($rel)->parse($src); 1 };
	push @parse_bad, "$rel: " . substr($@, 0, 200) unless $ok;

	# `include 'apps/transaction/' . $x` builds the name at render time; only a
	# literal, whole name can be checked here.
	while ($src =~ /<%=?\s*include\s+(['"])([^'"]+)\1(\s*\.)?/g) {
		my ($inc, $concat) = ($2, $3);
		next if $concat || $inc =~ m{/$};
		my $path = "$root/templates/$inc.html.ep";
		push @include_bad, "$rel includes '$inc' (no $inc.html.ep)" unless -f $path;
	}
}

is(scalar @parse_bad, 0, 'every template parses')
	or diag(join "\n", @parse_bad[0 .. ($#parse_bad > 9 ? 9 : $#parse_bad)]);
is(scalar @include_bad, 0, 'every include names a template that exists')
	or diag(join "\n", @include_bad[0 .. ($#include_bad > 9 ? 9 : $#include_bad)]);

done_testing();
