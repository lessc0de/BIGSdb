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
package BIGSdb::IndexPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Page);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');

sub set_pref_requirements {
	my ($self) = @_;
	$self->{'pref_requirements'} = { general => 1, main_display => 0, isolate_display => 0, analysis => 0, query_field => 0 };
	return;
}

sub initiate {
	my ($self) = @_;
	$self->{'jQuery'} = 1;
	if ( $self->{'system'}->{'dbtype'} eq 'isolates' && $self->{'system'}->{'read_access'} ne 'public' ) {
		$self->{'noCache'} = 1;    #Page will display user's queued/running jobs so should not be cached.
	}
	$self->choose_set;
	if ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		my $set_id = $self->get_set_id;
		my $scheme_data = $self->{'datastore'}->get_scheme_list( { with_pk => 1, set_id => $set_id } );
		$self->{'tooltips'} = 1 if @$scheme_data > 1;
	}
	return;
}

sub print_content {
	my ($self)      = @_;
	my $script_name = $self->{'system'}->{'script_name'};
	my $instance    = $self->{'instance'};
	my $system      = $self->{'system'};
	my $q           = $self->{'cgi'};
	my $desc        = $self->get_db_description;
	say "<h1>$desc database</h1>";
	$self->print_banner;
	$self->_print_jobs;
	my $set_id = $self->get_set_id;
	my $set_string = $set_id ? "&amp;set_id=$set_id" : '';    #append to URLs to ensure unique caching.

	if ( ( $self->{'system'}->{'sets'} // '' ) eq 'yes' ) {
		$self->print_set_section;
	}
	say qq(<div class="box" id="index"><div class="scrollable"><div style="float:left;margin-right:1em">);
	say qq(<img src="/images/icons/64x64/search.png" alt="" /><h2>Query database</h2><ul class="toplevel">);
	my $scheme_data =
	  $self->{'datastore'}->get_scheme_list( { with_pk => ( $self->{'system'}->{'dbtype'} eq 'sequences' ? 1 : 0 ), set_id => $set_id } );
	my $url_root = "$self->{'system'}->{'script_name'}?db=$instance$set_string&amp;";
	if ( $system->{'dbtype'} eq 'isolates' ) {
		say qq(<li><a href="${url_root}page=query">Search database</a> - advanced queries.</li>);
		say qq(<li><a href="${url_root}page=browse">Browse database</a> - peruse all records.</li>);
		my $loci = $self->{'datastore'}->get_loci( { set_id => $set_id, do_not_order => 1 } );
		if (@$loci) {
			say qq(<li><a href="${url_root}page=profiles">Search by combinations of loci (profiles)</a> - )
			  . qq(including partial matching.</li>);
		}
	} elsif ( $system->{'dbtype'} eq 'sequences' ) {
		say qq(<li><a href="${url_root}page=sequenceQuery">Sequence query</a> - query an allele sequence.</li>);
		say qq(<li><a href="${url_root}page=batchSequenceQuery">Batch sequence query</a> - query multiple sequences in FASTA format.</li>);
		say qq(<li><a href="${url_root}page=tableQuery&amp;table=sequences">Sequence attribute search</a> - )
		  . qq(find alleles by matching attributes.</li>);
		if (@$scheme_data) {
			my $scheme_arg  = @$scheme_data == 1 ? "&amp;scheme_id=$scheme_data->[0]->{'id'}" : '';
			my $scheme_desc = @$scheme_data == 1 ? $scheme_data->[0]->{'description'}         : '';
			say qq(<li><a href="${url_root}page=browse$scheme_arg">Browse $scheme_desc profiles</a></li>);
			say qq(<li><a href="${url_root}page=query$scheme_arg">Search $scheme_desc profiles</a></li>);
			say qq(<li><a href="${url_root}page=listQuery$scheme_arg">List</a> - find $scheme_desc profiles matched to entered list.</li>);
			say qq(<li><a href="${url_root}page=profiles$scheme_arg">Search by combinations of $scheme_desc alleles</a> - )
			  . qq(including partial matching.</li>);
			say qq(<li><a href="${url_root}page=batchProfiles$scheme_arg">Batch profile query</a> - lookup 	$scheme_desc profiles copied )
			  . qq(from a spreadsheet.</li>);
		}
	}
	if ( $self->{'config'}->{'jobs_db'} ) {
		my $query_html_file = "$self->{'system'}->{'dbase_config_dir'}/$self->{'instance'}/contents/job_query.html";
		$self->print_file($query_html_file) if -e $query_html_file;
	}
	if ( $system->{'dbtype'} eq 'isolates' ) {
		say qq(<li><a href="${url_root}page=listQuery">List query</a> - find isolates by matching a field to an entered list.</li>);
		my $projects = $self->{'datastore'}->run_query("SELECT COUNT(*) FROM projects WHERE list");
		say qq(<li><a href="${url_root}page=projects">Projects</a> - main projects defined in database.) if $projects;
		my $sample_fields = $self->{'xmlHandler'}->get_sample_field_list;
		if (@$sample_fields) {
			say qq(<li><a href="${url_root}page=tableQuery&amp;table=samples">Sample management</a> - culture/DNA storage tracking</li>);
		}
	}
	say "</ul></div>";
	$self->_print_download_section($scheme_data) if $system->{'dbtype'} eq 'sequences';
	$self->_print_options_section;
	$self->_print_general_info_section($scheme_data);
	say "</div></div>";
	$self->_print_plugin_section($scheme_data);
	return;
}

sub _print_jobs {
	my ($self) = @_;
	return if !$self->{'system'}->{'read_access'} eq 'public' || !$self->{'config'}->{'jobs_db'};
	return if !defined $self->{'username'};
	my $days = $self->{'config'}->{'results_deleted_days'} // 7;
	my $jobs = $self->{'jobManager'}->get_user_jobs( $self->{'instance'}, $self->{'username'}, $days );
	return if !@$jobs;
	my %status_counts;
	$status_counts{ $_->{'status'} }++ foreach @$jobs;
	my $days_plural = $days == 1  ? '' : 's';
	my $jobs_plural = @$jobs == 1 ? '' : 's';
	say "<div class=\"box\" id=\"jobs\">";
	say "<h2>Jobs</h2>";
	say "<p>You have submitted or run "
	  . @$jobs
	  . " offline job$jobs_plural in the past "
	  . ( $days_plural ? $days : '' )
	  . " day$days_plural. "
	  . "<a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=jobs\">Show jobs</a></p>";
	my %replace = ( started => 'running', submitted => 'queued' );
	my @breakdown;

	foreach my $status (qw (started submitted finished failed cancelled terminated)) {
		push @breakdown, ( $replace{$status} // $status ) . ": $status_counts{$status}" if $status_counts{$status};
	}
	local $" = '; ';
	say "<p>@breakdown</p>";
	say "</div>";
	return;
}

sub _print_download_section {
	my ( $self,           $scheme_data ) = @_;
	my ( $scheme_ids_ref, $desc_ref )    = $self->extract_scheme_desc($scheme_data);
	my $q                   = $self->{'cgi'};
	my $seq_download_buffer = '';
	my $scheme_buffer       = '';
	my $group_count         = $self->{'datastore'}->run_simple_query("SELECT COUNT(*) FROM scheme_groups")->[0];
	if ( !( $self->{'system'}->{'disable_seq_downloads'} && $self->{'system'}->{'disable_seq_downloads'} eq 'yes' ) || $self->is_admin ) {
		$seq_download_buffer =
		    "<li><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=downloadAlleles"
		  . ( $group_count ? '&amp;tree=1' : '' )
		  . "\">Allele sequences</a></li>\n";
	}
	my $first = 1;
	my $i     = 0;
	if ( @$scheme_data > 1 ) {
		$scheme_buffer .= "<li>";
		$scheme_buffer .= $q->start_form;
		$scheme_buffer .= $q->popup_menu( -name => 'scheme_id', -values => $scheme_ids_ref, -labels => $desc_ref );
		$scheme_buffer .= $q->hidden('db');
		$scheme_buffer .=
		  " <button type=\"submit\" name=\"page\" value=\"downloadProfiles\" class=\"smallbutton\">Download profiles</button>\n";
		$scheme_buffer .= $q->end_form;
		$scheme_buffer .= "</li>";
	} elsif ( @$scheme_data == 1 ) {
		$scheme_buffer .= "<li><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=downloadProfiles&amp;scheme_id="
		  . "$scheme_data->[0]->{'id'}\">$scheme_data->[0]->{'description'} profiles</a></li>";
	}
	if ( $seq_download_buffer || $scheme_buffer ) {
		print << "DOWNLOADS";
<div style="float:left; margin-right:1em">
<img src="/images/icons/64x64/download.png" alt="" />
<h2>Downloads</h2>
<ul class="toplevel">
$seq_download_buffer
$scheme_buffer
</ul>	
</div>
DOWNLOADS
	}
	return;
}

sub _print_options_section {
	my ($self) = @_;
	my $set_id = $self->get_set_id;
	my $set_string = $set_id ? "&amp;set_id=$set_id" : '';
	print << "OPTIONS";
<div style="float:left; margin-right:1em">
<img src="/images/icons/64x64/preferences.png" alt="" />
<h2>Option settings</h2>
<ul class="toplevel">
<li><a href="$self->{'system'}->{'script_name'}?page=options&amp;db=$self->{'instance'}$set_string">
Set general options</a>
OPTIONS
	say " - including isolate table field handling." if $self->{'system'}->{'dbtype'} eq 'isolates';
	say "</li>";
	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		my $url_root = "$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=tableQuery&amp;";
		say qq(<li>Set display and query options for )
		  . qq(<a href="${url_root}table=loci$set_string">locus</a>, )
		  . qq(<a href="${url_root}table=schemes$set_string">schemes</a> or )
		  . qq(<a href="${url_root}table=scheme_fields$set_string">scheme fields</a>.</li>);
	}
	say "</ul>\n</div>";
	return;
}

sub _print_general_info_section {
	my ( $self, $scheme_data ) = @_;
	say "<div style=\"float:left; margin-right:1em\">";
	say "<img src=\"/images/icons/64x64/information.png\" alt=\"\" />";
	say "<h2>General information</h2>\n<ul class=\"toplevel\">";
	my $set_id = $self->get_set_id;
	my $set_string = $set_id ? "&amp;set_id=$set_id" : '';    #append to URLs to ensure unique caching.
	my $max_date;
	if ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		my $allele_count = $self->_get_allele_count;
		my $tables       = [qw (sequences profiles profile_refs accession)];
		$max_date = $self->_get_max_date($tables);
		say "<li>Number of sequences: $allele_count</li>";
		if ( @$scheme_data == 1 ) {
			foreach (@$scheme_data) {
				my $profile_count =
				  $self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM profiles WHERE scheme_id=?", $scheme_data->[0]->{'id'} )
				  ->[0];
				say "<li>Number of profiles ($scheme_data->[0]->{'description'}): $profile_count</li>";
			}
		} elsif ( @$scheme_data > 1 ) {
			say "<li>Number of profiles: <a id=\"toggle1\" class=\"showhide\">Show</a>";
			say "<a id=\"toggle2\" class=\"hideshow\">Hide</a><div class=\"hideshow\"><ul>";
			foreach (@$scheme_data) {
				my $profile_count =
				  $self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM profiles WHERE scheme_id=?", $_->{'id'} )->[0];
				$_->{'description'} =~ s/\&/\&amp;/g;
				say "<li>$_->{'description'}: $profile_count</li>";
			}
			say "</ul></div></li>";
		}
	} else {
		my $isolate_count = $self->{'datastore'}->run_simple_query("SELECT COUNT(*) FROM $self->{'system'}->{'view'}")->[0];
		my @tables        = qw (isolates isolate_aliases allele_designations allele_sequences refs);
		$max_date = $self->_get_max_date( \@tables );
		print "<li>Isolates: $isolate_count</li>";
	}
	say "<li>Last updated: $max_date</li>" if $max_date;
	my $history_table = $self->{'system'}->{'dbtype'} eq 'isolates' ? 'history' : 'profile_history';
	my $history_exists = $self->{'datastore'}->run_simple_query("SELECT EXISTS(SELECT * FROM $history_table)")->[0];
	say "<li><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=tableQuery&amp;table=$history_table&amp;"
	  . "order=timestamp&amp;direction=descending&amp;submit=1$set_string\">"
	  . ( $self->{'system'}->{'dbtype'} eq 'sequences' ? 'Profile u' : 'U' )
	  . "pdate history</a></li>"
	  if $history_exists;
	say "<li><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=version\">About BIGSdb</a></li>";
	say "</ul>\n</div>";
	return;
}

sub _print_plugin_section {
	my ( $self,           $scheme_data ) = @_;
	my ( $scheme_ids_ref, $desc_ref )    = $self->extract_scheme_desc($scheme_data);
	my $q          = $self->{'cgi'};
	my $set_id     = $self->get_set_id;
	my $set_string = $set_id ? "&amp;set_id=$set_id" : '';
	my $plugins =
	  $self->{'pluginManager'}
	  ->get_appropriate_plugin_names( 'breakdown|export|analysis|miscellaneous', $self->{'system'}->{'dbtype'}, { set_id => $set_id } );
	if (@$plugins) {
		print "<div class=\"box\" id=\"plugins\"><div class=\"scrollable\">\n";
		foreach (qw (breakdown export analysis miscellaneous)) {
			$q->param( 'page', 'index' );
			$plugins = $self->{'pluginManager'}->get_appropriate_plugin_names( $_, $self->{'system'}->{'dbtype'}, { set_id => $set_id } );
			next if !@$plugins;
			say "<div style=\"float:left; margin-right:1em\">";
			say "<img src=\"/images/icons/64x64/$_.png\" alt=\"\" />";
			say "<h2>" . ucfirst($_) . "</h2>\n<ul class=\"toplevel\">";
			foreach (@$plugins) {
				my $att      = $self->{'pluginManager'}->get_plugin_attributes($_);
				my $menuitem = $att->{'menutext'};
				my $scheme_arg =
				  ( $self->{'system'}->{'dbtype'} eq 'sequences' && $att->{'seqdb_type'} eq 'schemes' && @$scheme_data == 1 )
				  ? "&amp;scheme_id=$scheme_data->[0]->{'id'}"
				  : '';
				say "<li><a href=\"$self->{'system'}->{'script_name'}?page=plugin&amp;name=$att->{'module'}&amp;"
				  . "db=$self->{'instance'}$scheme_arg$set_string\">$menuitem</a>";
				say " - $att->{'menu_description'}" if $att->{'menu_description'};
				say "</li>";
			}
			say "</ul>\n</div>";
		}
		say "</div>\n</div>";
	}
	return;
}

sub _get_max_date {
	my ( $self, $tables ) = @_;
	local $" = ' UNION SELECT MAX(datestamp) FROM ';
	my $qry          = "SELECT MAX(max_datestamp) FROM (SELECT MAX(datestamp) AS max_datestamp FROM @$tables) AS v";
	my $max_date_ref = $self->{'datastore'}->run_simple_query($qry);
	return ref $max_date_ref eq 'ARRAY' ? $max_date_ref->[0] : undef;
}

sub get_title {
	my ($self) = @_;
	my $desc = $self->get_db_description || 'BIGSdb';
	return $desc;
}

sub _get_allele_count {
	my ($self) = @_;
	my $set_id = $self->get_set_id;
	my $set_clause =
	  $set_id
	  ? " WHERE locus IN (SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT scheme_id FROM set_schemes WHERE "
	  . "set_id=$set_id)) OR locus IN (SELECT locus FROM set_loci WHERE set_id=$set_id)"
	  : '';
	return $self->{'datastore'}->run_simple_query("SELECT COUNT (*) FROM sequences$set_clause")->[0];
}
1;
