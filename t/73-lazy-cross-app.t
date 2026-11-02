# tests-for: public/js/manager/folders/01_view_and_commands.js public/js/manager/jp.js public/js/manager/keyboard/01_side_dock.js public/js/manager/manager/06_appointment_distance.js public/js/manager/travel/01_map_render_points.js public/js/manager/websocket/01_message_handler.js public/js/manager/windows.js public/js/manager/windows/01_storage.js public/js/manager/windows/02_fit.js
# covers:    Lazy app chunks are a trap for core code: a core handler that calls a function living in an app's chunk throws...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Lazy app chunks are a trap for core code: a core handler that calls a function
# living in an app's chunk throws "X is not defined" the moment that app has not
# been opened - and where the throw happens inside jQuery UI's drag callback it
# stops the window being moved at all. These are the roads that were repaired,
# and the rule that keeps a shared helper out of a chunk in the first place.

my $root = repo_root();
my $fits = read_file("$root/public/js/manager/windows/02_fit.js");
my $windows = read_file("$root/public/js/manager/windows.js");
my $storage = read_file("$root/public/js/manager/windows/01_storage.js");
my $ws = read_file("$root/public/js/manager/websocket/01_message_handler.js");
my $folders = read_file("$root/public/js/manager/folders/01_view_and_commands.js");
my $jp = read_file("$root/public/js/manager/jp.js");
my $dock = read_file("$root/public/js/manager/keyboard/01_side_dock.js");
my $core = read_file("$root/public/js/manager/manager/06_appointment_distance.js");
my $travel = read_file("$root/public/js/manager/travel/01_map_render_points.js");

# --- the drag that stopped working -----------------------------------------
like($fits, qr/if \(typeof markerDragger === 'function'\) \{ markerDragger\(p\.target\.id,'drag'\); \}/,
	'the drag callback asks for Marker only when its chunk is there');
like($fits, qr/if \(typeof markerDragger === 'function'\) \{ markerDragger\(p\.target\.id,'stop'\); \}/,
	'so does the stop callback');

# --- a shared helper belongs in core, not in one app's chunk ---------------
like($core, qr/^function continent_record\(/m,
	'continent_record lives in the core, where its ten callers are');
like($core, qr/^function continent_cancel\(/m, 'continent_cancel lives with it');
like($core, qr/^function jawnGpsFix\(/m, 'the GPS helpers it needs moved with it');
like($core, qr/^function continent_record_anyway\(/m, 'and the anyway route');
unlike($travel, qr/^function continent_record\(/m,
	'the Travel chunk no longer owns a function the whole manager calls');
unlike($travel, qr/^function jawnGpsWait\(/m, 'nor the helper beside it');

# --- the rest are guarded at the call site ---------------------------------
like($windows, qr/if \(typeof budgetLight === 'function'\) \{ budgetLight\(app_attr,circumstance,'open'\); \}/,
	'a window redraw guards the budget light');
like($storage, qr/if \(typeof budgetLight === 'function'\) \{ budgetLight\(i,v\['current_information'\],'open'\); \}/,
	'so does a restored window');
my $budget_guards = () = $ws =~ /typeof budgetLight === 'function'/g;
is($budget_guards, 2, 'both websocket paths guard the budget light');
like($ws, qr/if \(typeof terminalDataReceiver === 'function'\) \{ terminalDataReceiver\(data\); \}/,
	'a terminal message with no terminal chunk is ignored');
like($folders, qr/if \(typeof studioImport === 'function'\) \{ studioImport\(response\['files'\]\); \}/,
	'a studio file picked from a folder asks for the studio only if it is there');
like($folders, qr/if \(typeof ideFileOpen !== 'function'\) \{ return; \}/,
	'an IDE file picked from a folder returns quietly');
like($jp, qr/var marker = \(typeof markerInfoGrabber === 'function'\) \? markerInfoGrabber\(\) : \{\};/,
	'a recording with no Marker chunk reads an empty marker');
like($dock, qr/if \(typeof portfolioMaker === 'function'\) \{ portfolioMaker\(response\['portfolio'\]\); \}/,
	'the side dock guards the portfolio');

# --- the details form is fetched after the window, not before ---------------
like($windows, qr/appSectionGrabber\(app, 'details', win\)/, 'a drawn window prefetches its details form');
like($windows, qr/requestIdleCallback\(prefetch/, 'it waits for idle time rather than delaying the open');

done_testing();
