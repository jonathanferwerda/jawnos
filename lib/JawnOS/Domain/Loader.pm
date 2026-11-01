package subs;

# Lazy loader for the domain layer in lib/JawnOS/Domain/. subroutines.pl
# requires this file at boot; it defines no domain subs itself, only the map
# and AUTOLOAD, so a worker compiles a module the first time it calls into it.
# A name that is not in the map is a real typo and dies with the usual message.
use strict;
use warnings;

our %DOMAIN_MODULE = (
	appointment_overlap                => 'JawnOS::Domain::Budget',
	appts_marker_builder               => 'JawnOS::Domain::Log',
	budget_calculator                  => 'JawnOS::Domain::Budget',
	budget_status_maker                => 'JawnOS::Domain::Budget',
	coding_path                        => 'JawnOS::Domain::Misc',
	coding_repo                        => 'JawnOS::Domain::Misc',
	deletion_registration              => 'JawnOS::Domain::Notify',
	embedded_toggle                    => 'JawnOS::Domain::Notify',
	father_time                        => 'JawnOS::Domain::Budget',
	guide_aka_read                     => 'JawnOS::Domain::Guide',
	guide_alias_add                    => 'JawnOS::Domain::Guide',
	guide_alias_remove                 => 'JawnOS::Domain::Guide',
	guide_aliases_read                 => 'JawnOS::Domain::Guide',
	guide_aliases_write                => 'JawnOS::Domain::Guide',
	guide_ask_candidates               => 'JawnOS::Domain::Guide',
	guide_name_distance                => 'JawnOS::Domain::Guide',
	guide_name_normalize               => 'JawnOS::Domain::Guide',
	guide_resolve_action               => 'JawnOS::Domain::Guide',
	guide_resolve_target               => 'JawnOS::Domain::Guide',
	guide_resolve_when                 => 'JawnOS::Domain::Guide',
	guide_target_label                 => 'JawnOS::Domain::Guide',
	help_app_hidden                    => 'JawnOS::Domain::Log',
	leave                              => 'JawnOS::Domain::Misc',
	log_reader                         => 'JawnOS::Domain::Log',
	measure_calc_for                   => 'JawnOS::Domain::Budget',
	migration_already_applied          => 'JawnOS::Domain::Notify',
	misc_setting_list                  => 'JawnOS::Domain::Misc',
	notification_sender                => 'JawnOS::Domain::Notify',
	ocr_reader                         => 'JawnOS::Domain::Misc',
	original_timestamp                 => 'JawnOS::Domain::Log',
	people_chips                       => 'JawnOS::Domain::Guide',
	people_index                       => 'JawnOS::Domain::Guide',
	remote_relay_request               => 'JawnOS::Domain::Remote',
	remote_useragent_maker             => 'JawnOS::Domain::Remote',
	update_database                    => 'JawnOS::Domain::Migrations',
);

# True for a domain function this loader can provide. Tests use it instead of
# `defined &subs::name`, which would be false until the module is loaded.
sub provides { return exists $DOMAIN_MODULE{ $_[0] // '' } }

our $AUTOLOAD;
sub AUTOLOAD {
	my $name = $AUTOLOAD;
	return if $name eq 'subs::DESTROY';
	$name =~ s/.*:://;
	my $module = $DOMAIN_MODULE{$name}
		or die "Undefined subroutine &$AUTOLOAD called\n";
	(my $file = $module) =~ s{::}{/}g;
	require "$file.pm";
	die "&$AUTOLOAD is mapped to $module, which does not define $name\n"
		unless defined &$AUTOLOAD;
	goto &$AUTOLOAD;
}

1;
