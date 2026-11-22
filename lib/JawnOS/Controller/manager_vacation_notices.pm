package Manager;

# manager_vacation_notices: the Away card's held-notice review. One route, so
# the validation and the shape the card consumes are readable without opening
# manager_configure4. The package is still Manager, so its helpers and package
# state work exactly as they do in the other controller parts.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

# GET /manager/vacation/notices
sub action_60020 {
	my $c = shift;
	my $from = $c->param('from');
	my $to = $c->param('to');
	my $valid = defined $from && $from =~ /^\s*\d+(?:\.\d+)?\s*$/
		&& defined $to && $to =~ /^\s*\d+(?:\.\d+)?\s*$/
		&& $to > $from;
	return $c->render(json => { ok => 0, error => &subs::ui('That away period is not valid.') })
		unless $valid;
	my $held = &subs::vacation_held_notices($from, $to);
	return $c->render(json => { ok => 1, %{ $held } });
}

1;
