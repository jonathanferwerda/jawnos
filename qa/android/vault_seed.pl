use strict;
use warnings;

# The QA seed sets the house password but does not create the vault: the first
# real login does that (login_gate -> vault_seed). Without it suds_grabber()
# resolves nothing, the box office ticket is refused, and the app lands on the
# Gate. Run the app's own login path once, with the seed code.
$ENV{PURPOSE} = '';
# Manager.pl adds its own lib relative to FindBin, which is this script's
# directory, not the tree's. The tree's lib/ is the one that matters.
use lib 'lib';
eval { require './perl/Manager.pl'; 1 } or do { print "app: $@\n"; exit 2 };

my $config = eval { &subs::config_reader() } || {};
$ENV{PORT_DOCK} = $ENV{PORT_DOCK} || $config->{'port'} || 3000;
$ENV{PORT_AHOY} = $ENV{PORT_AHOY} || $config->{'working_port'} || 45545;

my $code = $ARGV[0] // '';
my ($authorized) = &subs::login_gate($code);
unless ($authorized) {
	print "the seed code is not this house's key\n";
	exit 3;
}
my $vault = eval { &subs::suds_grabber() };
unless ($vault) {
	print "the vault did not resolve after login\n";
	exit 4;
}
print "vault ok\n";
exit 0;
