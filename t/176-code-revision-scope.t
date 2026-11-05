# tests-for: lib/JawnOS/Domain/Generate.pm
# covers:    the code revision hashes only the code this process runs. A file
#            under .worktrees/ (an agent's second copy of the tree), .pio/build
#            or a staged release must not move the fingerprint that a connected
#            tab follows - otherwise every worktree edit re-rendered the live
#            UI and every fresh websocket worker read it all.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path getcwd);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my $root = abs_path("$FindBin::Bin/..");
require "$root/lib/JawnOS/Domain/Generate.pm";

# code_revision asks another domain part for the signatorial; this test loads
# one module and nothing else, so give it the one answer it needs.
{
	no warnings 'redefine';
	*subs::signatorial_designer = sub { 'test-signatorial' } unless defined &subs::signatorial_designer;
}

sub put {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} $text;
	close $fh;
}

sub revision_in {
	my ($dir) = @_;
	my $was = getcwd();
	chdir $dir or die "chdir $dir: $!";
	$subs::code_revision_cache = undef;
	my $rev = eval { subs::code_revision() };
	my $err = $@;
	chdir $was;
	die $err if $err;
	return $rev;
}

my $dir = tempdir(CLEANUP => 1);
make_path(
	"$dir/lib",
	"$dir/public/js",
	"$dir/.worktrees/agent-one/public/js",
	"$dir/.pio/build",
	"$dir/releases",
	"$dir/jawnos-test-abc123/public/js",
);
put("$dir/lib/thing.pm", "package thing; 1;\n");
put("$dir/public/js/app.js", "var app = 1;\n");
put("$dir/.worktrees/agent-one/public/js/app.js", "var app = 1;\n");
put("$dir/.pio/build/firmware.js", "var fw = 1;\n");
put("$dir/releases/staged.js", "var r = 1;\n");
put("$dir/jawnos-test-abc123/public/js/app.js", "var t = 1;\n");

my $before = revision_in($dir);
is(scalar(keys %{ $before->{'parts'} }), 5, 'the revision still reports its five parts');
ok($before->{'fingerprint'}, 'and has a fingerprint');

put("$dir/.worktrees/agent-one/public/js/app.js", "var app = 'changed in a worktree';\n");
put("$dir/.pio/build/firmware.js", "var fw = 2;\n");
put("$dir/releases/staged.js", "var r = 2;\n");
put("$dir/jawnos-test-abc123/public/js/app.js", "var t = 2;\n");
my $after_worktree = revision_in($dir);
is($after_worktree->{'fingerprint'}, $before->{'fingerprint'},
	'a worktree, build, release or test-sandbox edit does not move the fingerprint');
is($after_worktree->{'parts'}{'js'}, $before->{'parts'}{'js'},
	'and the js part the tab follows stays put');

put("$dir/public/js/app.js", "var app = 'the running tree changed';\n");
my $after_source = revision_in($dir);
isnt($after_source->{'fingerprint'}, $after_worktree->{'fingerprint'},
	'a real source edit still moves the fingerprint');
isnt($after_source->{'parts'}{'js'}, $after_worktree->{'parts'}{'js'},
	'and the js part moves with it');

done_testing();
