# Part of perl/President.pl (package President). The index requires this file
# at the line where the sub used to be defined. The only unqualified global the
# sub reads is the logger; $gb::* and subs::* are already fully qualified.
package President;
use strict;
use warnings;
no warnings qw(uninitialized once);
use vars qw($log);

sub utility_stopper() {
	foreach my $t ( keys %{$gb::timeouts} ) {
		next if $t =~ /^__/;
		Mojo::IOLoop->remove($gb::timeouts->{$t}->{'loop'}) if $gb::timeouts->{$t}->{'loop'};
		$gb::timeouts->{$t}->{'subroutine'} = undef if $gb::timeouts->{$t}->{'subroutine'};
	}
	$log->info('Loop is crashing at ' . localtime(&subs::rightNow() / 1000 )->strftime('%a %D %I:%M:%S%P'));

	$gb::utility_functions_watcher = 0;
}

1;
