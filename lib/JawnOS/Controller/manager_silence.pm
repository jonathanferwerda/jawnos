package Manager;

# manager_silence: the house's silence state, and the peer door that applies it.
#
# The status route is a read: the manager page polls it while silence may be on,
# and every device reads the same house-wide answer. The peer route is on the
# signed rail and applies the relayed state to this machine's own mixer.
use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;

# GET /manager/silence
sub action_53041 {
	my $c = shift;
	my $state = &subs::silence_state();
	$c->render(json => {
		ok => 1,
		active => ($state->{'active'} ? 1 : 0),
		state => $state,
	});
}

# POST /manager/silence/peer
#
# The machine that started or stopped the silence hands the same message to its
# peers. The caller is authenticated by its pinned peer signature, exactly as
# the padlock's peer rail is; relay_id lets the message walk a multi-hop mesh
# without looping.
sub action_53042 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) {
		return $c->rendered(403);
	}
	my $raw = $c->param('state') || '';
	my $state = (defined $raw && length $raw) ? eval { decode_json($raw) } : undef;
	$state = {} unless ref $state eq 'HASH';
	my $active = $c->param('active') ? 1 : ($state->{'active'} ? 1 : 0);
	$state->{'active'} = $active;
	$state->{'owners'} = [] unless ref $state->{'owners'} eq 'ARRAY';
	$state->{'apps'} = {} unless ref $state->{'apps'} eq 'HASH';
	&subs::silence_local_apply($active);
	&subs::silence_state_write($state);
	&subs::silence_push($state);
	my $relay_id = $c->param('relay_id') || '';
	if ($relay_id) {
		my $self = &subs::signatorial_designer() || '';
		eval { &subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			&subs::remote_relay_request($c, {
				override => 'manual',
				url => '/manager/silence/peer',
				type => 'post',
				dissemination => 'yes',
				params => {
					signatorial => $self,
					active => $active,
					state => encode_json($state),
					dissemination => 'yes',
					source_signatorial => $self,
					relay_from => $self,
					relay_id => $relay_id,
				},
			});
		}, { name => 'silence relay onward' }); };
	}
	$c->render(json => { ok => 1, active => $active });
}

1;
