package JawnOS::Platform::Server;

# One place that turns "run this app as a server" into a child process.
#
# On a box with fork the tree still forks its servers through subs::subprocessor,
# so nothing below runs. Windows has no fork - Strawberry's pseudofork makes
# Mojo::IOLoop::Subprocess refuse outright - so President starts each server as
# a real process through JawnOS::Platform::Runner instead. The Runner::Windows
# start() ignores an env spec (the child inherits), so the caller locals the
# environment here around start rather than handing it over.
#
# plan is pure: it names the interpreter, the lib include, the app and the
# environment a server needs, and a test pins it. spawn is the impure half: it
# creates the runner, drains the child's output and starts it.

use strict;
use warnings;

use Cwd ();

sub plan {
	my (%opt) = @_;
	my $app = $opt{'app'};
	return undef unless defined $app && length $app;
	my $cwd = $opt{'cwd'} || Cwd::getcwd();

	my %env = %{ $opt{'env'} || {} };
	$env{'PURPOSE'} = $opt{'purpose'} if defined $opt{'purpose'} && length $opt{'purpose'};
	my $listen = $opt{'listen'};
	my @listen = ref $listen eq 'ARRAY' ? @$listen : (defined $listen && length $listen ? $listen : ());
	$env{'MOJO_LISTEN'} = join ',', @listen if @listen;
	# watch.pl and teletype.pl do not put lib on @INC themselves, and Mojolicious
	# needs to know the tree it is serving from.
	$env{'MOJO_HOME'} = $cwd;

	# `app->start` with no arguments does NOT read MOJO_LISTEN in this Mojolicious
	# (measured on Strawberry in VM 200: it fell back to a host Windows cannot
	# resolve). Giving the daemon command an explicit -l per listener is what
	# binds, and `*` works when written that way.
	my @args = ('-I', "$cwd/lib", $app, 'daemon');
	push @args, map { ('-l', $_) } @listen;

	return {
		program      => $^X,
		program_args => \@args,
		cwd          => $cwd,
		env          => \%env,
	};
}

sub spawn {
	my (%opt) = @_;
	my $plan = &plan(%opt);
	return undef unless $plan;

	require JawnOS::Platform::Runner;
	my $runner = JawnOS::Platform::Runner->new;
	$runner->conduit({ type => 'pipe' });
	# A chatty child fills an undrained pipe and stalls, so the default handler
	# drains it into a per-purpose file - the only place a server's own startup
	# error was ever visible on Windows.
	my $log_file;
	if ($opt{'purpose'}) {
		require JawnOS::Platform;
		require File::Path;
		my $dir = JawnOS::Platform::data_dir();
		eval { File::Path::make_path($dir) } unless -d $dir;
		$log_file = "$dir/server-$opt{'purpose'}.log";
	}
	my $default_read = sub {
		return unless $log_file;
		my ($runner, $bytes) = @_;
		if (open(my $fh, '>>', $log_file)) { print {$fh} $bytes; close $fh }
	};
	$runner->on(read => $opt{'on_read'} || $default_read);
	$runner->on(close => $opt{'on_close'} || sub {});

	my $pid;
	{
		# Runner::Windows ignores an env spec, and ReadWriteFork snapshots %ENV
		# when start is called, so the local covers both backends.
		local @ENV{ keys %{ $plan->{'env'} } } = values %{ $plan->{'env'} };
		$pid = $runner->start({
			program      => $plan->{'program'},
			program_args => $plan->{'program_args'},
			cwd          => $plan->{'cwd'},
		});
	}
	return { runner => $runner, pid => $pid };
}

1;
