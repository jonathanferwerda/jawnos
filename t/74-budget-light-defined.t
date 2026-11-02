#!/usr/bin/perl
# tests-for: public/js/manager/budget/00_budget_light.js
#
# The appointment view's budget light is opened by budgetLight(). The callers
# all name it but the definition had gone missing, so a click filled nothing
# and the budget_current_information panel came up with no view.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Spec;

my $root  = File::Spec->catdir(dirname(__FILE__), '..');
my $light = File::Spec->catfile($root, 'public', 'js', 'manager', 'budget', '00_budget_light.js');

ok(-e $light, 'the budget light has a definition file');

my $src = '';
if (-e $light) {
	local $/;
	open my $fh, '<', $light or die "cannot read $light: $!";
	$src = <$fh>;
	close $fh;
}

like($src, qr/function\s+budgetLight\s*\(/, 'budgetLight() is defined');
like($src, qr{/manager/budget/current_information}, 'the light reads the current_information route');
like($src, qr/budget_current_information/, 'the light fills the budget_current_information panel');
like($src, qr/\.show\(\)/, 'opening the light shows the panel');

# Every caller that was left pointing at nothing still names the function.
my @callers = (
	['public', 'js', 'manager', 'windows.js'],
	['public', 'js', 'manager', 'windows', '01_storage.js'],
	['public', 'js', 'manager', 'websocket', '01_message_handler.js'],
	['public', 'js', 'manager', 'budget', '01_reconcile_payables.js'],
);

foreach my $parts (@callers) {
	my $path = File::Spec->catfile($root, @{$parts});
	my $text = '';
	if (-e $path) {
		local $/;
		open my $cfh, '<', $path or die "cannot read $path: $!";
		$text = <$cfh>;
		close $cfh;
	}
	like($text, qr/budgetLight\s*\(/, join('/', @{$parts}) . ' calls budgetLight()');
}

done_testing();
