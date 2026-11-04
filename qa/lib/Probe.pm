package Probe;

# Route enumeration and the request policy for the route layer.
#
# The route table is plain Perl (`lib/JawnOS/Routes/*.pm`), so the whole list
# can be read without booting the app. That makes this layer fast and safe: the
# only cost is the HTTP requests themselves.
#
# Every route must be *classified* before it is requested. The default is to
# skip: a route is only requested when a policy entry names it as a read. That
# is deliberate - this tree has GET routes that write (`backup_now`,
# `update_database`), that talk to hardware (`torch`, `lorawan`), that spend
# money (`pay/...`), or that reach peers. A test suite that guesses would be
# worse than one that admits what it skipped.

use strict;
use warnings;

use JSON::PP;
use File::Slurp qw(read_file);

our $VERSION = '1';

# The tier table is subs::tier_needed (perl/subroutines.pl). It is mirrored
# here so route classification needs no app boot; t/56 asserts the two agree
# for every route, so drift is a test failure rather than a surprise.
my @TIER = (
	['citizen',  qr{^/manager/(?:configure|security|magazine/publish|power)(?:/|$)}],
	['resident', qr{^/manager(?:/|$)}],
);

sub tier_needed {
	my ($path) = @_;
	return '' unless defined $path && length $path;
	for my $t (@TIER) {
		return $t->[0] if $path =~ $t->[1];
	}
	return '';
}

# ---------------------------------------------------------------------------
# the route table
# ---------------------------------------------------------------------------

sub routes {
	my ($repo) = @_;
	die "Probe: no route dir under $repo\n" unless -d "$repo/lib/JawnOS/Routes";

	my @out;
	for my $file (sort glob "$repo/lib/JawnOS/Routes/*.pm") {
		(my $module = $file) =~ s{.*/}{};
		$module =~ s{\.pm$}{};
		my $pkg = "JawnOS::Routes::$module";
		unless (defined &{"${pkg}::routes"}) {
			require $file;
		}
		no strict 'refs';
		my @entries = $pkg->routes;
		for my $e (@entries) {
			push @out, {
				method => $e->[1],
				path   => $e->[2],
				action => $e->[3],
				line   => $e->[0],
				module => $module,
			};
		}
	}
	return [sort { $a->{'path'} cmp $b->{'path'} || $a->{'method'} cmp $b->{'method'} } @out];
}

# ---------------------------------------------------------------------------
# the policy
# ---------------------------------------------------------------------------

sub load_policy {
	my ($path) = @_;
	my $json = -f $path ? read_file($path) : '{}';
	my $p = eval { JSON::PP->new->utf8->decode($json) };
	die "Probe: $path is not valid JSON: $@" unless ref $p eq 'HASH';
	$p->{'skip'}  ||= [];
	$p->{'allow'} ||= [];
	$p->{'tolerate'} ||= [];
	$p->{'tier_status'} ||= { citizen => 403, resident => 200, '' => 200 };
	return $p;
}

my @MUTATION_METHODS = qw(post put patch delete any websocket);

# Returns (1, reason) when the route must not be requested, (0, undef) when it
# should be, and (2, reason) when it needs fixture arguments we do not have.
sub classify {
	my ($policy, $route) = @_;
	my $method = lc($route->{'method'} // 'get');
	my $path   = $route->{'path'} // '';

	my $key = "$method $path";
	for my $allow (@{ $policy->{'allow'} }) {
		next unless defined $allow->{'method'} && lc($allow->{'method'}) eq $method;
		next unless $path =~ /$allow->{'path'}/;
		return (0, undef);
	}

	if (grep { $_ eq $method } @MUTATION_METHODS) {
		return (1, "a $method route is not requested in this layer");
	}

	for my $rule (@{ $policy->{'skip'} }) {
		my $m = defined $rule->{'method'} ? lc($rule->{'method'}) : '';
		next if $m ne '' && $m ne $method;
		next unless $path =~ /$rule->{'path'}/;
		return (1, $rule->{'why'} || 'skipped by policy');
	}

	return (2, 'needs fixture arguments') if $path =~ /[:*]/;

	return (0, undef);
}

sub expected_status {
	my ($policy, $route, $session_privilege) = @_;
	my $path = $route->{'path'};
	# The tier table exempts rails that authenticate themselves (the padlock
	# protocol, the device rail). hooks.pl skips the tier check for those, so a
	# resident session must still reach them.
	return 200 if $policy->{'tier_exempt'} && $path =~ /$policy->{'tier_exempt'}/;
	my $need = tier_needed($path);
	my $rank = { '' => 0, resident => 1, citizen => 2 };
	return $policy->{'tier_status'}->{$need}
		if exists $policy->{'tier_status'}->{$need};
	return 403 if ($rank->{$need} || 0) > ($rank->{$session_privilege // ''} || 0);
	return 200;
}

# A route that is expected to complain without the arguments the UI always
# sends. Recorded as a warning, not a failure, so the failure list stays
# about regressions. Every entry names why.
sub tolerated {
	my ($policy, $route) = @_;
	my $method = lc($route->{'method'} // 'get');
	my $path = $route->{'path'} // '';
	for my $rule (@{ $policy->{'tolerate'} || [] }) {
		next if defined $rule->{'method'} && lc($rule->{'method'}) ne $method;
		next unless $path =~ /$rule->{'path'}/;
		return $rule->{'why'} || 'tolerated';
	}
	return undef;
}

1;
