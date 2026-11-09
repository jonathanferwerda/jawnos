package JawnOS::Platform;

# The portability questions P0 asks, answered in one place. Nothing here starts
# a process, opens a socket or reads the database, so ./jawn can require it
# before the tree exists and a test can exercise it without a house.
#
# Two different questions are kept apart:
#
#   *_available   what this OS and this perl can do
#   use_*         what the current mode asks us to use
#
# JAWNOS_PORTABLE=1 (or strict) disables fork, PTY and UNIX sockets without
# pretending the platform cannot do them. MSWin32 is portable by default.
#
# JAWNOS_TRANSPORT=tcp|unix picks the control/log/watch transport explicitly;
# the default stays UNIX on POSIX until the TCP slice lands, so setting
# JAWNOS_PORTABLE=1 does not silently move a running master's sockets.

use strict;
use warnings;

use Config ();
use Cwd ();
use File::Spec ();

our $VERSION = '0.01';

# The modules a house cannot boot without. Kept in step with the Dockerfile's
# cpanm list; a missing one is a packaging failure, not a platform surprise.
my @REQUIRED_MODULES = qw(
	Mojolicious
	Mojo::SQLite
	Minion
	Minion::Backend::SQLite
	DBD::SQLite
	Sereal::Encoder
	Sereal::Decoder
	Net::SSLeay
	CryptX
);

sub required_modules { return [ @REQUIRED_MODULES ] }

sub os { return $^O }

sub arch { return $Config::Config{'archname'} || '' }

sub home {
	my $home = $ENV{'HOME'};
	if (!defined $home || !length $home) {
		$home = (getpwuid($<))[7] || '';
	}
	return $home;
}

sub portable {
	my $mode = lc($ENV{'JAWNOS_PORTABLE'} || '');
	return 1 if $mode eq '1' || $mode eq 'yes' || $mode eq 'on'
		|| $mode eq 'true' || $mode eq 'strict';
	return 1 if $^O eq 'MSWin32';
	return 0;
}

sub strict {
	my $mode = lc($ENV{'JAWNOS_PORTABLE'} || '');
	return 1 if $mode eq 'strict';
	return 1 if $ENV{'JAWNOS_NO_FORK'};
	return 0;
}

# What the platform can do.
sub fork_available {
	return 0 if $^O eq 'MSWin32';
	return $Config::Config{'d_fork'} ? 1 : 0;
}

sub pty_available {
	return 0 if $^O eq 'MSWin32';
	return 0 unless eval { require IO::Pty; 1 };
	my $pty = eval { IO::Pty->new };
	return 0 unless $pty;
	eval { close $pty };
	return 1;
}

sub unix_socket_available {
	return 0 if $^O eq 'MSWin32';
	return eval { require IO::Socket::UNIX; 1 } ? 1 : 0;
}

# What the current mode asks for.
sub use_fork { return (fork_available() && !portable()) ? 1 : 0 }
sub use_pty  { return (pty_available()  && !portable()) ? 1 : 0 }

sub transport {
	my $explicit = lc($ENV{'JAWNOS_TRANSPORT'} || '');
	return 'tcp'  if $explicit eq 'tcp';
	return 'unix' if $explicit eq 'unix';
	return $^O eq 'MSWin32' ? 'tcp' : 'unix';
}

sub use_unix_socket {
	return (unix_socket_available() && transport() eq 'unix') ? 1 : 0;
}

sub preferred_transport { return portable() ? 'tcp' : 'unix' }

# The tree is cwd-relative; the runtime state lives under ~/.president. Both
# get an explicit override so an app bundle never has to guess.
sub tree_dir {
	my $dir = $ENV{'JAWNOS_DIR'};
	return $dir if defined $dir && length $dir;
	my $cwd = eval { Cwd::getcwd() };
	return (defined $cwd && length $cwd) ? $cwd : '.';
}

sub data_dir {
	my $dir = $ENV{'JAWNOS_DATA_DIR'};
	return $dir if defined $dir && length $dir;
	my $home = home();
	return length($home) ? "$home/.president" : './.president';
}

sub module_version {
	my ($module) = @_;
	return undef unless defined $module && length $module;
	(my $file = $module) =~ s{::}{/}g; $file .= ".pm"; my $loaded = eval { require $file; 1 };
	return undef unless $loaded;
	no strict 'refs';
	my $version = ${"${module}::VERSION"};
	return defined $version ? "$version" : '';
}

sub missing_required {
	return [ grep { !defined module_version($_) } @REQUIRED_MODULES ];
}

sub tool_path {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	my @names = ($name);
	push @names, "$name.exe", "$name.bat", "$name.cmd" if $^O eq 'MSWin32';
	foreach my $dir (File::Spec->path) {
		next unless defined $dir && length $dir;
		foreach my $candidate (@names) {
			my $path = File::Spec->catfile($dir, $candidate);
			return $path if -f $path && -x $path;
		}
	}
	return undef;
}

sub serial_devices {
	return [] if $^O eq 'MSWin32';
	my @patterns = $^O eq 'darwin'
		? ('/dev/cu.usbmodem*', '/dev/cu.usbserial*')
		: ('/dev/ttyACM*', '/dev/ttyUSB*');
	my @found;
	foreach my $pattern (@patterns) {
		push @found, sort glob($pattern);
	}
	return [ @found ];
}

sub capabilities {
	my %modules;
	my @extra = qw(
		Mojo::IOLoop::ReadWriteFork
		IO::Socket::UNIX
		IO::Pty
		threads
	);
	foreach my $module (@REQUIRED_MODULES, @extra) {
		$modules{$module} = module_version($module);
	}

	my @tool_names = qw(
		bluetoothctl busctl system_profiler powershell
		pactl wpctl amixer say afplay
		lpstat lp lpadmin cupsd
		avahi-browse avahi-publish-service dns-sd
		tailscale git node
		ffmpeg magick convert tesseract qrencode zbarimg espeak sox
	);
	my %tools = map { $_ => (tool_path($_) ? 1 : 0) } @tool_names;

	return {
		os                       => os(),
		arch                     => arch(),
		perl                     => "$]",
		perl_version             => "$^V",
		ithreads                 => $Config::Config{'useithreads'} ? 1 : 0,
		portable                 => portable(),
		strict                   => strict(),
		mode                     => strict() ? 'portable-strict' : (portable() ? 'portable' : 'native'),
		fork_available           => fork_available(),
		fork_emulated            => ($^O eq 'MSWin32' ? 1 : 0),
		pty_available            => pty_available(),
		unix_socket_available    => unix_socket_available(),
		use_fork                 => use_fork(),
		use_pty                  => use_pty(),
		use_unix_socket          => use_unix_socket(),
		transport                => transport(),
		preferred_transport      => preferred_transport(),
		tree_dir                 => tree_dir(),
		data_dir                 => data_dir(),
		modules                  => \%modules,
		tools                    => \%tools,
		serial_devices           => serial_devices(),
		missing_required         => missing_required(),
	};
}

1;
