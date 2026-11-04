# tests-for: perl/crew.pl
# covers:    the local Ollama client is found under the home directory when the
#           service's PATH does not name it - an LXC with no sudo installs it
#           there. PATH still wins, and the older ~/ollama/bin location is read.

use strict;
use warnings;

use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

require "$FindBin::Bin/../perl/crew.pl";

sub fake_ollama {
	my ($path) = @_;
	my ($dir) = $path =~ m{^(.*)/[^/]+$};
	make_path($dir);
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh "#!/bin/sh\nexit 0\n";
	close $fh;
	chmod 0755, $path;
	return $path;
}

my $tmp = tempdir(CLEANUP => 1);
local $ENV{'HOME'} = $tmp;
local $ENV{'PATH'} = '/nonexistent';

is(crew::_ollama_binary(), '', 'no PATH entry and no home install: not found');

&fake_ollama("$tmp/.local/bin/ollama");
is(crew::_ollama_binary(), "$tmp/.local/bin/ollama", 'a user install under ~/.local/bin is found');

&fake_ollama("$tmp/pathbin/ollama");
local $ENV{'PATH'} = "$tmp/pathbin";
is(crew::_ollama_binary(), "$tmp/pathbin/ollama", 'PATH is preferred when both exist');

local $ENV{'PATH'} = '/nonexistent';
unlink "$tmp/.local/bin/ollama";
&fake_ollama("$tmp/ollama/bin/ollama");
is(crew::_ollama_binary(), "$tmp/ollama/bin/ollama", 'the older ~/ollama/bin install is found too');

done_testing();
