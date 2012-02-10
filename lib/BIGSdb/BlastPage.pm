#Written by Keith Jolley
#Copyright (c) 2010-2012, University of Oxford
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
package BIGSdb::BlastPage;
use strict;
use warnings;
use base qw(BIGSdb::Page);
use File::Path;
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');

sub run_blast {
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';

	#Options are locus, seq_ref, qry_type, num_results, alignment, cache, job
	#if parameter cache=1, the previously generated FASTA database will be used.
	#The calling function should clean up the temporary files.
	my $locus_info = $self->{'datastore'}->get_locus_info( $options->{'locus'} );
	my $already_generated = $options->{'job'} ? 1 : 0;
	$options->{'job'} = BIGSdb::Utils::get_random() if !$options->{'job'};
	my $temp_infile  = "$self->{'config'}->{'secure_tmp_dir'}/$options->{'job'}.txt";
	my $temp_outfile = "$self->{'config'}->{'secure_tmp_dir'}/$options->{'job'}\_outfile.txt";
	my $outfile_url  = "$options->{'job'}\_outfile.txt";

	#create fasta index
	my @runs;
	if ( $options->{'locus'} && $options->{'locus'} !~ /SCHEME_(\d+)/ ) {
		if ( $options->{'locus'} =~ /^((?:(?!\.\.).)*)$/ ) {    #untaint - check for directory traversal
			$options->{'locus'} = $1;
		}
		@runs = ( $options->{'locus'} );
	} else {
		@runs = qw (DNA peptide);
	}
	my @files_to_delete;
	foreach my $run (@runs) {
		( my $cleaned_run = $run ) =~ s/'/_prime_/g;
		my $temp_fastafile;
		if ( !$options->{'locus'} ) {

			#Create file and BLAST db of all sequences in a cache directory so can be reused.
			$temp_fastafile = "$self->{'config'}->{'secure_tmp_dir'}/$self->{'instance'}/$cleaned_run\_fastafile.txt";
			my $stale_flag_file = "$self->{'config'}->{'secure_tmp_dir'}/$self->{'instance'}/stale";
			if ( -e $temp_fastafile && !-e $stale_flag_file ) {
				$already_generated = 1;
			} else {
				eval {
					mkpath("$self->{'config'}->{'secure_tmp_dir'}/$self->{'instance'}");
					unlink $stale_flag_file;
				};
				$logger->error($@) if $@;
			}
		} else {
			$temp_fastafile = "$self->{'config'}->{'secure_tmp_dir'}/$options->{'job'}\_$cleaned_run\_fastafile.txt";
			push @files_to_delete, $temp_fastafile;
		}
		if ( !$already_generated ) {
			my ( $qry, $sql );
			if ( $options->{'locus'} && $options->{'locus'} !~ /SCHEME_(\d+)/ ) {
				$qry = "SELECT locus,allele_id,sequence from sequences WHERE locus=?";
			} else {
				if ( $options->{'locus'} =~ /SCHEME_(\d+)/ ) {
					my $scheme_id = $1;
					$qry =
"SELECT locus,allele_id,sequence FROM sequences WHERE locus IN (SELECT locus FROM scheme_members WHERE scheme_id=$scheme_id) AND locus IN (SELECT id FROM loci WHERE data_type=?)";
				} else {
					$qry = "SELECT locus,allele_id,sequence FROM sequences WHERE locus IN (SELECT id FROM loci WHERE data_type=?)";
				}
			}
			$sql = $self->{'db'}->prepare($qry);
			eval { $sql->execute($run) };
			$logger->error($@) if $@;
			open( my $fasta_fh, '>', $temp_fastafile );
			my $seqs_ref = $sql->fetchall_arrayref;
			foreach (@$seqs_ref) {
				my ( $returned_locus, $id, $seq ) = @$_;
				next if !length $seq;
				print $fasta_fh ( $options->{'locus'} && $options->{'locus'} !~ /SCHEME_(\d+)/ )
				  ? ">$id\n$seq\n"
				  : ">$returned_locus:$id\n$seq\n";
			}
			close $fasta_fh;
			if ( !-z $temp_fastafile ) {
				if ( $self->{'config'}->{'blast+_path'} ) {
					my $dbtype;
					if ( $options->{'locus'} && $options->{'locus'} !~ /SCHEME_(\d+)/ ) {
						$dbtype = $locus_info->{'data_type'} eq 'DNA' ? 'nucl' : 'prot';
					} else {
						$dbtype = $run eq 'DNA' ? 'nucl' : 'prot';
					}
					system(
"$self->{'config'}->{'blast+_path'}/makeblastdb -in $temp_fastafile -logfile /dev/null -parse_seqids -dbtype $dbtype"
					);
				} else {
					my $p;
					if ( $options->{'locus'} && $options->{'locus'} !~ /SCHEME_(\d+)/ ) {
						$p = $locus_info->{'data_type'} eq 'DNA' ? 'F' : 'T';
					} else {
						$p = $run eq 'DNA' ? 'F' : 'T';
					}
					system("$self->{'config'}->{'blast_path'}/formatdb -i $temp_fastafile -p $p -o T");
				}
			}
		}
		if ( !-z $temp_fastafile ) {

			#create query fasta file
			open( my $infile_fh, '>', $temp_infile );
			print $infile_fh ">Query\n";
			print $infile_fh "${$options->{'seq_ref'}}\n";
			close $infile_fh;
			my $program;
			if ( $options->{'locus'} && $options->{'locus'} !~ /SCHEME_(\d+)/ ) {
				if ( $options->{'qry_type'} eq 'DNA' ) {
					$program = $locus_info->{'data_type'} eq 'DNA' ? 'blastn' : 'blastx';
				} else {
					$program = $locus_info->{'data_type'} eq 'DNA' ? 'tblastn' : 'blastp';
				}
			} else {
				if ( $run eq 'DNA' ) {
					$program = $options->{'qry_type'} eq 'DNA' ? 'blastn' : 'tblastn';
				} else {
					$program = $options->{'qry_type'} eq 'DNA' ? 'blastx' : 'blastp';
				}
			}
			my $blast_threads = $self->{'config'}->{'blast_threads'} || 1;
			my $filter    = $program eq 'blastn' ? 'dust' : 'seg';
			my $word_size = $program eq 'blastn' ? 11     : 3;
			my ( $old_format, $format );
			if ( $options->{'alignment'} ) {
				$old_format = 2;
				$format     = 0;
			} else {
				$old_format = 9;
				$format     = 6;
			}
			if ( $self->{'config'}->{'blast+_path'} ) {
				system(
"$self->{'config'}->{'blast+_path'}/$program -num_threads $blast_threads -num_descriptions $options->{'num_results'} -num_alignments $options->{'num_results'} -parse_deflines -word_size $word_size -db $temp_fastafile -query $temp_infile -out $temp_outfile -outfmt $format -$filter no"
				);
			} else {
				system(
"$self->{'config'}->{'blast_path'}/blastall -v $options->{'num_results'} -b $options->{'num_results'} -p $program -d $temp_fastafile -i $temp_infile -o $temp_outfile -F F -m$old_format > /dev/null"
				);
			}
			if ( $run eq 'DNA' ) {
				system "mv $temp_outfile $temp_outfile\.1";
			}
		}
	}
	if ( !$options->{'locus'} || $options->{'locus'} =~ /SCHEME_(\d+)/ ) {
		my $outfile1 = "$temp_outfile\.1";
		BIGSdb::Utils::append( $outfile1, $temp_outfile ) if -e $outfile1;
		unlink $outfile1 if -e $outfile1;
	}

	#delete all working files
	local $" = ' ';
	system "rm -f $temp_infile @files_to_delete" if !$options->{'cache'};
	return ( $outfile_url, $options->{'job'} );
}

1;