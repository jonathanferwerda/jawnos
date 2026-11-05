#!/usr/bin/env perl
# refresh-probe - catch a WebUI page reload and say what caused it.
#
# Two inputs become one timeline:
#   * scripts/tools/refresh-probe.js, pasted into the page, posts one JSON
#     record per event to http://127.0.0.1:<port>/event
#   * this process tails ~/manager.log and fingerprints the code tree, so a
#     reload can be lined up with a restart, a sync pass or a revision move.
#
#   perl scripts/tools/refresh-probe.pl --port 45997
#   perl scripts/tools/refresh-probe.pl --report [--browser dump.json]
#
# If the page's https origin blocks the http loopback beacon (WebKit can), the
# browser ring is still complete: save jawnosRefreshProbe.dump() to a file and
# pass it with --browser.
#
# The browser half is fire-and-forget text/plain, so no CORS preflight. Run
# this on the same machine as the browser (127.0.0.1 from the page's view).
# Read-only with respect to the tree: records go to --out.
use strict;
use warnings;
use Mojolicious::Lite;
use JSON::PP;
use Getopt::Long qw(GetOptionsFromArray);
use Time::HiRes qw(time);
use File::Find qw(find);
use POSIX qw(strftime);

my %o = (
	port => 45997,
	log  => (($ENV{HOME} || '.') . '/manager.log'),
	out  => '/tmp/refresh-probe.jsonl',
	tree => (($ENV{HOME} || '.') . '/jawnos'),
	browser => '',
);
GetOptionsFromArray(\@ARGV, \%o, 'port=i', 'log=s', 'out=s', 'tree=s', 'browser=s', 'report', 'quiet')
	or die "usage: $0 [--port N] [--log FILE] [--out FILE] [--tree DIR] [--quiet] | --report\n";
@ARGV = ();

my @EV;
sub time_ms { return int(time() * 1000) }

sub append {
	my ($rec) = @_;
	$rec->{'t'} = time_ms() unless defined $rec->{'t'};
	open(my $fh, '>>', $o{'out'}) or die "$o{out}: $!";
	print {$fh} JSON::PP->new->canonical->encode($rec), "\n";
	close $fh;
	print STDERR strftime('%H:%M:%S', localtime), " $rec->{'src'} $rec->{'ev'}"
		. (defined $rec->{'kind'} ? " $rec->{'kind'}" : '') . "\n" unless $o{'quiet'};
}

sub run_report {
	my @rows;
	if (-r $o{'out'}) {
		open(my $fh, '<', $o{'out'}) or die "refresh-probe: $o{out}: $!\n";
		while (defined(my $line = <$fh>)) {
			chomp $line;
			my $e = eval { JSON::PP->new->decode($line) };
			push @rows, $e if $e && ref $e eq 'HASH' && defined $e->{'t'};
		}
		close $fh;
	}
	# A page that could not reach the loopback collector still keeps its ring.
	# Save jawnosRefreshProbe.dump() to a file and pass that file here.
	if (length($o{'browser'} || '') && -r $o{'browser'}) {
		local $/;
		open(my $bf, '<', $o{'browser'}) or die "refresh-probe: $o{browser}: $!\n";
		my $raw = <$bf>;
		close $bf;
		my $arr = eval { JSON::PP->new->decode($raw) };
		push @rows, grep { ref $_ eq 'HASH' && defined $_->{'t'} } @{$arr}
			if $arr && ref $arr eq 'ARRAY';
	}
	die "refresh-probe: no events (looked at $o{out} and $o{browser})\n" unless @rows;
	@rows = sort { $a->{'t'} <=> $b->{'t'} } @rows;

	my (%by, %loads);
	foreach my $r (@rows) {
		my $key = ($r->{'src'} || '?') . ':' . ($r->{'ev'} || '?');
		$by{$key}++;
		$loads{$r->{'nav'} || '?'}++ if ($r->{'ev'} || '') eq 'page_load';
	}
	print "refresh-probe report over ", scalar(@rows), " events\n";
	print "  window: ", strftime('%Y-%m-%d %H:%M:%S', localtime($rows[0]{'t'} / 1000)),
		" .. ", strftime('%H:%M:%S', localtime($rows[-1]{'t'} / 1000)), "\n";
	print "  page loads:", join(' ', map { " $_=$loads{$_}" } sort keys %loads), "\n" if %loads;
	print "  events:\n";
	print "    $_ = $by{$_}\n" foreach sort { $by{$b} <=> $by{$a} } keys %by;

	my $n = 0;
	for my $i (0 .. $#rows) {
		my $r = $rows[$i];
		next unless ($r->{'ev'} || '') eq 'page_load' && ($r->{'nav'} || '') eq 'reload';
		$n++;
		print "\nreload #$n at ", strftime('%H:%M:%S', localtime($r->{'t'} / 1000)),
			" gap=", (defined $r->{'since_prev_ms'} ? int($r->{'since_prev_ms'} / 1000) . 's' : '?'),
			" auto=", (defined $r->{'autoreload'} ? $r->{'autoreload'} : '?'), "\n";
		my @before = grep { $_->{'t'} < $r->{'t'} && $_->{'t'} >= $r->{'t'} - 15000 } @rows[0 .. $i - 1];
		@before = @before[ -8 .. -1 ] if @before > 8;
		foreach my $b (@before) {
			printf "    -%5.1fs %s %s%s\n", ($r->{'t'} - $b->{'t'}) / 1000,
				($b->{'src'} || '?'),
				($b->{'ev'} || '?'),
				(defined $b->{'kind'} ? " ($b->{'kind'})" : '');
		}
		if ($r->{'prev_events'} && ref $r->{'prev_events'} eq 'ARRAY') {
			print "    browser remembered (older session):\n";
			foreach my $p (@{ $r->{'prev_events'} }) {
				printf "      %s %s\n", ($p->{'t'} ? strftime('%H:%M:%S', localtime($p->{'t'} / 1000)) : '?'),
					($p->{'ev'} || '?');
			}
		}
	}
	print "\nno page reloads in the capture\n" unless $n;
}

if ($o{'report'}) { run_report(); exit 0; }

# ---- collector ------------------------------------------------------------
post '/event' => sub {
	my $c = shift;
	my $raw = $c->req->body || '';
	my $rec = length $raw ? eval { JSON::PP->new->decode($raw) } : undef;
	if ($rec && ref $rec eq 'HASH') {
		$rec->{'recv'} = time_ms();
		$rec->{'src'} ||= 'browser';
		append($rec);
	}
	$c->rendered(204);
};
get '/' => { text => "refresh-probe collecting to $o{out}\n" };

# ---- the server side of the same timeline ---------------------------------
my $TAIL;
open($TAIL, '<', $o{'log'}) or die "$o{log}: $!";
seek($TAIL, 0, 2);

my %KIND = (
	qr/BLE listener closed/ => 'ble_listener_closed',
	qr/BLE listener (?:error|held)/ => 'ble_listener_error',
	qr/worker spawn/        => 'worker_spawn',
	qr/sync pull/           => 'sync_pull',
	qr/remote sync:/        => 'remote_sync',
	qr/\[error\]/           => 'log_error',
	qr/\[warn\]/            => 'log_warn',
	qr/restart/i            => 'restart',
	qr/revision/            => 'revision',
);
my %seen;
app->log->level('error');
Mojo::IOLoop->recurring(0.5 => sub {
	while (defined(my $line = <$TAIL>)) {
		my ($kind) = map { $KIND{$_} } grep { $line =~ $_ } keys %KIND;
		next unless $kind;
		$seen{$kind}++;
		# a flood would bury the reload: keep a sample of the chatty kinds
		next if $kind =~ /^(?:ble_listener_closed|worker_spawn)$/ && $seen{$kind} % 25 != 1;
		append({ src => 'perl', ev => 'log', kind => $kind, text => substr($line, 0, 220) });
	}
});

my $TREE_AT = 0;
Mojo::IOLoop->recurring(10 => sub {
	my ($newest, $name) = (0, '');
	find({ no_chdir => 1, wanted => sub {
		my $path = $File::Find::name;
		return unless -f $path;
		return if $path =~ /\.(?:db|db-wal|db-shm|log|pyc)$/;
		my $m = (stat($path))[9] || 0;
		if ($m > $newest) { ($newest, $name) = ($m, $path); }
	} }, map { "$o{tree}/$_" } grep { -d "$o{tree}/$_" } qw(lib perl templates public/js));
	return unless $newest && $newest != $TREE_AT;
	$TREE_AT = $newest;
	(my $rel = $name) =~ s{^\Q$o{tree}\E/}{};
	append({ src => 'perl', ev => 'tree_changed', file => $rel, at => $newest });
});

print "refresh-probe: listening on http://127.0.0.1:$o{port}/event -> $o{out}\n";
print "  tailing $o{log}; watching $o{tree}\n";
app->start('daemon', '-l', "http://127.0.0.1:$o{port}");
