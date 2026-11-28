package Manager;

# voice_music_extra: one route, added for voice's transport control. The Music
# player's transport lives in the browser (musicTransportLocal in
# public/js/music.js), so this action names the console command the websocket
# router already knows and sends it to the music channel. It returns JSON so
# the app-action bridge can speak the result.
use strict;
use warnings;
no warnings 'uninitialized';

sub action_99710 {
	my $c = shift;
	my $action = lc($c->param('action') // '');
	$action = 'prev' if $action eq 'previous';
	my %known = map { $_ => 1 } qw(play pause next prev stop);
	unless ($known{$action}) {
		$c->render(json => { ok => 0, error => 'Choose play, pause, next, previous or stop.' });
		return;
	}
	&Websocket::send('server', { console => &Websocket::console_command('musicTransportLocal', $action) });
	$c->render(json => { ok => 1, action => $action });
}

1;
