#!/usr/bin/perl

# tunnel.pl — password-less, NAT-friendly TCP tunnels for JawnOS.
#
# Why this exists: today a tunnel is `sshpass -p <system password> ssh -N -R`
# (subroutines.pl::tunnel_starter), which means every peer's system password
# is stored. This module replaces the SSH data plane with a websocket:
#
#   * one hub (thejunderground.com, reachable) accepts outbound websocket
#     connections from peers that live behind NAT (phone/laptop/desktop/tablet);
#   * a single websocket carries many forwarded TCP connections ("channels");
#   * control frames are JSON text, payload frames are binary with a 4-byte
#     big-endian channel id prefix.
#
# No system password is anywhere in this path. The peer authenticates with the
# app-issued signatorial token it already uses on every manager route.
#
# Roles:
#   hub  — the side with a listening port. A connection to that port opens a
#          channel; the peer dials the local service ("dest").  (hub -> peer)
#   peer — dials the hub, then serves `open` frames by connecting to local dest.
#
# Integration: the hub side is hosted by Manager.pl's websocket route, which
# calls Tunnel::hub_session($c->tx, { signatorial => $s, listen => {...} }).
# The peer side runs as Tunnel::peer_session($url, {...}) under any Mojo loop.

use strict;
use warnings;

package Tunnel;

use Mojo::IOLoop;
use Mojo::UserAgent;
use Mojo::Server::Daemon;
use Mojo::JSON qw(decode_json encode_json);
use IO::Socket::INET;

our $VERSION = '0.1';
our $HUB_LISTEN = {};   # used by the CLI hub app below

my %HUB;                # signatorial => hub session
# The hub's manager serves https with a self-signed certificate, so a peer must
# not reject it on the wss handshake.
my $ua = Mojo::UserAgent->new;
$ua->insecure(1);
$ua->max_response_size(0);

sub _log {
  my ($fmt, @a) = @_;
  my $line = sprintf("[tunnel $$] $fmt\n", @a);
  warn $line if $ENV{TUNNEL_DEBUG};
  # A file-gated trace for diagnosing a flapping tunnel on a live device without
  # restarting to set TUNNEL_DEBUG: touch /tmp/tunnel_debug_arm and the holder
  # (and hub) append to /tmp/tunnel_debug.log; remove it to go quiet again.
  if (-e '/tmp/tunnel_debug_arm' && open(my $fh, '>>', '/tmp/tunnel_debug.log')) {
    print $fh $line;
    close $fh;
  }
}

sub _txt { my ($ws, $h) = @_; $ws->send({ text   => encode_json($h) }); }
sub _bin { my ($ws, $ch, $d) = @_; $ws->send({ binary => pack('N', $ch) . $d }); }

# ---------------------------------------------------------------------------
# Heartbeat freshness
# ---------------------------------------------------------------------------
# Liveness is the data plane's own beat, not a cross-machine round-trip. The
# peer's holder pings the hub every 15s and stamps a per-hub file on every pong;
# the manager's tunnel checker reads that stamp's age, so "is the tunnel up?" is
# answered locally - and the ping keeps a NAT mapping from silently expiring.
# Keyed by the hub host so a machine with more than one hub keeps one stamp per
# hub. The stamp lives in $HOME, not the app's state dir: that dir is wiped at
# boot and the two sides would then disagree about where the stamp is.
sub alive_file {
  my ($url) = @_;
  my $host = eval { Mojo::URL->new($url)->host } || '';
  $host =~ s/[^A-Za-z0-9.\-]/_/g;
  my $dir = $ENV{HOME} || '/tmp';
  return "$dir/.tunnel_alive_$host";
}

sub touch_alive {
  my ($url, $ports) = @_;
  my $f = alive_file($url);
  # The body is how many listeners the hub bound for us (its last pong), or empty
  # while unknown. A live-but-hollow session (the hub lost our tunnels rows and
  # bound nothing) then reads as "0" and the checker re-requests instead of
  # calling a socket that forwards nowhere connected.
  my $n = (ref $ports eq 'ARRAY') ? scalar(@{$ports}) : '';
  if (open(my $fh, '>', $f)) { print $fh $n; close $fh; }
}

# The hub's listener count from the last pong, or undef while unknown.
sub alive_ports {
  my ($url) = @_;
  my $f = alive_file($url);
  return unless -e $f;
  my $v = do { local $/; open(my $fh, '<', $f) or return; <$fh> };
  return undef unless defined $v && $v =~ /^\d+$/;
  return $v + 0;
}

# Milliseconds since the holder last heard a pong, or undef if it never has.
sub alive_age {
  my ($url) = @_;
  my $f = alive_file($url);
  return unless -e $f;
  my $m = (stat($f))[9];
  return unless $m;
  return (time() - $m) * 1000;
}

# ---------------------------------------------------------------------------
# Hub side
# ---------------------------------------------------------------------------
# hub_session($tx, {
#     signatorial => 'abc',
#     listen      => { name => { source => <hub local port>, dest => <peer port> } },
#     on_listen   => sub { my ($name, $port) = @_; },   # optional, for tests
# })
sub hub_session {
  my ($ws, $opts) = @_;
  my $sig    = $opts->{'signatorial'} || 'anonymous';
  my $listen = $opts->{'listen'} || {};

  # A peer redials after any drop; retire the previous session for this
  # signatorial first so its listeners release the ports before we rebind them.
  if (my $old = $HUB{$sig}) {
    Mojo::IOLoop->remove($old->{'listeners'}{$_}) for keys %{$old->{'listeners'}};
    $_->{'tcp'}->close for values %{$old->{'channels'}};
    delete $HUB{$sig};
  }

  my $session = $HUB{$sig} = {
    ws => $ws, signatorial => $sig, channel_next => 1,
    channels => {}, listeners => {}, last_seen => time(),
  };
  _log('hub session for %s', $sig);

  foreach my $name (sort keys %{$listen}) {
    my $r  = $listen->{$name};
    # A redial can arrive on a different worker while the worker that served
    # the previous session still holds this peer's listening ports. Binding
    # again would log EADDRINUSE into the tree's pty - which ./jawn reads as a
    # dead tree and answers with a whole-server restart. Probe first (same
    # ReuseAddr Mojo uses) and leave a held port to its holder; the peer's own
    # redial retires it. New peers dial the ws port, whose server has one
    # worker, so the retire-and-rebind below always runs in the right process.
    my $free = IO::Socket::INET->new(
      LocalAddr => '127.0.0.1', LocalPort => $r->{'source'},
      Proto => 'tcp', Listen => 5, ReuseAddr => 1
    );
    unless ($free) {
      _log('hub port %s for %s is held by another worker; leaving it alone', $r->{'source'}, $name);
      next;
    }
    close $free;
    my $id = Mojo::IOLoop->server({ address => '127.0.0.1', port => $r->{'source'} } => sub {
      my ($loop, $stream) = @_;
      my $ch = $session->{'channel_next'}++;
      $session->{'channels'}{$ch} = { tcp => $stream, name => $name, dest => $r->{'dest'} };
      # Hold the socket until the peer has dialled its dest, or the first bytes
      # a client sent land in a channel the peer does not know about yet.
      $stream->stop;
      _log('hub accept %s -> channel %d (peer dest %s)', $name, $ch, $r->{'dest'});
      _txt($ws, { op => 'open', channel => $ch, name => $name, dest => $r->{'dest'} });
      $stream->on(read  => sub { my ($s, $bytes) = @_; _bin($ws, $ch, $bytes); });
      $stream->on(close => sub { _txt($ws, { op => 'close', channel => $ch }); delete $session->{'channels'}{$ch}; });
      $stream->on(error => sub { _txt($ws, { op => 'close', channel => $ch }); delete $session->{'channels'}{$ch}; });
    });
    $session->{'listeners'}{$name} = $id;
    my $bound = Mojo::IOLoop->acceptor($id)->port;
    _log('hub listening on 127.0.0.1:%d for %s', $bound, $name);
    $opts->{'on_listen'}->($name, $bound) if $opts->{'on_listen'};
  }

  $ws->on(text => sub {
    my ($ws, $str) = @_;
    my $m  = eval { decode_json $str } || {};
    my $op = $m->{'op'} // '';
    $session->{'last_seen'} = time();
    if ($op eq 'ping') {
      _txt($ws, { op => 'pong', ports => [ sort keys %{$session->{'listeners'}} ] });
    }
    elsif ($op eq 'ready') {
      my $c = $session->{'channels'}{$m->{'channel'}};
      $c->{'tcp'}->start if $c && $c->{'tcp'};
      _log('peer ready on channel %d', $m->{'channel'});
    }
    elsif ($op eq 'close' && $m->{'channel'}) {
      if (my $c = $session->{'channels'}{$m->{'channel'}}) {
        # The peer's close frame follows the last binary payload. A bare close
        # discards whatever write is still queued - which cut the tail off every
        # large backup served over the tunnel (including the appended
        # encryption-standard marker, so the merge saw a container it could not
        # read). Let the queued bytes drain, then close.
        $c->{'tcp'}->close_gracefully;
        delete $session->{'channels'}{$m->{'channel'}};
      }
    }
  });

  $ws->on(binary => sub {
    my ($ws, $bytes) = @_;
    $session->{'last_seen'} = time();
    return if length $bytes < 4;
    my $ch      = unpack('N', substr($bytes, 0, 4));
    my $payload = substr($bytes, 4);
    my $c = $session->{'channels'}{$ch} or return;
    $c->{'tcp'}->write($payload);
  });

  # Drop a peer whose socket went silent: the peer pings every 15s, so 60s of
  # silence is a half-open death Mojo cannot see, and closing it frees the
  # listeners for the peer's own redial (which the idle timeout would otherwise
  # never prompt).
  my $watchdog;
  $watchdog = Mojo::IOLoop->recurring(30 => sub {
    return unless $HUB{$sig} && $HUB{$sig} == $session;
    if (time() - ($session->{'last_seen'} || time()) > 60) {
      _log('hub session %s silent; dropping', $sig);
      Mojo::IOLoop->remove($watchdog) if $watchdog;
      eval { $ws->finish };
    }
  });

  $ws->on(finish => sub {
    _log('hub session %s down', $sig);
    Mojo::IOLoop->remove($watchdog) if $watchdog;
    Mojo::IOLoop->remove(delete $session->{'listeners'}{$_}) for keys %{$session->{'listeners'}};
    $_->{'tcp'}->close for values %{$session->{'channels'}};
    # Only deregister if we are still the current session for this signatorial;
    # a redial replaces $HUB{$sig} and its own finish will clean up.
    delete $HUB{$sig} if $HUB{$sig} && $HUB{$sig} == $session;
  });
}

# ---------------------------------------------------------------------------
# Peer side
# ---------------------------------------------------------------------------
# peer_session($url, { signatorial => '', token => '', on_ready => sub {...} })
# Runs under the ambient Mojo::IOLoop and reconnects on drop.
sub peer_session {
  my ($url, $opts) = @_;
  my $sig      = $opts->{'signatorial'} || '';
  my %channels;   # channel id => TCP stream to the local service

  # sign the ws handshake the way the HTTP peer rail signs its requests, so the
  # hub verifies identity instead of trusting a name alone. The UA's start event
  # passes ($ua, $tx), so the signer must be handed the request, exactly as every
  # HTTP-rail caller does (on(start => sub { ...peer_sign_request($tx->req) })).
  # Handing it the event directly gave it the UA, and $ua->method killed the
  # handshake (and the holder) before a byte was signed.
  if ($opts->{'sign'}) {
    my $sign = $opts->{'sign'};
    $ua->on(start => sub { my ($ua, $tx) = @_; $sign->($tx->req); });
  }

  my $connect;
  $connect = sub {
    _log('peer dialing %s', $url);
    $ua->websocket($url => sub {
      my ($ua, $tx) = @_;
      _log('peer ws callback (is_ws=%d)', $tx->is_websocket ? 1 : 0);
      unless ($tx->is_websocket) {
        my $err = $tx->error || {};
        _log('peer dial failed: %s', $err->{'message'} // 'unknown');
        _reconnect($connect);
        return;
      }
      _log('peer connected');
      _txt($tx, { op => 'hello', signatorial => $sig, token => ($opts->{'token'} // '') });
      $opts->{'on_ready'}->($tx) if $opts->{'on_ready'};

      # Heartbeat: a ping every 15s keeps the NAT mapping open and proves the
      # link is live; silence past 40s is a zombie socket (a NAT/idle drop Mojo
      # never notices), so redial. Each pong stamps the freshness file the
      # manager's tunnel checker reads - liveness without a cross-machine ping.
      my $last_pong = time();
      my $hb;
      touch_alive($url);

      $tx->on(text => sub {
        my ($tx, $str) = @_;
        my $m  = eval { decode_json $str } || {};
        my $op = $m->{'op'} // '';
        if ($op eq 'pong') { $last_pong = time(); touch_alive($url, $m->{'ports'}); return; }
        if ($op eq 'open') {
          my $ch = $m->{'channel'};
          Mojo::IOLoop->client({ address => '127.0.0.1', port => $m->{'dest'} } => sub {
            my ($loop, $err, $stream) = @_;
            if ($err || !$stream) { _txt($tx, { op => 'close', channel => $ch }); return; }
            $channels{$ch} = $stream;
            _txt($tx, { op => 'ready', channel => $ch });
            $stream->on(read  => sub { my ($s, $bytes) = @_; _bin($tx, $ch, $bytes); });
            $stream->on(close => sub { _txt($tx, { op => 'close', channel => $ch }); delete $channels{$ch}; });
            $stream->on(error => sub { _txt($tx, { op => 'close', channel => $ch }); delete $channels{$ch}; });
          });
        }
        elsif ($op eq 'close' && $m->{'channel'}) {
          if (my $s = $channels{$m->{'channel'}}) { $s->close_gracefully; delete $channels{$m->{'channel'}}; }
        }
      });

      $tx->on(binary => sub {
        my ($tx, $bytes) = @_;
        return if length $bytes < 4;
        my $ch      = unpack('N', substr($bytes, 0, 4));
        my $payload = substr($bytes, 4);
        $channels{$ch}->write($payload) if $channels{$ch};
      });

      # One teardown, whichever notices first: the socket's own finish, or the
      # heartbeat. A half-open socket (the hub closed but we never saw the FIN)
      # can make the ping write die inside the timer callback, so the send is
      # guarded too - otherwise the recurring timer stops firing and nothing
      # redials until the checker's slow failures path.
      my $closed = 0;
      my $closer = sub {
        return if $closed;
        $closed = 1;
        Mojo::IOLoop->remove($hb) if $hb;
        $hb = undef;
        $_->close for values %channels;
        %channels = ();
        _reconnect($connect);
      };

      $tx->on(finish => sub {
        _log('peer disconnected');
        $closer->();
      });

      $hb = Mojo::IOLoop->recurring(15 => sub {
        # A backup can keep this link busy for minutes. Pongs queue behind the
        # payload, so a 40s silence was a false death and cut every large
        # download mid-stream (the server then saw a short body, which is why
        # its merges kept finding no standard marker). A genuinely dead link is
        # still caught by the hub's own 60s silence watchdog and by the TCP
        # error; this is only the backstop for a zombie socket.
        my $stale = (time() - $last_pong > 300) ? 1 : 0;
        unless ($stale) {
          $stale = 1 unless eval { _txt($tx, { op => 'ping' }); 1 };
        }
        return unless $stale;
        _log('peer heartbeat timeout; redialing');
        eval { $tx->finish };
        $closer->();
      });
    });
  };
  $connect->();
}

sub _reconnect {
  my ($connect) = @_;
  Mojo::IOLoop->timer(3 => sub { $connect->() });
}

# ---------------------------------------------------------------------------
# Standalone hub CLI (for local/remote testing without Manager.pl)
# ---------------------------------------------------------------------------
{
  package Tunnel::Hub::App;
  use Mojo::Base 'Mojolicious', -strict;
  sub startup {
    my $self   = shift;
    my $listen = $Tunnel::HUB_LISTEN || {};
    $self->routes->websocket('/tunnel' => sub {
      my $c = shift;
      $c->rendered(101);   # establish the websocket (see Mojolicious::Controller)
      Tunnel::hub_session($c->tx, {
        signatorial => ($c->param('signatorial') // 'anonymous'),
        listen      => $listen,
      });
    });
  }
}

unless (caller) {
  my $mode = shift @ARGV // '';
  my %arg  = map { my ($k, $v) = split /=/, $_, 2; $k =~ s/^--?//; ($k => $v) } @ARGV;

  if ($mode eq 'peer') {
    my $url = $arg{'url'} or die "usage: tunnel.pl peer --url=ws://host:port/tunnel [--signatorial=...] [--token=...]\n";
    peer_session($url, { signatorial => $arg{'signatorial'}, token => $arg{'token'} });
    Mojo::IOLoop->start;
  }
  elsif ($mode eq 'hub') {
    my $port = $arg{'port'} || 47900;
    my %listen;
    if ($arg{'listen'}) {
      foreach my $spec (split /;/, $arg{'listen'}) {
        my ($name, $source, $dest) = split /:/, $spec;
        $listen{$name} = { source => $source + 0, dest => $dest + 0 } if defined $name && defined $dest;
      }
    }
    $HUB_LISTEN = \%listen;
    my $host = $arg{'host'} || '127.0.0.1';
    # Keep a strong ref: _listen weakens the daemon, so an unbound
    # Mojo::Server::Daemon->new(...)->start is collected and stops listening.
    my $daemon = Mojo::Server::Daemon->new(listen => ["http://$host:$port"], app => Tunnel::Hub::App->new);
    $daemon->start;
    print "hub on $host:$port (listen: ", join(',', map { "$_:$listen{$_}{source}->$listen{$_}{dest}" } sort keys %listen), ")\n";
    Mojo::IOLoop->start;
  }
  else {
    die "usage: tunnel.pl <peer|hub> [...]\n";
  }
}

1;
