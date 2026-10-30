use strict;
use warnings;
use utf8;

use Encode qw(encode_utf8);
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# Names accept every printable character (AGENTS.md). These are the conversions
# every app, folder and URL goes through, so a change here is visible everywhere.

# ---------------------------------------------------------------- format_name
is(&subs::format_name('hello_world'),        'Hello World',      'underscores read as spaces');
is(&subs::format_name('MIXED_case'),         'Mixed Case',       'every word is capitalised');
is(&subs::format_name('  multiple   spaces '), 'Multiple Spaces', 'runs of whitespace collapse');
is(&subs::format_name('café_au_lait'),       'Café Au Lait',     'non-ASCII letters survive');
is(&subs::format_name('中文'),                '中文',              'a script without case is unchanged');
is(&subs::format_name('my-app'),             'My-app',           'a hyphen is not a word break');
is(&subs::format_name(''),                   '',                 'empty stays empty');
is(&subs::format_name('occurences'),         'Occurrences',      'the legacy misspelling reads correctly');

# -------------------------------------------------------------- unformat_name
is(&subs::unformat_name('Hello World'), 'hello_world', 'spaces become the key separator');
is(&subs::unformat_name('  Hello   World  '), 'hello_world', 'surrounding and repeated whitespace fold away');
is(&subs::unformat_name("it's"),        'it’s',        "a straight apostrophe becomes the typographic mark");
is(&subs::unformat_name('a"b'),         'a”b',         'a straight double quote becomes the typographic mark');
is(&subs::unformat_name('__private'),   '__private',   'a double-underscore prefix is preserved');
is(&subs::unformat_name('A__B'),        'a_b',         'repeated underscores collapse to one');
is(&subs::unformat_name("a\tb"),        'ab',          'control characters are dropped');
is(&subs::unformat_name('Foo-Bar'),     'foo-bar',     'punctuation a path can keep is kept');

# ------------------------------------------------------------------ path_name
is(&subs::path_name('café'),   'café',    'letters of any script stay literal in a path');
is(&subs::path_name('中文'),    '中文',     'Chinese letters stay literal in a path');
is(&subs::path_name('a/b'),    'a%2Fb',   'a slash cannot become a directory separator');
is(&subs::path_name('a b'),    'a%20b',   'a space is percent-encoded');
is(&subs::path_name('a:b'),    'a%3Ab',   'a colon is percent-encoded');
is(&subs::path_name('.'),      '%2E',     'a single dot is encoded');
is(&subs::path_name('..'),     '%2E%2E',  'a parent reference is encoded');
is(&subs::path_name('-x'),     '%2Dx',    'a leading dash cannot look like an option');
{
	my $long = 'x' x 300;
	my $path = &subs::path_name($long);
	cmp_ok(length(encode_utf8($path)), '<=', 200, 'a long name is capped below the filesystem limit');
	like($path, qr/-[0-9a-f]{16}\z/, 'a capped name keeps a digest so it stays distinct');
	my $other = &subs::path_name('y' x 300);
	isnt($path, $other, 'two long names do not collide after capping');
}

# ------------------------------------------------------------------ html_name
is(&subs::html_name('simple'),  'simple',  'an already-safe name is unchanged');
is(&subs::html_name('a_b-c'),   'a_b-c',   'safe punctuation is unchanged');
like(&subs::html_name('My App'), qr/\AMyApp-[0-9a-f]{8}\z/, 'a changed name carries a digest');
like(&subs::html_name('café'),   qr/\Acafe-[0-9a-f]{8}\z/,  'a Latin accent is transliterated');
like(&subs::html_name('中文'),    qr/\A[A-Za-z][A-Za-z0-9]*-[0-9a-f]{8}\z/, 'a non-Latin name is a token, not empty');
isnt(&subs::html_name('中文'), &subs::html_name('日本語'), 'two non-Latin names stay distinct');

# ------------------------------------------------------------------ http_name
is(&subs::http_name('My App'), 'My_App', 'a space becomes an underscore in a URL token');
is(&subs::http_name('a/b'),    'ab',     'a slash is dropped from a URL token');
is(&subs::http_name('a.b'),    'ab',     'a dot is dropped from a URL token');

# ------------------------------------------------------- short display names
is(&subs::shorthand_name('Hello'),      'Hello',  'a name below the limit is unchanged');
is(&subs::shorthand_name('Hello', 3),   'Hel',    'a name can be shortened by count');
is(&subs::initialize_name('John Ronald Reuel Tolkien'), 'JRR', 'initials come from the first three words');
is(&subs::teaser_name('y' x 60),        'y' x 50, 'a teaser is capped at fifty characters');
is(&subs::abbreviate_name('Hello World 42'), 'HW4', 'abbreviation takes each word\'s first character');
is(&subs::wiki_name('my_name'),         'My_name', 'wiki form capitalises the first word only');

# ------------------------------------------------------------ escaping helpers
is(&subs::apostrophe_escape("it's?"), 'it\\\'s\\?', 'quote and question mark are escaped');
is(&subs::terminal_name("a b'c"),     'a\\ b\\\'c', 'a shell-visible name escapes spaces and quotes');
is(&subs::terminal_name('x(y)&z'),    'x\\(y\\)\\&z', 'parentheses and ampersand are escaped');
like(&subs::html_text('<b> & "x"'), qr/&lt;b&gt;.*&amp;/, 'html_text encodes markup');

# A digest is deterministic: the same name always renders the same class.
is(&subs::html_name('My App'), &subs::html_name('My App'), 'html_name is stable across calls');

done_testing();
