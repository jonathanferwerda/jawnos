# tests-for: perl/help.pl lib/JawnOS/Domain/Guide.pm lib/JawnOS/Controller/manager_help.pm templates/configure/plat_setting_list.html.ep public/js/manager/configure/01_update_controls.js
# covers:    the Guide's own behavioural rules: a keyword-scoped, capped prompt
#           block, remember_rule/forget_rule against the shared setting, and the
#           Configure editor's textarea + Save wiring.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

my $root = JawnOSTest::root();
require "$root/perl/gb.pl";
require "$root/perl/help.pl";

# The stored list is a setting; the harness stubs the reader/writer so no test
# touches the live house database.
my $stored;
{
	no warnings 'redefine';
	local *subs::setting_grabber = sub {
		my ($s) = @_;
		return undef unless (($s->{'setting'} // '') eq 'guide_rules');
		return $stored;
	};
	local *subs::setting_setter = sub {
		my ($s) = @_;
		$stored = $s->{'value'};
		return 1;
	};

	# The injected block only, so the prompt's own example wording ("present
	# coordinates...") is not mistaken for an injected rule.
	my $block = sub {
		my ($prompt) = @_;
		my ($b) = $prompt =~ /(Rules the person asked you to follow on this turn[^\n]*\n(?:- [^\n]*\n?)*)/;
		return $b // '';
	};

	# --- remember stores a rule ---------------------------------------------
	my $r = subs::guide_rule_remember([ 'coordinates', 'latitude', 'longitude' ],
		'ROUND-COORDS to three decimal places');
	ok($r->{'ok'}, 'remember_rule stores a rule');
	like($r->{'text'}, qr/Remembered/, 'and says so in words');
	my $rows = subs::guide_rules_read();
	is(scalar @{$rows}, 1, 'the shared list holds one rule');
	is_deeply($rows->[0]{'match'}, [ 'coordinates', 'latitude', 'longitude' ],
		'the trigger words are kept');

	# A second rule with the same trigger words replaces, not stacks.
	subs::guide_rule_remember([ 'coordinates', 'latitude', 'longitude' ], 'ROUND-COORDS v2');
	is(scalar @{ subs::guide_rules_read() }, 1, 'the same triggers replace the old rule');

	# --- a matching rule reaches the prompt, a non-matching one does not -----
	subs::guide_rule_remember([ 'recipe', 'cooking' ], 'LIST-GRAMS in grams');
	my $hit = help::actions_prompt(undef, 0, 'what are the coordinates of Sarnia?');
	like($block->($hit), qr/ROUND-COORDS v2/, 'a matching rule is injected');
	unlike($block->($hit), qr/LIST-GRAMS/, 'a rule whose words are absent is not injected');
	my $miss = help::actions_prompt(undef, 0, 'what is the weather tomorrow');
	is($block->($miss), '', 'an unrelated question carries no rule block at all');

	# Case-insensitive and word-ish: the trigger inside a longer word does not fire.
	like($block->(help::actions_prompt(undef, 0, 'COORDINATES please')), qr/ROUND-COORDS/,
		'a trigger matches regardless of case');
	is($block->(help::actions_prompt(undef, 0, 'uncoordinatesss')), '',
		'a trigger does not fire inside a longer word');

	# --- app scoping --------------------------------------------------------
	subs::guide_rule_remember([ 'grid' ], 'SCOPE-TRAVEL only here', 'travel');
	like($block->(help::actions_prompt(undef, 0, 'show the grid in travel')), qr/SCOPE-TRAVEL/,
		'an app-scoped rule fires when its window is in view');
	unlike($block->(help::actions_prompt(undef, 0, 'show the grid')), qr/SCOPE-TRAVEL/,
		'and stays out when that app is not named');

	# --- forget by word and by position -------------------------------------
	my $f = subs::guide_rule_forget('latitude');
	ok($f->{'ok'}, 'forget_rule removes by a trigger word');
	unlike(join('', map { $_->{'rule'} } @{ subs::guide_rules_read() }), qr/ROUND-COORDS/,
		'the named rule is gone');
	my $before = scalar @{ subs::guide_rules_read() };
	my $first = subs::guide_rules_read()->[0]{'rule'};
	my $f2 = subs::guide_rule_forget(1);
	ok($f2->{'ok'}, 'forget_rule removes by position (1 is the first)');
	unlike(join('', map { $_->{'rule'} } @{ subs::guide_rules_read() }), qr/\Q$first\E/,
		'and removed the first one');
	is(scalar @{ subs::guide_rules_read() }, $before - 1, 'one fewer rule');
}

# --- the cap: count and characters ------------------------------------------
{
	$stored = undef;
	no warnings 'redefine';
	local *subs::setting_grabber = sub {
		my ($s) = @_;
		return undef unless (($s->{'setting'} // '') eq 'guide_rules');
		return $stored;
	};
	local *subs::setting_setter = sub { my ($s) = @_; $stored = $s->{'value'}; return 1; };
	my $block = sub {
		my ($prompt) = @_;
		my ($b) = $prompt =~ /(Rules the person asked you to follow on this turn[^\n]*\n(?:- [^\n]*\n?)*)/;
		return $b // '';
	};
	# Six short rules whose words are all in the question: all six fit.
	for my $i ( 1 .. 8 ) {
		subs::guide_rule_remember([ 'w' . $i ], 'CAP-rule ' . $i);
	}
	my $q = join(' ', map { 'w' . $_ } 1 .. 8);
	my $b = $block->(help::actions_prompt(undef, 0, $q));
	my @lines = $b =~ /^- /mg;
	is(scalar @lines, 6, 'at most six rules are injected');

	# A long rule costs more: the 800-character cap stops the block early.
	$stored = undef;
	for my $i ( 1 .. 6 ) {
		subs::guide_rule_remember([ 'long' . $i ], 'L' x 300);
	}
	my $ql = join(' ', map { 'long' . $_ } 1 .. 6);
	my $bl = $block->(help::actions_prompt(undef, 0, $ql));
	my $used = 0;
	$used += length($_) + 1 for ( $bl =~ /^(- [^\n]*)$/mg );
	cmp_ok($used, '<=', 800, 'the injected rule lines stay within 800 characters');
	ok(scalar(() = $bl =~ /^- /mg) >= 1, 'at least one rule still makes it in');
}

# --- the editor wiring ------------------------------------------------------
{
	my $template = do { local (@ARGV, $/) = ("$root/templates/configure/plat_setting_list.html.ep"); <> };
	like($template, qr/id="guide_rules_json"/, 'the rules textarea exists');
	like($template, qr/id="guide_rules_save"/, 'the rules Save button exists');
	like($template, qr/setting\s*=>\s*'guide_rules'/, 'the textarea shows the shared setting');
	like($template, qr/subs::ui\('Guide rules'\)/, 'the section is labelled in the on-screen words');

	my $js = do { local (@ARGV, $/) = ("$root/public/js/manager/configure/01_update_controls.js"); <> };
	like($js, qr/#guide_rules_save/, 'the Save button is wired');
	like($js, qr/setting:\s*'guide_rules'/, 'it writes the guide_rules setting');
	like($js, qr/settingSetter\(/, 'through the shared setting writer');
	like($js, qr/device:\s*'all'/, 'as a house setting every machine reads');
}

done_testing();
