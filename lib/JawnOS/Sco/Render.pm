package JawnOS::Sco::Render;

# Turn a prompt's words into the one shape the SCO helper can play: raw
# 8 kHz mono s16le, cached by the words and the voice.
#
# Piper writes a WAV at the model's own rate (22.05 kHz for the bundled
# voices); the phone's Hands-Free link carries CVSD at 8 kHz, so ffmpeg is the
# converter. The cache matters because a caller waits through this: the
# greeting is rendered on the first call and played from disk after that.
use strict;
use warnings;
use Digest::SHA qw(sha1_hex);
use File::Path qw(make_path);

sub dir {
	my $dir = &subs::home('~/.president/sco/clips');
	make_path($dir) unless -d $dir;
	return $dir;
}

# The cache key: the words and the voice, so editing a prompt (or changing the
# voice) makes a new clip instead of replaying the old one.
sub key {
	my ($text, $voice) = @_;
	return sha1_hex(($voice || '') . "\x00" . ($text || ''));
}

sub cached {
	my ($text, $voice) = @_;
	my $path = &dir() . '/' . &key($text, $voice) . '.raw';
	return -s $path ? $path : '';
}

# Render and convert. Returns the raw path, or '' when this machine cannot
# speak (no piper voice, no ffmpeg) - the gateway then plays silence rather
# than failing the call.
sub render {
	my ($text, $voice) = @_;
	return '' unless defined $text && length $text;
	my $cache = &cached($text, $voice);
	return $cache if $cache;
	my $wav = &subs::say_render_wav($text, $voice);
	return '' unless $wav && -e $wav;
	my $raw = &dir() . '/' . &key($text, $voice) . '.raw';
	my $tmp = $raw . '.tmp.' . $$;
	my $ok = system('ffmpeg', '-nostdin', '-loglevel', 'error', '-y',
		'-i', $wav, '-f', 's16le', '-ar', '8000', '-ac', '1', $tmp);
	unlink $wav;
	if ($ok != 0 || !-s $tmp) {
		unlink $tmp;
		return '';
	}
	rename $tmp, $raw or do { unlink $tmp; return '' };
	&prune();
	return $raw;
}

# The clips a plan will play, filled in on the machine that owns the adapter.
#
# A phone sends words, not paths: a clip rendered on the phone does not exist on
# the laptop, and a phone has no Piper anyway. A local arm still sends paths and
# they win - only a missing or empty entry is rendered from the words here.
# Entries nothing can speak are dropped, so the plan skips them instead of
# handing the helper a path that does not exist.
sub merge_clips {
	my ($clips, $words, $voice) = @_;
	my %out = ref $clips eq 'HASH' ? %{$clips} : ();
	my $text = ref $words eq 'HASH' ? $words : {};
	foreach my $key (qw(greeting prompt thanks)) {
		my $path = $out{$key};
		next if defined $path && length $path && -s $path;
		delete $out{$key};
		my $raw = &render($text->{$key}, $voice);
		$out{$key} = $raw if $raw;
	}
	return \%out;
}

# Clips are small (about 16 KB a second) but a house edits prompts rarely and
# calls for years: drop anything untouched for a fortnight, and never keep
# more than 128.
sub prune {
	my $dir = &dir();
	my @clips = sort { (stat($a))[9] <=> (stat($b))[9] } glob("$dir/*.raw");
	my $now = time;
	my $keep = 128;
	my $i = 0;
	foreach my $clip (@clips) {
		my $at = (stat($clip))[9] || 0;
		$i++;
		unlink $clip if ($i > $keep) || ($now - $at > 14 * 86400);
	}
	return 1;
}

1;
