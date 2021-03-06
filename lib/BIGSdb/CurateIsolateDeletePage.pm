#Written by Keith Jolley
#Copyright (c) 2010-2014, University of Oxford
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
package BIGSdb::CurateIsolateDeletePage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::IsolateInfoPage BIGSdb::CuratePage);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');

sub initiate {
	my ($self) = @_;
	$self->{$_} = 1 foreach qw(jQuery jQuery.columnizer);
	return;
}

sub print_content {
	my ($self) = @_;
	my $q      = $self->{'cgi'};
	my $id     = $q->param('id');
	my $buffer;
	say "<h1>Delete isolate</h1>";
	if ( !$id ) {
		say qq(<div class="box" id="statusbad"><p>No id passed.</p></div>);
		return;
	} elsif ( !BIGSdb::Utils::is_int($id) ) {
		say qq(<div class="box" id="statusbad"><p>Isolate id must be an integer.</p></div>);
		return;
	}
	my $data = $self->{'datastore'}->get_isolate_field_values($id);
	if ( !$data ) {
		say qq(<div class="box" id="statusbad"><p>No record with id-$id exists or your account is not allowed to delete it.</p></div>);
		return;
	}
	if ( !$self->can_modify_table('isolates') ) {
		say qq(<div class="box" id="statusbad"><p>Your user account is not allowed to delete records in the isolates table.</p></div>);
		return;
	} 
	$buffer .= qq(<div class="box" id="resultstable">\n);
	$buffer .= "<p>You have selected to delete the following record:</p>";
	$buffer .= $q->start_form;
	$buffer .= $q->hidden($_) foreach qw (page db id);
	$buffer .= $q->end_form;
	my $isolate_record = BIGSdb::IsolateInfoPage->new(
		(
			system        => $self->{'system'},
			cgi           => $self->{'cgi'},
			instance      => $self->{'instance'},
			prefs         => $self->{'prefs'},
			prefstore     => $self->{'prefstore'},
			config        => $self->{'config'},
			datastore     => $self->{'datastore'},
			db            => $self->{'db'},
			xmlHandler    => $self->{'xmlHandler'},
			dataConnector => $self->{'dataConnector'},
			curate        => 1
		)
	);
	my $record_table = $isolate_record->get_isolate_record($id);
	$buffer .= $record_table;
	$buffer .= $q->start_form;
	$q->param( page => 'isolateDelete' );    #need to set as this may have changed if there is a seqbin display button
	$buffer .= $q->hidden($_) foreach qw (page db id);
	$buffer .= $self->print_action_fieldset( { get_only => 1, no_reset => 1, submit_label => 'Delete' } );
	$buffer .= $q->end_form;
	$buffer .= "</div>\n";

	if ( $q->param('submit') ) {
		$self->_delete( $data->{'id'} );
		return;
	}
	print $buffer;
	return;
}

sub _delete {
	my ( $self, $isolate_id ) = @_;
	my @actions;
	my $old_version = $self->{'datastore'}->run_query( "SELECT id FROM $self->{'system'}->{'view'} WHERE new_version=?",
		$isolate_id, { cache => 'CurateIsolateDeletePage::get_old_version' } );
	my $field_values = $self->{'datastore'}->get_isolate_field_values($isolate_id);
	my $new_version  = $field_values->{'new_version'};
	if ( $new_version && $old_version ) {    #Deleting intermediate version - update old version to point to newer version
		push @actions, { statement => 'UPDATE isolates SET new_version=? WHERE id=?', arguments => [ $new_version, $old_version ] };
	} elsif ($old_version) {                 #Deleting latest version - remove link to this version in old version
		push @actions, { statement => 'UPDATE isolates SET new_version=NULL WHERE id=?', arguments => [$old_version] };
	}
	push @actions, { statement => 'DELETE FROM isolates WHERE id=?', arguments => [$isolate_id] };
	eval {
		foreach my $action (@actions)
		{
			$self->{'db'}->do( $action->{'statement'}, undef, @{ $action->{'arguments'} } );
		}
	};
	if ($@) {
		say qq(<div class="box" id="statusbad"><p>Delete failed - transaction cancelled - no records have been touched.</p>);
		say "<p>Failed SQL: $_</p>";
		say "<p>Error message: $@</p></div>";
		$logger->error("Delete failed: $_ $@");
		$self->{'db'}->rollback;
		return;
	}
	$self->{'db'}->commit
	  && say qq(<div class="box" id="resultsheader"><p>Isolate id:$isolate_id deleted!</p>);
	say qq(<p><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>);
	return;
}

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return "Delete isolate - $desc";
}
1;
