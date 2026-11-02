#!/usr/bin/perl

# qa/coding_night/recover.pl - read a night's report and say what to do next.
#
#   perl qa/coding_night/recover.pl                 # the newest run, printed
#   perl qa/coding_night/recover.pl --run DIR       # a named run dir
#   perl qa/coding_night/recover.pl --note          # re-file the failure note
#   perl qa/coding_night/recover.pl --rollback      # run that run's rollback.sh
#
# Nothing is written by default. `--note` files a JawnOS note through the app's
# own route (status open), and `--rollback` runs the generated rollback script.
# Both are explicit; a plain read only prints a summary that can be pasted into
# Zed for the next agent.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use Cwd qw(abs_path);
use JSON::PP;

my %opt = (
	run      => undef,
	root     => undef,
	repo     => undef,
	note     => 0,
	rollback => 0,
	live_url => undef,
	ticket   => undef,
);
my @argv = @ARGV;
while (my $arg = shift @argv) {
	if ($arg eq '--run')       { $opt{'run'} = shift @argv; next }
	if ($arg =~ /^--run=(.*)$/) { $opt{'run'} = $1; next }
	if ($arg eq '--root')      { $opt{'root'} = shift @argv; next }
	if ($arg =~ /^--root=(.*)$/) { $opt{'root'} = $1; next }
	if ($arg eq '--repo')      { $opt{'repo'} = shift @argv; next }
	if ($arg =~ /^--repo=(.*)$/) { $opt{'repo'} = $1; next }
	if ($arg eq '--live-url')  { $opt{'live_url'} = shift @argv // ''; next }
	if ($arg =~ /^--live-url=(.*)$/) { $opt{'live_url'} = $1; next }
	if ($arg eq '--ticket')    { $opt{'ticket'} = shift @argv // ''; next }
	if ($arg =~ /^--ticket=(.*)$/) { $opt{'ticket'} = $1; next }
	if ($arg eq '--note')      { $opt{'note'} = 1; next }
	if ($arg eq '--rollback')  { $opt{'rollback'} = 1; next }
	if ($arg eq '--help' || $arg eq '-h') {
		print "qa/coding_night/recover.pl [--run DIR] [--root DIR] [--note] [--rollback]\n";
		exit 0;
	}
	die "qa/coding_night/recover.pl: unknown argument: $arg\n";
}

my $repo = $opt{'repo'} || abs_path("$FindBin::Bin/../..") || '.';
my $root = $opt{'root'} || (($ENV{'HOME'} || '') . '/jawnos-qa');
$root = abs_path($root) || $root;

my $dir = $opt{'run'};
unless (defined $dir && length $dir) {
	$dir = newest_run($root);
	unless (defined $dir) {
		print "No nightly runs under $root/coding\n";
		exit 0;
	}
}
$dir = abs_path($dir) || $dir;
unless (-d $dir) {
	print "No such run directory: $dir\n";
	exit 1;
}

my $report = read_json("$dir/report.json");
my $failure = -f "$dir/failure.md" ? slurp("$dir/failure.md") : '';

my $summary = run_summary($dir, $report, $failure);

# --rollback is the only path that changes the checkout here, and it delegates
# to the script the runner wrote so the human action and the automatic one use
# the same guard.
if ($opt{'rollback'}) {
	my $script = "$dir/rollback.sh";
	unless (-f $script) {
		print "No rollback.sh in $dir; nothing was done.\n";
		exit 2;
	}
	unless (-x $script) {
		print "rollback.sh exists but is not executable; run: sh $script\n";
		exit 2;
	}
	print "Running $script\n\n";
	my $rc = system('sh', $script);
	print "\nrollback.sh exited " . ($rc >> 8) . "\n";
	exit($rc >> 8);
}

if ($opt{'note'}) {
	my $title = 'Nightly failed: ' . failure_title($dir, $report);
	my $body = $title . "\n\n" . $summary;
	my $live = live_url($repo, $opt{'live_url'});
	my $ticket = ticket_url($repo, $opt{'ticket'});
	my $ok = eval {
		post_note(live_url => $live, ticket => $ticket, text => $body,
			category => 'jawnos', status => 'open');
		1;
	};
	if ($ok) {
		print "Filed a JawnOS note (status open): $title\n";
	}
	else {
		print "The failure note could not be filed: " . ($@ || 'unknown') . "\n";
		exit 1;
	}
	exit 0;
}

print $summary;
exit 0;

# ---------------------------------------------------------------------------

sub newest_run {
	my ($root) = @_;
	my $coding = "$root/coding";
	opendir(my $dh, $coding) or return undef;
	my @dirs = sort grep { !/^\.\.?$/ && -d "$coding/$_" } readdir $dh;
	closedir $dh;
	return @dirs ? "$coding/$dirs[-1]" : undef;
}

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh> // '';
	close $fh;
	return $text;
}

sub read_json {
	my ($path) = @_;
	return undef unless -f $path;
	my $text = slurp($path);
	my $data = eval { JSON::PP->new->utf8->decode($text) };
	return ref $data eq 'HASH' ? $data : undef;
}

sub failure_title {
	my ($dir, $report) = @_;
	my $runs = ($report && ref $report->{'runs'} eq 'ARRAY') ? $report->{'runs'} : [];
	for my $run (reverse @{$runs}) {
		my $status = $run->{'status'} // '';
		next if $status eq 'green' || $status eq 'pending';
		return ($run->{'title'} || ('note ' . ($run->{'note_id'} // '')));
	}
	return 'run ' . ($report->{'stamp'} // $dir);
}

sub run_summary {
	my ($dir, $report, $failure) = @_;
	my $out = "JawnOS coding nightly recovery\n";
	$out .= "run: $dir\n";
	unless ($report) {
		$out .= "No report.json in this run directory.\n";
		$out .= $failure ? "\n$failure\n" : '';
		$out .= "\nNext action: inspect the run directory; there is no report to trust.\n";
		return $out;
	}

	my $runs = ref $report->{'runs'} eq 'ARRAY' ? $report->{'runs'} : [];
	my $failed_run;
	for my $run (reverse @{$runs}) {
		my $status = $run->{'status'} // '';
		if ($status ne 'green' && $status ne 'pending') { $failed_run = $run; last }
	}
	my $ok = $report->{'ok'} ? 'PASS' : 'ATTENTION';
	$out .= 'stamp: ' . ($report->{'stamp'} // '') . " · result: $ok\n";
	$out .= 'generated: ' . ($report->{'generated'} // '') . "\n";
	my $default_push = (ref $report->{'push_repo'} eq 'HASH' ? ($report->{'push_repo'}->{'effective'} // '') : '');
	$out .= 'push target: ' . (($failed_run && $failed_run->{'push_target'}) || $default_push || 'origin') . "\n";
	$out .= 'rollback tag: ' . (($failed_run && $failed_run->{'rollback_tag'}) || $report->{'rollback_tag'} || '(none)') . "\n";
	$out .= 'rollback script: ' . ($report->{'rollback_script'} || "$dir/rollback.sh") . "\n\n";

	if (!@{$runs}) {
		$out .= "No note was worked on.\n";
	}
	else {
		$out .= "What ran:\n";
		for my $run (@{$runs}) {
			$out .= '  [' . ($run->{'n'} // '?') . '] ' . ($run->{'title'} // '(untitled)')
				. ' - ' . ($run->{'status'} // 'unknown') . "\n";
			$out .= '      worktree: ' . ($run->{'worktree'} // '') . "\n";
			$out .= '      branch: ' . ($run->{'branch'} // '') . "\n";
			$out .= '      suite exit: ' . ($run->{'suite_exit'} // '-')
				. ' · merged: ' . ($run->{'merged'} ? 'yes' : 'no')
				. ' · restarted: ' . ($run->{'restarted'} ? 'yes' : 'no')
				. ' · health 200: ' . ($run->{'health_ok'} ? 'yes' : 'no') . "\n";
			if ($run->{'rolled_back'} eq 'yes') {
				$out .= '      rolled back: yes · reset '
					. (defined $run->{'rollback_reset_ok'} ? ($run->{'rollback_reset_ok'} ? 'ok' : 'FAILED') : '?')
					. ' · restart ' . (defined $run->{'rollback_restart_ok'} ? ($run->{'rollback_restart_ok'} ? 'ok' : 'FAILED') : '?')
					. ' · health 200 ' . (defined $run->{'rollback_health_ok'} ? ($run->{'rollback_health_ok'} ? 'yes' : 'no') : 'not checked') . "\n";
			}
			$out .= '      error: ' . ($run->{'error'} // '') . "\n" if length($run->{'error'} // '');
		}
	}

	if ($failed_run) {
		$out .= "\nWhat failed:\n";
		$out .= '  status: ' . ($failed_run->{'status'} // 'unknown') . "\n";
		$out .= '  note: ' . ($failed_run->{'note_id'} // '') . ' ' . ($failed_run->{'title'} // '') . "\n";
		$out .= '  error: ' . ($failed_run->{'error'} // '') . "\n";
		$out .= '  worktree: ' . ($failed_run->{'worktree'} // '') . "\n";
		my @failing = failing_lines($failed_run->{'suite_log'});
		if (@failing) {
			$out .= "  failing test lines:\n";
			$out .= "    $_\n" for @failing;
		}
		$out .= "\nNext action: ";
		my $tag = $failed_run->{'rollback_tag'} || $report->{'rollback_tag'} || '';
		if (($failed_run->{'rolled_back'} // '') eq 'yes') {
			if (defined $failed_run->{'rollback_restart_ok'} && !$failed_run->{'rollback_restart_ok'}) {
				$out .= "URGENT: main is on $tag but the rollback restart was refused."
					. " Restart the house by hand, then rerun the night.\n";
			}
			elsif (defined $failed_run->{'rollback_health_ok'} && !$failed_run->{'rollback_health_ok'}) {
				$out .= "main is on $tag, but health is not 200. Check the house, then rerun."
					. " To retry the full recovery: sh $dir/rollback.sh\n";
			}
			else {
				$out .= "main is back on $tag and healthy. The note stays open; fix the failure and rerun.\n";
			}
		}
		else {
			$out .= "main was not merged by this note. Inspect the worktree, fix the failure, and rerun."
				. " To put main on the backup tag anyway: sh $dir/rollback.sh\n";
		}
	}
	else {
		$out .= "\nWhat failed:\n  nothing; the night is green.\n";
	}

	if (length $failure) {
		$out .= "\nfailure.md:\n";
		$out .= $failure;
		$out .= "\n" unless $failure =~ /\n\z/;
	}
	return $out;
}

sub failing_lines {
	my ($path) = @_;
	return () unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return ();
	my @lines;
	while (my $line = <$fh>) {
		chomp $line;
		push @lines, $line if $line =~ /^\s*(?:not\s+ok\b|#\s+Failed test|#\s+Looks like|FAILED\b|Error:)/i;
	}
	close $fh;
	@lines = @lines[0 .. 19] if scalar @lines > 20;
	return @lines;
}

sub config {
	my ($repo) = @_;
	my $path = "$repo/config.json";
	return {} unless -f $path;
	my $text = slurp($path);
	my $cfg = eval { JSON::PP->new->utf8->decode($text) };
	return ref $cfg eq 'HASH' ? $cfg : {};
}

sub live_url {
	my ($repo, $given) = @_;
	return $given if defined $given && length $given;
	my $cfg = config($repo);
	my $port = $cfg->{'working_port'} || 3000;
	return "https://127.0.0.1:$port";
}

sub ticket_url {
	my ($repo, $given) = @_;
	return $given if defined $given;
	my $path = "$repo/.shots/ticket.txt";
	return '' unless -f $path;
	my $url = slurp($path);
	$url =~ s/^\s+|\s+$//g;
	return $url;
}

sub post_note {
	my (%a) = @_;
	require Mojo::UserAgent;
	my $ua = Mojo::UserAgent->new(insecure => 1, max_redirects => 5, request_timeout => 30);
	if (defined $a{'ticket'} && length $a{'ticket'}) {
		my $tx = $ua->get($a{'ticket'});
		die "the ticket did not mint a session (" . ($tx->res->code // 'no answer') . ")\n"
			unless $tx->res->is_success;
	}
	my $tx = $ua->post($a{'live_url'} . '/manager/note_save' => form => {
		text     => $a{'text'},
		category => $a{'category'} || 'jawnos',
		status   => $a{'status'} || 'open',
	});
	die "note_save answered " . ($tx->res->code // 'no answer') . "\n"
		unless $tx->res->is_success;
	return $tx->res->json || {};
}
