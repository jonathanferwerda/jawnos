package Manager;

# manager_vacation_keep: the keep list behind the Away card. The package is
# Manager, so unqualified calls to its helpers and its package state work as
# they do in the other route parts.
use strict;
use warnings;
use utf8;

# GET /manager/vacation/keep
# The rows the card offers and the three lists they are ticked against.
sub action_60010 {
	my $c = shift;
	return $c->render(json => {
		ok => 1,
		rows => &subs::vacation_keep_rows(),
		lists => &subs::vacation_keep_lists(),
	});
}

# POST /manager/vacation/keep
# Put an app into or out of one keep list: app, kind, on (on/off).
sub action_60011 {
	my $c = shift;
	my $lists = &subs::vacation_keep_toggle(
		$c->param('app'),
		$c->param('kind'),
		$c->param('on'),
	);
	return $c->render(json => {
		ok => 0,
		error => &subs::ui('Could not save the keep list.'),
	}) unless $lists;
	return $c->render(json => { ok => 1, lists => $lists });
}

1;
