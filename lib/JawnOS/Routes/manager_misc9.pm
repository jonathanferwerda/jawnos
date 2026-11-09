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
	);
}

1;
