#SequenceExport.pm - Export concatenated sequences/XMFA file plugin for BIGSdb
#Written by Keith Jolley
#Copyright (c) 2010-2015, University of Oxford
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
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See thef
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with BIGSdb.  If not, see <http://www.gnu.org/licenses/>.
package BIGSdb::Plugins::SequenceExport;
use strict;
use warnings;
use parent qw(BIGSdb::Plugin);
use 5.010;
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Plugins');
use Error qw(:try);
use List::MoreUtils qw(any none uniq);
use Apache2::Connection ();
use Bio::Perl;
use Bio::SeqIO;
use Bio::AlignIO;
use BIGSdb::Utils;
use constant DEFAULT_ALIGN_LIMIT => 200;
use constant DEFAULT_SEQ_LIMIT   => 1_000_000;
use BIGSdb::Page qw(LOCUS_PATTERN);
use BIGSdb::Plugin qw(SEQ_SOURCE);

sub get_attributes {
	my ($self) = @_;
	my %att = (
		name             => 'Sequence Export',
		author           => 'Keith Jolley',
		affiliation      => 'University of Oxford, UK',
		email            => 'keith.jolley@zoo.ox.ac.uk',
		description      => 'Export concatenated allele sequences in XMFA and FASTA formats',
		menu_description => 'XMFA / concatenated FASTA formats',
		category         => 'Export',
		buttontext       => 'Sequences',
		menutext         => 'Sequences',
		module           => 'SequenceExport',
		version          => '1.5.3',
		dbtype           => 'isolates,sequences',
		seqdb_type       => 'schemes',
		section          => 'export,postquery',
		url              => "$self->{'config'}->{'doclink'}/data_export.html#sequence-export",
		input            => 'query',
		help             => 'tooltips',
		requires         => 'aligner,offline_jobs,js_tree',
		order            => 22,
	);
	return \%att;
}

sub set_pref_requirements {
	my ($self) = @_;
	$self->{'pref_requirements'} = { general => 1, main_display => 0, isolate_display => 0, analysis => 1, query_field => 0 };
	return;
}

sub run {
	my ($self)     = @_;
	my $q          = $self->{'cgi'};
	my $query_file = $q->param('query_file');
	my $scheme_id  = $q->param('scheme_id');
	my $desc       = $self->get_db_description;
	my $max_seqs = $self->{'system'}->{'seq_export_limit'} // DEFAULT_SEQ_LIMIT;
	my $commified_max = BIGSdb::Utils::commify($max_seqs);
	say "<h1>Export allele sequences in XMFA/concatenated FASTA formats - $desc</h1>";
	return if $self->has_set_changed;
	my $allow_alignment = 1;

	if ( !-x $self->{'config'}->{'muscle_path'} && !-x $self->{'config'}->{'mafft_path'} ) {
		$logger->error( "This plugin requires an aligner (MAFFT or MUSCLE) to be installed and one isn't.  Please install one of these "
			  . "or check the settings in bigsdb.conf." );
		$allow_alignment = 0;
	}
	my $pk;
	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		$pk = 'id';
	} else {
		return if defined $scheme_id && $self->is_scheme_invalid( $scheme_id, { with_pk => 1 } );
		if ( !$q->param('submit') ) {
			$self->print_scheme_section( { with_pk => 1 } );
			$scheme_id = $q->param('scheme_id');    #Will be set by scheme section method
		}
		if ( !defined $scheme_id ) {
			say qq(<div class="box" id="statusbad"><p>Invalid scheme selected.</p></div>);
			return;
		}
		my $scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { get_pk => 1 } );
		$pk = $scheme_info->{'primary_key'};
	}
	if ( $q->param('submit') ) {
		my $loci_selected = $self->get_selected_loci;
		my ( $pasted_cleaned_loci, $invalid_loci ) = $self->get_loci_from_pasted_list;
		$q->delete('locus');
		push @$loci_selected, @$pasted_cleaned_loci;
		@$loci_selected = uniq @$loci_selected;
		$self->add_scheme_loci($loci_selected);
		if (@$invalid_loci) {
			local $" = ', ';
			say "<div class=\"box\" id=\"statusbad\"><p>The following loci in your pasted list are invalid: @$invalid_loci.</p></div>";
		} elsif ( !@$loci_selected ) {
			print "<div class=\"box\" id=\"statusbad\"><p>You must select one or more loci";
			print " or schemes" if $self->{'system'}->{'dbtype'} eq 'isolates';
			say ".</p></div>\n";
		} elsif ( $self->attempted_spam( \( $q->param('list') ) ) ) {
			say qq(<div class="box" id="statusbad"><p>Invalid data detected in list.</p></div>);
		} else {
			$self->set_scheme_param;
			my $params = $q->Vars;
			$params->{'pk'}     = $pk;
			$params->{'set_id'} = $self->get_set_id;
			my @list = split /[\r\n]+/, $q->param('list');
			@list = uniq @list;
			if ( !@list ) {
				if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
					my $qry = "SELECT id FROM $self->{'system'}->{'view'} ORDER BY id";
					my $id_list = $self->{'datastore'}->run_query( $qry, undef, { fetch => 'col_arrayref' } );
					@list = @$id_list;
				} else {
					my $pk_info = $self->{'datastore'}->get_scheme_field_info( $scheme_id, $pk );
					my $qry = "SELECT profile_id FROM profiles WHERE scheme_id=? ORDER BY ";
					$qry .= $pk_info->{'type'} eq 'integer' ? 'CAST(profile_id AS INT)' : 'profile_id';
					my $id_list = $self->{'datastore'}->run_query( $qry, $scheme_id, { fetch => 'col_arrayref' } );
					@list = @$id_list;
				}
			}
			my $total_seqs = @$loci_selected * @list;
			if ( $total_seqs > $max_seqs ) {
				my $commified_total = BIGSdb::Utils::commify($total_seqs);
				say qq(<div class="box" id="statusbad"><p>Output is limited to a total of $commified_max sequences (records x loci).  You )
				  . qq(have selected $commified_total.</p></div>);
				return;
			}
			my $list_type = $self->{'system'}->{'dbtype'} eq 'isolates' ? 'isolates' : 'profiles';
			$q->delete('list');
			my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
			my $job_id    = $self->{'jobManager'}->add_job(
				{
					dbase_config => $self->{'instance'},
					ip_address   => $q->remote_host,
					module       => 'SequenceExport',
					parameters   => $params,
					username     => $self->{'username'},
					email        => $user_info->{'email'},
					loci         => $loci_selected,
					$list_type   => \@list
				}
			);
			say qq(<div class="box" id="resultstable">);
			say qq(<p>This analysis has been submitted to the job queue.</p>);
			say qq(<p>Please be aware that this job may take a long time depending on the number of sequences to align and how busy the )
			  . qq(server is.  Alignment of hundreds of sequences can take many hours!</p>);
			say qq(<p><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=job&amp;id=$job_id">Follow the progress )
			  . qq(of this job and view the output.</a></p>);
			say qq(<p>Please note that the % complete value will only update after the extraction (and, if selected, alignment) of )
			  . qq(each locus.</p></div>);
			return;
		}
	}
	my $limit = $self->{'system'}->{'XMFA_limit'} // $self->{'system'}->{'align_limit'} // DEFAULT_ALIGN_LIMIT;
	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		say qq(<div class="box" id="queryform">);
		say qq(<p>This script will export allele sequences in Extended Multi-FASTA (XMFA) format suitable for loading into third-party )
		  . qq(applications, such as ClonalFrame.  It will also produce concatenated FASTA files. Only DNA loci that have a corresponding )
		  . qq(database containing allele sequence identifiers, or DNA and peptide loci with genome sequences tagged, can be included. )
		  . qq(Please check the loci that you would like to include.  Alternatively select one or more schemes to include )
		  . qq(all loci that are members of the scheme.  If a sequence does not exist in the remote database, it will be replaced with )
		  . qq(gap characters.</p>);
		say qq(<p>Aligned output is limited to $limit records; total output (records x loci) is limited to $commified_max sequences.</p>);
		say qq(<p>Please be aware that if you select the alignment option it may take a long time to generate the output file.</p>);
	} else {
		say qq(<div class="box" id="queryform">);
		say qq(<p>This script will export allele sequences in Extended Multi-FASTA (XMFA) format suitable for loading into third-party )
		  . qq(applications, such as ClonalFrame.</p>);
		say qq(<p>Aligned Output is limited to $limit records; total output (records x loci) is limited to $commified_max sequences.</p>);
		say qq(<p>Please be aware that if you select the alignment option it may take a long time to generate the output file.</p>);
	}
	my $list = $self->get_id_list( $pk, $query_file );
	$self->print_sequence_export_form(
		$pk, $list,
		$scheme_id,
		{
			default_select    => 0,
			translate         => 1,
			flanking          => 1,
			ignore_seqflags   => 1,
			ignore_incomplete => 1,
			align             => $allow_alignment,
			in_frame          => 1,
			include_seqbin_id => 1
		}
	);
	say "</div>";
	return;
}

sub run_job {
	my ( $self, $job_id, $params ) = @_;
	$self->set_offline_view($params);
	$self->{'exit'} = 0;
	local @SIG{qw (INT TERM HUP)} = ( sub { $self->{'exit'} = 1 } ) x 3;    #Allow temp files to be cleaned on kill signals
	my $scheme_id = $params->{'scheme_id'};
	my $pk        = $params->{'pk'};
	my $filename  = "$self->{'config'}->{'tmp_dir'}/$job_id\.xmfa";
	open( my $fh, '>', $filename )
	  or $logger->error("Can't open output file $filename for writing");
	my $isolate_sql =
	    $self->{'system'}->{'dbtype'} eq 'isolates'
	  ? $self->{'db'}->prepare("SELECT * FROM $self->{'system'}->{'view'} WHERE id=?")
	  : undef;
	my ( @includes, %field_included );

	if ( $params->{'includes'} ) {
		my $separator = '\|\|';
		@includes = split /$separator/, $params->{'includes'};
		%field_included = map { $_ => 1 } @includes;
	}
	my $substring_query;
	if ( $params->{'flanking'} && BIGSdb::Utils::is_int( $params->{'flanking'} ) ) {

		#round up to the nearest multiple of 3 if translating sequences to keep in reading frame
		if ( $params->{'translate'} ) {
			$params->{'flanking'} = BIGSdb::Utils::round_to_nearest( $params->{'flanking'}, 3 );
		}
		$substring_query = "substring(sequence from allele_sequences.start_pos-$params->{'flanking'} for "
		  . "allele_sequences.end_pos-allele_sequences.start_pos+1+2*$params->{'flanking'})";
	} else {
		$substring_query = "substring(sequence from allele_sequences.start_pos for allele_sequences.end_pos-allele_sequences.start_pos+1)";
	}
	my $ignore_seqflags   = $params->{'ignore_seqflags'}   ? 'AND flag IS NULL' : '';
	my $ignore_incomplete = $params->{'ignore_incomplete'} ? 'AND complete'     : '';
	my $seqbin_qry =
	    "SELECT $substring_query,reverse, seqbin_id, start_pos FROM allele_sequences LEFT JOIN sequence_bin ON allele_sequences.seqbin_id="
	  . "sequence_bin.id LEFT JOIN sequence_flags ON allele_sequences.id=sequence_flags.id WHERE allele_sequences.isolate_id=? "
	  . "AND allele_sequences.locus=? $ignore_seqflags $ignore_incomplete ORDER BY complete,allele_sequences.datestamp LIMIT 1";
	my @problem_ids;
	my %problem_id_checked;
	my $start = 1;
	my $end;
	my $no_output     = 1;
	my $loci          = $self->{'jobManager'}->get_job_loci($job_id);
	my $selected_loci = $self->order_loci($loci);
	my $ids;

	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		$ids = $self->{'jobManager'}->get_job_isolates($job_id);
	} else {
		$ids = $self->{'jobManager'}->get_job_profiles( $job_id, $scheme_id );
	}
	my $limit = $self->{'system'}->{'XMFA_limit'} // $self->{'system'}->{'align_limit'} // DEFAULT_ALIGN_LIMIT;
	if ( $params->{'align'} && @$ids > $limit ) {
		my $message_html = "<p class=\"statusbad\">Please note that output is limited to the first $limit records.</p>\n";
		$self->{'jobManager'}->update_job_status( $job_id, { message_html => $message_html } );
	}
	my $progress = 0;
	foreach my $locus_name (@$selected_loci) {
		last if $self->{'exit'};
		my $output_locus_name = $self->clean_locus( $locus_name, { text_output => 1, no_common_name => 1 } );
		$self->{'jobManager'}->update_job_status( $job_id, { stage => "Processing $output_locus_name" } );
		my %no_seq;
		my $locus;
		my $locus_info = $self->{'datastore'}->get_locus_info($locus_name);
		try {
			$locus = $self->{'datastore'}->get_locus($locus_name);
		}
		catch BIGSdb::DataException with {
			$logger->warn("Invalid locus '$locus_name' passed.");
		};
		my $temp         = BIGSdb::Utils::get_random();
		my $temp_file    = "$self->{'config'}->{secure_tmp_dir}/$temp.txt";
		my $aligned_file = "$self->{'config'}->{secure_tmp_dir}/$temp.aligned";
		open( my $fh_unaligned, '>', "$temp_file" ) or $logger->error("could not open temp file $temp_file");
		my $count = 0;
		foreach my $id (@$ids) {
			last if $count == $limit && $params->{'align'};
			$count++;
			if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
				my @include_values;
				eval { $isolate_sql->execute($id) };
				$logger->error($@) if $@;
				my $isolate_data = $isolate_sql->fetchrow_hashref;
				if (@includes) {
					foreach my $field (@includes) {
						next if $field eq SEQ_SOURCE;
						my ( $metaset, $metafield ) = $self->get_metaset_and_fieldname($field);
						my $value;
						if ( defined $metaset ) {
							$value = $self->{'datastore'}->get_metadata_value( $id, $metaset, $metafield );
						} else {
							$value = $isolate_data->{$field} // '';
						}
						$value =~ tr/ /_/;
						push @include_values, $value;
					}
				}
				if ( !$isolate_data->{'id'} ) {
					push @problem_ids, $id if !$problem_id_checked{$id};
					$problem_id_checked{$id} = 1;
					next;
				}
				my $allele_ids = $self->{'datastore'}->get_allele_ids( $id, $locus_name );
				my $allele_seq;
				if ( $locus_info->{'data_type'} eq 'DNA' ) {
					try {
						foreach my $allele_id ( sort @$allele_ids ) {
							next if $allele_id eq '0';
							$allele_seq .= ${ $locus->get_allele_sequence($allele_id) };
						}
					}
					catch BIGSdb::DatabaseConnectionException with {

						#do nothing
					};
				}
				my $seqbin_seq;
				my $seqbin_pos = '';
				if ($@) {
					$logger->error($@);
				} else {
					my ( $reverse, $seqbin_id, $start_pos );
					( $seqbin_seq, $reverse, $seqbin_id, $start_pos ) =
					  $self->{'datastore'}->run_query( $seqbin_qry, [ $id, $locus_name ], { cache => 'SequenceExport::run_job' } );
					if ($reverse) {
						$seqbin_seq = BIGSdb::Utils::reverse_complement($seqbin_seq);
					}
					$seqbin_pos = "$seqbin_id\_$start_pos" if $seqbin_seq;
				}
				my $seq;
				if ( $allele_seq && $seqbin_seq ) {
					if ( $params->{'chooseseq'} eq 'seqbin' ) {
						$seq = $seqbin_seq;
						push @include_values, $seqbin_pos if $field_included{&SEQ_SOURCE};
					} else {
						$seq = $allele_seq;
						push @include_values, 'defined_allele' if $field_included{&SEQ_SOURCE};
					}
				} elsif ( $allele_seq && !$seqbin_seq ) {
					$seq = $allele_seq;
					push @include_values, 'defined_allele' if $field_included{&SEQ_SOURCE};
				} elsif ($seqbin_seq) {
					$seq = $seqbin_seq;
					push @include_values, $seqbin_pos if $field_included{&SEQ_SOURCE};
				} else {
					$seq = 'N';
					$no_seq{$id} = 1;
					push @include_values, 'no_seq' if $field_included{&SEQ_SOURCE};
				}
				if ( $params->{'in_frame'} || $params->{'translate'} ) {
					$seq = BIGSdb::Utils::chop_seq( $seq, $locus_info->{'orf'} || 1 );
				}
				print $fh_unaligned ">$id";
				local $" = '|';
				print $fh_unaligned "|@include_values" if @includes;
				print $fh_unaligned "\n";
				if ( $params->{'translate'} ) {
					my $peptide = $seq ? Bio::Perl::translate_as_string($seq) : 'X';
					say $fh_unaligned $peptide;
				} else {
					say $fh_unaligned $seq;
				}
			} else {
				my $scheme_view = $self->{'datastore'}->materialized_view_exists($scheme_id) ? "mv_scheme_$scheme_id" : "scheme_$scheme_id";
				my $profile_sql = $self->{'db'}->prepare("SELECT * FROM $scheme_view WHERE $pk=?");
				eval { $profile_sql->execute($id) };
				$logger->error($@) if $@;
				my $profile_data = $profile_sql->fetchrow_hashref;
				my $profile_id   = $profile_data->{ lc($pk) };
				my $header;
				if ( defined $profile_id ) {
					$header = ">$profile_id";
					if (@includes) {
						foreach my $field (@includes) {
							my $value = $profile_data->{ lc($field) } // '';
							$value =~ tr/[\(\):, ]/_/;
							$header .= "|$value";
						}
					}
				}
				if ($profile_id) {
					my $allele_id = $self->{'datastore'}->get_profile_allele_designation( $scheme_id, $id, $locus_name )->{'allele_id'};
					my $allele_seq_ref = $self->{'datastore'}->get_sequence( $locus_name, $allele_id );
					say $fh_unaligned $header;
					if ( $allele_id eq '0' || $allele_id eq 'N' ) {
						say $fh_unaligned 'N';
						$no_seq{$id} = 1;
					} else {
						my $allele_seq = $$allele_seq_ref;
						if ( ( $params->{'in_frame'} || $params->{'translate'} ) && $locus_info->{'data_type'} eq 'DNA' ) {
							$allele_seq = BIGSdb::Utils::chop_seq( $allele_seq, $locus_info->{'orf'} || 1 );
						}
						if ( $params->{'translate'} && $locus_info->{'data_type'} eq 'DNA' ) {
							my $peptide = $allele_seq ? Bio::Perl::translate_as_string($allele_seq) : 'X';
							say $fh_unaligned $peptide;
						} else {
							say $fh_unaligned $allele_seq;
						}
					}
				} else {
					push @problem_ids, $id if !$problem_id_checked{$id};
					$problem_id_checked{$id} = 1;
					next;
				}
			}
		}
		close $fh_unaligned;
		$self->{'db'}->commit;    #prevent idle in transaction table locks
		my $output_file;
		if ( $params->{'align'} && $params->{'aligner'} eq 'MAFFT' && -e $temp_file && -s $temp_file ) {
			system("$self->{'config'}->{'mafft_path'} --quiet --preservecase $temp_file > $aligned_file");
			$output_file = $aligned_file;
		} elsif ( $params->{'align'} && $params->{'aligner'} eq 'MUSCLE' && -e $temp_file && -s $temp_file ) {
			system( $self->{'config'}->{'muscle_path'}, -in => $temp_file, -out => $aligned_file, '-quiet' );
			$output_file = $aligned_file;
		} else {
			$output_file = $temp_file;
		}
		if ( -e $output_file ) {
			$no_output = 0;
			my $seq_in = Bio::SeqIO->new( -format => 'fasta', -file => $output_file );
			while ( my $seq = $seq_in->next_seq ) {
				my $length = $seq->length;
				$end = $start + $length - 1;
				print $fh '>' . $seq->id . ":$start-$end + $output_locus_name\n";
				my $sequence = BIGSdb::Utils::break_line( $seq->seq, 60 );
				( my $id = $seq->id ) =~ s/\|.*$//;
				$sequence =~ s/N/-/g if $no_seq{$id};
				say $fh $sequence;
			}
			$start = ( $end // 0 ) + 1;
			print $fh "=\n";
		}
		unlink $output_file;
		unlink $temp_file;
		$progress++;
		my $complete = int( 100 * $progress / scalar @$selected_loci );
		$self->{'jobManager'}->update_job_status( $job_id, { percent_complete => $complete } );
	}
	close $fh;
	if ( $self->{'exit'} ) {
		$self->{'jobManager'}->update_job_status( $job_id, { status => 'terminated' } );
		unlink $filename;
		return;
	}
	my $message_html;
	if (@problem_ids) {
		local $" = ', ';
		$message_html = "<p>The following ids could not be processed (they do not exist): @problem_ids.</p>\n";
	}
	if ($no_output) {
		$message_html .= "<p>No output generated.  Please ensure that your sequences have been defined for these isolates.</p>\n";
	} else {
		my $align_qualifier = ( $params->{'align'} || $params->{'translate'} ) ? '(aligned)' : '(not aligned)';
		$self->{'jobManager'}
		  ->update_job_output( $job_id, { filename => "$job_id.xmfa", description => "10_XMFA output file $align_qualifier" } );
		try {
			$self->{'jobManager'}->update_job_status( $job_id, { stage => "Converting XMFA to FASTA" } );
			my $fasta_file = BIGSdb::Utils::xmfa2fasta("$self->{'config'}->{'tmp_dir'}/$job_id\.xmfa");
			if ( -e $fasta_file ) {
				$self->{'jobManager'}
				  ->update_job_output( $job_id, { filename => "$job_id.fas", description => "20_Concatenated FASTA $align_qualifier" } );
			}
		}
		catch BIGSdb::CannotOpenFileException with {
			$logger->error("Can't create FASTA file from XMFA.");
		};
	}
	$self->{'jobManager'}->update_job_status( $job_id, { message_html => $message_html } ) if $message_html;
	return;
}

sub get_plugin_javascript {
	my ($self) = @_;
	my $buffer = << "END";
function enable_aligner(){
	if (\$("#align").prop("checked")){
		\$("#aligner").prop("disabled", false);
	} else {
		\$("#aligner").prop("disabled", true);
	}
}
	
\$(function () {
	enable_aligner();
	\$("#align").change(function(e) {
		enable_aligner();
	});
});
END
	return $buffer;
}
1;
