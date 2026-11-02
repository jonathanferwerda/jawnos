#!/usr/bin/perl
# tests-for: public/js/manager/budget_light.js lib/JawnOS/Manager/Core1_tables_hooks.pm
#
# The appointment view's budget light is opened by budgetLight(). An appointment
# view renders .budget_light and .budget_current_information without the Budget
# app ever being opened, so the click binding and the function have to be in the
# core bundle. Put in the lazy budget chunk, they arrived only after the Budget
# app was opened and every click before that filled nothing - the panel came up
# with no view.
#
# The bundle and every lazy chunk share one global scope, so a second definition
# of these names anywhere in public/js would silently replace the core one. That
# is exactly how a "restore" of budgetLight inside budget/ left the appointment
# view broken while every file still parsed (v0.1.1810).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Find qw(find);
use File::Spec;

my $root  = File::Spec->catdir(dirname(__FILE__), '..');
my $light = File::Spec->catfile($root, 'public', 'js', 'manager', 'budget_light.js');

ok(-e $light, 'the budget light lives in the core bundle');

my $src = '';
if (-e $light) {
	local $/;
	open my $fh, '<', $light or die "cannot read $light: $!";
	$src = <$fh>;
	close $fh;
}

like($src, qr/^function\s+budgetLight\s*\(/m, 'budgetLight() is defined');
like($src, qr/\.on\('click',\s*'\.budget_light'/, 'the core binds the light click');
like($src, qr{/manager/budget/current_information}, 'the light reads the current_information route');
like($src, qr/budget_current_information/, 'the light fills the budget_current_information panel');
like($src, qr/\.show\(\)/, 'opening the light shows the panel');

# The bundle list is what puts it in the page before any app is opened.
my $boot = '';
for my $part (qw(Core1_tables_hooks.pm Core2_worker_boot.pm Manager.pm)) {
	my $path = File::Spec->catfile($root, 'lib', 'JawnOS', 'Manager', $part);
	next unless -e $path;
	local $/;
	open my $bh, '<', $path or die "cannot read $path: $!";
	$boot .= <$bh>;
	close $bh;
}
like($boot, qr{^\s*/js/manager/budget_light\.js\s*$}m,
	'budget_light.js is named in the manager bundle');

# It must not also be owned by the lazy budget app, or it would be fetched as a
# chunk (and loaded twice) instead of arriving with core.
my ($apps_block) = $boot =~ /our %manager_app_scripts = \((.*?)\n\);/s;
unlike($apps_block // '', qr/budget_light/,
	'no app chunk claims the core budget light');

# One definition, anywhere the page can concatenate.
my @defs;
find(
	{
		no_chdir => 1,
		wanted   => sub {
			my $path = $File::Find::name;
			return unless -f $path && $path =~ /\.js$/;
			open my $fh, '<', $path or return;
			while (my $line = <$fh>) {
				push @defs, $path if $line =~ /^function\s+budgetLight\s*\(/;
			}
			close $fh;
		},
	},
	File::Spec->catdir($root, 'public', 'js'),
);
is(scalar(@defs), 1, 'budgetLight() is defined exactly once in public/js')
	or diag("definitions: @defs");

# Every caller that opens or restores the panel still names the function.
my @callers = (
	['public', 'js', 'manager', 'budget_light.js'],
	['public', 'js', 'manager', 'windows.js'],
	['public', 'js', 'manager', 'windows', '01_storage.js'],
	['public', 'js', 'manager', 'websocket', '01_message_handler.js'],
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
