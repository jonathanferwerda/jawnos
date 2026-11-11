# tests-for: templates/keyboard.html.ep public/js/manager/keyboard/03_editor_switcher.js
# covers:    The remote_control VPN button routed only through a machine in the
#           roster, so an exit node the house had not enrolled - the house
#           server itself, whose roster row carries no tailnet address - was
#           never offered and the button could not use it. The panel now lists
#           the tailnet's own exit nodes beside the button.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $tpl  = read_file("$root/templates/keyboard.html.ep");
my $js   = read_file("$root/public/js/manager/keyboard/03_editor_switcher.js");

# --- the panel offers the node it will use ----------------------------------
my ($toolbar, $content) = split /<div id="remote_control_view"/, $tpl, 2;
unlike($toolbar // '', qr/id="remote_control_vpn_node"/,
	'the exit-node list is not in the top toolbar');
my ($me_view) = ($content // '') =~ /if \( !\$selected_rm \) \{(.*?)\} else \{/s;
like($me_view // '', qr/id="remote_control_vpn_node"/,
	'the exit-node list lives on the Me view');
like($me_view // '', qr/id="remote_control_vpn_row"/,
	'and has a row that can stay hidden when no node offers one');
like($tpl, qr/<button type="button" id="remote_control_vpn"/,
	'the VPN button is still there');

# --- the list comes from the tailnet, not the roster ------------------------
like($js, qr/function jawnosVpnNodes\(status\)/,
	'the node list is built from a tailnet status');
like($js, qr/if \(!p\.ip \|\| !p\.exit \|\| !p\.online\) \{ continue; \}/,
	'only an online peer that offers an exit node is listed');
like($js, qr/jawnosVpnStatus\(function \(s\) \{.*?jawnosVpnNodes\(s\)/s,
	'refresh reads the live tailnet status before choosing');
unlike($js, qr/if \(!picked\.ip\) \{/,
	'a machine with no tailnet address no longer blocks the button');
like($js, qr/sel\.append\(\$\('<option>'\)\.val\(nodes\[i\]\.ip\)\.text\(nodes\[i\]\.name\)\)/,
	'each exit node becomes an option on the list');
like($js, qr/\$\('#remote_control_vpn_row'\)\.toggle\(nodes\.length > 0\)/,
	'the Me view hides the row when no node offers one');
like($js, qr/if \(!\$\('#remote_control_vpn_node'\)\.length\) \{ b\.hide\(\); return; \}/,
	'a peer view shows no VPN button');
like($js, qr/function jawnosVpnTarget\(\)/,
	'the button has one place that names its target');
like($js, qr/var target = on \? '' : jawnosVpnTarget\(\);/,
	'turning the VPN on targets the chosen exit node');
like($js, qr/\$\.post\('\/manager\/tailnet\/exit', \{ ip: target \}/,
	'and that target is what the route is asked to use');

# --- the rule itself, run against sample statuses ---------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my $harness = "$FindBin::Bin/lib/vpn_exit_nodes.js";
	my $out = `$node "$harness" "$FindBin::Bin/../public/js/manager/keyboard/03_editor_switcher.js" 2>&1`;
	my $status = $? >> 8;
	my @lines = grep { /^(?:not )?ok / } split /\n/, $out;
	ok(scalar @lines >= 4, 'the exit-node harness ran');
	for my $line (@lines) {
		my ($verdict, $name) = $line =~ /^(ok|not ok) (.*)$/;
		ok($verdict eq 'ok', $name);
	}
	is($status, 0, 'the exit-node harness exits clean');
}
else {
	diag('node is not installed; the behavioural exit-node checks are skipped');
}


like($js, qr/dock_key == 'k'.*?softKbDockOpen\('letters'\)/s, 'Ctrl+Super+K opens the keyboard');
like($js, qr/dock_key == 'c'.*?softKbDockOpen\('calc'\)/s, 'Ctrl+Super+C opens the calculator');

done_testing();
