package JawnOS::Routes::manager_mapping;

use strict;
use warnings;

sub routes {
	return (
	[44100, 'get', '/manager/games/mapping', 'action_44100'],
	[44101, 'post', '/manager/games/mapping', 'action_44101'],
	);
}

1;
