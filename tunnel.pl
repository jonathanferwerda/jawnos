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

our $VERSION = '0.1';
our $HUB_LISTEN = {};   # used by the CLI hub app below

my %HUB;                # signatorial => hub session
# The hub's manager serves https with a self-signed certificate, so a peer must
# not reject it on the wss handshake.
my $ua = Mojo::UserAgent->new;
$ua->insecure(1);
$ua->max_response_size(0);

sub _log { my ($fmt, @a) = @_; warn sprintf("[tunnel] $fmt\n", @a) if $ENV{TUNNEL_DEBUG}; }

sub _txt { my ($ws, $h) = @_; $ws->send({ text   => encode_json($h) }); }
sub _bin { my ($ws, $ch, $d) = @_; $ws->send({ binary => pack('N', $ch) . $d }); }

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
    channels => {}, listeners => {},
  };
  _log('hub session for %s', $sig);

  foreach my $name (sort keys %{$listen}) {
    my $r  = $listen->{$name};
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
    if ($op eq 'ready') {
      my $c = $session->{'channels'}{$m->{'channel'}};
      $c->{'tcp'}->start if $c && $c->{'tcp'};
      _log('peer ready on channel %d', $m->{'channel'});
    }
    elsif ($op eq 'close' && $m->{'channel'}) {
      if (my $c = $session->{'channels'}{$m->{'channel'}}) {
        $c->{'tcp'}->close;
        delete $session->{'channels'}{$m->{'channel'}};
      }
    }
  });

  $ws->on(binary => sub {
    my ($ws, $bytes) = @_;
    return if length $bytes < 4;
    my $ch      = unpack('N', substr($bytes, 0, 4));
    my $payload = substr($bytes, 4);
    my $c = $session->{'channels'}{$ch} or return;
    $c->{'tcp'}->write($payload);
  });

  $ws->on(finish => sub {
    _log('hub session %s down', $sig);
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

      $tx->on(text => sub {
        my ($tx, $str) = @_;
        my $m  = eval { decode_json $str } || {};
        my $op = $m->{'op'} // '';
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
          if (my $s = $channels{$m->{'channel'}}) { $s->close; delete $channels{$m->{'channel'}}; }
        }
      });

      $tx->on(binary => sub {
        my ($tx, $bytes) = @_;
        return if length $bytes < 4;
        my $ch      = unpack('N', substr($bytes, 0, 4));
        my $payload = substr($bytes, 4);
        $channels{$ch}->write($payload) if $channels{$ch};
      });

      $tx->on(finish => sub {
        _log('peer disconnected');
        $_->close for values %channels;
        %channels = ();
        _reconnect($connect);
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
