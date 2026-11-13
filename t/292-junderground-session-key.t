# tests-for: perl/junderground.pl
# covers:    jg_key resolves the house key from the session's suds. Sessions
#            carry only suds_id now, so the client must hand crest_key_read()
#            subs::session_suds($c); asking the session for a `suds` field
#            returns undef and every signed call answers "house key locked".

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);

# junderground.pl declares no package of its own: Manager.pl requires it, so
# its subs live in Manager. Load it from the repo, not a sandbox - the file
# needs no config, database or network.
my $root = abs_path("$FindBin::Bin/..");
{
	package Manager;
	do "$root/perl/junderground.pl";
}
die $@ if $@;
is(defined &Manager::jg_key, 1, 'junderground.pl defines Manager::jg_key');

package FakeSession;

sub new {
	my ($class, %args) = @_;
	return bless { %args }, $class;
}

sub session {
	my ($self, $key) = @_;
	return $self->{$key};
}

package main;

my $KEY = 'K' x 32;

subtest 'suds_id is resolved server-side' => sub {
	my $c = FakeSession->new(suds_id => 'session-7');
	is($c->session('suds'), undef, 'the session carries no suds field');

	my (@asked, @keyed);
	local *subs::session_suds = sub {
		push @asked, $_[0];
		return 'resolved-suds';
	};
	local *subs::crest_key_read = sub {
		push @keyed, $_[0];
		return $_[0] eq 'resolved-suds' ? $KEY : undef;
	};

	is(Manager::jg_key($c), $KEY, 'jg_key returns the 32-byte house key');
	is_deeply(\@asked, [$c], 'session_suds was asked for this request');
	is_deeply(\@keyed, ['resolved-suds'], 'crest_key_read got the resolved suds');
};

subtest 'no suds means no key' => sub {
	my $c = FakeSession->new(suds_id => 'session-8');
	my @asked;
	local *subs::session_suds = sub {
		push @asked, $_[0];
		return undef;
	};
	local *subs::crest_key_read = sub {
		return defined $_[0] ? $KEY : undef;
	};

	is(Manager::jg_key($c), undef, 'jg_key is undef when session_suds yields undef');
	is_deeply(\@asked, [$c], 'session_suds was still asked for this request');
};

done_testing();
