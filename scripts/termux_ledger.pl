#!/usr/bin/perl
# The M0 dependency ledger for docs/leaving-termux.md.
#
#   perl scripts/termux_ledger.pl            print the ledger
#   perl scripts/termux_ledger.pl --check    fail when the dependency grew
#   perl scripts/termux_ledger.pl --quiet    only print a --check failure
#   perl scripts/termux_ledger.pl --record   print a %BASELINE stanza to paste
#
# Every Android device command is reached through subs::device_cmd /
# subs::device_run / subs::device_bin in subroutines.pl (the "one door"), so the
# call sites name the command without the "termux-" prefix. This script finds
# both shapes:
#
#   - a wrapped site:  device_run('battery-status', ...)   -> wrapped
#   - a raw site:      `termux-battery-status`             -> todo
#
# A raw site is then either a command (counted, and the ratchet fails if the
# count grows) or a mention that is not an invocation: the Termux package and
# repository names, a comment, or a documented exception. The counts in
# %BASELINE are decremented in the same commit as each migration (M1 removes a
# command, so its baseline count goes down by its call sites).
#
# The tool and module tables answer M0's "confirm which tools are real": they
# are read from scripts/jawnos_deps.pl and cross-checked against the tree, and
# the decision column is the intent M3 executes.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);

my $root = abs_path("$FindBin::Bin/..");
my %opt = map { $_ => 1 } @ARGV;

if ($opt{'--help'} || $opt{'-h'}) {
	print <<'USAGE';
perl scripts/termux_ledger.pl            print the ledger
perl scripts/termux_ledger.pl --check    exit 1 when a count exceeds %BASELINE
perl scripts/termux_ledger.pl --quiet    only print a --check failure
perl scripts/termux_ledger.pl --record   print a %BASELINE stanza to paste
USAGE
	exit 0;
}

# --- what a termux-* token means --------------------------------------------

# Package and repository names: identity references, not device calls. M4
# removes them, and docs/leaving-termux.md says not to relocate them before
# then.
my %PACKAGE = map { $_ => 1 } qw(app api shared exec am bootstrap installer terminal emulator tools packages);

# Known non-commands that still start with the prefix.
my %IGNORED = (
	'tts-spea' => 1,   # a truncated pkill pattern in scripts/manager_killer.pl
);

# The replacement each command gets under M1 (subs::device_call names, in the
# order docs/leaving-termux.md migrates them).
my %REPLACEMENT = (
	'battery-status'       => 'battery.status',
	'notification'         => 'notification.post',
	'notification-list'    => 'notification.list',
	'notification-remove'  => 'notification.remove',
	'toast'                => 'toast.show',
	'clipboard-get'        => 'clipboard.get',
	'clipboard-set'        => 'clipboard.set',
	'wake-lock'            => 'power.wake_lock',
	'wake-unlock'          => 'power.wake_unlock',
	'sms-send'             => 'sms.send',
	'sms-list'             => 'sms.list',
	'location'             => 'location.current',
	'telephony-call'       => 'telephony.dial',
	'telephony-deviceinfo' => 'telephony.deviceinfo',
	'call-log'             => 'telephony.call_log',
	'tts-speak'            => 'speech.speak',
	'camera-photo'         => 'camera.photo',
	'fingerprint'          => 'auth.fingerprint',
	'volume'               => 'audio.volume',
	'torch'                => 'hardware.torch',
	'media-player'         => 'media.player',
	'share'                => 'share.send',
	'open'                 => 'open.url',
	'contact-list'         => 'contact.list',
	'microphone-record'    => 'audio.record',
);

# A call site that deliberately stays raw in M0, with the reason. The ratchet
# allows exactly these and no others.
my @EXEMPT = (
	[ 'scripts/jawnos_setup.pl', 'termux-open',
	  'the first-run wizard runs before the tree is serving and loads no runtime module; M3 replaces it' ],
);

# --- the intent for each tool (M3 decides the build, this records the plan) ---
my %TOOL_INTENT = (
	'perl'      => 'bundle (M3)',
	'openssl'   => 'bundle (M3)',
	'sqlite3'   => 'bundle (M3)',
	'argon2'    => 'bundle, or OpenSSL 3.2+ KDF (M3)',
	'curl'      => 'bundle (M3)',
	'ssh'       => 'bundle (M3)',
	'sshpass'   => 'bundle (M3)',
	'autossh'   => 'drop? confirm: nothing in the tree spawns it (M3)',
	'rsync'     => 'bundle (M3)',
	'zip'       => 'bundle (M3)',
	'git'       => 'drop if the first run ships an asset, else bundle (M3)',
	'ffmpeg'    => 'replace with MediaCodec (M3)',
	'convert'   => 'replace with BitmapFactory (M3)',
	'tesseract' => 'replace with ML Kit (M3)',
	'espeak'    => 'replace with TextToSpeech (M3)',
	'sox'       => 'replace with MediaCodec (M3)',
	'tmux'      => 'drop? confirm: nothing in the tree spawns it (M3)',
	'qrencode'  => 'bundle: the QR share spawns it (M3)',
	'zbarimg'   => 'drop? confirm: nothing in the tree spawns it (M3)',
	'node'      => 'drop from the runtime: only dev scripts spawn it (M3)',
	'cpanm'     => 'drop; the runtime ships built modules (M3)',
);

# Modules that need cross-building for Android rather than a .pm tree.
my %XS_MODULES = map { $_ => 1 } qw(
	Sereal::Encoder Sereal::Decoder CryptX Crypt::KeyDerivation
	Crypt::AuthEnc::GCM Crypt::PK::X25519 Crypt::PK::Ed25519 Crypt::PRNG
	Net::SSLeay LWP::Protocol::https URI::Encode DBD::SQLite
);

# The compiled runtime that has no entry in jawnos_deps.pl yet.
my @MODULE_EXTRA = ('DBD::SQLite');   # reached through Mojo::SQLite / Minion

# --- the PTY and the runtime, the other two things M0 counts ---------------
my @PTY_PATTERNS = (
	[ qr/terminal_pty_runner/,      'the master launches President on a PTY' ],
	[ qr/type\s*=>\s*["']pty["']/,   'ReadWriteFork runs the tree on a pty' ],
	[ qr/pty_log_fh/,               'the pty tee into ~/pty.log' ],
	[ qr/\bisatty\b/,               'isatty' ],
	[ qr/TIOCGWINSZ/,               'window size ioctl' ],
	[ qr{/dev/ptmx},                'pty allocation' ],
);

# --- baseline ---------------------------------------------------------------
# Recorded by this script's --record output at v0.1.1611, the M0 commit. Counts
# only go down from here; a new call site, command, tool or module fails
# --check. The lists catch a swap that leaves the totals unchanged.
my %BASELINE = (
	'version'  => '0.1.1611',
	'raw' => 0,
	'exempt' => 1,
	'logical' => 35,
	'commands' => 24,
	'tools' => 21,
	'modules' => 39,
	'pty' => 12,
	'command_list' => 'termux-battery-status termux-call-log termux-camera-photo termux-clipboard-get termux-contact-list termux-fingerprint termux-location termux-media-player termux-microphone-record termux-notification termux-notification-list termux-notification-remove termux-open termux-share termux-sms-list termux-sms-send termux-telephony-call termux-telephony-deviceinfo termux-toast termux-torch termux-tts-speak termux-volume termux-wake-lock termux-wake-unlock',
	'tool_list' => 'argon2 autossh convert cpanm curl espeak ffmpeg git node openssl perl qrencode rsync sox sqlite3 ssh sshpass tesseract tmux zbarimg zip',
	'module_list' => 'Authen::SASL Crypt::AuthEnc::GCM Crypt::KeyDerivation Crypt::PK::Ed25519 Crypt::PK::X25519 Crypt::PRNG Crypt::Simple CryptX DBD::SQLite Data::UUID Date::Parse Digest::SHA Email::Stuffer Encode File::Slurp File::Type HTML::Strip Hash::Merge LWP::Protocol::https LWP::UserAgent MIME::Parser Math::BigInt Minion Minion::Backend::SQLite Mojo::IOLoop::ReadWriteFork Mojo::SQLite Mojolicious::Lite Mojolicious::Plugin::RenderFile Net::IMAP::Client Net::SSLeay Number::Format SQL::Abstract Sereal::Decoder Sereal::Encoder Time::Duration Time::Piece URI::Encode URI::Escape WWW::Mechanize',
);

# --- scanning ---------------------------------------------------------------

sub code_file {
	my ($f) = @_;
	return 0 if $f =~ m{^(?:\.shots|releases|node_modules|vendor)/};
	return 0 if $f =~ m{/\.stage/};
	return 1 if $f =~ /\.(?:pl|pm|js|ep|sh)$/;
	return 1 if $f =~ m{^scripts/[^/]+$};   # jawn-bt and friends
	return 1 if $f eq 'jawn';
	return 0;
}

sub tracked_files {
	my @out;
	if (open(my $g, '-|', 'git', '-C', $root, 'ls-files')) {
		while (my $l = <$g>) {
			chomp $l;
			push @out, $l if length $l && code_file($l);
		}
		close $g;
	}
	return @out if @out;

	# Not a git tree (the runtime may ship as an asset): walk it instead.
	require File::Find;
	no warnings 'once';
	File::Find::find({
		no_chdir => 1,
		wanted => sub {
			my $path = $File::Find::name;
			$path =~ s/^\Q$root\E\///;
			return if $File::Find::dir =~ m{/(?:\.git|node_modules|\.pio|build)(?:/|$)};
			push @out, $path if -f $path && code_file($path);
		},
	}, $root);
	return sort @out;
}

sub trim {
	my ($s, $max) = @_;
	$s = '' unless defined $s;
	$s =~ s/\s+/ /g;
	$s =~ s/^\s+//;
	$s =~ s/\s+$//;
	$s = substr($s, 0, $max) . '...' if $max && length($s) > $max;
	return $s;
}

# A line that can actually spawn something, as opposed to prose or a data row.
sub is_execution {
	my ($line) = @_;
	return $line =~ /`|system\s*\(|\bexec\s*\(|\bqx\b|\bcommand -v\b|\|-|-\|/ ? 1 : 0;
}

my @files = tracked_files();
my @sites;
my @bridge;
my @mentions;
my %tool_files;
my %tool_exec;
my %module_files;
my @pty;
my @shebangs;

my @tools = deps_tools();
my @modules = (deps_modules(), @MODULE_EXTRA);

for my $file (@files) {
	next if $file eq 'scripts/termux_ledger.pl';   # the counter, not a caller
	open(my $fh, '<', "$root/$file") or next;
	my $n = 0;
	while (my $line = <$fh>) {
		$n++;
		my $comment = $line =~ /^\s*(?:#|\/\/|\/\*|\*|<!--)/;

		if ($line =~ /^#!\s*\S*com\.termux/) {
			push @shebangs, { file => $file, line => $n };
		}
		foreach my $p (@PTY_PATTERNS) {
			push @pty, { file => $file, line => $n, what => $p->[1] } if $line =~ $p->[0];
		}
		foreach my $t (@tools) {
			next if index($line, $t) < 0 || $line !~ /\b\Q$t\E\b/;
			$tool_files{$t}->{$file} = 1;
			$tool_exec{$t}->{$file} = 1 if is_execution($line);
		}
		foreach my $m (@modules) {
			next if $module_files{$m} && $module_files{$m}->{$file};
			next unless $line =~ /^\s*(?:use|require)\b/;
			$module_files{$m}->{$file} = 1 if $line =~ /\b\Q$m\E\b/;
		}

		# A wrapped call site names the command without the prefix.
		while (!$comment && $line =~ /device_(?:run|cmd|bin)\s*\(\s*(['"])([a-z0-9][a-z0-9-]*)\1/g) {
			push @sites, {
				file => $file, line => $n, command => "termux-$2",
				how => 'wrapped', text => trim($line, 72),
			};
		}

		# An M1 bridge call answers from the app instead of spawning anything.
		while (!$comment && $line =~ /device_call\s*\(\s*(['"])([A-Za-z0-9_.-]+)\1/g) {
			push @bridge, { file => $file, line => $n, method => $2 };
		}

		# Anything still spelling out the prefix.
		while ($line =~ /termux-([a-z0-9][a-z0-9-]*)/g) {
			my $full = "termux-$1";
			my $class = $comment ? 'comment'
				: $PACKAGE{$1} ? 'package'
				: $IGNORED{$1} ? 'other'
				: is_execution($line) ? 'command'
				: 'doc';
			push @mentions, { file => $file, line => $n, name => $full, class => $class };
			next unless $class eq 'command';
			push @sites, {
				file => $file, line => $n, command => $full,
				how => 'todo', text => trim($line, 72),
			};
		}
	}
	close $fh;
}

@sites = sort { $a->{'file'} cmp $b->{'file'} || $a->{'line'} <=> $b->{'line'} } @sites;

my %exempt = map { $_->[0] . ' ' . $_->[1] => $_->[2] } @EXEMPT;
my @raw = grep { $_->{'how'} eq 'todo' } @sites;
my @exempt_sites = grep { $exempt{ $_->{'file'} . ' ' . $_->{'command'} } } @raw;
my @unwrapped = grep { !$exempt{ $_->{'file'} . ' ' . $_->{'command'} } } @raw;

my %cmd_count;
$cmd_count{$_->{'command'}}++ foreach @sites;
my @command_list = sort keys %cmd_count;
my @tool_list = sort @tools;
my @module_list = sort @modules;

my %now = (
	'raw'      => scalar @unwrapped,
	'exempt'   => scalar @exempt_sites,
	'logical'  => scalar @sites,
	'commands' => scalar @command_list,
	'tools'    => scalar @tools,
	'modules'  => scalar @modules,
	'pty'      => scalar @pty,
);

my %list_now = (
	'command_list' => join(' ', @command_list),
	'tool_list'    => join(' ', @tool_list),
	'module_list'  => join(' ', @module_list),
);

# --- check ------------------------------------------------------------------

if ($opt{'--check'}) {
	my @fail;
	foreach my $key (qw(raw exempt logical commands tools modules pty)) {
		my $base = $BASELINE{$key};
		next unless defined $base;
		push @fail, "$key: now $now{$key}, baseline $base" if $now{$key} > $base;
	}
	foreach my $key (qw(command_list tool_list module_list)) {
		my %base = map { $_ => 1 } split ' ', ($BASELINE{$key} || '');
		my @added = grep { !$base{$_} } split ' ', $list_now{$key};
		push @fail, "$key gained: @added" if @added;
	}
	if (@fail) {
		print "termux_ledger: dependency grew\n";
		print "  $_\n" foreach @fail;
		print "  a new call site must go through subs::device_* (subroutines.pl);\n";
		print "  a new tool or module is a decision for M3, not an accident\n";
		exit 1;
	}
	print "termux_ledger: ok ($now{logical} call sites, $now{raw} unwrapped, $now{commands} commands)\n"
		unless $opt{'--quiet'};
	exit 0;
}

# --- record -----------------------------------------------------------------

if ($opt{'--record'}) {
	print "my %BASELINE = (\n";
	printf "\t'version'  => '%s',\n", ($BASELINE{'version'} || 'VERSION');
	printf "\t'%s' => %d,\n", $_, $now{$_} foreach qw(raw exempt logical commands tools modules pty);
	printf "\t'%s' => '%s',\n", $_, $list_now{$_} foreach qw(command_list tool_list module_list);
	print ");\n";
	exit 0;
}

# --- report -----------------------------------------------------------------

my $version = '?';
if (open(my $vf, '<', "$root/VERSION")) {
	my $v = <$vf>;
	close $vf;
	if (defined $v) { chomp $v; $version = $v; }
}

sub table {
	my ($head, $rows) = @_;
	my $out = '| ' . join(' | ', @$head) . " |\n";
	$out .= '| ' . join(' | ', map { '---' } @$head) . " |\n";
	$out .= '| ' . join(' | ', map { defined $_ ? $_ : '' } @$_) . " |\n" foreach @$rows;
	return $out;
}

print "# Termux dependency ledger\n\n";
print "Tree: $root\n\n";
print "Version: $version   Baseline: v$BASELINE{'version'}\n\n";

print "## Baseline counts\n\n";
print table(
	[ 'Measure', 'Now', 'Baseline', 'Status' ],
	[ map {
		[ $_, $now{$_}, $BASELINE{$_}, ($now{$_} > $BASELINE{$_}) ? 'GREW' : 'ok' ]
	} qw(raw exempt logical commands tools modules pty) ],
);

print "\n## Device call sites (" . scalar(@sites) . ")\n\n";
print table(
	[ 'File:line', 'Command', 'Replacement (M1)', 'How', 'Line' ],
	[ map {
		[ "$_->{'file'}:$_->{'line'}", $_->{'command'},
		  ($REPLACEMENT{ $_->{'command'} =~ s/^termux-//r } || 'review'), $_->{'how'}, $_->{'text'} ]
	} @sites ],
);

if (@exempt_sites) {
	print "\n## Exempt call sites (" . scalar(@exempt_sites) . ")\n\n";
	print table(
		[ 'File:line', 'Command', 'Why' ],
		[ map {
			[ "$_->{'file'}:$_->{'line'}", $_->{'command'}, $exempt{ $_->{'file'} . ' ' . $_->{'command'} } ]
		} @exempt_sites ],
	);
}

print "\n## Bridge call sites (" . scalar(@bridge) . ")\n\n";
print table(
	[ 'File:line', 'Method' ],
	[ map { [ "$_->{'file'}:$_->{'line'}", $_->{'method'} ] } @bridge ],
);

my @not_calls = grep { $_->{'class'} ne 'command' } @mentions;
my %mention_meaning = (
	'package' => 'Termux package/repository identity (M4)',
	'comment' => 'a comment; nothing executes it',
	'doc' => 'prose (help or UI text); update it with the command in M1',
	'other' => 'a known non-command',
);
print "\n## Non-call mentions (" . scalar(@not_calls) . ")\n\n";
print table(
	[ 'File:line', 'Token', 'Kind', 'Meaning' ],
	[ map {
		[ "$_->{'file'}:$_->{'line'}", $_->{'name'}, $_->{'class'},
		  ($mention_meaning{ $_->{'class'} } || '') ]
	} sort { $a->{'file'} cmp $b->{'file'} || $a->{'line'} <=> $b->{'line'} } @not_calls ],
);

print "\n## Tools (" . scalar(@tools) . ")\n\n";
print table(
	[ 'Tool', 'Spawned in', 'Decision' ],
	[ map {
		my @x = sort keys %{ $tool_exec{$_} || {} };
		my @m = sort keys %{ $tool_files{$_} || {} };
		my $used = @x ? scalar(@x) . ' files: ' . join(', ', @x[0 .. ($#x < 2 ? $#x : 2)]) . ($#x > 2 ? ' (+' . ($#x - 2) . ')' : '')
			: @m ? 'no spawn; only mentioned (' . scalar(@m) . ' files)'
			: 'nothing outside scripts/jawnos_deps.pl';
		[ $_, $used, ($TOOL_INTENT{$_} || 'review (M3)') ]
	} @tools ],
);

print "\n## Modules (" . scalar(@modules) . ")\n\n";
print table(
	[ 'Module', 'Used by', 'Decision' ],
	[ map {
		my @f = sort keys %{ $module_files{$_} || {} };
		my $used = @f ? scalar(@f) . ' files: ' . join(', ', @f[0 .. ($#f < 1 ? $#f : 1)]) . ($#f > 1 ? ' (+' . ($#f - 1) . ')' : '')
			: 'reached indirectly (no direct use)';
		[ $_, $used, $XS_MODULES{$_} ? 'cross-build for Android (M3)' : 'ship as a .pm tree (M3)' ]
	} @modules ],
);

print "\n## PTY and session touch points (" . scalar(@pty) . ")\n\n";
print table(
	[ 'File:line', 'What' ],
	[ map { [ "$_->{'file'}:$_->{'line'}", $_->{'what'} ] } @pty ],
);

print "\n## Runtime touch points\n\n";
if (@shebangs) {
	print "* Termux-runtime shebangs (M3 removes them):\n";
	print "  * `$_->{'file'}` line $_->{'line'}\n" foreach @shebangs;
}
else {
	print "* No Termux-runtime shebangs in the tracked tree.\n";
}
print "* The runtime itself is not in this tree: `scripts/jawnos_deps.pl` names the installer's tools and modules, and `assets/bootstrap*` lives in the app repo.\n";

# --- reading jawnos_deps.pl ------------------------------------------------

sub deps_source {
	open(my $fh, '<', "$root/scripts/jawnos_deps.pl") or return '';
	local $/;
	my $src = <$fh>;
	close $fh;
	return $src || '';
}

sub deps_tools {
	my $src = deps_source();
	my @found;
	while ($src =~ /\{\s*cmd\s*=>\s*['"]([^'"]+)['"]/g) {
		push @found, $1;
	}
	return @found;
}

sub deps_modules {
	my $src = deps_source();
	return () unless $src =~ /my \@modules\s*=\s*qw\((.*?)\);/s;
	return grep { length } split ' ', $1;
}
