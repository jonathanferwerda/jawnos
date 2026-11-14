# tests-for: lib/JawnOS/Manager/Part16.pm templates/apps/inventory.html.ep public/js/manager/inventory.js public/css/manager.css perl/help/topics_business.pl
# covers:    The inventory panel names the open session, reads a stored Allocation
#            choice as the timeline, and carries the table/card/control wording
#            that makes the lookback matrix readable.

use strict;
use warnings;
use utf8;

no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::Template;
use RepoSource qw(repo_root);

my $root = repo_root();
my $part16 = $root . '/lib/JawnOS/Manager/Part16.pm';
require $part16;

$gb::budget_modes = {
	duration => {}, occurences => {}, total => {}, quantity => {},
};

package FakeResult;

sub new {
	my ($class, $rows) = @_;
	return bless { rows => $rows }, $class;
}

sub hashes {
	my $self = shift;
	return [ map { { %{$_} } } @{$self->{'rows'}} ];
}

package FakeController;

sub new {
	my ($class, $params) = @_;
	return bless { params => $params, rendered => {} }, $class;
}

sub param {
	my ($self, $name) = @_;
	return $self->{'params'}->{$name};
}

sub render_to_string {
	my ($self, %args) = @_;
	$self->{'rendered'} = { %args };
	return '';
}

package main;

my $now = 1800000000000;
my $started = $now - 9000000;	# two and a half hours ago

{
	no warnings 'redefine';
	*subs::rightNow = sub { return $now };
	*subs::setting_setter = sub { };
	*subs::settings_grabber = sub { return {} };
	*subs::setting_grabber = sub { return undef };
	*subs::db_query = sub {
		return FakeResult->new([
			{
				app => 'depressed', type => 'start', timestamp => $started,
				duration => 0, stop_timestamp => '', total => 0,
				measures => '', unit => '', quantity => 0, uuid => 'u1',
				server_time => $started,
			},
		]);
	};
	*subs::format_name = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::unformat_name = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::time_scope_page = sub { return ('this', 'last') };
	*subs::duration_sayer = sub { return '2h 30m' };
	*subs::time_abbrev_translator = sub { return $_[0] };
	*subs::timespan_widener = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::cache_get = sub { return {} };
	*subs::cache_set = sub { };
	*subs::random_string_creator = sub { return 'random' };
	*subs::appt_header_printer = sub { };
	*Manager::father_time = sub { return (0, 4000000000000) };
	*Manager::appointment_overlap = sub { return $_[1] ? 9000000 : 0 };
	*Manager::budget_calculator = sub { return {} };
	*Manager::budget_status_maker = sub { return $_[0] };
	*Manager::allocation_duration_add = sub { };
	*Manager::formula_calculator = sub { return ('', 0, '', '') };
	*Websocket::send = sub { };
}

my $c = FakeController->new({ app => 'depressed' });
my $settings = {
	app_measures => '{"intensity":"21","polarity":"0"}',
	s_display => 'duration',
	s_visual => 'allocation',
	s_calc => 'sum',
	s_lock => 'on',
	s_scope_count => 30,
	s_movement => '["all"]',
	duration => '4h 54m',
	unit => 'belief',
};

my $returner = eval { Manager::inventory_details($c, $settings) };
is($@, '', 'the panel renders with a stored Allocation choice');
is($returner->{'settings'}->{'s_visual'}, 'historical', 'a stored Allocation choice reads as the timeline');
is_deeply($returner->{'time_lengths'}, [ qw/minute hour day week month year/ ], 'the timeline columns are the readable units');
ok($returner->{'running'}, 'the open session is named on the panel');
is($returner->{'running'}->{'timestamp'}, $started, 'the notice carries the session start');
cmp_ok($returner->{'running'}->{'duration'}, '==', 9000000, 'the notice carries the running time');
is($returner->{'running'}->{'duration_text'}, '2h 30m', 'the notice carries a readable duration');

my $template = read_file("$root/templates/apps/inventory.html.ep");
like($template, qr/inventory_table_help/, 'the table carries its lookback explanation');
like($template, qr/Rows are how far back/, 'the explanation says how to read the rows');
like($template, qr/'Lookback'/, 'the first column is named');
like($template, qr/\$row_label\{\$rw\}/, 'rows are rendered through their readable labels');
like($template, qr/'Average gap'/, 'the average gap card is named');
like($template, qr/'First to last'/, 'the first-to-last card is named');
like($template, qr/'All time'/, 'the cards say they are all time');
like($template, qr/'Still running'/, 'the running session is called out');
like($template, qr/'Auto-calc'/, 'the calculator has a label');
like($template, qr/statistic_empty/, 'empty cells have a marker');
like($template, qr/inventory_status_legend/, 'budget cell colours have a key');
like($template, qr/statistic_pie_caption/, 'the share wheel has a caption');
like($template, qr/class="statistic_visual" value="historical"/, 'the timeline is the only view offered');
unlike($template, qr/<option value="allocation"/, 'the broken Allocation option is hidden');

my $js = read_file("$root/public/js/manager/inventory.js");
like($js, qr/function inventoryCellHints/, 'cells get their exact dates as a hint');
like($js, qr/inventoryCellHints\(iq, response\)/, 'the hint pass runs after the panel lands');
like($js, qr/function statisticChartCaptions/, 'the charts carry captions');
like($js, qr/statisticChartCaptions\(data\)/, 'the caption pass runs with the charts');

my $css = read_file("$root/public/css/manager.css");
like($css, qr/\.inventory_details \.inventory_running/, 'the running notice has a surface');
like($css, qr/\.inventory_details \.inventory_status_chip\.inv_status_burnt_out/, 'the status key wears the status palette');
like($css, qr/\.inventory_details \.statistic_empty/, 'the empty marker is quiet');

my $help = read_file("$root/perl/help/topics_business.pl");
like($help, qr/lookback matrix/i, 'the help topic explains the table');
like($help, qr/average gap/i, 'the help topic explains the gap card');
like($help, qr/still running/i, 'the help topic explains the running notice');
like($help, qr/verified => '2026-11-14'/, 'the topic carries the audit date');

# ---- the page compiles with the keys inventory_details passes ----------------
#
# Mojo::Template declares exactly the stash keys it is handed and compiles the
# page under strict, so a template that reads a key the details call does not
# pass is a 500 on the whole panel. Render the real page with that stash.
{
	no warnings 'redefine';
	*subs::ui = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::lang = sub { my $k = shift; return $k eq 'common.total' ? 'Total' : $k; };
	*subs::duration_readout = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::icon_for = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::icon_plate_colours = sub { return { plate => '#ffffff', ink => '#111111' } };
	*subs::price_formatter = sub { return defined $_[0] ? "$_[0]" : '' };
}

my $stash = {
	app => 'depressed',
	appts => [ {
		app => 'depressed', type => 'start', timestamp => $started,
		duration => 9000000, stop_timestamp => '', total => 0,
		measures => '', unit => '', quantity => 0, uuid => 'u1',
		server_time => $started,
	} ],
	settings => $settings,
	returner => $returner,
	time_scopes => $returner->{'scopes'},
	time_lengths => $returner->{'time_lengths'},
	movements => [ 'all', 'start' ],
	display_options => [ { name => 'duration', formatted_name => 'Duration' } ],
	measure_calc_json => '{}',
	evaluation => {},
};
my $mt = Mojo::Template->new(vars => 1, namespace => 'InventoryRender');
my $source = read_file("$root/templates/apps/inventory.html.ep");
my $html;
{
	local $SIG{__WARN__} = sub { };
	$html = eval { $mt->render($source, $stash) };
}
is($@, '', 'the inventory page compiles with the details stash');
like($html || '', qr/inventory_table_help/, 'the rendered page carries the table explanation');
like($html || '', qr/Still running/, 'the rendered page names the running session');
like($html || '', qr/Average gap/, 'the rendered page names the gap card');
like($html || '', qr/Lookback/, 'the rendered page names the lookback column');
like($html || '', qr/>Current</, 'the current lookback row is named in words');
like($html || '', qr/>Previous</, 'the previous lookback row is named in words');
unlike($html || '', qr/HASH\(/, 'average and total cells render values, not a hash reference');

done_testing();
