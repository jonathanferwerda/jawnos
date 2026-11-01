package JawnOS::Routes::manager_gallery;

use strict;
use warnings;

sub routes {
	return (
	[27838, 'get', '/manager/gallery', 'action_27838'],
	[27855, 'get', '/manager/gallery/data', 'action_27855'],
	[28066, 'get', '/manager/gallery/scroll', 'action_28066'],
	);
}

1;
