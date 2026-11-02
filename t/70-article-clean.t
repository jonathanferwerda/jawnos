# tests-for: lib/JawnOS/Domain/Article.pm
# covers:    The magazine editor writes HTML that the homepage renders raw, and magazine rows sync between machines, so art...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

# The magazine editor writes HTML that the homepage renders raw, and magazine
# rows sync between machines, so article content is untrusted. This is the
# allowlist it passes through.
require JawnOS::Domain::Article;

my $clean = \&subs::article_html_clean;

# --- the dangerous shapes ----------------------------------------------------
my $script = $clean->('<p>hi</p><script>alert(1)</script>');
is($script, '<p>hi</p>', 'a script element and its content are dropped');

is($clean->('<p onmouseover="steal()">x</p>'), '<p>x</p>',
	'an on* handler is dropped');

is($clean->('<a href="javascript:alert(1)">x</a>'), '<a>x</a>',
	'a javascript: link is dropped');

is($clean->('<a href="JaVaScRiPt:alert(1)">x</a>'), '<a>x</a>',
	'the scheme check is case blind');

is($clean->('<img src="data:image/svg+xml;base64,AAA">'), '<img>',
	'an SVG data URL is refused (it can carry script)');

is($clean->('<iframe src="/x"></iframe>'), '', 'an iframe is dropped');

is($clean->('<p>a<style>p{color:red}</style>b</p>'), '<p>ab</p>',
	'a style element is dropped and the text around it kept');

is($clean->('<p style="position:fixed;color:red;background-image:url(x)">x</p>'),
	'<p style="color:red">x</p>',
	'CSS outside the allowlist is dropped, the colour stays');

is($clean->('<div class="a b" onclick="x()">c</div>'), '<div class="a b">c</div>',
	'class is kept and the handler is not');

# --- what an article keeps ---------------------------------------------------
is($clean->('<img src="/images/a.png" alt="A">'), '<img alt="A" src="/images/a.png">',
	'a house image keeps its source and alt (attributes come out sorted)');

is($clean->('<a href="https://example.com/x">x</a>'),
	'<a href="https://example.com/x">x</a>', 'an https link is kept');

is($clean->('<p><strong>b</strong> and <em>i</em></p>'),
	'<p><strong>b</strong> and <em>i</em></p>', 'inline markup survives');

is($clean->('<video controls src="/m/a.mp4"></video>'),
	'<video controls="controls" src="/m/a.mp4"></video>', 'a video keeps controls and src');

is($clean->('<img src="data:image/png;base64,AAA">'), '<img src="data:image/png;base64,AAA">',
	'an embedded picture is kept');

# --- shape -------------------------------------------------------------------
is($clean->('<p>unclosed'), '<p>unclosed</p>',
	'a tag the article never closed is closed for it');

is($clean->('<b><i>x</b></i>'), '<b><i>x</i></b>',
	'a crossed pair comes out balanced');

is($clean->('<blink>x</blink>'), 'x', 'an unknown tag keeps its text only');

is($clean->('&amp; and &lt;stay&gt;'), '&amp; and &lt;stay&gt;',
	'entities in ordinary text are left alone');

my $already = '<h2>Title</h2><p class="lead">Body</p>';
is($clean->($already), $already, 'markup with nothing to vet comes back untouched');

is($clean->('<p>a &amp; b</p>'), '<p>a &amp; b</p>',
	'an ampersand entity is not double escaped');

done_testing();
