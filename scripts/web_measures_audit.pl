#!/usr/bin/perl
# web_measures_audit.pl - test the web measures, list JSON paths, or convert a
# prettyfier id selector to a real JSON path.
#
#   perl scripts/web_measures_audit.pl [--app weather,metals] [--fetch] [--json]
#   perl scripts/web_measures_audit.pl --app weather --paths [--limit 40]
#   perl scripts/web_measures_audit.pl --app weather --convert-json [--apply]
#   perl scripts/web_measures_audit.pl --prune [--apply]
#
# --prune removes a web_measure_data row whose measure is not in app_measures
# (dead config such as weather/visibility). Without --fetch an HTML app is read
# from the last page stored in `websites`;
# a JSON app is fetched because the stored page is the prettyfied HTML, not the
# data. --fetch always asks the site. Nothing is written without --apply.
use strict;
use warnings;
no warnings 'once';
use FindBin;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './subroutines.pl';
use Mojo::UserAgent;
use Mojo::DOM;
use Mojo::JSON qw(decode_json encode_json);

my ($json, $fetch, $apply, $paths, $convert, $suggest, $prune, $limit) = (0, 0, 0, 0, 0, 0, 0, 40);
my (@apps, $only);
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	$json = 1 if $a eq '--json';
	$fetch = 1 if $a eq '--fetch';
	$apply = 1 if $a eq '--apply';
	$paths = 1 if $a eq '--paths';
	$convert = 1 if $a eq '--convert-json';
	$suggest = 1 if $a eq '--suggest';
	$prune = 1 if $a eq '--prune';
	@apps = split /,/, $ARGV[$i + 1] if $a eq '--app' && defined $ARGV[$i + 1];
	$limit = $ARGV[$i + 1] if $a eq '--limit' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/;
	$only = $ARGV[$i + 1] if $a eq '--measure' && defined $ARGV[$i + 1];
}

my %want = map { $_ => 1 } @apps;
my $apps = &subs::db_query('select distinct app from settings where setting = ? and app is not null order by app', 'web_measure_data')->hashes || [];
my @report;
foreach my $a ( @{$apps} ) {
	my $app = $a->{'app'};
	next if scalar @apps && !$want{$app};
	my $url = &subs::setting_value_for($app, 'web');
	next unless $url;
	my $format = &subs::setting_value_for($app, 'web_format') || 'html';

	# --prune: a web_measure_data row with no app_measures entry is dead config
	# (weather/visibility outlived its source). Delete it as a durable
	# tombstone so every machine drops it too.
	if ($prune) {
		my $am = eval { decode_json &subs::setting_value_for($app, 'app_measures') } || {};
		my $dead = &subs::db_query('select * from settings where app = ? and setting = ?', $app, 'web_measure_data')->hashes || [];
		my %seen;
		foreach my $wm ( @{$dead} ) {
			my $m = defined $wm->{'subsetting'} ? $wm->{'subsetting'} : '';
			next if exists $am->{$m} || $seen{$m}++;
			push @report, { app => $app, measure => $m, prune => 1 };
			if ($apply) {
				&subs::tombstone_writer({ table => 'settings', app => $app, uuid => $wm->{'uuid'}, scope => 'single' });
				&subs::db_query('delete from settings where app = ? and setting = ? and coalesce(subsetting, \'\') = ?', $app, 'web_measure_data', $m);
				$report[-1]->{'pruned'} = 1;
			}
		}
		next;
	}

	my ($raw, $data, $source);
	if ($fetch || $format eq 'json') {
		my $ua = Mojo::UserAgent->new(insecure => 1, inactivity_timeout => 30, connect_timeout => 10);
		my $res = eval { $ua->get($url => { user_agent => $gb::user_agent })->result };
		if ($res && $res->is_success) { $raw = $res->body; $source = 'fetch'; }
	}
	if (!defined $raw) {
		my $stored = &subs::db_query('select content from websites where app = ? and url = ? order by timestamp desc limit 1', $app, $url)->hashes->[0];
		$raw = $stored->{'content'} if $stored;
		$source = 'stored' if defined $raw;
	}
	unless (defined $raw && length $raw) {
		push @report, { app => $app, url => $url, format => $format, error => 'no page could be fetched or read' };
		next;
	}
	if ($format eq 'json') { $data = eval { decode_json $raw }; }

	if ($paths) {
		unless (ref $data) {
			push @report, { app => $app, url => $url, format => $format, error => 'not JSON' };
			next;
		}
		my $list = &subs::web_measure_json_paths($data);
		my $n = 0;
		foreach my $p ( @{$list} ) {
			last if $n++ >= $limit;
			push @report, { app => $app, path => $p->{'path'}, value => $p->{'value'} };
		}
		next;
	}

	my $am = eval { decode_json &subs::setting_value_for($app, 'app_measures') } || {};
	my $ctx = {
		format => $format,
		json => $data,
		dom => Mojo::DOM->new($raw),
		raw => $raw,
	};
	my $rows = &subs::setting_rows_for($app, 'web_measure_data', 'subsetting');
	foreach my $wm ( @{$rows} ) {
		next if defined $only && $only ne $wm->{'subsetting'};
		my $spec = eval { decode_json $wm->{'value'} } || {};
		$spec->{'measure'} ||= $wm->{'subsetting'};
		my $type = $am->{$wm->{'subsetting'}}->{'type'} || '';
		$spec->{'number'} = 1 if !exists $spec->{'number'} && ($type eq 'number' || $type eq 'range');
		$spec->{'unit'} ||= $am->{$wm->{'subsetting'}}->{'unit'};

		if ($suggest) {
			my @labels;
			push @labels, &subs::format_name($wm->{'subsetting'}) if defined $wm->{'subsetting'} && length $wm->{'subsetting'};
			push @labels, $am->{$wm->{'subsetting'}}->{'name'} if $am->{$wm->{'subsetting'}}->{'name'};
			push @labels, $wm->{'subsetting'} =~ s/_/ /gr if defined $wm->{'subsetting'};
			my %seen_label;
			@labels = grep { defined $_ && length $_ && !$seen_label{lc $_}++ } @labels;
			my @ok;
			my %seen_spec;
			foreach my $label ( @labels ) {
				my $suggestions = &subs::web_measure_suggest($ctx, $label);
				foreach my $s ( @{$suggestions} ) {
					my $key = encode_json($s->{'spec'});
					next if $seen_spec{$key}++;
					push @ok, $s;
					last if scalar @ok >= 4;
				}
				last if scalar @ok >= 4;
			}
			push @report, {
				app => $app, measure => $wm->{'subsetting'}, suggestions => \@ok,
				source => $source, format => $format, url => $url,
			};
			if ($apply && scalar @ok) {
				my $spec = { %{ $ok[0]->{'spec'} } };
				my $type = $am->{$wm->{'subsetting'}}->{'type'} || '';
				$spec->{'number'} = 1 if $type eq 'number' || $type eq 'range';
				$spec->{'unit'} = $am->{$wm->{'subsetting'}}->{'unit'} if $am->{$wm->{'subsetting'}}->{'unit'};
				&subs::setting_setter({
					app => $app, setting => 'web_measure_data', subsetting => $wm->{'subsetting'},
					value => encode_json($spec),
				});
				$report[-1]->{'applied'} = $spec;
			}
			next;
		}

		if ($convert) {
			next unless $format eq 'json' && !defined $spec->{'path'} && defined $spec->{'selector'};
			next unless $spec->{'selector'} =~ /^\s*\[id\s*=\s*["']?([^"'\]]+)["']?\]\s*$/i;
			my $path = &subs::web_measure_json_id_path($data, $1);
			push @report, { app => $app, measure => $wm->{'subsetting'}, ok => ($path ? 1 : 0), path => $path, old => $spec, error => ($path ? '' : 'no path for that id') };
			if ($path && $apply) {
				my $new = { %{$spec}, path => $path };
				delete $new->{'selector'};
				delete $new->{'count'};
				&subs::setting_setter({
					app => $app, setting => 'web_measure_data', subsetting => $wm->{'subsetting'},
					value => encode_json($new),
				});
			}
			next;
		}

		my $r = &subs::web_measure_extract($spec, $ctx);
		push @report, {
			app => $app, measure => $wm->{'subsetting'}, ok => ($r->{'ok'} ? 1 : 0),
			value => $r->{'value'}, used => $r->{'used'}, path => $r->{'path'},
			error => $r->{'error'}, selector => $spec->{'selector'}, row => $spec->{'row'},
			match => $spec->{'match'}, within => $spec->{'within'}, count => $spec->{'count'}, expr => $spec->{'path'},
			label => $spec->{'label'}, container => $spec->{'container'}, value_mode => $spec->{'value'},
			source => $source, format => $format, url => $url,
		};
	}
}

if ($json) {
	print encode_json({ results => \@report }), "\n";
	exit 0;
}

foreach my $r ( @report ) {
	if ($r->{'path'} && !defined $r->{'measure'}) {
		printf "%-20s %-58s = %s\n", $r->{'app'}, $r->{'path'}, (defined $r->{'value'} ? substr($r->{'value'}, 0, 60) : '');
		next;
	}
	if ($prune) {
		printf "%-20s %-20s %s\n", $r->{'app'}, $r->{'measure'}, ($r->{'pruned'} ? 'removed (no app_measures entry)' : 'would remove (no app_measures entry)');
		next;
	}
	if ($convert) {
		printf "%-20s %-20s %-4s %s\n", $r->{'app'}, $r->{'measure'}, ($r->{'ok'} ? 'OK' : 'FAIL'), ($r->{'path'} || $r->{'error'} || '');
		next;
	}
	if ($suggest) {
		my $s = $r->{'suggestions'} || [];
		if (scalar @{$s}) {
			printf "%-20s %-20s e.g. %-24s %s%s\n", $r->{'app'}, $r->{'measure'}, substr($s->[0]->{'value'},0,24), encode_json($s->[0]->{'spec'}), ($r->{'applied'} ? '  [saved]' : '');
			for my $extra ( @{$s}[1..$#{$s}] ) {
				last unless $extra;
				printf "%-42s alt  %-24s %s\n", '', substr($extra->{'value'},0,24), encode_json($extra->{'spec'});
			}
		}
		else {
			printf "%-20s %-20s no working label spec (%s)\n", $r->{'app'}, $r->{'measure'}, $r->{'source'} || '?'; 
		}
		next;
	}
	if ($r->{'error'} && !defined $r->{'measure'}) {
		printf "%-20s %s\n", $r->{'app'}, $r->{'error'};
		next;
	}
	my $how = $r->{'expr'} ? 'path=' . $r->{'expr'}
		: $r->{'row'} ? 'row=' . $r->{'row'} . ' match=' . ($r->{'match'} // '') . ' within=' . ($r->{'within'} // '') . ' count=' . ($r->{'count'} // 0)
		: defined $r->{'label'} ? 'label=' . $r->{'label'} . ($r->{'container'} ? ' in ' . $r->{'container'} : '') . ($r->{'value_mode'} ? ' -> ' . $r->{'value_mode'} : '')
		: 'selector=' . ($r->{'selector'} // '');
	printf "%-9s %-20s %-20s %-28s %s\n",
		($r->{'ok'} ? 'OK' : 'FAIL'), $r->{'app'}, $r->{'measure'},
		(defined $r->{'value'} ? substr($r->{'value'}, 0, 28) : ($r->{'error'} // '')),
		$how;
}
