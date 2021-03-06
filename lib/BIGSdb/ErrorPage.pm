#Written by Keith Jolley
#Copyright (c) 2010-2013, University of Oxford
#E-mail: keith.jolley@zoo.ox.ac.uk
#
#This file is part of Bacterial Isolate Genome Sequence Database (BIGSdb).
#
#BIGSdb is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#BIGSdb is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with BIGSdb.  If not, see <http://www.gnu.org/licenses/>.
package BIGSdb::ErrorPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Page);
use List::MoreUtils qw(any);
use Log::Log4perl qw(get_logger);

sub print_content {
	my ($self) = @_;
	my $logger = get_logger('BIGSdb.Page');
	my $desc   = $self->get_title;
	my $show_oops = ( any { $self->{'error'} eq $_ } qw (userNotAuthenticated accessDisabled configAccessDenied) ) ? 0 : 1;
	say "<h1>$desc</h1>";
	say "<p style=\"font-size:5em; color:#A0A0A0; padding-top:1em\">Oops ...</p>" if $show_oops;
	say "<div class=\"box\" id=\"statusbad\">";
	if ( $self->{'error'} eq 'unknown' ) {
		my $function = $self->{'cgi'}->param('page');
		say "<p>Unknown function '$function' requested - either an incorrect link brought you here or this functionality has not been "
		  . "implemented yet!</p>";
		$logger->info("Unknown function '$function' specified in URL");
	} elsif ( $self->{'error'} eq 'invalidXML' ) {
		say "<p>Invalid (or no) database description file specified!</p>";
	} elsif ( $self->{'error'} eq 'invalidDbType' ) {
		say "<p>Invalid database type specified! Please set dbtype to either 'isolates' or 'sequences' in the system attributes of the "
		  . "XML description file for this database.</p>";
	} elsif ( $self->{'error'} eq 'invalidScriptPath' ) {
		say "<p>You are attempting to access this database from an invalid script path.</p>";
	} elsif ( $self->{'error'} eq 'invalidCurator' ) {
		say "<p>You are not a curator for this database.</p>";
	} elsif ( $self->{'error'} eq 'noConnect' ) {
		say "<p>Can not connect to database!</p>";
	} elsif ( $self->{'error'} eq 'noAuth' ) {
		say "<p>Can not connect to the authentication database!</p>";
	} elsif ( $self->{'error'} eq 'noPrefs' ) {
		if ( $self->{'fatal'} ) {
			say "<p>The preference database can be reached but it appears to be misconfigured!</p>";
		} else {
			say "<p>Can not connect to the preference database!</p>";
		}
	} elsif ( $self->{'error'} eq 'userAuthenticationFiles' ) {
		say "<p>Can not open the user authentication database!</p>";
	} elsif ( $self->{'error'} eq 'noAuthenticationSet' ) {
		say "<p>No authentication mechanism has been set in the database configuration!</p>";
	} elsif ( $self->{'error'} eq 'disableUpdates' ) {
		say "<p>Database updates are currently disabled.</p>";
		say "<p>$self->{'message'}</p>" if $self->{'message'};
	} elsif ( $self->{'error'} eq 'userNotAuthenticated' ) {
		say "<p>You have been denied access by the server configuration.  Either your login details are invalid or you are trying to "
		  . "connect from an unauthorized IP address.</p>";
		$self->print_warning_sign;
	} elsif ( $self->{'error'} eq 'accessDisabled' ) {
		say "<p>Your user account has been disabled.  If you believe this to be an error, please contact the system administrator.</p>";
		$self->print_warning_sign;
	} elsif ( $self->{'error'} eq 'configAccessDenied' ) {
		say "<p>Your user account can not access this database configuration.  If you believe this to be an error, please contact "
		  . "the system administrator.</p>";
		$self->print_warning_sign;
	} else {
		say "<p>An unforeseen error has occurred - please contact the system administrator.</p>";
		$logger->error("Unforeseen error page displayed to user");
	}
	say "</div>";
	return;
}

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return "Unknown function - $desc" if ( $self->{'error'} eq 'unknown' );
	return "Invalid XML - $desc"                     if $self->{'error'} eq 'invalidXML';
	return "Invalid database type - $desc"           if $self->{'error'} eq 'invalidDbType';
	return "Invalid script path - $desc"             if $self->{'error'} eq 'invalidScriptPath';
	return "Invalid curator - $desc"                 if $self->{'error'} eq 'invalidCurator';
	return "Can not connect to database - $desc"     if $self->{'error'} eq 'noConnect';
	return "Access denied - $desc"                   if $self->{'error'} eq 'userNotAuthenticated';
	return "Preference database error - $desc"       if $self->{'error'} eq 'noPrefs';
	return "No authentication mechanism set - $desc" if $self->{'error'} eq 'noAuthenticationSet';
	return "Access disabled - $desc"                 if $self->{'error'} eq 'accessDisabled';
	return "Access denied - $desc"                   if $self->{'error'} eq 'configAccessDenied';
	return $desc;
}
1;
