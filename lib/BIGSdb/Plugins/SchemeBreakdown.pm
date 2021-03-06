#SchemeBreakdown.pm - SchemeBreakdown plugin for BIGSdb
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
package BIGSdb::Plugins::SchemeBreakdown;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Plugin);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Plugins');
use Error qw(:try);

sub get_attributes {
	my ($self) = @_;
	my %att = (
		name        => 'Scheme Breakdown',
		author      => 'Keith Jolley',
		affiliation => 'University of Oxford, UK',
		email       => 'keith.jolley@zoo.ox.ac.uk',
		description => 'Breakdown of scheme fields and alleles',
		category    => 'Breakdown',
		buttontext  => 'Schemes/alleles',
		menutext    => 'Scheme and alleles',
		module      => 'SchemeBreakdown',
		version     => '1.1.6',
		section     => 'breakdown,postquery',
		url         => "$self->{'config'}->{'doclink'}/data_analysis.html#scheme-and-allele-breakdown",
		input       => 'query',
		requires    => 'js_tree',
		order       => 20,
		dbtype      => 'isolates'
	);
	return \%att;
}

sub get_option_list {
	my ($self) = @_;
	my @list =
	  ( { name => 'order', description => 'Order results by', optlist => 'field/allele name;frequency', default => 'frequency' }, );
	if ( $self->{'config'}->{'chartdirector'} ) {
		push @list,
		  (
			{ name => 'style',       description => 'Pie chart style',            optlist => 'pie;doughnut', default => 'doughnut' },
			{ name => 'threeD',      description => 'Enable 3D effect',           default => 1 },
			{ name => 'transparent', description => 'Enable transparent palette', default => 1 }
		  );
	}
	return \@list;
}

sub get_hidden_attributes {
	my @hidden = qw (field type field_breakdown);
	return \@hidden;
}

sub run {
	my ($self)     = @_;
	my $q          = $self->{'cgi'};
	my $query_file = $q->param('query_file');
	my $format     = $q->param('format');
	if ( $format eq 'text' ) {
		say "Scheme field and allele breakdown of dataset\n" if !$q->param('download');
	} else {
		say "<h1>Scheme field and allele breakdown of dataset</h1>";
	}
	return if $self->has_set_changed;
	my $loci = $self->{'datastore'}->run_query( "SELECT id FROM loci ORDER BY id", undef, { fetch => 'col_arrayref' } );
	if ( !scalar @$loci ) {
		say qq(<div class="box" id="statusbad"><p>No loci are defined for this database.</p></div>);
		return;
	}
	my $qry_ref = $self->get_query($query_file);
	return if ref $qry_ref ne 'SCALAR';
	my $qry = $$qry_ref;
	$qry =~ s/ORDER BY.*$//g;
	$logger->debug("Breakdown query: $qry");
	return if !$self->create_temp_tables($qry_ref);
	if ( $q->param('field_breakdown') || $q->param('download') ) {
		$self->_do_analysis( \$qry );
		return;
	}
	say "<div class=\"box\" id=\"queryform\">";
	$self->_print_tree;
	say "</div>";
	my $schemes =
	  $self->{'datastore'}->run_query( "SELECT id FROM schemes ORDER BY display_order,description", undef, { fetch => 'col_arrayref' } );
	my @selected_schemes;
	foreach ( @$schemes, 0 ) {
		push @selected_schemes, $_ if $q->param("s_$_");
	}
	return if !@selected_schemes;
	say "<div class=\"box\" id=\"resultstable\">";
	foreach my $scheme_id (@selected_schemes) {
		$self->_print_scheme_table( $scheme_id, \$qry );
	}
	say "</div>";
	return;
}

sub _do_analysis {
	my ( $self, $qry_ref ) = @_;
	my $q           = $self->{'cgi'};
	my $field_query = $$qry_ref;
	my $field_type  = 'text';
	my ( $field, $scheme_id );
	my $temp_table;
	my $view = $self->{'system'}->{'view'};
	if ( $q->param('type') eq 'field' ) {

		if ( $q->param('field') =~ /^(\d+)_(.*)$/ ) {
			$scheme_id = $1;
			$field     = $2;
			if ( !$self->{'datastore'}->is_scheme_field( $scheme_id, $field ) ) {
				say "<div class=\"box\" id=\"statusbad\"><p>Invalid field passed for analysis!</p></div>";
				$logger->error( "Invalid field passed for analysis. Field is set as '" . $q->param('field') . "'." );
				return;
			}
			my $scheme_fields_qry;
			my $scheme_info = $self->{'datastore'}->get_scheme_info($scheme_id);
			if ( $scheme_info->{'dbase_name'} ) {
				my $continue = 1;
				try {
					$temp_table        = $self->{'datastore'}->create_temp_isolate_scheme_fields_view($scheme_id);
					$scheme_fields_qry = "SELECT * FROM $view LEFT JOIN $temp_table ON $view.id=$temp_table.id";
				}
				catch BIGSdb::DatabaseConnectionException with {
					say "<div class=\"box\" id=\"statusbad\"><p>The database for scheme $scheme_id is not accessible.  This may be a "
					  . "configuration problem.</p></div>";
					$continue = 0;
				};
				return if !$continue;
			}
			$field_query = $scheme_fields_qry;
			my $scheme_field_info = $self->{'datastore'}->get_scheme_field_info( $scheme_id, $field );
			$field_type = $scheme_field_info->{'type'};
			if ( $field_type eq 'integer' ) {
				$field_query =~ s/\*/DISTINCT(CAST($temp_table\.$field AS int)),COUNT($temp_table\.$field)/;
			} else {
				$field_query =~ s/\*/DISTINCT($temp_table\.$field),COUNT($temp_table\.$field)/;
			}
			if ( $$qry_ref =~ /SELECT \* FROM refs/ || $$qry_ref =~ /SELECT \* FROM $view LEFT JOIN refs/ ) {
				$field_query =~ s/FROM $view/FROM $view LEFT JOIN refs ON refs.isolate_id=id/;
			}
			if ( $$qry_ref =~ /WHERE (.*)$/ ) {
				$field_query .= " AND $1";
			}
			$field_query .= " GROUP BY $temp_table.$field";
		} else {
			say "<div class=\"box\" id=\"statusbad\"><p>Invalid field passed for analysis!</p></div>";
			$logger->error( "Invalid field passed for analysis. Field is set as '" . $q->param('field') . "'." );
			return;
		}
	} elsif ( $q->param('type') eq 'locus' ) {
		my $locus = $q->param('field');
		if ( !$self->{'datastore'}->is_locus($locus) ) {
			say "<div class=\"box\" id=\"statusbad\"><p>Invalid locus passed for analysis!</p></div>";
			$logger->error( "Invalid locus passed for analysis. Locus is set as '" . $q->param('field') . "'." );
			return;
		}
		my $locus_info = $self->{'datastore'}->get_locus_info($locus);
		$locus =~ s/'/\\'/g;
		$field_type = $locus_info->{'allele_id_format'};
		$field_query =~ s/SELECT \* FROM $view/SELECT \* FROM $view LEFT JOIN allele_designations ON isolate_id=$view\.id/;
		if ( $field_type eq 'integer' ) {
			$field_query =~ s/\*/DISTINCT(CAST(allele_id AS int)),COUNT(allele_id)/;
		} else {
			$field_query =~ s/\*/DISTINCT(allele_id),COUNT(allele_id)/;
		}
		if ( $field_query =~ /WHERE/ ) {
			$field_query =~ s/WHERE (.*)$/WHERE \($1\)/;
			$field_query .= " AND locus=E'$locus'";
		} else {
			$field_query .= " WHERE locus=E'$locus'";
		}
		$field_query =~ s/refs RIGHT JOIN $view/refs RIGHT JOIN $view LEFT JOIN allele_designations ON isolate_id=$view\.id/;
		$field_query .= " GROUP BY allele_id";
	} else {
		say "<div class=\"box\" id=\"statusbad\"><p>Invalid field passed for analysis!</p></div>";
		$logger->error( "Invalid field passed for analysis. Field type is set as '" . $q->param('type') . "'." );
		return;
	}
	my $order;
	my $guid = $self->get_guid;
	my $temp_fieldname;
	if ( $q->param('type') eq 'locus' ) {
		$temp_fieldname = 'allele_id';
	} else {
		$temp_fieldname = defined $scheme_id ? "$temp_table\.$field" : $field;
	}
	try {
		$order = $self->{'prefstore'}->get_plugin_attribute( $guid, $self->{'system'}->{'db'}, 'SchemeBreakdown', 'order' );
		if ( $order eq 'frequency' ) {
			$order = "COUNT($temp_fieldname) desc";
		} else {
			$order =
			    $field_type eq 'text'
			  ? $temp_fieldname
			  : "CAST($temp_fieldname AS int)";
		}
	}
	catch BIGSdb::DatabaseNoRecordException with {
		$order = "COUNT($temp_fieldname) desc";
	};
	$field_query .= " ORDER BY $order";
	if ( $q->param('download') ) {
		$self->_download_alleles( $q->param('field'), \$field_query );
		return;
	} else {
		$self->_breakdown_field( $field, $$qry_ref, \$field_query );
	}
	return;
}

sub _breakdown_field {
	my ( $self, $field, $qry, $field_query_ref ) = @_;
	my $q   = $self->{'cgi'};
	my $sql = $self->{'db'}->prepare($$field_query_ref);
	eval { $sql->execute };
	$logger->error($@) if $@;
	my $heading = $q->param('type') eq 'field' ? $field : $q->param('field');
	my $html_heading = '';
	if ( $q->param('type') eq 'locus' ) {
		my $locus = $q->param('field');
		my @other_display_names;
		local $" = '; ';
		my $aliases = $self->{'datastore'}->get_locus_aliases($locus);
		push @other_display_names, @$aliases if @$aliases;
		$html_heading .= " <span class=\"comment\">(@other_display_names)</span>" if @other_display_names;
	}
	my $td = 1;
	$qry =~ s/\*/COUNT(\*)/;
	my $total  = $self->{'datastore'}->run_query($qry);
	my $format = $q->param('format');
	if ( $format eq 'text' ) {
		say "Total: $total isolates\n";
		say "$heading\tFrequency\tPercentage";
	} else {
		say qq(<div class="box" id="resultstable"><div class="scrollable">);
		say qq(<table><tr><td style="vertical-align:top">);
		say "<p>Total: $total isolates</p>";
		say qq(<table class="tablesorter" id="sortTable">);
		$heading = $self->clean_locus($heading) if $q->param('type') eq 'locus';
		say "<thead><tr><th>$heading$html_heading</th><th>Frequency</th><th>Percentage</th></tr></thead>";
	}
	my ( @labels, @values );
	while ( my ( $allele_id, $count ) = $sql->fetchrow_array ) {
		if ($count) {
			my $percentage = BIGSdb::Utils::decimal_place( $count * 100 / $total, 2 );
			if ( $format eq 'text' ) {
				say "$allele_id\t$count\t$percentage";
			} else {
				say "<tr class=\"td$td\"><td>";
				if ( $allele_id eq '' ) {
					say 'No value';
				} else {
					my $url;
					if ( $q->param('type') eq 'locus' ) {
						$url = $self->{'datastore'}->get_locus_info( $q->param('field') )->{'url'} || '';
						$url =~ s/\&/\&amp;/g;
						$url =~ s/\[\?\]/$allele_id/;
					}
					say $url ? "<a href=\"$url\">$allele_id</a>" : $allele_id;
				}
				say "</td><td>$count</td><td>$percentage</td></tr>";
				$td = $td == 1 ? 2 : 1;
			}
			push @labels, ( $allele_id ne '' ) ? $allele_id : 'No value';
			push @values, $count;
		}
	}
	if ( $format ne 'text' ) {
		say "</table>";
		say qq(</td><td style="vertical-align:top; padding-left:2em">);
		my $query_file_att = $q->param('query_file') ? ( "&amp;query_file=" . $q->param('query_file') ) : undef;
		say $q->start_form;
		say $q->submit( -name => 'field_breakdown', -label => 'Tab-delimited text', -class => 'smallbutton' );
		$q->param( 'format', 'text' );
		say $q->hidden($_) foreach qw (query_file field type page name db format list_file datatype);
		say $q->end_form;

		if ( $self->{'config'}->{'chartdirector'} ) {
			my %prefs;
			my $guid = $self->get_guid;
			foreach (qw (threeD transparent )) {
				try {
					$prefs{$_} = $self->{'prefstore'}->get_plugin_attribute( $guid, $self->{'system'}->{'db'}, 'SchemeBreakdown', $_ );
					$prefs{$_} = $prefs{$_} eq 'true' ? 1 : 0;
				}
				catch BIGSdb::DatabaseNoRecordException with {
					$prefs{$_} = 1;
				};
			}
			try {
				$prefs{'style'} =
				  $self->{'prefstore'}->get_plugin_attribute( $guid, $self->{'system'}->{'db'}, 'SchemeBreakdown', 'style' );
			}
			catch BIGSdb::DatabaseNoRecordException with {
				$prefs{'style'} = 'doughnut';
			};
			my $temp = BIGSdb::Utils::get_random();
			BIGSdb::Charts::piechart( \@labels, \@values, "$self->{'config'}->{'tmp_dir'}/$temp\_pie.png", 24, 'small', \%prefs );
			say "<img src=\"/tmp/$temp\_pie.png\" alt=\"pie chart\" />";
			BIGSdb::Charts::barchart( \@labels, \@values, "$self->{'config'}->{'tmp_dir'}/$temp\_bar.png", 'small', \%prefs );
			say "<img src=\"/tmp/$temp\_bar.png\" alt=\"bar chart\" />";
		}
		say "</td></tr></table>";
		say "</div></div>";
	}
	return;
}

sub _print_scheme_table {
	my ( $self, $scheme_id, $qry_ref ) = @_;
	my $q      = $self->{'cgi'};
	my $set_id = $self->get_set_id;
	return
	  if !$self->{'prefs'}->{'analysis_schemes'}->{$scheme_id}
	  && $scheme_id;
	my ( $fields, $loci );
	if ($scheme_id) {
		$fields = $self->{'datastore'}->get_scheme_fields($scheme_id);
		$loci = $self->{'datastore'}->get_scheme_loci( $scheme_id, ( { profile_name => 0, analysis_pref => 1 } ) );
	} else {
		$loci = $self->{'datastore'}->get_loci_in_no_scheme( { analyse_pref => 1, set_id => $set_id } );
		$fields = \@;;
	}
	return if !@$loci && !@$fields;
	if ( !$self->{'sql'}->{'alias_sql'} ) {
		$self->{'sql'}->{'alias_sql'} = $self->{'db'}->prepare("SELECT alias FROM locus_aliases WHERE locus=?");
	}
	my $rows = ( @$fields >= @$loci ? @$fields : @$loci ) || 1;
	my $scheme_info;
	if ($scheme_id) {
		$scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { set_id => $set_id } );
	} else {
		$scheme_info->{'description'} = 'Loci not in schemes';
	}
	my $scheme_fields_qry;
	my $temp_table;
	my $view = $self->{'system'}->{'view'};
	if ( $scheme_id && $scheme_info->{'dbase_name'} && @$fields ) {
		my $continue = 1;
		try {
			$temp_table        = $self->{'datastore'}->create_temp_isolate_scheme_fields_view($scheme_id);
			$scheme_fields_qry = "SELECT * FROM $view LEFT JOIN $temp_table ON $view.id=$temp_table.id";
		}
		catch BIGSdb::DatabaseConnectionException with {
			say "</table>\n</div>";
			say "<div class=\"box\" id=\"statusbad\"><p>The database for scheme $scheme_id is not accessible.  "
			  . "This may be a configuration problem.</p></div>";
			$continue = 0;
		};
		return if !$continue;
	}
	( my $desc = $scheme_info->{'description'} ) =~ s/&/&amp;/g;
	local $| = 1;
	say "<h2>$desc</h2>";
	say "<table class=\"resultstable\">\n<tr>";
	say "<th colspan=\"3\">Fields</th>" if @$fields;
	say "<th colspan=\"4\">Alleles</th></tr>\n<tr>";
	say "<th>Field name</th><th>Unique values</th><th>Analyse</th>" if @$fields;
	say "<th>Locus</th><th>Unique alleles</th><th>Analyse</th><th>Download</th>";
	say "</tr>";
	my $td = 1;
	say "<tr class=\"td$td\">";
	my $field_values;

	if ( $scheme_info->{'dbase_name'} && @$fields ) {
		my $scheme_query = $scheme_fields_qry;
		if ( $$qry_ref =~ /SELECT \* FROM refs/ || $$qry_ref =~ /SELECT \* FROM $view LEFT JOIN refs/ ) {
			$scheme_query =~ s/FROM $view/FROM $view LEFT JOIN refs ON refs.isolate_id=id/;
		}
		if ( $$qry_ref =~ /WHERE (.*)$/ ) {
			$scheme_query .= " WHERE ($1)";
		}
		local $" = ",$temp_table.";
		my $field_string = "$temp_table.@$fields";
		$scheme_query =~ s/\*/$field_string/;
		my $sql = $self->{'db'}->prepare($scheme_query);
		$logger->debug($scheme_query);
		eval { $sql->execute };
		$logger->error($@) if $@;
		my $data = $sql->fetchall_arrayref;

		foreach my $values (@$data) {
			my $i = 0;
			foreach my $field (@$fields) {
				$field_values->{$field}->{ $values->[$i] } = 1 if defined $values->[$i];
				$i++;
			}
		}
	}
	for my $i ( 0 .. $rows - 1 ) {
		say "<tr class=\"td$td\">" if $i;
		my $display;
		if (@$fields) {
			$display = $fields->[$i] || '';
			$display =~ tr/_/ /;
			say "<td>$display</td>";
			if ( $scheme_info->{'dbase_name'} && @$fields && $fields->[$i] ) {
				my $value = keys %{ $field_values->{ $fields->[$i] } };
				say "<td>$value</td><td>";
				if ($value) {
					say $q->start_form;
					say $q->submit( -label => 'Breakdown', -class => 'smallbutton' );
					$q->param( field           => "$scheme_id\_$fields->[$i]" );
					$q->param( type            => 'field' );
					$q->param( field_breakdown => 1 );
					say $q->hidden($_) foreach qw (page name db query_file type field field_breakdown list_file datatype);
					say $q->end_form;
				}
				say "</td>";
			} else {
				say "<td></td><td></td>";
			}
		}
		$display = $self->clean_locus( $loci->[$i] );
		my @other_display_names;
		if ( defined $loci->[$i] ) {
			if ( $self->{'prefs'}->{'locus_alias'} ) {
				eval { $self->{'sql'}->{'alias_sql'}->execute( $loci->[$i] ) };
				if ($@) {
					$logger->error($@);
				} else {
					while ( my ($alias) = $self->{'sql'}->{'alias_sql'}->fetchrow_array ) {
						push @other_display_names, $alias;
					}
				}
			}
		}
		if (@other_display_names) {
			local $" = ', ';
			$display .= " <span class=\"comment\">(@other_display_names)</span>";
			$display =~ tr/_/ /;
		}
		print defined $display ? "<td>$display</td>" : '<td></td>';
		if ( $loci->[$i] ) {
			my $cleaned_locus = $loci->[$i];
			$cleaned_locus =~ s/'/\\'/g;
			my $locus_query = $$qry_ref;
			$locus_query =~
			  s/SELECT \* FROM $view/SELECT \* FROM $view LEFT JOIN allele_designations ON allele_designations.isolate_id=$view.id/;
			$locus_query =~ s/\*/COUNT (DISTINCT(allele_id))/;
			if ( $locus_query =~ /WHERE/ ) {
				$locus_query =~ s/WHERE (.*)$/WHERE \($1\)/;
				$locus_query .= " AND locus=E'$cleaned_locus'";
			} else {
				$locus_query .= " WHERE locus=E'$cleaned_locus'";
			}
			$locus_query .= " AND status != 'ignore'";
			$locus_query =~
			  s/refs RIGHT JOIN $view/refs RIGHT JOIN $view LEFT JOIN allele_designations ON allele_designations.isolate_id=$view.id/;
			my $sql = $self->{'db'}->prepare($locus_query);
			eval { $sql->execute };
			$logger->error($@) if $@;
			my ($value) = $sql->fetchrow_array;
			say "<td>$value</td>";

			if ($value) {
				say "<td>";
				say $q->start_form;
				say $q->submit( -label => 'Breakdown', -class => 'smallbutton' );
				$q->param( field => $loci->[$i] );
				$q->param( type  => 'locus' );
				say $q->hidden( field_breakdown => 1 );
				say $q->hidden($_) foreach qw (page name db query_file field type list_file datatype);
				say $q->end_form;
				say "</td><td>";
				say $q->start_form;
				say $q->submit( -label => 'Download', -class => 'smallbutton' );
				say $q->hidden( download => 1 );
				$q->param( format => 'text' );
				say $q->hidden($_) foreach qw (page name db query_file field type format list_file datatype);
				say $q->end_form;
				say "</td>";
			} else {
				say "<td></td><td></td>";
			}
		} else {
			say "<td></td><td></td>";
		}
		say "</tr>";
		$td = $td == 1 ? 2 : 1;
	}
	print "</table>\n";
	if ( $ENV{'MOD_PERL'} ) {
		$self->{'mod_perl_request'}->rflush;
		return if $self->{'mod_perl_request'}->connection->aborted;
	}
	return;
}

sub _download_alleles {
	my ( $self, $locus_name, $query_ref ) = @_;
	my $allele_ids = $self->{'datastore'}->run_query( $$query_ref, undef, { fetch => 'all_arrayref', slice => {} } );
	my $locus = $self->{'datastore'}->get_locus($locus_name);
	foreach (@$allele_ids) {
		my $seq_ref = $locus->get_allele_sequence( $_->{'allele_id'} );
		if ( ref $seq_ref eq 'SCALAR' && defined $$seq_ref ) {
			$seq_ref = BIGSdb::Utils::break_line( $seq_ref, 60 );
			say ">$_->{'allele_id'}";
			say $$seq_ref;
		}
	}
	return;
}

sub _print_tree {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	say $q->start_form;
	print << "HTML";
<p>Select schemes or groups of schemes within the tree.  A breakdown of the individual fields and loci belonging to 
these schemes will then be performed.</p>
<noscript>
<p class="highlight">You need to enable Javascript in order to select schemes for analysis.</p>
</noscript>
<div id="tree" class="tree" style=\"display:none; height:10em; width:30em\">
HTML
	say $self->get_tree( undef, { no_link_out => 1, select_schemes => 1, analysis_pref => 1 } );
	say "</div>";
	say $q->submit( -name => 'selected', -label => 'Select', -class => 'submit' );
	my $set_id = $self->get_set_id;
	$q->param( set_id => $set_id );
	say $q->hidden($_) foreach qw(db page name query_file set_id list_file datatype);
	say $q->end_form;
	return;
}

sub get_plugin_javascript {
	my ($self) = @_;
	my $buffer = << "END";
\$(function () {
	\$('#tree').show();
});
	
END
	return $buffer;
}
1;
