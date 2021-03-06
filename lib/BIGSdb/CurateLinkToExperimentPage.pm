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
package BIGSdb::CurateLinkToExperimentPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::CuratePage);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');

sub print_content {
	my ($self)     = @_;
	my $q          = $self->{'cgi'};
	my $query_file = $q->param('query_file');
	my $query      = $self->get_query_from_temp_file($query_file);
	say "<h1>Link sequences to experiment</h1>";
	if ( !$query ) {
		say "<div class=\"box\" id=\"statusbad\"><p>No selection query passed!</p></div>";
		return;
	} elsif ( $query !~ /SELECT \* FROM sequence_bin/ ) {
		$logger->error("Query:$query");
		say "<div class=\"box\" id=\"statusbad\"><p>Invalid query passed!</p></div>";
		return;
	} elsif ( !$self->can_modify_table('sequence_bin') ) {
		say "<div class=\"box\" id=\"statusbad\"><p>Your user account is not allowed to link sequences to experiments.</p></div>";
		return;
	}
	$query =~ s/SELECT \*/SELECT id/;
	my $ids = $self->{'datastore'}->run_list_query($query);
	if ( $q->param('Link') ) {
		my $experiment = $q->param('experiment');
		if ( !$experiment ) {
			say "<div class=\"box\" id=\"statusbad\"><p>No experiment selected.</p></div>";
			return;
		} elsif ( !BIGSdb::Utils::is_int($experiment) ) {
			say "<div class=\"box\" id=\"statusbad\"><p>Invalid experiment selected.</p></div>";
			return;
		}
		my $qry = "SELECT COUNT(*) FROM experiment_sequences WHERE experiment_id=? AND seqbin_id=?";
		my $sql = $self->{'db'}->prepare($qry);
		$qry = "INSERT INTO experiment_sequences (experiment_id,seqbin_id,curator,datestamp) VALUES (?,?,?,?)";
		my $sql_insert = $self->{'db'}->prepare($qry);
		my $curator_id = $self->get_curator_id;
		eval {
			foreach (@$ids)
			{
				$sql->execute( $experiment, $_ );
				my ($exists) = $sql->fetchrow_array;
				if ( !$exists ) {
					$sql_insert->execute( $experiment, $_, $curator_id, 'now' );
				}
			}
		};
		if ($@) {
			$logger->error("Can't execute $@");
			say "<div class=\"box\" id=\"statusbad\"><p>Error encountered linking experiments. There should be more details of "
			  . "this error in the server log.</p></div>";
			$self->{'db'}->rollback;
		} else {
			$self->{'db'}->commit;
			say "<div class=\"box\" id=\"resultsheader\"><p>Sequences linked!</p></div>";
		}
		return;
	}
	say "<div class=\"box\" id=\"queryform\">";
	say "<p>" . @$ids . " sequence" . ( @$ids == 1 ? '' : 's' ) . " selected.</p>";
	say "<p>Please select the experiment to link these sequences to:</p>";
	my $sql = $self->{'db'}->prepare("SELECT id,description FROM experiments ORDER BY description");
	eval { $sql->execute };
	$logger->error($@) if $@;
	my @ids = (0);
	my %desc = ( 0 => '' );

	while ( my ( $id, $desc ) = $sql->fetchrow_array ) {
		push @ids, $id;
		$desc{$id} = $desc;
	}
	say $q->start_form;
	say $q->popup_menu( -name => 'experiment', -values => \@ids, -labels => \%desc );
	say $q->submit( -name => 'Link', -class => 'button' );
	say $q->hidden($_) foreach qw (db page query_file);
	say $q->end_form;
	say "</div>";
	return;
}

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return "Link sequences to experiment - $desc";
}
1;
