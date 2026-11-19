package JawnOS::Routes::manager_games;

use strict;
use warnings;

# The two house games that live in their own windows, beside Cards and Twirl.
# The Games launcher opens them with ?open=pipedream / ?open=minesweeper.
sub routes {
	return (
		[44030, 'get', '/manager/pipedream', 'action_44030'],
		[44031, 'get', '/manager/minesweeper', 'action_44031'],
	);
}

1;
