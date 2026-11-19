package JawnOS::Routes::manager_misc9;

use strict;
use warnings;

sub routes {
	return (
	[27642, 'get', '/manager/terminal', 'action_27642'],
	[27770, 'post', '/manager/terminal/error_report', 'action_27770'],
	[27792, 'post', '/manager/window_closer', 'action_27792'],
	[27819, 'post', '/manager/terminal', 'action_27819'],
	[28093, 'get', '/manager/file/information', 'action_28093'],
	[28131, 'post', '/manager/file/information_updater', 'action_28131'],
	[28156, 'get', '/manager/cards', 'action_28156'],
	[28170, 'get', '/manager/card_picker', 'action_28170'],
	[28384, 'get', '/manager/synth', 'action_28384'],
	[28412, 'get', '/manager/studio', 'action_28412'],
	[28457, 'get', '/manager/studio/plug/select', 'action_28457'],
	[28480, 'post', '/manager/studio/save', 'action_28480'],
	[28546, 'get', '/manager/studio/load', 'action_28546'],
	[28573, 'post', '/manager/studio/delete', 'action_28573'],
	[29083, 'get', '/manager/twirl', 'action_29083'],
	[30779, 'get', '/manager/ide', 'action_30779'],
	[30859, 'post', '/manager/ide/folder_selector', 'action_30859'],
	[30875, 'post', '/manager/ide/folder_open', 'action_30875'],
	[44001, 'get', '/manager/controller', 'action_44001'],
	[44002, 'get', '/manager/controller/volume', 'action_44002'],
	[44003, 'post', '/manager/controller/volume', 'action_44003'],
	[44004, 'get', '/manager/games', 'action_44004'],
	[44005, 'get', '/manager/games/library', 'action_44005'],
	[44006, 'get', '/manager/games/art', 'action_44006'],
	[44007, 'post', '/manager/games/install', 'action_44007'],
	[44008, 'get', '/manager/games/install_status', 'action_44008'],
	[44009, 'post', '/manager/games/launch', 'action_44009'],
	[44010, 'get', '/manager/controller/config', 'action_44010'],
	[44011, 'get', '/manager/controller/time', 'action_44011'],
	[44012, 'post', '/manager/controller/time', 'action_44012'],
	[44013, 'get', '/manager/controller/retroarch', 'action_44013'],
	[44014, 'post', '/manager/controller/retroarch', 'action_44014'],
	[44015, 'post', '/manager/games/emulator', 'action_44015'],
	[44016, 'post', '/manager/games/covers', 'action_44016'],
	[44017, 'get', '/manager/games/covers/status', 'action_44017'],
	[44018, 'get', '/manager/games/launch_status', 'action_44018'],
	[44019, 'post', '/manager/game_play', 'action_44019'],
	[44020, 'post', '/manager/controller/panel', 'action_44020'],
	[44021, 'get',  '/manager/controller/power', 'action_44021'],
	[44022, 'post', '/manager/studio/latency', 'action_44022'],
	[44023, 'post', '/manager/studio/take', 'action_44023'],
	[44024, 'get', '/manager/games/play', 'action_44024'],
	[44025, 'get', '/manager/games/dos_bundle', 'action_44025'],
	[44026, 'get', '/manager/games/peer_library', 'action_44026'],
	[44027, 'get', '/manager/games/serve', 'action_44027'],
	[44028, 'get', '/manager/games/house', 'action_44028'],
	[44029, 'post', '/manager/games/pull', 'action_44029'],
	[44032, 'post', '/manager/studio/export', 'action_44032'],
	);
}

1;
