# tests-for: templates/appointment_wrapper.html.ep templates/configure/appointment_list.html.ep templates/apps/inventory.html.ep
# covers:    These three templates are rendered into a window's innerHTML, so a
#            start tag with no ">" swallows the tag after it and a stray end tag
#            closes an element the template never opened. Both leave the window
#            content nested incorrectly (a hidden span wrapping a whole app card,
#            or a table cell running into the next row). Every start tag here must
#            be terminated and every end tag must close an open element.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root template_source);

my $root = repo_root();

my @templates = (
	[ 'appointment wrapper', 'appointment_wrapper.html.ep' ],
	[ 'Configure app list',  'configure/appointment_list.html.ep' ],
	[ 'inventory panel',     'apps/inventory.html.ep' ],
);

# Elements the HTML parser never expects an end tag for.
my %void = map { $_ => 1 } qw(
	area base br col embed hr img input link meta param source track wbr
);

# Very small HTML5 rule set: the end tag of these may be omitted, so a new one
# (or the parent's end tag) closes the previous automatically.
my %auto_close = (
	option => [qw(option)],
	optgroup => [qw(option)],
	li => [qw(li)],
	dt => [qw(dt dd)],
	dd => [qw(dt dd)],
	p => [qw(p)],
	td => [qw(td th)],
	th => [qw(td th)],
	tr => [qw(td th tr)],
	thead => [qw(td th tr thead tbody tfoot)],
	tbody => [qw(td th tr thead tbody tfoot)],
	tfoot => [qw(td th tr thead tbody tfoot)],
);

sub line_at {
	my ($text, $offset) = @_;
	return 1 + ( substr($text, 0, $offset) =~ tr/\n// );
}

sub strip_ep {
	my $text = shift;
	$text =~ s{<%.*?%>}{
		my $keep = $&;
		$keep =~ s/[^\n]//g;
		$keep;
	}ges;
	# A <script> or <style> body is not markup: men write tags as prose in its
	# comments, and the tag map must not read those. Keep the element's own tags.
	for my $pair ( [ 'style', 'style' ], [ 'script', 'script' ] ) {
		my ($open_tag, $close_tag) = @{$pair};
		$text =~ s{(<$open_tag\b[^>]*>)(.*?)(</$close_tag>)}{
			my ($open, $body, $close) = ($1, $2, $3);
			$body =~ s/[^\n]//g;
			$open . $body . $close;
		}gise;
	}
	return $text;
}

sub check_markup {
	my ($label, $text) = @_;
	my @errors;

	# A start tag must reach a ">" before the next "<"; otherwise it is not a
	# tag yet and the browser reads the next markup as its attributes.
	while ( $text =~ /<([a-zA-Z][a-zA-Z0-9:-]*)/g ) {
		my $tag    = lc $1;
		my $at     = $-[0];
		my $after  = $+[0];
		my $gt     = index($text, '>', $after);
		my $next   = index($text, '<', $after);
		if ( $gt < 0 || ( $next >= 0 && $next < $gt ) ) {
			push @errors, sprintf(
				'line %d: <%s> has no ">" before the next tag',
				line_at($text, $at), $tag
			);
		}
	}

	my @open;
	while ( $text =~ /<(\/?)([a-zA-Z][a-zA-Z0-9:-]*)([^>]*)>/g ) {
		my ($slash, $tag, $attrs) = ($1, lc $2, $3);
		my $line = line_at($text, $-[0]);

		if ( $slash ) {
			next if $void{$tag};
			# The parent's end tag implies the end of its optional children.
			pop @open while @open && (
				( $tag eq 'tr'    && $open[-1][0] =~ /^(?:td|th)$/ )
				|| ( $tag eq 'table' && $open[-1][0] =~ /^(?:td|th|tr|thead|tbody|tfoot)$/ )
				|| ( $tag =~ /^(?:thead|tbody|tfoot)$/ && $open[-1][0] =~ /^(?:td|th|tr)$/ )
				|| ( $tag eq 'select' && $open[-1][0] eq 'option' )
				|| ( $tag eq 'optgroup' && $open[-1][0] eq 'option' )
			);
			if ( @open && $open[-1][0] eq $tag ) {
				pop @open;
				next;
			}
			my $found = -1;
			for ( my $i = $#open; $i >= 0; $i-- ) {
				if ( $open[$i][0] eq $tag ) { $found = $i; last; }
			}
			if ( $found >= 0 ) {
				my @left = splice(@open, $found);
				my $inner = join ', ', map { '<' . $_->[0] . '> line ' . $_->[1] } @left[1 .. $#left];
				push @errors, sprintf(
					'line %d: </%s> closes over unclosed %s',
					$line, $tag, $inner
				);
			}
			else {
				push @errors, sprintf(
					'line %d: </%s> has no open <%s>',
					$line, $tag, $tag
				);
			}
			next;
		}

		next if $void{$tag};
		next if $attrs =~ /\/\s*$/;    # <tag ... /> closes itself

		if ( my $closes = $auto_close{$tag} ) {
			my %closes = map { $_ => 1 } @{$closes};
			pop @open while @open && $closes{ $open[-1][0] };
		}
		push @open, [ $tag, $line ];
	}

	for my $node ( @open ) {
		push @errors, sprintf( 'line %d: <%s> is never closed', $node->[1], $node->[0] );
	}

	is( scalar @errors, 0, "$label has balanced, terminated markup" )
		or diag( join "\n", @errors );
	return scalar @errors;
}

for my $tpl ( @templates ) {
	my ( $label, $path ) = @{$tpl};
	my $source = -f "$root/templates/$path"
		? read_file("$root/templates/$path")
		: template_source($path);
	check_markup( $label, strip_ep($source) );
}

# The two shapes that were wrong, pinned in the on-screen markup: the blank
# "Might Also Be" choice is a complete option, and the main-image delete button
# is a complete img (so it does not swallow its own closing span).
my $configure = read_file("$root/templates/configure/appointment_list.html.ep");
like( $configure, qr/^\s*<option value=""[^\n]*><\/option>/m, 'the blank Might Also Be option is complete' );
like( $configure, qr/main_image_config.*?\.remove\(\)" \/>/s, 'the main-image delete button is a complete img' );

my $inventory = read_file("$root/templates/apps/inventory.html.ep");
unlike( $inventory, qr/<% \} elsif \(\$rw eq 'average'.*?<\/span>\s*<% \} %>/s,
	'the average/total cells do not close a span they never opened' );

done_testing();
