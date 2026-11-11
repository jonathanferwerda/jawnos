#!/usr/bin/perl
# A read-only security audit for this tree (and, with --host, this machine).
#
#   perl scripts/security_audit.pl                 # tree + host
#   perl scripts/security_audit.pl --check         # tree only (fast, no host probes)
#   perl scripts/security_audit.pl --json          # machine-readable report
#   perl scripts/security_audit.pl --write-report  # also writes a report the QA panel reads
#
# --write-report leaves $JAWNOS_QA_ROOT/reports/security/<stamp>/ (report.json and
# status.txt) when the QA root is set, which is what Configure -> Plat -> QA reads;
# otherwise it falls back to ~/.presidency/security/<stamp>/.
#
# Exit 0 when no *new* finding at or above --fail-on (default high); 1 otherwise.
# A finding listed in qa/security/allowlist.json is reported as known and does
# not fail the run, so an accepted design (the calculator's numeric eval, the
# terminal's named JS command, the self-signed peer rail) does not hide a new
# instance of the same class.
#
# The audit never writes the tree, never prints a secret, and treats a missing
# tool as a skip rather than a finding.

use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP;
use POSIX qw(strftime);
use Getopt::Long;

my %opt = (check => 0, json => 0, host => 1, 'write-report' => 0, 'fail-on' => 'high', root => '');
GetOptions(\%opt, 'check', 'json', 'host!', 'write-report', 'fail-on=s', 'root=s') or die "usage: $0 [--check] [--json] [--no-host] [--write-report] [--fail-on high|medium|low] [--root DIR]\n";
$opt{host} = 0 if $opt{check};

my $root = $opt{root} ? abs_path($opt{root}) : abs_path(File::Spec->catdir(dirname(abs_path($0)), '..'));
chdir $root or die "security_audit: chdir $root: $!\n";

my %rank = (critical => 4, high => 3, medium => 2, low => 1, info => 0);
my $threshold = $rank{ lc($opt{'fail-on'}) } // $rank{high};
my @findings;

sub finding($severity, $id, $area, $title, %rest) {
	push @findings, {
		severity => $severity,
		id => $id,
		area => $area,
		title => $title,
		path => ($rest{path} // ''),
		line => ($rest{line} // 0),
		evidence => ($rest{evidence} // ''),
		fix => ($rest{fix} // ''),
	};
}

sub capture {
	my @cmd = @_;
	open(my $fh, '-|', @cmd) or return (127, '');
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return ($? >> 8, $out);
}

sub redact($text) {
	$text = '' unless defined $text;
	$text =~ s/[A-Za-z0-9+\/]{40,}/<redacted>/g;
	$text =~ s/(password|secret|token|key)\s*[:=]\s*\S+/$1=<redacted>/gi;
	$text =~ s/\s+$//;
	return length($text) > 220 ? substr($text, 0, 217) . '...' : $text;
}

sub is_tracked($path) {
	return 0 unless -e $path;
	my ($rc, $out) = capture('git', '-C', $root, 'ls-files', '--', $path);
	return ($rc == 0 && $out =~ /\S/) ? 1 : 0;
}

# The lines of one tracked file, memoised: a rule that needs context around a
# grep hit reads the file once, not once per hit.
my %source_line_cache;
sub source_lines($path) {
	return $source_line_cache{$path} if exists $source_line_cache{$path};
	open(my $fh, '<', $path) or return $source_line_cache{$path} = [];
	my @lines = <$fh>;
	close $fh;
	return $source_line_cache{$path} = \@lines;
}

# Git grep over tracked source. Returns (path, line, text) triples.
# A pathspec the tree does not have is a skip, not a fatal: the same script runs
# on a partial tree (a fixture, or a distribution without firmware), and git
# grep exits 128 when one pathspec matches nothing.
sub grep_tree($pattern, @paths) {
	if (@paths) {
		my @have = grep { -e $_ } @paths;
		return () unless @have;
		@paths = @have;
	}
	my @args = ('git', '-C', $root, 'grep', '-n', '-I', '-E', '--', $pattern);
	push @args, @paths if @paths;
	my ($rc, $out) = capture(@args);
	return () if $rc > 1;
	my @hits;
	for my $line ( split /\n/, $out ) {
		my ($path, $num, $text) = split /:/, $line, 3;
		next unless defined $text;
		push @hits, [ $path, $num + 0, $text ];
	}
	return @hits;
}

# --- tree: code execution, injection, auth, paths, secrets -----------------
for my $hit ( grep_tree('eval\s+[\$@"\x27]', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	finding('high', 'perl.eval.string', 'rce',
		'string eval in the service layer', path => $path, line => $line,
		evidence => redact($text),
		fix => 'use a block eval or a parsed table; never eval request data');
}

for my $hit ( grep_tree('(system|exec)\s*\(\s*["\x27][^"\x27]*\$|`[^`]*\$', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /\b(?:quote|shell_quote|path_is_within|console_command)\b/;
	next unless $text =~ /\$c->param|\$c->req|\$q->param|\$data->|\$ENV/;
	finding('high', 'perl.shell.request', 'command injection',
		'request data near a shell execution', path => $path, line => $line,
		evidence => redact($text),
		fix => 'list-form system/exec, or subs::shell_quote() every interpolated word');
}

# A base64 value on a shell command line is a shell metacharacter away from RCE,
# and the value is often a database row or a device's answer. MIME::Base64 does
# the same work in-process (and is portable: BSD base64 has no -w 0).
for my $hit ( grep_tree('`[^`]*base64[^`]*`', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	finding('high', 'perl.shell.base64', 'command injection',
		'base64 is piped through a shell command', path => $path, line => $line,
		evidence => redact($text),
		fix => 'encode/decode with MIME::Base64 in Perl; never interpolate a value into a shell');
}

# A double-quoted string handed to system()/exec() is parsed by a shell. A
# variable inside it is not quoted for that shell, so a path or a name holding
# `$(...)` runs there. List form, or a string built from quote()ed words, is the
# shape that is safe.
for my $hit ( grep_tree('(system|exec)[[:space:]]*\([[:space:]]*"[^)]*[$]', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	finding('high', 'perl.shell.double_quoted', 'command injection',
		'a double-quoted command string reaches system/exec', path => $path, line => $line,
		evidence => redact($text),
		fix => 'use list-form system()/exec(), or build the string from subs::shell_quote()d words');
}

# terminal_name escapes a short list of characters, not a shell word: `;`, a
# backtick, `$`, `<` and `>` survive it. It is a display helper; a shell argument
# must be quote()ed or, better, passed as a list.
for my $hit ( grep_tree('terminal_name[^;]*`|`[^`]*terminal_name|(system|exec)[[:space:]]*\([^)]*terminal_name', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	finding('high', 'perl.shell.terminal_name', 'command injection',
		'terminal_name is used as a shell quoter', path => $path, line => $line,
		evidence => redact($text),
		fix => 'use list-form system()/exec(), or subs::shell_quote() every interpolated word');
}

# A leading & once meant Perl eval in run_command. It is not a command, and the
# strings that reach it come from requests, settings and automations.
for my $hit ( grep_tree('eval[[:space:]]*\{[[:space:]]*\$command', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	finding('high', 'perl.eval.command', 'rce',
		'a command string is eval\'d as Perl', path => $path, line => $line,
		evidence => redact($text),
		fix => 'refuse a leading &, or run the text through the tracked subprocessor only');
}

# am broadcast is the phone's intent rail; its words are data a board or a
# message supplies, so a shell string around them is an injection.
for my $hit ( grep_tree('`[^`]*am[[:space:]]+broadcast', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	finding('high', 'perl.shell.am_broadcast', 'command injection',
		'am broadcast runs inside a shell string', path => $path, line => $line,
		evidence => redact($text),
		fix => 'pass am an argv list (open -|, system)');
}

# A backtick command concatenated with a string runs only the first fragment:
# `sqlite3 ` . quote($db) ran sqlite3 with no database, then discarded the path.
# Build the whole command in a variable, then run that variable.
for my $hit ( grep_tree('`[^`]*[[:space:]]`[[:space:]]*\.', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	next if $path =~ m{^perl/help\.pl$};
	finding('high', 'perl.shell.concat', 'command injection',
		'a backtick command is concatenated instead of run as a string', path => $path, line => $line,
		evidence => redact($text),
		fix => 'build the command in a variable, then `$cmd`; never `cmd ` . arg');
}

# Mojo::Util::quote escapes only " and \: it is not a shell quoter. `$()`, a
# backtick or `;` inside its result still runs in the shell, so a command built
# with it is injectable however tidy the call looks. subs::shell_quote wraps the
# whole word in single quotes; list form avoids the shell entirely.
for my $hit ( grep_tree('(^|[^_[:alnum:]:])(&?quote)[[:space:]]*\(', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	next if $text =~ /(?:shell|un|url|html|xml|sql|path|js)_quote[[:space:]]*\(/;
	next unless $text =~ /`|(?:system|exec)[[:space:]]*\(/;
	finding('high', 'perl.shell.mojo_quote', 'command injection',
		'Mojo::Util::quote is used to build a shell command', path => $path, line => $line,
		evidence => redact($text),
		fix => 'use subs::shell_quote(), or list-form system()/exec()');
}

for my $hit ( grep_tree('read_file\s*\(\s*\$c->param|`tail \$', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /path_is_within|path_name|shell_quote\(/;
	finding('high', 'perl.path.request', 'path traversal',
		'a caller-named path reaches a file operation', path => $path, line => $line,
		evidence => redact($text),
		fix => 'resolve with path_is_within/path_name and shell-quote the shell word');
}

for my $hit ( grep_tree('db_(query|select|insert|update|delete)\s*\(\s*"[^"]*\$', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	my ($sql) = $text =~ /db_(query|select|insert|update|delete)\s*\(\s*"((?:[^"\\]|\\.)*)"/;
	next unless defined $sql && $sql =~ /\$(c->param|c->req|q->param|data->|ENV)/;
	finding('high', 'perl.sql.interpolated', 'sql injection',
		'a value is interpolated into SQL', path => $path, line => $line,
		evidence => redact($text),
		fix => 'bind with ? placeholders');
}

for my $hit ( grep_tree('\beval\s*\(', 'public/js') ) {
	my ($path, $line, $text) = @{$hit};
	next if $path =~ m{/(?:jquery|jquery-ui|vendor)[^/]*\.js$};
	finding('high', 'js.eval', 'xss/rce',
		'eval in browser code', path => $path, line => $line,
		evidence => redact($text),
		fix => 'route a named command; keep at most the explicit terminalJs eval');
}

for my $hit ( grep_tree('eval\(data\[', 'public/js') ) {
	finding('critical', 'js.console.eval', 'xss/rce',
		'a websocket frame is evaluated', path => $hit->[0], line => $hit->[1],
		evidence => redact($hit->[2]), fix => 'send {cmd,args}; route it in 00_console_router.js');
}

# The console channel carries command objects now ({cmd,args}). A JS string in
# `console =>` is the legacy shape the router only tolerates for the old static
# instructions, so a new one is a regression, not a style choice.
for my $hit ( grep_tree('console\\s*=>\\s*["\x27]', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	finding('high', 'perl.console.string', 'rce',
		'a console send is still a JS string', path => $path, line => $line,
		evidence => redact($text),
		fix => 'send &Websocket::console_command(\'name\', ...args) and add the name to 00_console_router.js');
}

for my $hit ( grep_tree('innerHTML\s*=\s*[^"\x27]', 'public/js') ) {
	my ($path, $line, $text) = @{$hit};
	next if $path =~ m{/(?:jquery|jquery-ui|vendor)[^/]*\.js$};
	finding('low', 'js.innerhtml.dynamic', 'xss',
		'dynamic innerHTML assignment', path => $path, line => $line,
		evidence => redact($text), fix => 'use text()/escape, or a fixed template');
}

for my $hit ( grep_tree('return \(\$stored \? 0 : 1\)', 'lib') ) {
	finding('high', 'auth.peer.unsigned', 'authentication',
		'a keyless peer is accepted without a signature', path => $hit->[0], line => $hit->[1],
		evidence => redact($hit->[2]), fix => 'require X-Peer-Signature on every peer request');
}

# A signatorial is a name, not a secret (it rides in query strings and mirror
# lists). peer_verify's trust-on-first-contact is for the handshake that enrols
# a machine; the rails that deploy, restart, read the database, drive the
# keyboard or hand out tickets must name a key already pinned on the roster.
# Exceptions: the primitive and its strict wrapper, app_peer_ok (it matches the
# offered key against a stored one), and the address directory's first boot.
for my $hit ( grep_tree('peer_verify\(\$c', 'lib', 'perl') ) {
	my ($path, $line, $text) = @{$hit};
	next if $text =~ /^\s*#/;
	next if $path =~ m{^(?:lib/JawnOS/Domain/Crypt\.pm|lib/JawnOS/Manager/Part30\.pm|perl/AddressDirectory\.pl)$};
	# The remote_auth_test handshake is the signed door that pins a new machine.
	next if $path =~ m{/manager_misc14\.pm$} && $text =~ /\$cand/;
	my $lines = &source_lines($path);
	my $from = $line > 7 ? $line - 7 : 1;
	my $near = join '', @{$lines}[ $from - 1 .. $line - 1 ];
	next if $near =~ /pubkey/;
	finding('high', 'peer.no_pin', 'authentication',
		'a peer rail verifies a signature without a pinned key', path => $path, line => $line,
		evidence => redact($text),
		fix => 'require $rm->{\'pubkey\'} before peer_verify; keep TOFU to the enrolment handshake');
}

for my $hit ( grep_tree('-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----', '.') ) {
	my ($path, $line, $text) = @{$hit};
	next if $path =~ m{^(?:t/|docs/|\.secrets/)};
	finding('critical', 'secret.private_key', 'secrets',
		'a private key is tracked', path => $path, line => $line,
		evidence => redact($text), fix => 'remove it from history and rotate the key');
}

for my $hit ( grep_tree('(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,})', '.') ) {
	my ($path, $line, $text) = @{$hit};
	next if $path =~ m{^(?:t/|docs/|qa/|\.secrets/)};
	finding('high', 'secret.token', 'secrets',
		'a live-looking token is tracked', path => $path, line => $line,
		evidence => redact($text), fix => 'remove it and rotate the credential');
}

for my $hit ( grep_tree('->insecure\(1\)|setInsecure\(', 'lib', 'perl', 'jp', 'jt', 'jw') ) {
	my ($path, $line, $text) = @{$hit};
	finding('medium', 'tls.insecure', 'transport',
		'certificate verification is disabled', path => $path, line => $line,
		evidence => redact($text), fix => 'pin the house CA/certificate');
}

for my $hit ( grep_tree('curl[^|]*\|\s*(ba)?sh|wget[^|]*\|\s*(ba)?sh|cpanmin\.us\|perl[^|]*\|\s*perl', 'scripts', 'desktop', 'qa') ) {
	my ($path, $line, $text) = @{$hit};
	finding('medium', 'supply.pipe_to_shell', 'supply chain',
		'a download is piped into a shell', path => $path, line => $line,
		evidence => redact($text), fix => 'fetch a pinned artifact and verify its digest first');
}

# The fixes that must stay fixed.
my $wallet = -e 'desktop/install-wallet.sh' ? do { local $/; open(my $fh, '<', 'desktop/install-wallet.sh') or die; <$fh> } : '';
finding('high', 'supply.wallet.unpinned', 'supply chain', 'the wallet installer is not digest-pinned')
	unless $wallet =~ /SPARROW_PINNED_VERSION/ && $wallet =~ /pinned_sha256/ && $wallet !~ /\byay\s+-S\s+sparrow/;

for my $pair ( [ 'jt/jt_02_lorawan_radio_gps.ino', 'ota_refused' ], [ 'jw/jw_03_setup.ino', 'ota_refused' ] ) {
	next unless -e $pair->[0];
	my $text = do { local $/; open(my $fh, '<', $pair->[0]) or die; <$fh> };
	finding('high', 'firmware.ota.auth', 'firmware', 'the ESP32 OTA accepts an unsigned upload', path => $pair->[0])
		unless index($text, $pair->[1]) >= 0 && index($text, 'authorization') >= 0;
}
my $pico = -e 'jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino'
	? do { local $/; open(my $fh, '<', 'jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino') or die; <$fh> } : '';
finding('high', 'firmware.ota.token', 'firmware', 'the Pico OTA accepts an empty token', path => 'jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino')
	if $pico ne '' && $pico !~ /authorization\.length\(\)\s*>\s*0/;

finding('high', 'git.tracked.secret_file', 'secrets', 'the live SSH secrets file is tracked', path => '.secrets/ssh.txt')
	if is_tracked('.secrets/ssh.txt');
finding('high', 'git.tracked.config', 'secrets', 'the live config is tracked', path => 'config.json')
	if is_tracked('config.json');
finding('high', 'git.tracked.database', 'secrets', 'the live database is tracked')
	if is_tracked('database/jawnos.db');

# --- host checks -----------------------------------------------------------
if ($opt{host}) {
	my ($rc, $passwd) = capture('cat', '/etc/passwd');
	if ($rc == 0) {
		for my $line ( split /\n/, $passwd ) {
			my @f = split /:/, $line;
			finding('critical', 'host.uid0', 'privilege', 'a second UID 0 account exists',
				evidence => "$f[0] uid=$f[2]", fix => 'remove or lock the account')
				if @f > 2 && $f[2] == 0 && $f[0] ne 'root';
		}
	}
	finding('high', 'host.ld_preload', 'persistence', '/etc/ld.so.preload exists', path => '/etc/ld.so.preload',
		fix => 'inspect and remove it; nothing on this house needs it')
		if -e '/etc/ld.so.preload';

	my ($sr, $sshd) = capture('sshd', '-T');
	if ($sr == 0) {
		finding('high', 'host.ssh.password', 'authentication', 'sshd accepts passwords')
			if $sshd =~ /^passwordauthentication yes$/mi;
		finding('high', 'host.ssh.root_login', 'authentication', 'sshd permits root login with a password')
			if $sshd =~ /^permitrootlogin yes$/mi;
		finding('high', 'host.ssh.empty', 'authentication', 'sshd permits empty passwords')
			if $sshd =~ /^permitemptypasswords yes$/mi;
	}

	for my $file ( glob('/root/.ssh/authorized_keys /home/*/.ssh/authorized_keys') ) {
		next unless -f $file;
		open(my $fh, '<', $file) or next;
		while (my $line = <$fh>) {
			next unless $line =~ /^\s*(?:ssh-|ecdsa-|sk-)/;
			my ($comment) = $line =~ /\s(\S+)\s*$/;
			$comment //= '(no comment)';
			next if $comment =~ /^(?:jawnos-agent|jawnos-dev|root\@ks5|jawn\@)/;
			finding('medium', 'host.ssh.key', 'authentication', 'an unknown SSH key is authorised',
				path => $file, evidence => $comment, fix => 'remove the key if it is not a known device');
		}
		close $fh;
	}

	my ($lr, $listen) = capture('ss', '-lntup');
	if ($lr == 0) {
		my %public;
		while ($listen =~ /^(?:tcp|udp)\s+\S+\s+\S+\s+(\S+):(\d+)\s+/mg) {
			my ($addr, $port) = ($1, $2);
			$public{$port} = 1 if $addr =~ /^(?:0\.0\.0\.0|\*|\[::\]|::)$/;
		}
		my %known = map { $_ => 1 } qw(25 85 111 443 3128 8006 8022 45545 45546 45550);
		for my $port ( sort { $a <=> $b } keys %public ) {
			next if $known{$port};
			finding('low', 'host.public_listener', 'exposure', "a new public listener is $port", evidence => "port $port", fix => 'bind loopback or add a firewall rule');
		}
	}

	my ($fr, $fw) = capture('iptables', '-S', 'PVEFW-HOST-IN');
	if ($fr == 0 && length $fw) {
		for my $port ( 111, 25, 3128 ) {
			finding('medium', 'host.firewall.public', 'exposure', "port $port has no public DROP in PVEFW-HOST-IN", evidence => "port $port", fix => 'add IN DROP for this port')
				unless $fw =~ /--dport $port -j DROP/;
		}
	}

	my ($dr, $dpkg) = capture('dpkg', '-V');
	if ($dr == 0) {
		my @changed = grep { /^\?\?5/ } split /\n/, $dpkg;
		for my $line (@changed[ 0 .. ($#changed > 9 ? 9 : $#changed) ]) {
			finding('low', 'host.package.changed', 'integrity', 'a package file differs from its manifest', evidence => redact($line), fix => 'review the file; reinstall the package if unexpected');
		}
	}

	for my $spec ( [ 'database/jawnos.db', 0600 ], [ '.secrets/ssh.txt', 0600 ], [ 'config.json', 0600 ] ) {
		next unless -e $spec->[0];
		my $mode = (stat($spec->[0]))[2] & 07777;
		finding('medium', 'host.perm.loose', 'secrets', "$spec->[0] is group/world readable", path => $spec->[0], evidence => sprintf('%04o', $mode), fix => sprintf('chmod %04o %s', $spec->[1], $spec->[0]))
			if $mode & 0077;
	}
}

# --- allowlist and report --------------------------------------------------
my $allow_file = 'qa/security/allowlist.json';
my @allow;
if (-e $allow_file) {
	my $text = do { local $/; open(my $fh, '<', $allow_file) or die; <$fh> };
	my $list = eval { JSON::PP->new->decode($text) };
	@allow = grep { ref $_ eq 'HASH' && $_->{'id'} } @{ ref $list eq 'ARRAY' ? $list : [] };
}
for my $f ( @findings ) {
	$f->{'known'} = 0;
	for my $a ( @allow ) {
		next unless $a->{'id'} eq $f->{'id'};
		next if defined $a->{'path'} && index($f->{'path'}, $a->{'path'}) < 0;
		next if defined $a->{'line'} && $a->{'line'} != $f->{'line'};
		$f->{'known'} = 1;
		last;
	}
}

my %count = (critical => 0, high => 0, medium => 0, low => 0, info => 0, known => 0);
for my $f ( @findings ) {
	$count{ $f->{'severity'} }++;
	$count{known}++ if $f->{'known'};
}
my @new = grep { !$_->{'known'} && ($rank{ $_->{'severity'} } // 0) >= $threshold } @findings;
my $summary = { %count, new_fail => scalar(@new), fail_on => lc($opt{'fail-on'}), ok => (@new ? 0 : 1) };

my $report = {
	generated => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
	root => $root,
	mode => $opt{check} ? 'tree' : 'tree+host',
	findings => \@findings,
	summary => $summary,
};

if ($opt{'write-report'}) {
	my $qa_root = $ENV{'JAWNOS_QA_ROOT'} || $ENV{'QA_ROOT'} || '';
	my $stamp = strftime('%Y%m%dT%H%M%SZ', gmtime);
	my $status = @new ? 'failed' : 'ok';
	my $dir = length $qa_root
		? File::Spec->catdir($qa_root, 'reports', 'security', $stamp)
		: File::Spec->catdir($ENV{'HOME'} // '/tmp', '.presidency', 'security', $stamp);
	make_path($dir);
	# The same document is both the machine-readable audit and the run the QA
	# panel renders: a title, a status, and one table of findings.
	my @rows = map {
		[ $_->{'severity'}, $_->{'area'}, $_->{'title'},
		  ($_->{'path'} || '') . ($_->{'line'} ? ":$_->{'line'}" : ''),
		  { text => ($_->{'known'} ? 'known' : 'new'), tone => ($_->{'known'} ? 'note' : 'bad') } ]
	} sort { $rank{$b->{'severity'}} <=> $rank{$a->{'severity'}} || $a->{'id'} cmp $b->{'id'} } @findings;
	my $doc = {
		%$report,
		kind => 'security',
		schedule => 'nightly',
		status => $status,
		ok => (@new ? 0 : 1),
		stamp => $stamp,
		generated => time,
		title => 'Security audit',
		note => scalar(@findings) . ' findings, ' . $count{known} . ' known, ' . scalar(@new) . ' new',
		sections => [ { title => 'Findings', columns => [ 'Severity', 'Area', 'Finding', 'Where', 'State' ], rows => \@rows } ],
	};
	open(my $fh, '>', "$dir/report.json") or die "security_audit: $dir/report.json: $!\n";
	print $fh JSON::PP->new->canonical->pretty->encode($doc);
	close $fh;
	open(my $st, '>', "$dir/status.txt") or die "security_audit: $dir/status.txt: $!\n";
	print $st "$status\n";
	close $st;
	# keep the last 14 days, the same window every other QA kind keeps
	if (length $qa_root) {
		my $kind_dir = File::Spec->catdir($qa_root, 'reports', 'security');
		if (opendir(my $dh, $kind_dir)) {
			my $cutoff = time - 14 * 24 * 60 * 60;
			for my $old ( grep { /^\d{8}T\d{6}Z$/ && -d "$kind_dir/$_" } readdir $dh ) {
				my ($y, $mo, $d, $h, $mi, $se) = $old =~ /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;
				my $epoch = eval { require Time::Local; Time::Local::timegm($se, $mi, $h, $d, $mo - 1, $y) };
				next unless defined $epoch;
				require File::Path;
				File::Path::remove_tree("$kind_dir/$old") if $epoch < $cutoff;
			}
			closedir $dh;
		}
	}
	$report->{'report_dir'} = $dir;
}

if ($opt{json}) {
	print JSON::PP->new->canonical->pretty->encode($report);
}
else {
	print "security audit: $report->{mode} at $report->{generated}\n";
	for my $f ( sort { $rank{$b->{'severity'}} <=> $rank{$a->{'severity'}} || $a->{'id'} cmp $b->{'id'} } @findings ) {
		next if $f->{'severity'} eq 'info';
		printf "  %-8s %-28s %s%s%s\n",
			$f->{'known'} ? 'known' : $f->{'severity'},
			$f->{'id'},
			$f->{'title'},
			$f->{'path'} ? " ($f->{'path'}" . ($f->{'line'} ? ":$f->{'line'}" : '') . ')' : '',
			$f->{'evidence'} ? " - $f->{'evidence'}" : '';
	}
	printf "  %d findings (%d known), %d new at or above %s\n",
		scalar(@findings), $count{known}, scalar(@new), lc($opt{'fail-on'});
	print $report->{'report_dir'} ? "  report: $report->{'report_dir'}\n" : '';
}

exit(@new ? 1 : 0);
