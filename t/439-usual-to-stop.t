# tests-for: scripts/usual_to_stop.pl lib/JawnOS/Domain/Usual.pm lib/JawnOS/Domain/UsualWrite.pm lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Domain/Resolve.pm lib/JawnOS/Manager/Part28.pm lib/JawnOS/Manager/Part29.pm templates/apps/edit_app.html.ep perl/gb/03_engines_and_tools.pl
# covers:    the one-off migration that turns the person's old usual rows into stop rows, and the sign-aware session reading that lets both the old end-anchored rows and the new start-anchored pre-usual rows share one type

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();

# ---------------------------------------------------------------- the script
my $script = read_file("$root/scripts/usual_to_stop.pl");
like($script, qr/my \$apply = \(grep \{ \$_ eq '--apply' \} \@ARGV\)/, 'the default is a dry run');
like($script, qr/type = 'usual'/, 'it starts from the usual type');
like($script, qr/coalesce\(source, ''\) in \('', 'press'\)/, 'only the person\'s own press or older blank source');
like($script, qr/coalesce\(source_uuid, ''\) = ''/, 'a child of another appointment is left alone');
like($script, qr/stop_timestamp is null or stop_timestamp = ''/, 'a row that already names a stop is left alone');
like($script, qr/cast\(timestamp as integer\) < \?/, 'only rows before the migration moment');
like($script, qr/update appointments set type = 'stop', stop_seen = 'yes', seen = 'yes', server_time = \?/,
	'the write changes the type and closes the row, and stamps it for sync');
unlike($script, qr/\btimestamp\s*=/, 'the script never assigns timestamp');
unlike($script, qr/\bduration\s*=/, 'the script never assigns duration');
unlike($script, qr/set [^\n]*stop_timestamp/, 'the script never assigns stop_timestamp');

# ------------------------------------------------------------ the session read
my $usual = read_file("$root/lib/JawnOS/Domain/Usual.pm");
like($usual, qr/my \$signed = 0 \+ \(\$row->\{'duration'\} \/\/ 0\)/,
	'the learner reads the duration sign');
like($usual, qr/\$start = \$stamp - abs\(\$signed\)/,
	'a positive length puts the start before the press');
like($usual, qr/\$end = \$stamp \+ abs\(\$signed\)/,
	'a negative length puts the end after the press');
like($usual, qr/not in \('task','default','guide'\)/,
	'the usual fallback drops task, default and guide children');
like($usual, qr/coalesce\(source_uuid, ''\) = ''/,
	'and drops a child that names a parent');

# ---------------------------------------------------------------- the writer
my $write = read_file("$root/lib/JawnOS/Domain/UsualWrite.pm");
like($write, qr/type => 'stop'/, 'the usual parent is written as a stop');
like($write, qr/stop_seen => 'yes'/, 'and is closed');
like($write, qr/status => 'usual'/, 'while keeping the usual marker in status');
like($write, qr/duration => \$at->\{'signed'\}/, 'with the signed length the sign-aware reader expects');
like($write, qr/type => 'stop',\s*\}, \{\s*project/, 'the default model/options inherit the stop type');

# --------------------------------------------- every other usual writer
my $warehouse = read_file("$root/lib/JawnOS/Domain/Warehouse.pm");
like($warehouse, qr/type => 'stop',[\s\S]{0,180}stop_seen => 'yes'/, 'a task completion is a closed stop');
unlike($warehouse, qr/type => 'usual'/, 'the task writer has no usual type left');

my $generate = read_file("$root/lib/JawnOS/Domain/Generate.pm");
like($generate, qr/\(\$source_row->\{'type'\} \|\| ''\) eq 'stop'/, 'a default child of a stop parent is spanned by the parent sign');
like($generate, qr/\$done\{'duration'\} = -abs\(\$p_dur\)/, 'and written as a negative stop length');

my $part29 = read_file("$root/lib/JawnOS/Manager/Part29.pm");
unlike($part29, qr/\|\| 'usual'/, 'the Guide and schedule defaults no longer fall back to usual');
like($part29, qr/\|\| 'stop'/, 'they fall back to stop');

my $part28 = read_file("$root/lib/JawnOS/Manager/Part28.pm");
unlike($part28, qr/\|\| 'usual'/, 'the Guide stage/promote has no usual fallback');
like($part28, qr/\|\| 'stop'/, 'it falls back to stop');

my $resolve = read_file("$root/lib/JawnOS/Domain/Resolve.pm");
like($resolve, qr/type = 'stop'/, 'the ghost reads the stop history');
like($resolve, qr/type => 'stop'/, 'and presents itself as a stop');
unlike($resolve, qr/type => 'usual'/, 'no usual ghost type remains');

my $edit = read_file("$root/templates/apps/edit_app.html.ep");
like($edit, qr/\|\| 'stop'/, 'the editor defaults a new app to stop');

my $gb = read_file("$root/perl/gb/03_engines_and_tools.pl");
like($gb, qr/qw\/stop start record command\//, 'the Guide create types offer stop');
unlike($gb, qr/leave it \\"usual\\"/, 'and no longer tell the model to leave it usual');

done_testing();
