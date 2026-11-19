package Manager;

# manager_games: the two house games that have a window of their own. Pipedream
# and Minesweeper follow Twirl's shape: the route renders the game page through
# the window maker, and the page's own chunk draws the game and starts the play
# appointment on the first control.
use strict;
use warnings;
use utf8;

# GET /manager/pipedream
sub action_44030 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		settings => &subs::settings_grabber({ app => 'pipedream' }),
		template => 'pipedream',
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'pipedream', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# GET /manager/minesweeper
sub action_44031 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		settings => &subs::settings_grabber({ app => 'minesweeper' }),
		template => 'minesweeper',
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'minesweeper', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

1;
