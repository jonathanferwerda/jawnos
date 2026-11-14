# tests-for: templates/
# covers:    every Mojo template in templates/ compiles. Reading a template as
#            text (t/168) cannot catch an if/elsif split across separate <% %>
#            tags: that is valid text and invalid Perl once the renderer
#            compiles it. On 2026-11-14 exactly that broke the manager layout
#            on every peer ("syntax error ... near \"; elsif\"") and the
#            page fell back to the denial image.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Find qw(find);
use Encode qw(decode);
use Mojo::Template;
use Mojolicious;
use RepoSource qw(repo_root);

my $root = repo_root();
my @files;
find({ no_chdir => 1, wanted => sub {
	push @files, $File::Find::name
		if -f $File::Find::name && $File::Find::name =~ /\.ep\z/;
} }, "$root/templates");
@files = sort @files;
ok(scalar(@files) > 250,
	'the template tree was read (' . scalar(@files) . ' files)');

# The renderer installs this in the template namespace before it compiles the
# generated Perl; a syntax check needs the same bareword to parse.
my $mt = Mojo::Template->new;
my $ns = $mt->namespace;
{
	no warnings 'redefine';
	no strict 'refs';
	*{"${ns}::_escape"} = sub { $_[0] };
	# EPRenderer installs every registered helper as a sub before compiling;
	# the stock set is enough for the templates' include/title/layout calls.
	my $app = Mojolicious->new;
	for my $name (grep { /^\w+$/ } keys %{ $app->renderer->helpers }) {
		*{"${ns}::$name"} = sub { '' };
	}
}

my @bad;
for my $file (@files) {
	local $/;
	open(my $fh, '<', $file) or die "$file: $!";
	my $src = decode('UTF-8', <$fh>);
	close $fh;

	my $error = '';
	# parse() splits the template; _compile() turns it into Perl and _wrap()
	# wraps it in the sub the renderer would eval. The stash is empty here, so
	# strict vars/subs is relaxed for the syntax check; a syntax error still
	# fails, which is what this test is for.
	my $ok = eval {
		my $t = Mojo::Template->new->parse($src);
		my $code = $t->_wrap($t->_compile->code, {});
		$code =~ s/use Mojo::Base -strict;/use Mojo::Base; no strict;/;
		eval $code;
		$error = $@;
		1;
	};
	$error ||= $@;
	(my $rel = $file) =~ s{^\Q$root\E/}{};
	push @bad, "$rel: $error" if !$ok || length $error;
}

is(scalar @bad, 0, 'every template compiles')
	or diag join("\n", @bad);

done_testing();
