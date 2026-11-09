package JawnOS::Platform::Mdns;

# The mDNS/DNS-SD tool surface: browse one service type and publish a service.
# Linux keeps Avahi (the responder the house already runs); macOS will use
# dns-sd in P2, Windows the DNS-SD API in P3. A platform without a tool answers
# [] or () so a caller's fallback runs unchanged.
#
# The Avahi parsable records are pinned by fixture: one `=;` line per resolved
# instance, semicolon-separated, with the TXT field last.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(available browse parse_browse publish_argv);

BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
use JawnOS::Platform ();

sub _tool_path {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	my $path = JawnOS::Platform::tool_path($name);
	return $path if $path;
	foreach my $dir ('/usr/sbin', '/sbin', '/usr/local/sbin') {
		my $candidate = "$dir/$name";
		return $candidate if -f $candidate && -x $candidate;
	}
	return undef;
}

sub _run {
	my (@command) = @_;
	return '' unless @command;
	open(my $fh, '-|', @command) or return '';
	my $out = do { local $/; <$fh> };
	close $fh;
	return defined $out ? $out : '';
}

# The responder path for a role, or undef. Linux has avahi-browse and
# avahi-publish-service; macOS has one dns-sd for both; Windows has neither yet.
sub available {
	my ($role) = @_;
	$role = 'browse' unless defined $role && length $role;
	if ($^O eq 'linux') {
		return _tool_path($role eq 'publish' ? 'avahi-publish-service' : 'avahi-browse');
	}
	if ($^O eq 'darwin') {
		return _tool_path('dns-sd');
	}
	return undef;
}

# Resolve one service type, as the list the domain report consumes. Linux runs
# `avahi-browse -rtp`; the timeout keeps a quiet network from holding the pass.
sub browse {
	my ($type, %opt) = @_;
	return [] unless defined $type && $type =~ /^_[A-Za-z0-9-]+\._(?:tcp|udp)$/;
	return [] unless $^O eq 'linux';
	my $avahi = available('browse') or return [];
	my $seconds = (defined $opt{'timeout'} && $opt{'timeout'} > 0) ? int($opt{'timeout'}) : 8;
	my @command = ($avahi, '-rtp', $type);
	if (my $timeout = _tool_path('timeout')) {
		@command = ($timeout, $seconds, @command);
	}
	return parse_browse(_run(@command));
}

# Parsable Avahi output:
#   =;iface;proto;name;type;domain;host;address;port;txt
# The TXT field is quoted key=value pairs; only an IPv4 address is accepted,
# because the discovery rows are IPv4 (Q9 keeps IPv6 for later).
sub parse_browse {
	my ($text) = @_;
	my @records;
	return \@records unless defined $text && length $text;
	my @line = split /\n/, $text;
	foreach my $one (@line) {
		next unless $one =~ /^=;/;
		my @field = split /;/, $one, 10;
		my $name = defined $field[3] ? $field[3] : '';
		my $service = defined $field[4] ? $field[4] : '';
		my $host = defined $field[6] ? $field[6] : '';
		my $address = defined $field[7] ? $field[7] : '';
		my $port = defined $field[8] ? $field[8] : '';
		my $txt = defined $field[9] ? $field[9] : '';
		next unless $address =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
		my %fields;
		my @pair = $txt =~ /"([^"]*)"/g;
		foreach my $kv (@pair) {
			my ($key, $value) = split /=/, $kv, 2;
			$fields{$key} = $value if defined $value;
		}
		my $mac;
		if (defined $fields{'mac'} && $fields{'mac'} =~ /^[0-9a-fA-F:]{17}$/) {
			$mac = lc $fields{'mac'};
		}
		my $txt_ty = defined $fields{'ty'} ? $fields{'ty'} : '';
		my $txt_product = defined $fields{'product'} ? $fields{'product'} : '';
		$txt_product =~ s/^\(//;
		$txt_product =~ s/\)$//;
		push @records, {
			service => $service,
			hostname => $host,
			ip => $address,
			port => $port,
			mac => $mac,
			name => $fields{'name'} || $txt_ty || $txt_product || $name,
			model => $fields{'model'} || $txt_product || $txt_ty,
			txt => $txt,
			fields => \%fields,
		};
	}
	return \@records;
}

# The argv that publishes a service. Linux keeps Avahi's -s/--no-reverse
# spelling; macOS will use dns-sd -R. The caller owns the instance name and TXT
# records.
sub publish_argv {
	my ($service, $instance, $port, $txt) = @_;
	return () unless defined $service && length $service;
	return () unless defined $instance && length $instance;
	return () unless defined $port && $port =~ /^\d+$/;
	my @txt = ref $txt eq 'ARRAY' ? @{$txt} : ();
	if ($^O eq 'linux') {
		my $avahi = available('publish') or return ();
		return ($avahi, '--no-reverse', '-s', $instance, $service, $port, @txt);
	}
	if ($^O eq 'darwin') {
		my $dns_sd = available('publish') or return ();
		return ($dns_sd, '-R', $instance, $service, 'local', $port, @txt);
	}
	return ();
}

1;
