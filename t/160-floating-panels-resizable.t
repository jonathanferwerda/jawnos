# tests-for: public/js/manager/manager.js public/js/manager/agents.js public/js/manager/coding/02_panels.js public/js/manager/keyboard.js perl/help/topics_functions.pl perl/help/topics_features.pl
# covers:    The floating panels - the dock's keyboard panels, the floating soft
#            keyboard, the Guide associate, the Coding agent and the Agents list
#            - are all sized by their edge or corner, and the size they were
#            left at is remembered per device with their place. The dock panel
#            restore no longer overwrites a saved width with the default.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;

my $manager = js_source('public/js/manager/manager.js');
my $agents = js_source('public/js/manager/agents.js');
my $coding = js_source('public/js/manager/coding/02_panels.js');
my $keyboard = js_source('public/js/manager/keyboard.js');
my $kb_maker = js_source('public/js/manager/keyboard/02_keyboard_maker.js');
my $help = help_source();

# --- the shared chat-panel memory keeps the size ----------------------------
like($manager, qr/function jawnosPanelPosSave\(key, panel\)/, 'the panel spot saver exists');
like($manager, qr/var spot = \{ left: Math\.round\(left\), top: Math\.round\(top\) \};/,
	'the spot still carries its place');
like($manager, qr/var width = parseFloat\(panel\.css\('width'\)\), height = parseFloat\(panel\.css\('height'\)\);/,
	'the save reads the panel size');
like($manager, qr/spot\.width = Math\.round\(width\)/, 'the width rides with the place');
like($manager, qr/spot\.height = Math\.round\(height\)/, 'the height rides with the place');
like($manager, qr/function jawnosPanelPosRestore\(key, panel\)/, 'the panel spot restorer exists');
like($manager, qr/panel\.css\('width', saved_w \+ 'px'\)/, 'a saved width is applied');
like($manager, qr/panel\.css\('height', saved_h \+ 'px'\)/, 'a saved height is applied');
like($manager, qr/saved_w = Math\.min\(s\.width, Math\.max\(160, \$\(window\)\.width\(\) - 8\)\)/,
	'a saved width is clamped to the screen');
like($manager, qr/saved_h = Math\.min\(s\.height, Math\.max\(120, \$\(window\)\.height\(\) - limit - bar - 8\)\)/,
	'a saved height is clamped above the taskbar, under the ceiling');
like($manager, qr/var limit = \(typeof panelTopLimit == 'function'\) \? panelTopLimit\(\) : 0;/,
	'the panel place is held under the clothesline ceiling');
like($manager, qr/var top = Math\.max\(limit, Math\.min\(s\.top, \$\(window\)\.height\(\) - h - bar\)\);/,
	'a saved spot never puts the header behind a top taskbar or the clothesline');

# --- a panel opened from the taskbar keeps its header in reach ---------------
like($manager, qr/function assistantOpenPanel\(panel\)/, 'the associate opener exists');
like($manager, qr/panel\.css\('max-height', Math\.max\(180, \$\(window\)\.height\(\) - limit - bar - 16\) \+ 'px'\);/,
	'the associate is capped to the room under the ceiling');
like($manager, qr/var top = Math\.max\(limit, Math\.min\(\$\(window\)\.height\(\) - h - 70, Math\.max\(limit, \$\(window\)\.height\(\) - h - bar - 6\)\)\);/,
	'a fresh associate opens under the ceiling, with its header and close in reach');

# --- one resizable helper, by edge and corner -------------------------------
like($manager, qr/function jawnosPanelResizable\(panel, keyOf\)/, 'the resizable helper exists');
like($manager, qr/handles: 'e, s, se'/, 'the edge and corner handles are offered');
like($manager, qr/minWidth: 240,\s*minHeight: 180,/, 'a panel keeps a usable minimum');
like($manager, qr/jawnosPanelPosSave\(\(typeof keyOf == 'function'\) \? keyOf\(p\) : keyOf, p\);/,
	'the size is saved under the panel\'s own key');
like($manager, qr/function jawnosPanelAnchor\(panel\)/, 'right/bottom anchored panels are normalised first');
like($manager, qr/panel\.css\(\{ left: rect\.left \+ 'px', top: rect\.top \+ 'px', right: 'auto', bottom: 'auto' \}\)/,
	'and keep their visual spot');

# --- every chat/agent panel is armed ----------------------------------------
like($manager, qr/jawnosPanelResizable\(panel, function \(p\) \{ return 'guide:' \+ \(p\.attr\('conversation'\) \|\| 'assistant'\)/,
	'the Guide associate is resizable, keyed by its conversation');
like($coding, qr/jawnosPanelResizable\(panel, function \(p\) \{ return 'coding:' \+ \(p\.attr\('conversation'\) \|\| p\.attr\('mount'\)\)/,
	'a Coding agent is resizable, keyed by its conversation');
like($agents, qr/jawnosPanelResizable\(panel, 'agents'\)/, 'the Agents list is resizable');

# --- the dock keyboard panels are resizable and keep a saved width ---------
like($keyboard, qr/k\.resizable\(\{/, 'a dock keyboard panel is resizable');
like($keyboard, qr/handles: 'e, s, se'/, 'with edge and corner handles');
like($keyboard, qr/function keyboardPanelSave\(panel\)/, 'one save writes its whole style');
like($keyboard, qr/jawnosWindowStyleSet\(id, jcss\);/, 'the style dump is kept per device');
like($keyboard, qr/stop: function\(\) \{ keyboardPanelSave\(\$\(this\)\); \}/,
	'the resize stop saves the new size');
like($keyboard, qr/stop: function\(p\) \{\s*keyboardPanelSave\(\$\(this\)\);\s*\}/,
	'the drag stop saves through the same helper');
like($kb_maker, qr/if \(css\['width'\] == null \|\| css\['width'\] === ''\) \{ css\['width'\] = t\.width\(\); \}/,
	'a saved width is not overwritten by the panel\'s default');

# --- the guide explains it ---------------------------------------------------
like($help, qr/Drag its edge or corner to size it/, 'the agents topic explains resizing');
like($help, qr/It opens under the top edge/, 'the agents topic says a panel opens under the top edge');
like($help, qr/resized by its edge or corner, and both its place and its size are remembered/,
	'the dock topic explains the dock panels\' size memory');

done_testing();
