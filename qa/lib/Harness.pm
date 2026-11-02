package Harness;

# The isolation fence and the instance lifecycle for the qa/ suite.
#
# The app's database is hardwired to <install dir>/database/jawnos.db, and the
# install dir is resolved from perl/subroutines.pl's own real path. A symlink
# farm therefore resolves back to the live tree, so an instance-level test must
# run a *copy*. That is the first rule here.
#
# The second rule is that the copy runs inside user/PID/net/mount namespaces:
#
#   * PID namespace - scripts/manager_killer.pl stops "everything jawn runs" by
#     process name, machine-wide. A second tree calling it would kill the live
#     tree. Inside its own PID namespace it can only see itself.
#   * net namespace - the tree binds https://*:PORT. In a netns that means
#     loopback only, so a QA house is never on the LAN and can reach no peer,
#     mail relay or model API.
#   * mount namespace - the live repo is bind-mounted read-only, and /tmp is a
#     private tmpfs, so a bug that names the live tree gets EROFS.
#
# Teardown is SIGKILL of the instance's process group: the master's graceful
# path runs manager_killer.pl, and we never want that running for a test.
#
# Nothing here reads or writes the live database. The only live file touched is
# the repo read by `git archive`, and audit() records that no instance process
# references the live database path.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP;
use IO::Socket::INET;
use Time::HiRes qw(time sleep);
use POSIX ();
use Mojo::UserAgent;
use Mojo::UserAgent::CookieJar;

our $VERSION = '1';

# ---------------------------------------------------------------------------
# the fence
# ---------------------------------------------------------------------------

sub enter_namespace {
	my (@args) = @_;

	return 1 if $ENV{'JAWNOS_QA_NS'};

	if (grep { $_ eq '--no-namespace' } @args) {
		$ENV{'JAWNOS_QA_NO_NS'} = 1;
		warn "qa: running WITHOUT namespaces (--no-namespace).\n"
			. "qa: a second tree can then reach the live tree; teardown still uses SIGKILL.\n";
		return 1;
	}

	my $unshare = `command -v unshare 2>/dev/null`;
	chomp $unshare if defined $unshare;
	die "qa: unshare(1) is not installed; install util-linux or pass --no-namespace\n"
		unless defined $unshare && length $unshare && -x $unshare;

	# prove the kernel allows an unprivileged user namespace before relying on it
	my $probe = system($unshare, '--user', '--map-root-user', '--', '/bin/true') == 0;
	die "qa: unprivileged user namespaces are disabled; enable them or pass --no-namespace\n"
		unless $probe;

	$ENV{'JAWNOS_QA_NS'} = '1';
	$ENV{'JAWNOS_QA_OUTER_PIDNS'} = _ns_id('pid');

	exec $unshare,
		'--user', '--map-root-user',
		'--mount', '--pid', '--fork', '--mount-proc',
		'--net', '--',
		$^X, abs_path($0), @args;
	die "qa: cannot enter the namespace: $!\n";
}

sub _ns_id {
	my ($kind) = @_;
	my $id = readlink("/proc/self/ns/$kind");
	return defined $id ? $id : '';
}

# Inside a fresh net namespace the loopback interface starts down. The tree
# binds https://*:PORT, which is loopback-only here, so it needs lo up.
sub bring_up_loopback {
	return 1 if $ENV{'JAWNOS_QA_NO_NS'};
	# Only a fresh net namespace needs this, and only there is it permitted.
	return 0 unless $ENV{'JAWNOS_QA_NS'};
	return system('ip', 'link', 'set', 'lo', 'up') == 0 ? 1 : 0;
}

sub namespace_state {
	my %state = (pid => 0, net => 0);
	$state{'pid'} = 1
		if $ENV{'JAWNOS_QA_OUTER_PIDNS'}
		&& _ns_id('pid') ne $ENV{'JAWNOS_QA_OUTER_PIDNS'};
	my $links = `ip -o link show 2>/dev/null`;
	$state{'net'} = 1 if $links !~ /: (?:eth|wlan|enp|wlp|wlan)\d/;
	return \%state;
}

sub _bind_live_read_only {
	my ($repo) = @_;
	return 0 if $ENV{'JAWNOS_QA_NO_NS'};
	return 0 unless -d $repo;
	return 1 if system('mount', '--bind', '-o', 'ro', $repo, $repo) == 0;
	return 0;
}

sub _private_tmp {
	return 0 if $ENV{'JAWNOS_QA_NO_NS'};
	return system('mount', '-t', 'tmpfs', 'tmpfs', '/tmp') == 0 ? 1 : 0;
}

# ---------------------------------------------------------------------------
# construction
# ---------------------------------------------------------------------------

sub new {
	my ($class, %opt) = @_;

	my $self = bless {%opt}, $class;

	my $repo = $opt{'repo'} || abs_path(dirname(__FILE__) . '/../..');
	$repo = abs_path($repo);
	die "Harness: no repo at $repo\n" unless -f "$repo/perl/subroutines.pl" && -d "$repo/lib";
	$self->{'repo'} = $repo;

	my $root = $opt{'root'} || $ENV{'JAWNOS_QA_ROOT'} || (($ENV{'HOME'} || '/tmp') . '/jawnos-qa');
	$root = abs_path($root) || $root;
	die "Harness: QA root $root is inside the live repo; choose a path outside it\n"
		if $root eq $repo || index($root, "$repo/") == 0;
	$self->{'root'} = $root;

	my $stamp = POSIX::strftime('%Y%m%d-%H%M%S', localtime) . '-' . $$;
	$self->{'run'}     = "$root/runs/$stamp";
	$self->{'tree'}    = "$self->{'run'}/tree";
	$self->{'home'}    = "$self->{'run'}/home";
	$self->{'tmp'}     = "$self->{'run'}/tmp";
	$self->{'logs'}    = "$self->{'run'}/logs";
	$self->{'results'} = "$self->{'run'}/results";
	$self->{'stamp'}   = $stamp;

	$self->{'perl5lib'} = _local_lib($ENV{'HOME'}, $ENV{'PERL5LIB'});
	$self->{'source'}   = $opt{'source'} || 'head';
	$self->{'booted'}   = {};

	# a fresh net namespace starts with loopback down, and the tree binds
	# https://*:PORT - which succeeds even then, while 127.0.0.1 is unreachable
	bring_up_loopback();

	make_path($self->{'tree'}, $self->{'home'}, $self->{'tmp'},
		$self->{'logs'}, $self->{'results'},
		"$self->{'home'}/.president");
	return $self;
}

# The app's modules live in the user's local::lib, which ./jawn finds from
# $HOME. A non-interactive ssh session exports no PERL5LIB at all, and the
# system perl on the table has Mojo but not Sereal, so a bare `perl ./perl/
# President.pl` dies at line 29. Discover the same tree here and pass it down.
sub _local_lib {
	my ($home, $existing) = @_;
	my @dirs;
	my $base = (($home // '') . '/perl5/lib/perl5');
	if ($base =~ m{/} && -d $base) {
		push @dirs, $base;
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ /-linux-/ || $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
	}
	push @dirs, grep { length } split /:/, ($existing // '');
	my %seen;
	@dirs = grep { !$seen{$_}++ } @dirs;
	return join ':', @dirs;
}

sub repo    { $_[0]->{'repo'} }
sub root    { $_[0]->{'root'} }
sub run     { $_[0]->{'run'} }
sub tree    { $_[0]->{'tree'} }
sub home    { $_[0]->{'home'} }
sub logs    { $_[0]->{'logs'} }
sub results { $_[0]->{'results'} }

# ---------------------------------------------------------------------------
# the copy
# ---------------------------------------------------------------------------

sub export_tree {
	my ($self) = @_;
	my $repo = $self->{'repo'};
	my $tree = $self->{'tree'};

	if ($self->{'source'} eq 'worktree') {
		my @exclude = (
			'--exclude=./.git', '--exclude=./.shots', '--exclude=./releases',
			'--exclude=./.secrets', '--exclude=./database/jawnos.db*',
			'--exclude=./database/backups', '--exclude=./desktop/mkosi/output',
			'--exclude=./desktop/mkosi/.stage', '--exclude=./.pio',
			'--exclude=./jp/alarmclock/.pio', '--exclude=./jt/.pio',
			'--exclude=./jw/.pio', '--exclude=./node_modules',
		);
		my $cmd = join ' ', map { "'$_'" } ('tar', '-C', $repo, '-cf', '-', @exclude, '.');
		my $untar = join ' ', map { "'$_'" } ('tar', '-x', '-C', $tree);
		system("$cmd | $untar") == 0 or die "Harness: worktree export failed\n";
	}
	else {
		system("git --no-optional-locks -C '$repo' archive HEAD | tar -x -C '$tree'") == 0
			or die "Harness: git archive failed\n";
	}

	die "Harness: the copy carries a live database\n" if -f "$self->{'tree'}/database/jawnos.db";
	die "Harness: the copy carries live TLS keys\n" if -f "$self->{'tree'}/server/privkey.pem";
	return 1;
}

# ---------------------------------------------------------------------------
# a fresh house, with no user secret
# ---------------------------------------------------------------------------

sub seed {
	my ($self, %opt) = @_;
	my $code = $opt{'code'} || '424242';

	$self->{'code'} = $code;
	my $ok = $self->_run_in_instance($self->{'tree'},
		$^X, 'scripts/jawnos_setup.pl',
		'--seed', '--code', $code,
		'--name', 'QAHouse', '--device', 'computer',
		'--language', 'en', '--domain', '127.0.0.1');
	die "Harness: setup --seed failed\n" unless $ok;
	die "Harness: setup produced no database\n"
		unless -f "$self->{'tree'}/database/jawnos.db";
	return 1;
}

sub make_certificate {
	my ($self) = @_;
	my $ok = system('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
		'-days', '2', '-subj', '/CN=127.0.0.1',
		'-keyout', "$self->{'tree'}/server/privkey.pem",
		'-out', "$self->{'tree'}/server/fullchain.pem") == 0;
	die "Harness: openssl could not make the QA certificate\n" unless $ok;
	chmod 0600, "$self->{'tree'}/server/privkey.pem";
	return 1;
}

# ---------------------------------------------------------------------------
# ports and config
# ---------------------------------------------------------------------------

sub _free {
	my ($port) = @_;
	my $s = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 1, ReuseAddr => 1);
	return 0 unless $s;
	close $s;
	return 1;
}

# The tree uses eight ports: the working port W, W+1 ws, W+2 watch, W+3 tty,
# W+4 coms, W+5 alarm, the dock port, and W+101 for the plain-loopback socket.
sub pick_ports {
	my ($self) = @_;
	for my $n (0 .. 800) {
		my $w = 21000 + $n * 37;
		next if $w + 101 >= 60000;
		next unless _free($w) && _free($w + 1) && _free($w + 2) && _free($w + 3)
			&& _free($w + 4) && _free($w + 5) && _free($w + 11) && _free($w + 101);
		$self->{'ports'} = { working => $w, ws => $w + 1, dock => $w + 11 };
		return $self->{'ports'};
	}
	die "Harness: no free port block\n";
}

sub write_config {
	my ($self, %opt) = @_;
	my $p = $self->{'ports'} || $self->pick_ports();
	my $cfgp = "$self->{'tree'}/config.json";

	open(my $cf, '<', $cfgp) or die "Harness: $cfgp: $!\n";
	my $cfg = JSON::PP->new->utf8->decode(do { local $/; <$cf> });
	close $cf;

	$cfg->{'port'}         = "$p->{'dock'}";
	$cfg->{'working_port'} = "$p->{'working'}";
	$cfg->{'ws_port'}      = $p->{'ws'};
	$cfg->{'domain'}       = '127.0.0.1';
	$cfg->{'name'}         = 'QAHouse';
	$cfg->{'device'}       = $opt{'device'} || 'computer';
	$cfg->{'environment'}  = $opt{'environment'} || 'production';
	$cfg->{'open_browser'} = 'no';
	$cfg->{'live'}         = $opt{'live'} ? 1 : 0;
	$cfg->{'logfile'}      = "$self->{'logs'}/manager.log";
	$cfg->{'signatorial'}  = "$self->{'home'}/.jawnos_signatorial";
	$cfg->{'folders'}      = [];
	$cfg->{'ssh_port'}     = '0';

	open(my $out, '>', $cfgp) or die "Harness: $cfgp: $!\n";
	print $out JSON::PP->new->canonical->pretty->utf8->encode($cfg);
	close $out;
	return $cfg;
}

# ---------------------------------------------------------------------------
# boot and stop
# ---------------------------------------------------------------------------

sub _run_in_instance {
	my ($self, $dir, @cmd) = @_;
	my $pid = fork();
	die "Harness: fork: $!\n" unless defined $pid;
	if (!$pid) {
		chdir $dir or POSIX::_exit(126);
		$ENV{'HOME'}   = $self->{'home'};
		$ENV{'TMPDIR'} = $self->{'tmp'};
		$ENV{'PERL5LIB'} = $self->{'perl5lib'} if length $self->{'perl5lib'};
		exec @cmd;
		POSIX::_exit(127);
	}
	waitpid($pid, 0);
	return ($? == 0) ? 1 : 0;
}

sub boot {
	my ($self, %opt) = @_;
	my $name = $opt{'name'} || 'main';
	die "Harness: instance '$name' is already booted\n" if $self->{'booted'}->{$name};

	my $p = $self->{'ports'};
	my $log = "$self->{'logs'}/boot-$name.log";

	my $pid = fork();
	die "Harness: fork: $!\n" unless defined $pid;
	if (!$pid) {
		POSIX::setsid();
		chdir $self->{'tree'} or POSIX::_exit(126);
		$ENV{'HOME'}     = $self->{'home'};
		$ENV{'TMPDIR'}   = $self->{'tmp'};
		$ENV{'PERL5LIB'} = $self->{'perl5lib'} if length $self->{'perl5lib'};
		open(STDOUT, '>>', "$log.console") or POSIX::_exit(127);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(127);
		# Run the tree, not the supervisor. ./jawn's boot watch probes both
		# ports and restarts the tree if it cannot, which under QA load turned
		# into a restart loop; and its graceful stop runs manager_killer.pl,
		# whose sweeps are machine-wide. A PTY is required (President reads its
		# children's output through one), hence script(1).
		exec('script', '-qfec', 'exec ./perl/President.pl', $log);
		POSIX::_exit(127);
	}

	$self->{'booted'}->{$name} = { pid => $pid, log => $log, up => 0 };

	my $t0 = time;
	my $up = 0;
	my $good = 0;
	my $last = 'no attempt';
	while (time - $t0 < ($opt{'timeout'} || 180)) {
		require HTTP::Tiny;
		my $tiny = HTTP::Tiny->new(
			verify_SSL => 0, timeout => 3, keep_alive => 0,
			max_redirect => 0, agent => 'jawnos-qa',
		);
		my $r = $tiny->get("https://127.0.0.1:$p->{'working'}/manager/health");
		my $code = $r->{'status'} || 0;
		$last = "status=$code reason=" . ($r->{'reason'} // '-')
			. ' content=' . substr(($r->{'content'} // '-'), 0, 90);
		# three answers in a row: the tree is not merely bound, it is serving
		$good = ($code >= 200 && $code < 500) ? $good + 1 : 0;
		if ($good >= 3) { $up = 1; last }
		sleep 1;
	}
	unless ($up) {
		my $tail = _tail($log, 30);
		my $ss = `ss -ltn 2>/dev/null`;
		my $curl = `curl -k -s -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1:$p->{'working'}/manager/health 2>&1`;
		$self->stop($name);
		die "Harness: instance '$name' did not answer in time ($last; curl=$curl)\nlisteners:\n$ss\n$tail";
	}
	$self->{'booted'}->{$name}->{'up'} = 1;
	$self->{'booted'}->{$name}->{'seconds'} = time - $t0;
	return $self->{'booted'}->{$name};
}

sub _tail {
	my ($path, $n) = @_;
	return '' unless -f $path;
	open(my $fh, '<', $path) or return '';
	my @lines = <$fh>;
	close $fh;
	@lines = @lines[-$n .. -1] if @lines > $n;
	return join '', @lines;
}

sub stop {
	my ($self, $name) = @_;
	$name ||= 'main';
	my $b = $self->{'booted'}->{$name};
	return 0 unless $b;
	my $pid = $b->{'pid'};

	# SIGKILL, never the graceful path: that runs scripts/manager_killer.pl,
	# whose sweeps are machine-wide by process name.
	kill 'KILL', -$pid if $pid;
	kill 'KILL', $pid if $pid;

	for my $dir (glob '/proc/[0-9]*') {
		my $cwd = readlink "$dir/cwd";
		next unless defined $cwd && index($cwd, $self->{'tree'}) == 0;
		my ($n) = $dir =~ m{/proc/(\d+)};
		kill 'KILL', $n if $n;
	}
	# Only reap a child that is still there. A second stop() (the END cleanup
	# after the normal path already stopped it) must not waitpid a reaped pid:
	# that sets $? to -1 and turns a clean exit into 255.
	waitpid($pid, 0) if $pid && kill(0, $pid);
	sleep 1;
	my $left = $self->instance_pids();
	$b->{'up'} = 0;
	$b->{'left'} = scalar @$left;
	return $b;
}

sub stop_all {
	my ($self) = @_;
	for my $name (keys %{ $self->{'booted'} }) {
		$self->stop($name);
	}
}

# Is the tree answering right now? Used between requests to tell a route's own
# 5xx from a tree that has died under it.
sub alive {
	my ($self) = @_;
	my $p = $self->{'ports'};
	return 0 unless $p;
	require HTTP::Tiny;
	my $tiny = HTTP::Tiny->new(
		verify_SSL => 0, timeout => 4, keep_alive => 0, max_redirect => 0);
	my $r = $tiny->get("https://127.0.0.1:$p->{'working'}/manager/health");
	my $code = $r->{'status'} || 0;
	return ($code >= 200 && $code < 500) ? 1 : 0;
}

sub restart {
	my ($self, $name) = @_;
	$name ||= 'main';
	$self->stop($name);
	my $b = $self->boot(name => $name, timeout => 180);
	$self->{'restarts'} = ($self->{'restarts'} || 0) + 1;
	return $b;
}

sub instance_pids {
	my ($self) = @_;
	my @pids;
	for my $dir (glob '/proc/[0-9]*') {
		my $cwd = readlink "$dir/cwd";
		next unless defined $cwd && index($cwd, $self->{'tree'}) == 0;
		my ($n) = $dir =~ m{/proc/(\d+)};
		push @pids, $n if $n;
	}
	return \@pids;
}

# ---------------------------------------------------------------------------
# the audit: would the fence hold even if a path were wrong?
# ---------------------------------------------------------------------------

sub audit {
	my ($self) = @_;
	my $live_db = "$self->{'repo'}/database/jawnos.db";
	my $pids = $self->instance_pids();
	my @touched;

	for my $pid (@$pids) {
		for my $fd (glob "/proc/$pid/fd/*") {
			my $target = readlink $fd;
			push @touched, { pid => $pid, what => 'fd', target => $target }
				if defined $target && $target =~ m{\Q$self->{'repo'}\E/database/};
		}
		open(my $maps, '<', "/proc/$pid/maps") or next;
		while (my $line = <$maps>) {
			push @touched, { pid => $pid, what => 'maps', target => $line }
				if $line =~ m{\Q$self->{'repo'}\E/database/};
		}
		close $maps;
	}

	my $ns = namespace_state();
	my $fenced = $ENV{'JAWNOS_QA_NO_NS'} ? 0 : (($ns->{'pid'} && $ns->{'net'}) ? 1 : 0);
	return {
		pids           => scalar @$pids,
		live_db        => $live_db,
		live_db_exists => (-e $live_db ? 1 : 0),
		live_opens     => \@touched,
		namespace      => $ns,
		ro_repo        => $self->{'ro_repo'} || 0,
		fenced         => $fenced,
		ok             => (@touched ? 0 : 1),
	};
}

sub bind_live_read_only {
	my ($self) = @_;
	my $ok = _bind_live_read_only($self->{'repo'});
	$self->{'ro_repo'} = $ok;
	return $ok;
}

sub private_tmp {
	my ($self) = @_;
	return _private_tmp();
}

# ---------------------------------------------------------------------------
# a client
# ---------------------------------------------------------------------------

sub ua {
	my ($self, %opt) = @_;
	my $jar = Mojo::UserAgent::CookieJar->new;
	my $ua = Mojo::UserAgent->new(
		insecure => 1,
		max_redirects => $opt{'redirects'} || 0,
		request_timeout => $opt{'timeout'} || 45,
		cookie_jar => $jar,
	);
	$ua->max_response_size($opt{'max_size'} || 8 * 1024 * 1024);
	return ($ua, $jar);
}

sub url_for {
	my ($self, $path) = @_;
	my $p = $self->{'ports'};
	return "https://127.0.0.1:$p->{'working'}" . ($path // '/');
}

# A live-boot loopback session: the documented way a machine in someone's
# hands opens its own manager. It is a resident session, so citizen-tier
# routes answer 403 and the route layer expects that.
sub session {
	my ($self, %opt) = @_;
	my ($ua, $jar) = $self->ua(%opt);
	my $tx = $ua->get($self->url_for('/manager'));
	my $body = $tx->res->body // '';
	$self->{'session'} = {
		ua => $ua, jar => $jar,
		status => $tx->res->code,
		ok => ($body =~ /id="start_menu_toggle"/ ? 1 : 0),
		bytes => length $body,
	};
	return $self->{'session'};
}

sub get {
	my ($self, $path, %opt) = @_;
	my $ua = ($self->{'session'} && $self->{'session'}->{'ua'}) || $self->ua();
	my $t0 = time;
	my $tx = $ua->get($self->url_for($path));
	my $elapsed = time - $t0;
	my $body = $tx->res->body // '';
	return {
		path    => $path,
		status  => $tx->res->code,
		body    => ($opt{'body'} ? $body : ''),
		bytes   => length $body,
		seconds => $elapsed,
		error   => $tx->error ? ($tx->error->{'message'} // 'error') : undef,
	};
}

# ---------------------------------------------------------------------------
# live-house observation (informational; the live app writes constantly)
# ---------------------------------------------------------------------------

sub live_snapshot {
	my ($self) = @_;
	my @files = (
		"$self->{'repo'}/database/jawnos.db",
		"$self->{'repo'}/database/jawnos.db-wal",
		"$self->{'repo'}/config.json",
	);
	my %out;
	for my $f (@files) {
		my @st = stat($f);
		$out{$f} = @st ? { inode => $st[1], size => $st[7], mtime => $st[9] } : undef;
	}
	return \%out;
}

1;
