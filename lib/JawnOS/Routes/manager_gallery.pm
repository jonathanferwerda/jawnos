package JawnOS::Routes::manager_gallery;

use strict;
use warnings;

sub routes {
	return (
	[27838, 'get', '/manager/gallery', 'action_27838'],
	[27855, 'get', '/manager/gallery/data', 'action_27855'],
	[28066, 'get', '/manager/gallery/scroll', 'action_28066'],
	[28080, 'post', '/manager/gallery/archive_toggle', 'action_28080'],
	[28081, 'post', '/manager/gallery/sort', 'action_28081'],
	);
}

1;
