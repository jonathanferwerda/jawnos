# tests-for: lib/JawnOS/Domain/Git.pm docs/voice-attribution.md
# covers:    the CC BY attribution that travels with the Piper voice models

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";

# The models are redistributed through voices/, so the attribution has to be
# written beside them, not only kept in the repository docs.
my $git = read_file("$root/lib/JawnOS/Domain/Git.pm");
like($git, qr/ATTRIBUTION\.md/, 'voice_sync writes the attribution beside the models');
like($git, qr/LibriTTS-R/, 'and names the CC BY LibriTTS-R dataset');
like($git, qr/Edinburgh DataShare/, 'and the CC BY Alba dataset');

my $doc = read_file("$root/docs/voice-attribution.md");
like($doc, qr/LibriTTS-R/, 'the doc names LibriTTS-R');
like($doc, qr/10283\/3270/, 'and the Alba handle');
like($doc, qr{creativecommons\.org/licenses/by/4\.0}, 'and the licence');

done_testing();
