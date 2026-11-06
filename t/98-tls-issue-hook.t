# tests-for: perl/tls.pl scripts/tls_issue.pl
# covers:    The certbot manual-hook command must start with a bare executable
#            path. certbot 5.x validates the hook's first whitespace-separated
#            token as a literal path, so a quoted interpreter ("'/usr/bin/perl'
#            …") is reported as "not found" and the renewal never reaches ACME.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

require "$FindBin::Bin/../perl/tls.pl";

my $plain = tls::certbot_hook('/usr/bin/perl', '/home/jawn/jawnos/scripts/tls_issue.pl');

is(
	$plain->{'hook'},
	'/usr/bin/perl /home/jawn/jawnos/scripts/tls_issue.pl hook',
	'ordinary paths are unquoted'
);
is($plain->{'disable_validation'}, 0, 'and certbot keeps checking the hook');

# This is the exact thing certbot looks up: the first token, as written.
my ($first) = split ' ', $plain->{'hook'};
ok(-x $first, 'the first token is an executable path');
unlike($first, qr/['"]/, 'the first token carries no quotes');

my $spaced = tls::certbot_hook('/opt/Perl 5/bin/perl', '/srv/my tree/scripts/tls_issue.pl');
is(
	$spaced->{'hook'},
	'"/opt/Perl 5/bin/perl" "/srv/my tree/scripts/tls_issue.pl" hook',
	'a path with a space is quoted so the shell keeps it whole'
);
is($spaced->{'disable_validation'}, 1, 'and the check is off, because it cannot parse quotes');

# --- one certificate per machine -------------------------------------------
# A wildcard key copied to every machine lets any one of them impersonate the
# whole domain. --host asks ACME for this machine's own name only, in its own
# certbot lineage, so a host run can never rotate the house's wildcard.
my $issuer = do {
	open(my $fh, '<', "$FindBin::Bin/../scripts/tls_issue.pl") or die $!;
	local $/;
	<$fh>;
};
like($issuer, qr/\$host_mode = 1 if \$ARGV\[\$i\] eq '--host'/, 'the issuer takes --host');
like($issuer, qr/\$host_mode \? \(\) : \('-d', '\*\.' \. \$domain\)/,
	'a host certificate asks ACME for no wildcard');
like($issuer, qr/\$cert_name = 'host-' \. \$slug/, 'and gets a certbot lineage of its own');
like($issuer, qr/\$out_dir = \$ARGV\[\$i \+ 1\] if \$ARGV\[\$i\] eq '--out'/,
	'it can install somewhere other than server/, for a staged rollout');
like($issuer, qr/copy\(\$full, "\$out_dir\/fullchain\.pem"\)/, 'the pair is installed under --out');
unlike($issuer, qr/'-d', '\*\.' \. \$domain,\n\t'--email'/, 'the wildcard stays the default branch');

done_testing();
