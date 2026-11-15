# tests-for: lib/JawnOS/Manager/Part31.pm
# covers:    an inbound MMS picture gets a .thumbs preview beside its part, the
#           preview is written before sealing, a picture still previews when
#           thumbnail_size is off, and the entry names both sealed files while
#           an audio part gets no thumb at all

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;

subs::preload('mms_attachment_store');
# A stub of a lazily loaded domain sub has to come after its module loads, or
# the module defines the real one over the top of the stub.
subs::preload($_) for qw(file_encrypter file_media_information file_preview_maker
	image_bridge_convert path_name setting_grabber home rightNow random_string_creator db_insert db_select);
require "$FindBin::Bin/../lib/JawnOS/Manager/Part31.pm";

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

# A 1x1 RGBA PNG: small enough to inline, real enough for magick and a browser.
my $PNG = pack('H*', '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489'
	. '0000000b49444154789c6360000200000500017a5eab3f0000000049454e44ae426082');

my $now = 1_700_000_000_000;

# Stands in for the real encrypter: renames each named file to `<path>.enc`,
# writes the sealed names back into the row, and records which files it was
# asked to seal. The read-back in mms_attachment_store then sees the same shape
# the live encrypter leaves.
sub fake_encrypter {
	my ($row_ref, $sealed) = @_;
	return sub {
		my $files = decode_json($$row_ref->{'file'});
		foreach my $f ( @{$files} ) {
			push @{$sealed}, [ grep { $f->{$_} && -e $f->{$_} } qw/f thumb/ ];
			foreach my $key ( qw/f thumb/ ) {
				next unless $f->{$key} && -e $f->{$key};
				rename($f->{$key}, $f->{$key} . '.enc');
				$f->{$key} = $f->{$key} . '.enc';
			}
		}
		$$row_ref->{'file'} = encode_json($files);
		return 1;
	};
}

# The wiring: a thumbnail is asked for while the part is still plain, both
# files ride the one json entry, and the read-back names what the encrypter
# actually left on disk.
{
	my $tmp = tempdir(CLEANUP => 1);
	my $inserted;
	my (@made, @sealed);
	no warnings 'redefine';
	local *subs::setting_grabber = sub { return $tmp };
	local *subs::home = sub { return $_[0] };
	local *subs::path_name = sub { return 'phone' };
	local *subs::rightNow = sub { return $now };
	local *subs::random_string_creator = sub { return 'abc123' };
	local *subs::db_insert = sub { my ($table, $row) = @_; $inserted = $row; return 1 };
	local *subs::db_select = sub { return FakeRows->new([ { file => $inserted->{'file'} } ]) };
	# Stands in for the real encrypter: renames each named file to `<path>.enc`
	# and writes the sealed names back into the row, so the read-back below is
	# the same shape the live one produces.
	local *subs::file_encrypter = fake_encrypter(\$inserted, \@sealed);
	# The maker here just records what it was handed and writes the fixture, so
	# the test says what Part31 asks for rather than what magick does.
	local *Manager::thumbnail_creator = sub {
		my ($data) = @_;
		push @made, { %{$data}, plain_on_disk => (-e $data->{'f'} ? 1 : 0) };
		write_file($data->{'thumb'}, $PNG);
		return $data;
	};

	my $entry = Manager::mms_attachment_store({ app => 'phone', name => 'pic.jpg', mime => 'image/jpeg', data => encode_base64($PNG) });
	is ref($entry), 'HASH', 'a picture part is stored';
	is scalar @made, 1, 'the thumbnail maker is asked once';
	is $made[0]->{'f'}, "$tmp/phone/phone_mms_abc123.jpg", 'for the part that was just written';
	is $made[0]->{'plain_on_disk'}, 1, 'while that part is still plain on disk';
	is $made[0]->{'type'}, 'image', 'as an image';
	is $made[0]->{'thumb'}, "$tmp/phone/.thumbs/phone_mms_abc123.png", 'into the app folder hidden .thumbs, as a png';

	is_deeply $sealed[0], [ 'f', 'thumb' ], 'the encrypter is handed both the part and its thumb';
	like $entry->{'f'}, qr/[.]enc$/, 'the entry names the sealed part';
	ok -e $entry->{'f'}, 'and that file is there';
	like $entry->{'thumb'}, qr{/phone/[.]thumbs/[^/]+[.]enc$}, 'the entry names the sealed thumb under .thumbs';
	ok -e $entry->{'thumb'}, 'and the thumb file is there';
	my $thumb_bytes = read_file($entry->{'thumb'});
	is $thumb_bytes, $PNG, 'carrying the bytes the maker wrote';
	unlike $entry->{'thumb'}, qr/abc123[.]png$/, 'not the plaintext path the maker was given';
	like $entry->{'src'}, qr{^/file_open[?]file=}, 'and the part still opens from the bubble';
}

# A part that is not a picture is filed the way it was: no maker, no .thumbs.
{
	my $tmp = tempdir(CLEANUP => 1);
	my $inserted;
	my @made;
	no warnings 'redefine';
	local *subs::setting_grabber = sub { return $tmp };
	local *subs::home = sub { return $_[0] };
	local *subs::path_name = sub { return 'phone' };
	local *subs::rightNow = sub { return $now };
	local *subs::random_string_creator = sub { return 'abc123' };
	local *subs::db_insert = sub { my ($table, $row) = @_; $inserted = $row; return 1 };
	local *subs::db_select = sub { return FakeRows->new([ { file => $inserted->{'file'} } ]) };
	local *subs::file_encrypter = sub { return 1 };
	local *Manager::thumbnail_creator = sub { push @made, $_[0]; return $_[0] };

	my $entry = Manager::mms_attachment_store({ app => 'phone', name => 'clip.amr', mime => 'audio/amr', data => encode_base64('noise') });
	ok $entry->{'f'}, 'an audio part is still kept';
	ok !defined $entry->{'thumb'}, 'and carries no thumb';
	is scalar @made, 0, 'so the thumbnail maker is never asked';
	ok !-e "$tmp/phone/.thumbs", 'and no empty .thumbs folder is left behind';
}

# The default install: thumbnail_size is 'none', so the maker writes nothing
# and the part is shrunk right here. A picture in a chat still gets a preview.
{
	my $tmp = tempdir(CLEANUP => 1);
	my $inserted;
	my (@made, @converted, @sealed);
	no warnings 'redefine';
	local *subs::setting_grabber = sub {
		my ($args) = @_;
		return 'none' if (($args->{'setting'} || '') eq 'thumbnail_size');
		return $tmp;
	};
	local *subs::home = sub { return $_[0] };
	local *subs::path_name = sub { return 'phone' };
	local *subs::rightNow = sub { return $now };
	local *subs::random_string_creator = sub { return 'abc123' };
	local *subs::db_insert = sub { my ($table, $row) = @_; $inserted = $row; return 1 };
	local *subs::db_select = sub { return FakeRows->new([ { file => $inserted->{'file'} } ]) };
	local *subs::file_encrypter = fake_encrypter(\$inserted, \@sealed);
	# What the real maker does at 'none': it returns the data and writes nothing.
	local *Manager::thumbnail_creator = sub { push @made, $_[0]; return $_[0] };
	local *subs::image_bridge_convert = sub {
		my ($src, $out) = @_;
		push @converted, { src => $src, out => $out };
		write_file($out, $PNG);
		return { path => $out };
	};

	my $entry = Manager::mms_attachment_store({ app => 'phone', name => 'pic.jpg', mime => 'image/jpeg', data => encode_base64($PNG) });
	is scalar @made, 1, 'the maker is asked first, as it is for an upload';
	is $converted[0]->{'src'}, "$tmp/phone/phone_mms_abc123.jpg", 'then the plain part is converted directly';
	is $converted[0]->{'out'}, "$tmp/phone/.thumbs/phone_mms_abc123.png", 'into the same .thumbs target';
	ok $entry->{'thumb'}, 'so the picture carries a thumb even with thumbnail_size none';
	is_deeply $sealed[0], [ 'f', 'thumb' ], 'and both files reach the encrypter';
	like $entry->{'thumb'}, qr{/phone/[.]thumbs/[^/]+[.]enc$}, 'sealed the same way as the part';
	ok -e $entry->{'thumb'}, 'and the thumb file is there';
	my $thumb_bytes = read_file($entry->{'thumb'});
	is $thumb_bytes, $PNG, 'holding what the conversion wrote';
}

# No preview can be made: the maker throws and there is no magick on the PATH.
# The part is still filed, just without one.
{
	my $tmp = tempdir(CLEANUP => 1);
	my $inserted;
	no warnings 'redefine';
	local *subs::setting_grabber = sub { return $tmp };
	local *subs::home = sub { return $_[0] };
	local *subs::path_name = sub { return 'phone' };
	local *subs::rightNow = sub { return $now };
	local *subs::random_string_creator = sub { return 'abc123' };
	local *subs::db_insert = sub { my ($table, $row) = @_; $inserted = $row; return 1 };
	local *subs::db_select = sub { return FakeRows->new([ { file => $inserted->{'file'} } ]) };
	local *subs::file_encrypter = sub { return 1 };
	local *Manager::thumbnail_creator = sub { die "magick exploded\n" };
	local *subs::image_bridge_convert = sub { return undef };
	local $ENV{'PATH'} = '/nonexistent';

	my $entry = eval { Manager::mms_attachment_store({ app => 'phone', name => 'pic.jpg', mime => 'image/jpeg', data => encode_base64($PNG) }) };
	is $@, '', 'a failed preview does not take the message with it';
	ok $entry && $entry->{'f'}, 'the picture is still filed';
	ok !defined $entry->{'thumb'}, 'with no thumb claimed';
	ok !-e "$tmp/phone/.thumbs", 'and no empty .thumbs folder is left behind';
	ok -e "$tmp/phone/phone_mms_abc123.jpg", 'and the part is where the entry says';
}

# The real maker, when ImageMagick is here: the preview is a PNG it wrote.
{
	my $have_magick = 0;
	{
		local $SIG{'__WARN__'} = sub { };
		$have_magick = 1 if system('magick -version >/dev/null 2>&1') == 0
			|| system('convert -version >/dev/null 2>&1') == 0;
	}
	SKIP: {
		skip 'ImageMagick is not installed here', 8 unless $have_magick;
		require "$FindBin::Bin/../lib/JawnOS/Manager/Part13.pm";

		my $tmp = tempdir(CLEANUP => 1);
		my $inserted;
		no warnings qw(redefine once);
		local *subs::setting_grabber = sub {
			my ($args) = @_;
			return '200x200>' if (($args->{'setting'} || '') eq 'thumbnail_size');
			return $tmp;
		};
		local *subs::home = sub { return $_[0] };
		local *subs::path_name = sub { return 'phone' };
		local *subs::rightNow = sub { return $now };
		local *subs::random_string_creator = sub { return 'abc123' };
		local *subs::db_insert = sub { my ($table, $row) = @_; $inserted = $row; return 1 };
		local *subs::db_select = sub { return FakeRows->new([ { file => $inserted->{'file'} } ]) };
		local *subs::file_encrypter = sub { return 1 };
		# A desktop: no phone bridge to answer a native thumbnail, and the
		# picture probe is not what this test is about.
		local *subs::file_media_information = sub { return $_[0] };
		local *Manager::native_thumb_png = sub { return undef };
		local *Manager::run_thumb_command = sub { my ($command) = @_; my $out = `$command 2>&1`; return $out };

		my $entry = Manager::mms_attachment_store({ app => 'phone', name => 'pic.png', mime => 'image/png', data => encode_base64($PNG) });
		ok $entry->{'thumb'}, 'the real maker gives a picture a thumb';
		ok -e $entry->{'thumb'}, 'and the thumb file exists';
		my $thumb_bytes = read_file($entry->{'thumb'});
		like $thumb_bytes, qr/^\x89PNG/, 'holding a png';
		ok -e "$tmp/phone/.thumbs/phone_mms_abc123.png", 'written beside the part, in .thumbs';
		ok -e $entry->{'f'}, 'and the part itself is unchanged and present';

		# The default install, end to end: thumbnail_size 'none' makes the real
		# maker write nothing, so the magick fallback has to produce the preview.
		{
			my $tmp2 = tempdir(CLEANUP => 1);
			my $inserted2;
			local *subs::setting_grabber = sub {
				my ($args) = @_;
				return 'none' if (($args->{'setting'} || '') eq 'thumbnail_size');
				return $tmp2;
			};
			local *subs::db_insert = sub { my ($table, $row) = @_; $inserted2 = $row; return 1 };
			local *subs::db_select = sub { return FakeRows->new([ { file => $inserted2->{'file'} } ]) };
			local *subs::image_bridge_convert = sub { return undef };

			my $bare = Manager::mms_attachment_store({ app => 'phone', name => 'pic.png', mime => 'image/png', data => encode_base64($PNG) });
			ok $bare->{'thumb'}, 'the magick fallback previews a picture with thumbnail_size none';
			ok -e "$tmp2/phone/.thumbs/phone_mms_abc123.png", 'writing the .thumbs png itself';
			my $bare_bytes = read_file($bare->{'thumb'});
			like $bare_bytes, qr/^\x89PNG/, 'and it is a png';
		}
	}
}

# The order is the point: magick cannot read a sealed part.
my $part31 = do { open(my $fh, '<', "$FindBin::Bin/../lib/JawnOS/Manager/Part31.pm") or die $!; local $/; <$fh> };
my ($body) = $part31 =~ /^(sub mms_attachment_store \{.*?\n\})/ms;
ok $body, 'the attachment helper is where the map says';
ok index($body, 'thumbnail_creator') >= 0, 'it asks for a thumbnail';
ok index($body, 'thumbnail_creator') < index($body, 'file_encrypter'),
	'before the part is sealed';

done_testing();
