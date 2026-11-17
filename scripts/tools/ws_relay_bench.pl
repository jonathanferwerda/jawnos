#!/usr/bin/perl
# ws_relay_bench - compare the one-socket relay with the per-app shape under a
# chosen load.
#
#   perl scripts/tools/ws_relay_bench.pl --shape both --apps 8 --senders 4 \
#        --seconds 10 --rate 200 --media-kb 64 --repeat 2
#
# Read-only against the live tree: every socket it binds lives in a temp
# directory, it never touches run/ws or a running worker, and the tree's own
# config is not read. Each shape gets the same frames, the same receiver loop
# (one Mojo::IOLoop per process, as the websocket worker runs it) and the same
# senders; the difference is only one listener versus one per app.
#
# Frames are encoded once, so the number compares the socket shape and the
# receiver's decode, not the sender's JSON work. `message` is incompressible
# bytes, so ZSTD cannot make a large frame disappear.
#
# Output per run: delivered frames/s, MiB/s, the sender's write-time p50/p99,
# and a probe frame's round-trip p50/p99 (a small frame on app 0 every 100 ms,
# which is what a notification feels like behind a burst).
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time sleep);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use Sereal::Encoder;
use Sereal::Decoder;
use JSON::PP;

my %o = (
	shape         => 'both',
	apps          => 8,
	senders       => 4,
	seconds       => 10,
	rate          => 200,
	'media-kb'    => 64,
	repeat        => 2,
	'frame-bytes' => 512,
	dir           => '',
);
GetOptions(\%o,
	'shape=s', 'apps=i', 'senders=i', 'seconds=i', 'rate=i',
	'media-kb=i', 'repeat=i', 'frame-bytes=i', 'dir=s',
) or die usage();
$o{'seconds'} = 2 if $o{'seconds'} < 2;
$o{'apps'} = 2 if $o{'apps'} < 2;
$o{'senders'} = 1 if $o{'senders'} < 1;
$o{'repeat'} = 1 if $o{'repeat'} < 1;

sub usage {
	return "usage: $0 [--shape single|multi|both] [--apps N] [--senders N] "
		. "[--seconds N] [--rate FRAMES_PER_SENDER] [--media-kb N] "
		. "[--frame-bytes N] [--repeat N] [--dir DIR]\n";
}

my $enc = Sereal::Encoder->new({ compress => Sereal::Encoder::SRL_ZSTD(), compress_level => 3 });
my $dec = Sereal::Decoder->new();

sub percentile {
	my ($list, $p) = @_;
	return 0 unless @$list;
	my @s = sort { $a <=> $b } @$list;
	my $i = int(($p / 100) * $#s + 0.5);
	return $s[$i];
}

# A blob with no repetition: a photo or a video frame is already compressed and
# must not be made cheap by ZSTD.
sub random_blob {
	my ($n) = @_;
	my $s = '';
	$s .= pack('C*', map { int(rand 256) } 1 .. 4096) while length($s) < $n;
	return substr($s, 0, $n);
}

sub packets_for {
	my ($apps, $small_bytes, $media_bytes) = @_;
	my $media = random_blob($media_bytes);
	my %p;
	for my $app (@$apps) {
		my $small = $enc->encode({ app => $app, uuid => 'bench', message => ('x' x $small_bytes) });
		my $big   = $enc->encode({ app => $app, uuid => 'bench', message => $media });
		$p{$app} = {
			small => pack('N', length $small) . $small,
			big   => pack('N', length $big) . $big,
		};
	}
	return \%p;
}

sub wait_for_paths {
	my ($paths, $seconds) = @_;
	my $deadline = time + $seconds;
	while (time < $deadline) {
		my $ready = 1;
		for my $p (@$paths) { $ready = 0 unless -S $p }
		return 1 if $ready;
		sleep 0.05;
	}
	return 0;
}

sub run_shape {
	my ($shape, $run) = @_;
	my $dir = $o{'dir'} ? "$o{'dir'}/$shape-$run" : tempdir("jawnos-ws-bench-$shape-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	make_path($dir);
	my @apps = map { "app$_" } 0 .. $o{'apps'} - 1;
	my @paths = $shape eq 'single' ? ("$dir/ws") : map { "$dir/$_" } @apps;
	my $packets = packets_for(\@apps, $o{'frame-bytes'}, $o{'media-kb'} * 1024);

	# ---- the receiver: the worker's loop, one Mojo process ------------------
	my $report = "$dir/receiver.json";
	my $rpid = fork();
	die "fork: $!" unless defined $rpid;
	if ($rpid == 0) {
		require Mojo::IOLoop;
		my %stats = (frames => 0, bytes => 0, probes => 0);
		for my $path (@paths) {
			Mojo::IOLoop->server({ path => $path } => sub {
				my ($loop, $stream, $id) = @_;
				$stream->high_water_mark(64 * 1024 * 1024);
				my $buf = '';
				$stream->on(read => sub {
					my ($s, $bytes) = @_;
					$buf .= $bytes;
					while (length($buf) >= 4) {
						my $len = unpack('N', substr($buf, 0, 4));
						last if length($buf) < 4 + $len;
						substr($buf, 0, 4, '');
						my $blob = substr($buf, 0, $len, '');
						$stats{'frames'}++;
						$stats{'bytes'} += 4 + $len;
						my $m = eval { $dec->decode($blob) } || {};
						if ($m->{'probe'}) {
							$stats{'probes'}++;
							my $r = $enc->encode({ seq => $m->{'seq'} });
							$s->write(pack('N', length $r) . $r);
						}
					}
				});
			});
		}
		Mojo::IOLoop->timer($o{'seconds'} + 3 => sub {
			write_file($report, JSON::PP->new->canonical->encode(\%stats));
			Mojo::IOLoop->stop;
		});
		Mojo::IOLoop->start;
		exit 0;
	}
	die "the receiver did not bind the bench paths\n" unless wait_for_paths(\@paths, 5);

	# ---- senders: the production write, pre-encoded -------------------------
	my @senders;
	for my $i (0 .. $o{'senders'} - 1) {
		my $pid = fork();
		die "fork: $!" unless defined $pid;
		if ($pid == 0) {
			my %sock;
			for my $path (@paths) {
				$sock{$path} = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path) or exit 9;
				$sock{$path}->autoflush(1);
			}
			my @lat;
			my ($writes, $bytes) = (0, 0);
			my $end = time + $o{'seconds'};
			my $next = time;
			my $n = 0;
			my $slot = $i % scalar(@apps);
			while (time < $end) {
				# the chatty app: every visit is the large frame, one in @apps
				my $app = $apps[$slot];
				my $path = $paths[ $shape eq 'single' ? 0 : $slot ];
				my $kind = $slot == 0 ? 'big' : 'small';
				my $packet = $packets->{$app}{$kind};
				my $t0 = time;
				my $off = 0;
				while ($off < length $packet) {
					my $w = syswrite($sock{$path}, $packet, length($packet) - $off, $off);
					last unless defined $w;
					$off += $w;
				}
				push @lat, (time - $t0) * 1000;
				$writes++;
				$bytes += $off;
				$n++;
				$slot = ($slot + 1) % scalar(@apps);
				$next += 1 / $o{'rate'};
				my $wait = $next - time;
				sleep($wait) if $wait > 0;
			}
			write_file("$dir/sender.$i.json", JSON::PP->new->canonical->encode({
				writes => $writes, bytes => $bytes,
				p50 => percentile(\@lat, 50), p99 => percentile(\@lat, 99),
			}));
			exit 0;
		}
		push @senders, $pid;
	}

	# ---- the probe: a control frame on app 0, once every 100 ms -------------
	my $probe_rtt = "$dir/probe.json";
	my $ppid = fork();
	die "fork: $!" unless defined $ppid;
	if ($ppid == 0) {
		my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $paths[0]) or exit 9;
		$s->autoflush(1);
		my @lat;
		my $seq = 0;
		my $end = time + $o{'seconds'};
		while (time < $end) {
			my $p = $enc->encode({ app => $apps[0], probe => 1, seq => $seq++ });
			my $t0 = time;
			print {$s} pack('N', length $p) . $p;
			my $hdr = '';
			while (length($hdr) < 4) {
				my $n = sysread($s, $hdr, 4 - length($hdr), length($hdr));
				last unless $n;
			}
			last unless length($hdr) == 4;
			my $len = unpack('N', $hdr);
			my $body = '';
			while (length($body) < $len) {
				my $n = sysread($s, $body, $len - length($body), length($body));
				last unless $n;
			}
			push @lat, (time - $t0) * 1000 if length($body) == $len;
			sleep 0.1;
		}
		write_file($probe_rtt, JSON::PP->new->canonical->encode({
			n => scalar(@lat), p50 => percentile(\@lat, 50), p99 => percentile(\@lat, 99),
		}));
		exit 0;
	}

	for my $p (@senders, $ppid) { waitpid($p, 0) }
	waitpid($rpid, 0);

	my %got = (writes => 0, bytes => 0, p50 => 0, p99 => 0);
	my (@p50, @p99);
	for my $i (0 .. $#senders) {
		my $f = "$dir/sender.$i.json";
		next unless -e $f;
		my $s = eval { JSON::PP->new->decode(read_file($f)) } || {};
		$got{'writes'} += $s->{'writes'} || 0;
		$got{'bytes'}  += $s->{'bytes'} || 0;
		push @p50, $s->{'p50'} || 0;
		push @p99, $s->{'p99'} || 0;
	}
	$got{'p50'} = percentile(\@p50, 50);
	$got{'p99'} = percentile(\@p99, 50);
	my $rec = eval { JSON::PP->new->decode(read_file($report)) } || {};
	my $probe = eval { JSON::PP->new->decode(read_file($probe_rtt)) } || {};
	my $secs = $o{'seconds'};
	return {
		shape  => $shape,
		sent   => $got{'writes'},
		frames => $rec->{'frames'} || 0,
		bytes  => $rec->{'bytes'} || 0,
		fps    => ($rec->{'frames'} || 0) / $secs,
		mibs   => ($rec->{'bytes'} || 0) / $secs / 1024 / 1024,
		wp50   => $got{'p50'},
		wp99   => $got{'p99'},
		pp50   => $probe->{'p50'} || 0,
		pp99   => $probe->{'p99'} || 0,
		probes => $probe->{'n'} || 0,
	};
}

my @shapes = $o{'shape'} eq 'both' ? qw(single multi) : ($o{'shape'});
printf "ws relay bench: apps=%d senders=%d seconds=%d rate=%d/s frame=%dB media=%dKB\n",
	$o{'apps'}, $o{'senders'}, $o{'seconds'}, $o{'rate'}, $o{'frame-bytes'}, $o{'media-kb'};

my %results;
for my $shape (@shapes) {
	for my $run (1 .. $o{'repeat'}) {
		my $r = run_shape($shape, $run);
		push @{ $results{$shape} }, $r;
		printf "  %-6s run %d: %8.0f frames/s %8.1f MiB/s  write p50/p99 %.2f/%.2f ms  probe p50/p99 %.2f/%.2f ms  (%d probes, %d sent)\n",
			$shape, $run, $r->{'fps'}, $r->{'mibs'}, $r->{'wp50'}, $r->{'wp99'},
			$r->{'pp50'}, $r->{'pp99'}, $r->{'probes'}, $r->{'sent'};
	}
}

print "\nmedian over repeats:\n";
for my $shape (@shapes) {
	my @r = @{ $results{$shape} || [] };
	next unless @r;
	my @fps = map { $_->{'fps'} } @r;
	my @mib = map { $_->{'mibs'} } @r;
	my @wp99 = map { $_->{'wp99'} } @r;
	my @pp50 = map { $_->{'pp50'} } @r;
	my @pp99 = map { $_->{'pp99'} } @r;
	printf "  %-6s %8.0f frames/s %8.1f MiB/s  write p99 %.2f ms  probe p50/p99 %.2f/%.2f ms\n",
		$shape, percentile(\@fps, 50), percentile(\@mib, 50),
		percentile(\@wp99, 50), percentile(\@pp50, 50), percentile(\@pp99, 50);
}

exit 0;
