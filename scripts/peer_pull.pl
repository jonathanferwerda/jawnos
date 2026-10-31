#!/usr/bin/env perl
# peer_pull.pl - reach the older rows a timestamp-driven sync never asks for.
#
#   perl scripts/peer_pull.pl <peer> [--since 120d] [--remote] [--status]
#                                   [--wait MINUTES] [--manager URL] [--list]
#
# <peer> is matched against this machine's remote_machines by uuid, signatorial,
# hostname, fqdn or ip (an exact name wins over a substring).
#
# The ordinary sync is watermark-driven: it pulls rows newer than the newest row
# it already holds, so a machine that was away (or restored from an older
# snapshot) keeps whatever *older* rows it missed forever. A windowed pull
# ("gimme") is the repair: the peer exports a snapshot back to that many days
# and the puller merges it.
#
# Two directions, because either machine can be the one that is behind:
#
#   (default)   this machine pulls the window from <peer>
#   --remote    asks <peer> to pull the window from this machine
#
# --remote uses the signed pull-now lever (/manager/configure/remote_upgrade):
# the peer verifies this machine against its own roster, so it needs no browser
# and no session on the peer. It is the only direction a CLI can start on
# another machine. The default direction logs in to this machine's own manager
# with an app ticket (scripts/app_ticket.pl) over loopback.
#
# --status is the signed handshake (no pull): it prints the peer's appointment
# count and how many of its rows sit above this machine's watermark.
# --wait N keeps asking until the peer's count has not moved for two passes
# (a remote pull runs on the peer, so its own count is the progress).
#
#   perl scripts/peer_pull.pl tablet --remote --since 120d --wait 30
#
# The window is a positive span: 120d (not -120d) - subs::ago_calc reads a
# leading minus as a future time.
use strict;
use warnings;

package Jawn::PeerPull;

use FindBin;
use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Time::HiRes qw(time);

chdir "$FindBin::Bin/.." or die "peer_pull: cannot find the jawnos root\n";
require './subroutines.pl';

sub usage {
	return <<'USAGE';
usage: perl scripts/peer_pull.pl <peer> [--since 120d] [--remote] [--status]
                                   [--wait MINUTES] [--manager URL] [--list]

  <peer>        a remote_machines row: uuid, signatorial, hostname, fqdn or ip
  --since SPAN  the window to repair, as a positive ago span (120d, 3d, 6h)
  --remote      ask <peer> to pull the window from this machine
  --status      print the peer's count and pending rows; start no pull
  --wait MIN    poll until the peer's count stops moving (default 0 = no wait)
  --manager URL call this peer's manager instead of the stored address
  --list        print the roster and exit
USAGE
}

# A peer named the way a person names it. An exact uuid/signatorial/hostname
# beats a substring, so "tablet" cannot be stolen by "tablet-old".
sub resolve_peer {
	my ($term, $rows) = @_;
	return (undef, 'no machine named') unless defined $term && length $term;
	my $t = lc $term;
	my @rows = grep { ref $_ eq 'HASH' } @{ $rows || [] };
	my @match = grep {
		my $r = $_;
		grep { (defined $r->{$_} && lc($r->{$_}) =~ /\Q$t\E/) }
			qw/uuid signatorial hostname fqdn ip domain name/
	} @rows;
	return (undef, 'no machine matches "' . $term . '"') unless @match;
	my @exact = grep {
		my $r = $_;
		grep { (defined $r->{$_} && lc($r->{$_}) eq $t) }
			qw/uuid signatorial hostname fqdn ip name/
	} @match;
	@match = @exact if @exact;
	return (undef, 'that matches more than one machine: '
		. join(', ', map { $_->{'hostname'} || $_->{'signatorial'} || $_->{'ip'} } @match))
		if @match > 1;
	return ($match[0], '');
}

# The peer's manager, rooted so a route can be appended. peer_live_manager
# rewrites a tunnel's leftover loopback address to the peer's own name; the
# stored row is the fallback when no fqdn is known.
sub peer_manager {
	my ($rm, $override) = @_;
	return $override if defined $override && length $override;
	my $manager = eval { &subs::peer_live_manager($rm) } || $rm->{'manager'} || '';
	return '' unless $manager;
	$manager =~ s{/+$}{};
	$manager .= '/manager' unless $manager =~ m{/manager$};
	return $manager;
}

# "120d" and "-120d" both mean 120 days ago to a person typing the window;
# ago_calc reads the minus as a future stamp, so drop it here.
sub normalize_window {
	my ($window) = @_;
	return '3d' unless defined $window && length $window;
	$window =~ s/^\s+|\s+$//g;
	$window =~ s/^-+//;
	return $window =~ /^\d+[a-z]+$/i ? $window : undef;
}

# One signing user agent for the whole run: subs::peer_sign_request rides every
# request's start event, so both the handshake and the lever are signed.
sub signed_ua {
	require Mojo::UserAgent;
	my $ua = Mojo::UserAgent->new->insecure(1)->connect_timeout(15);
	$ua = $ua->max_response_size(0);
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req) });
	return $ua;
}

# The signed handshake: the peer's own picture, and how far behind us it is.
sub peer_status {
	my ($ua, $rm, $manager) = @_;
	my $me = &subs::signatorial_designer();
	my $mine = eval { &subs::appointment_watermark() } || {};
	my $url = $manager . '/remote_auth_test?signatorial=' . $me . '&auth_test=yes';
	$url .= '&since=' . int($mine->{'max_server_time'} || 0);
	my $res = eval { $ua->inactivity_timeout(20)->request_timeout(30)->get($url)->result };
	unless ($res && $res->is_success) {
		return (undef, 'the peer did not answer' . ($res ? ' (' . $res->code . ')' : ''));
	}
	my $body = eval { require Mojo::JSON; Mojo::JSON::decode_json($res->body) } || {};
	my $count = $body->{'digest'}->{'appointments'}->{'count'};
	my $pending = $body->{'pending'}->{'count'};
	return ({
		count => (defined $count ? $count + 0 : undef),
		pending => (defined $pending ? $pending + 0 : undef),
		merging => ($body->{'merging'} || ''),
		version => ($body->{'version'} || ''),
	}, '');
}

# The pull-now lever on the peer, signed by this machine.
sub remote_pull {
	my ($ua, $rm, $manager, $window) = @_;
	my $me = &subs::signatorial_designer();
	my $res = eval {
		$ua->inactivity_timeout(30)->request_timeout(60)->post(
			$manager . '/configure/remote_upgrade' => form => {
				signatorial => $me,
				gimme => $window,
				device => &subs::device_setter(),
				timestamp => int(time() * 1000),
			});
	};
	my $reply = $res ? $res->result : undef;
	return (0, 'the request failed: ' . ($reply ? $reply->code : ($@ || 'no answer')))
		unless $reply && $reply->is_success;
	my $text = ($reply->body // '');
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return (1, $text);
}

# Log in to this machine's own manager without a browser: an app ticket is the
# one credential a script can mint (scripts/app_ticket.pl), and the box-office
# route turns it into the president session cookie. The loopback host is forced
# because the ticket's own host is the house domain, which a machine may reach
# over the internet instead of itself.
sub local_session {
	require Mojo::UserAgent;
	my $url = `perl scripts/app_ticket.pl peer-pull 2>/dev/null`;
	chomp $url;
	return (undef, 'could not mint an app ticket') unless $url =~ m{^https?://\S+/box_office/};
	my $config = eval { &subs::config_reader() } || {};
	my $dock = $ENV{'PORT_DOCK'} || $config->{'port'} || 3000;
	(my $local = $url) =~ s{^https?://[^/]+}{https://127.0.0.1:$dock};
	my $ua = Mojo::UserAgent->new->insecure(1)->connect_timeout(15);
	$ua = $ua->max_response_size(0);
	my $res = eval { $ua->inactivity_timeout(30)->request_timeout(60)->get($local)->result };
	return (undef, 'the ticket was refused') unless $res && $res->is_success;
	my $working = $config->{'working_port'} || 45545;
	return ($ua, '', "https://127.0.0.1:$working/manager");
}

# The ordinary, local direction: this machine pulls from the peer.
sub local_pull {
	my ($rm, $window) = @_;
	my ($ua, $why, $base) = local_session();
	return (0, $why || 'no local session') unless $ua;
	my $res = eval {
		$ua->inactivity_timeout(30)->request_timeout(60)->post(
			$base . '/configure/remote_upgrade' => form => {
				signatorial => $rm->{'signatorial'},
				ip => $rm->{'ip'},
				hostname => $rm->{'hostname'},
				database => $rm->{'database'},
				gimme => $window,
				device => &subs::device_setter(),
				timestamp => int(time() * 1000),
			});
	};
	my $reply = $res ? $res->result : undef;
	return (0, 'the request failed: ' . ($reply ? $reply->code : ($@ || 'no answer')))
		unless $reply && $reply->is_success;
	my $text = ($reply->body // '');
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return (1, $text);
}

# The local pull's progress lives in this machine's own job table; the remote
# pull's lives on the peer, so the peer's count is the signal there.
sub local_job_running {
	my @jobs = @{ &subs::sync_job_list(3) || [] };
	return scalar grep { ($_->{'state'} || '') eq 'running' } @jobs;
}

sub main {
	my @args = @_;
	my ($window, $remote, $status, $wait, $manager, $list, $help) = ('3d', 0, 0, 0, undef, 0, 0);
	my ($ok, $err) = GetOptionsFromArray(\@args,
		'since=s' => \$window,
		'remote' => \$remote,
		'status' => \$status,
		'wait=i' => \$wait,
		'manager=s' => \$manager,
		'list' => \$list,
		'help|h' => \$help,
	);
	if (!$ok || $help) { print usage(); return $ok ? 0 : 2; }
	$window = normalize_window($window);
	die "peer_pull: --since wants a positive span like 120d or 6h\n" unless defined $window;

	my $rows = [ @{ &subs::db_select('remote_machines')->hashes || [] } ];
	if ($list) {
		foreach my $r ( sort { ($a->{'hostname'} || '') cmp ($b->{'hostname'} || '') } @{$rows} ) {
			printf "%-16s %-12s %-22s %s\n",
				($r->{'signatorial'} || '?'), ($r->{'hostname'} || '?'),
				($r->{'ip'} || ''), &peer_manager($r) || '(no manager)';
		}
		return 0;
	}
	my $term = shift @args;
	unless (defined $term && length $term) { print usage(); return 2; }
	my ($rm, $why) = resolve_peer($term, $rows);
	unless ($rm) { die 'peer_pull: ' . $why . "\n"; }
	my $url = &peer_manager($rm, $manager);
	die "peer_pull: that machine has no known manager; use --manager\n" unless $url;
	my $name = $rm->{'hostname'} || $rm->{'signatorial'};

	if ($status) {
		my ($st, $serr) = peer_status(signed_ua(), $rm, $url);
		die 'peer_pull: ' . $serr . "\n" unless $st;
		printf "%s: %s appointments, %s above this machine's watermark, merging=%s\n",
			$name, (defined $st->{'count'} ? $st->{'count'} : '?'),
			(defined $st->{'pending'} ? $st->{'pending'} : '?'),
			($st->{'merging'} || 'no');
		return 0;
	}

	my ($started, $reply);
	if ($remote) {
		printf "asking %s to pull %s from this machine (%s)\n", $name, $window, $url;
		($started, $reply) = remote_pull(signed_ua(), $rm, $url, $window);
	}
	else {
		printf "pulling %s from %s (%s)\n", $window, $name, $url;
		($started, $reply) = local_pull($rm, $window);
	}
	print "  $reply\n";
	return 1 unless $started;

	return 0 unless $wait && $wait > 0;
	my $deadline = time() + $wait * 60;
	my $ua = signed_ua();
	my ($last, $same) = (undef, 0);
	while (time() < $deadline) {
		sleep 30;
		last unless time() < $deadline;
		if ($remote) {
			my ($st, $serr) = peer_status($ua, $rm, $url);
			unless ($st) { print "  waiting: $serr\n"; next; }
			printf "  %s: %s appointments (pending %s)\n", $name,
				(defined $st->{'count'} ? $st->{'count'} : '?'),
				(defined $st->{'pending'} ? $st->{'pending'} : '?');
			$same = (defined $last && defined $st->{'count'} && $st->{'count'} == $last) ? $same + 1 : 0;
			$last = $st->{'count'};
			if ($same >= 2 && !$st->{'merging'}) {
				print "  settled\n";
				return 0;
			}
		}
		else {
			my $running = local_job_running();
			print "  " . ($running ? "$running pull job(s) running" : 'no pull running') . "\n";
			last unless $running;
		}
	}
	print "  still going (the pull continues in the background); check --status\n";
	return 0;
}

main(@ARGV) unless caller;
