package Manager;

# manager_mapping: the per-console control map. The page draws the Gou and the
# console it is standing in for; a person arms a button on the Gou and then
# presses the console button it should produce. The mapping is stored as a
# house setting (one per device, like the rest of the Games app) and the save
# writes the RetroArch remap the emulator reads. The mapping table itself lives
# in lib/JawnOS/GameMapping.pm, so the page and the writer share one truth.

use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json);
use JawnOS::GameMapping;

# GET /manager/games/mapping
sub action_44100 {
	my $c = shift;
	my $system = &JawnOS::GameMapping::resolve_system($c->param('system')) || 'n64';
	my $raw = eval { &subs::setting_grabber({ app => 'games', setting => "mapping_$system" }) };
	my $mapping = &JawnOS::GameMapping::load_mapping($system, $raw);
	my $contents = $c->render_to_string(
		template => 'controller/mapping',
		system => $system,
		systems => &JawnOS::GameMapping::system_list(),
		profile => &JawnOS::GameMapping::profile($system),
		mapping => $mapping,
		defaults => &JawnOS::GameMapping::default_mapping($system),
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'games', contents => $contents }, $c->param('timestamp'));
	$c->render(text => $website);
}

# POST /manager/games/mapping
sub action_44101 {
	my $c = shift;
	my $system = &JawnOS::GameMapping::resolve_system($c->param('system'));
	unless ($system) {
		return $c->render(json => { ok => 0, error => &subs::ui('That console is not one the house knows.') });
	}
	my $raw = eval { decode_json($c->param('mapping') // '') };
	unless (ref $raw eq 'HASH') {
		return $c->render(json => { ok => 0, error => &subs::ui('The mapping was not readable.') });
	}
	my $mapping = &JawnOS::GameMapping::normalize_mapping($system, $raw);
	unless (ref $mapping eq 'HASH') {
		return $c->render(json => { ok => 0, error => &subs::ui('The mapping could not be read.') });
	}
	my $saved = eval {
		&subs::setting_setter({
			app => 'games',
			setting => "mapping_$system",
			value => &JawnOS::GameMapping::dump_mapping($mapping),
		});
		1;
	};
	# The remap is the part that touches the person's home directory. A refusal
	# there must not lose the mapping they just made, so it is reported as a
	# note beside a save that succeeded.
	my $remap = eval { &JawnOS::GameMapping::write_remap($system, $mapping) }
		|| { ok => 0, error => &subs::ui('the remap could not be written') };
	my $note;
	if (!$saved) {
		$note = &subs::ui('The mapping could not be saved.');
	}
	elsif ($remap->{'ok'}) {
		$note = &subs::ui('Saved. The emulator remap was written to ') . $remap->{'path'};
	}
	else {
		$note = &subs::ui('Saved, but the emulator remap could not be written: ')
			. ($remap->{'error'} // &subs::ui('unknown error'));
	}
	return $c->render(json => {
		ok => $saved ? 1 : 0,
		system => $system,
		mapping => $mapping,
		remap => {
			ok => $remap->{'ok'} ? 1 : 0,
			path => $remap->{'path'},
			error => $remap->{'error'},
		},
		note => $note,
	});
}

1;
