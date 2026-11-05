# tests-for: templates/ templates/appointment_wrapper.html.ep templates/configure/appointment_list.html.ep templates/apps/inventory.html.ep
# covers:    Every template's start tags are terminated (a "<option" with no ">"
#            swallows the next tag), and the templates that stand on their own have
#            every end tag closing an element they opened. A stray </span> or an
#            unclosed <div> used to leave the rest of a window nested inside the
#            wrong element. Three files are deliberately left open where a parent
#            closes them; they are named below.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Find qw(find);
use File::Slurp qw(read_file);
use RepoSource qw(repo_root template_source);

my $root = repo_root();

# Elements the HTML parser never expects an end tag for.
my %void = map { $_ => 1 } qw(
	area base br col embed hr img input link meta param source track wbr
);

# HTML5's optional end tags: a new one, or the parent's end tag, closes the last.
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

# Templates that are complete on their own: every element they open, they close.
my @self_contained = qw(
	templates/appointment_wrapper.html.ep
	templates/configure/appointment_list.html.ep
	templates/configure/crypto_setting_list.html.ep
	templates/apps/inventory.html.ep
	templates/apps/account.html.ep
	templates/apps/project.html.ep
	templates/apps/information.html.ep
	templates/apps/tasks.html.ep
	templates/apps/app_details.html.ep
	templates/apps/app_measure_details.html.ep
	templates/budget/statement.html.ep
	templates/budget_reconcile.html.ep
	templates/embedded/body.html.ep
	templates/embedded/embedded.html.ep
	templates/terminal/body.html.ep
	templates/terminal/terminal.html.ep
	templates/homepage.html.ep
	templates/manager.html.ep
	templates/keyboard.html.ep
	templates/marker.html.ep
	templates/pseudonyms.html.ep
	templates/measures/measures.html.ep
	templates/store/custom_item_selection_input.html.ep
	templates/studio/markup.html.ep
	templates/studio/plug_selection.html.ep
	templates/window.html.ep
	templates/file_information.html.ep
	templates/passkey.html.ep
	templates/layouts/homepage.html.ep
	templates/layouts/manager.html.ep
	templates/layouts/music.html.ep
	templates/layouts/store.html.ep
	templates/layouts/library.html.ep
);

# No template is allowed to leave an element for another file to close: the
# embedded page and the terminal page used to do that, and the crypto panel
# opened its div in both halves of an if/else. All three now stand on their own.

sub line_at {
	my ($text, $offset) = @_;
	return 1 + ( substr($text, 0, $offset) =~ tr/\n// );
}

sub blank {
	my $text = shift;
	$text =~ s/[^\n]//g;
	return $text;
}

sub strip_ep {
	my $text = shift // '';
	# Perl in the template and its comments are not markup.
	$text =~ s{<%.*?%>}{ blank($&) }ges;
	# Neither is an HTML comment, nor a script/style body (men write tags as
	# prose in their comments, and a "less than" is not a tag).
	$text =~ s{<!--.*?-->}{ blank($&) }gse;
	for my $tag (qw(style script)) {
		$text =~ s{(<$tag\b[^>]*>)(.*?)(</$tag>)}{ $1 . blank($2) . $3 }gise;
	}
	return $text;
}

sub unterminated {
	my $text = shift // '';
	my @errors;
	while ( $text =~ /<([a-zA-Z][a-zA-Z0-9:-]*)/g ) {
		my $tag   = lc $1;
		my $at    = $-[0];
		my $after = $+[0];
		my $gt    = index($text, '>', $after);
		my $next  = index($text, '<', $after);
		if ( $gt < 0 || ( $next >= 0 && $next < $gt ) ) {
			push @errors, sprintf( 'line %d: <%s> has no ">" before the next tag',
				line_at($text, $at), $tag );
		}
	}
	return @errors;
}

sub unbalanced {
	my $text = shift // '';
	my @errors;
	my @open;
	while ( $text =~ /<(\/?)([a-zA-Z][a-zA-Z0-9:-]*)([^>]*)>/g ) {
		my ($slash, $tag, $attrs) = ($1, lc $2, $3);
		my $line = line_at($text, $-[0]);

		if ($slash) {
			next if $void{$tag};
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
				push @errors, sprintf( 'line %d: </%s> closes over unclosed %s', $line, $tag, $inner );
			}
			else {
				push @errors, sprintf( 'line %d: </%s> has no open <%s>', $line, $tag, $tag );
			}
			next;
		}

		next if $void{$tag};
		next if $attrs =~ /\/\s*$/;
		if ( my $closes = $auto_close{$tag} ) {
			my %closes = map { $_ => 1 } @{$closes};
			pop @open while @open && $closes{ $open[-1][0] };
		}
		push @open, [ $tag, $line ];
	}

	push @errors, map { sprintf( 'line %d: <%s> is never closed', $_->[1], $_->[0] ) } @open;
	return @errors;
}

# Every template, so a new bad start tag anywhere fails here rather than in a
# window that quietly nests the rest of its content.
my @all;
find( sub { push @all, $File::Find::name if -f && /\.ep\z/ }, "$root/templates" );
@all = sort map { s{\A\Q$root\E/}{}r } @all;
ok( scalar(@all) > 100, 'the template tree was read (' . scalar(@all) . ' files)' );

my @termination;
for my $rel (@all) {
	# scalar context: File::Slurp returns a list of lines in list context
	my $source = read_file("$root/$rel");
	$source = '' unless defined $source;
	push @termination, map { "$rel: $_" } unterminated( strip_ep($source) );
}
is_deeply( \@termination, [], 'every start tag in every template is terminated' )
	or diag( join "\n", @termination );

my @imbalance;
for my $rel (@self_contained) {
	next unless -f "$root/$rel";
	my $source = read_file("$root/$rel");
	$source = '' unless defined $source;
	push @imbalance, map { "$rel: $_" } unbalanced( strip_ep($source) );
}
is_deeply( \@imbalance, [], 'the self-contained templates open and close the same elements' )
	or diag( join "\n", @imbalance );

for my $rel ( @self_contained ) {
	ok( -f "$root/$rel", "$rel is still a template" );
}

# The shapes that were wrong, pinned in the on-screen markup.
my $configure = read_file("$root/templates/configure/appointment_list.html.ep");
like( $configure, qr/^\s*<option value=""[^\n]*><\/option>/m, 'the blank Might Also Be option is complete' );
like( $configure, qr/main_image_config.*?\.remove\(\)" \/>/s, 'the main-image delete button is a complete img' );

my $inventory = read_file("$root/templates/apps/inventory.html.ep");
unlike( $inventory, qr/<% \} elsif \(\$rw eq 'average'.*?<\/span>\s*<% \} %>/s,
	'the average/total cells do not close a span they never opened' );

my $app_details = read_file("$root/templates/apps/app_details.html.ep");
like( $app_details, qr/<% \} %>><%|<% \} %>\n\s*<%= \$ap->\{'formatted_name'\} %>/,
	'the account option gets its closing ">" before its label' );

my $embedded = read_file("$root/templates/embedded/body.html.ep");
unlike( $embedded, qr/<b<span/, 'the OTA percentage is not a malformed <b<span> tag' );

done_testing();
