# tests-for: lib/JawnOS/Controller/manager_misc7.pm public/js/manager/manager/04_search.js lib/JawnOS/Domain/Format.pm lib/JawnOS/Domain/Name.pm
# covers:    the dock search's index walked every settings key, including corrupt
#           megabyte names; NFC on those keys is superlinear and held the whole
#           endpoint for minutes, so the box never drew a match. The route now
#           skips quarantine and overlong keys, the formatter bounds its input,
#           and the browser stops waiting on a request that will not answer.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $repo = root();
my $route = read_file("$repo/lib/JawnOS/Controller/manager_misc7.pm");

my ($body) = $route =~ /(sub action_26091\b.*?\n\})/s;
ok(defined $body && length $body, 'the search index action is readable');

like($body, qr/next if \$app =~ \/\^__\//,
	'a quarantine key stays out of the index');
like($body, qr/next if &subs::name_overlong\(\$app\)/,
	'an overlong corrupt key stays out of the index');

my $skip = index($body, '&subs::name_overlong($app)');
my $format = index($body, 'format_name');
ok($skip >= 0 && $format >= 0 && $skip < $format,
	'the overlong check runs before any name is formatted');

my $search = read_file("$repo/public/js/manager/manager/04_search.js");
like($search, qr{url: '/manager/search_index'.*?timeout: 20000}s,
	'the index request gives up instead of staying pending forever');
like($search, qr/jawnosSearchLoading = null/,
	'a failed or timed-out index clears the loading promise so the next key retries');

done_testing();
