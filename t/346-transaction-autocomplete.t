# tests-for: public/js/manager/transaction.js
# covers:    The recent-inputs list under a transaction field is fixed to the
#            viewport, so scrolling a window or opening the phone's keyboard left
#            it frozen where the field used to be. It is now re-seated on its
#            field after any scroll or resize, hides when the field leaves the
#            screen, and puts itself away when there is nothing to suggest.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;

my $js = js_source('public/js/manager/transaction.js');

like($js, qr/function transactionAutocompleteSeat\(input, ac\)/,
	'the list has one place that seats it on a field');
like($js, qr/var rect = input\[0\]\.getBoundingClientRect\(\);/,
	'it measures the field in viewport coordinates, the way a fixed list is placed');
like($js, qr/var list_top = rect\.top - ac\.outerHeight\(\) - 3;/,
	'it opens above the field');
like($js, qr/if \(list_top < 8\) \{ list_top = rect\.bottom \+ 3; \}/,
	'and drops below it when there is no room above');
like($js, qr/document\.addEventListener\('scroll', transactionAutocompleteFollow, true\)/,
	'a scroll anywhere in a window re-seats the list');
like($js, qr/window\.addEventListener\('resize', transactionAutocompleteFollow\)/,
	'a resize re-seats it too');
like($js, qr/window\.visualViewport\.addEventListener\('resize', transactionAutocompleteFollow\)/,
	'the phone keyboard shrinking the view re-seats it');
like($js, qr/if \(rect\.bottom < visible_top \|\| rect\.top > visible_bottom\)/,
	'a field scrolled off the screen is judged against the visible strip');
like($js, qr/if \(!input\.length\) \{ ac\.html\(''\)\.hide\(\); return; \}/,
	'a list whose field is gone puts itself away');
like($js, qr/if \(!shown\) \{ ac\.html\(''\)\.hide\(\); return; \}/,
	'an answer with nothing in it shows no empty box');
like($js, qr/ac\.attr\('follow_uuid', random\);/,
	'the list remembers which field it belongs to');
like($js, qr/me\.attr\('temp_uuid', random\);/,
	'and the field carries the same mark, so a pick still lands in it');

done_testing();
