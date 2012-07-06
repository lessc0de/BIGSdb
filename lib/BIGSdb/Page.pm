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
package BIGSdb::Page;
use strict;
use warnings;
use 5.010;
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');
use Error qw(:try);
use List::MoreUtils qw(uniq any none);
use autouse 'Data::Dumper' => qw(Dumper);
use parent 'Exporter';
use constant SEQ_METHODS => ( '454', 'Illumina', 'Ion Torrent', 'PacBio', 'Sanger', 'Solexa', 'SOLiD', 'other', 'unknown' );
use constant SEQ_FLAGS => (
	'ambiguous read',
	'apparent misassembly',
	'atypical',
	'downstream fusion',
	'frameshift',
	'internal stop codon',
	'no start codon',
	'phase variable: off',
	'truncated',
	'upstream fusion'
);
use constant ALLELE_FLAGS => (
	'atypical',
	'downstream fusion',
	'frameshift',
	'internal stop codon',
	'no start codon',
	'phase variable: off',
	'truncated',
	'upstream fusion'
);
use constant DATABANKS     => qw(Genbank);
use constant FLANKING      => qw(0 20 50 100 200 500 1000 2000 5000 10000 25000 50000);
use constant LOCUS_PATTERN => qr/^(?:l|cn|la)_(.+?)(?:\|\|.+)?$/;
our @EXPORT_OK = qw(SEQ_METHODS SEQ_FLAGS ALLELE_FLAGS DATABANKS FLANKING LOCUS_PATTERN);

sub new {    ## no critic
	my $class = shift;
	my $self  = {@_};
	$self->{'prefs'} = {};
	$logger->logdie("No CGI object passed")     if !$self->{'cgi'};
	$logger->logdie("No system hashref passed") if !$self->{'system'};
	$self->{'type'} = 'xhtml' if !$self->{'type'};
	bless( $self, $class );
	$self->initiate;
	$self->set_pref_requirements;
	return $self;
}

sub set_cookie_attributes {
	my ( $self, $cookies ) = @_;
	$self->{'cookies'} = $cookies;
	return;
}

sub initiate {
	my ($self) = @_;
	$self->{'jQuery'} = 1;    #Use JQuery javascript library
	return;
}

sub set_pref_requirements {
	my ($self) = @_;
	$self->{'pref_requirements'} = { 'general' => 1, 'main_display' => 1, 'isolate_display' => 1, 'analysis' => 1, 'query_field' => 1 };
	return;
}

sub get_javascript {

	#Override by returning javascript code to include in header
	return "";
}

sub get_guid {

	#If this is a non-public database, use a combination of database and user names as the
	#GUID for preference storage, otherwise use a random GUID which is stored as a browser cookie.
	my ($self) = @_;
	if ( $self->{'system'}->{'read_access'} ne 'public' ) {
		if ( !defined $self->{'username'} ) {

			#This can happen if a not logged in user tries to access a plugin.
			$logger->debug("No logged in user; Database $self->{'system'}->{'db'}");
			$self->{'username'} = '';
		}
		return "$self->{'system'}->{'db'}\|$self->{'username'}";
	} elsif ( $self->{'cgi'}->cookie( -name => 'guid' ) ) {
		return $self->{'cgi'}->cookie( -name => 'guid' );
	} else {
		return 0;
	}
}

sub print_banner {
	my ($self) = @_;
	my $bannerfile = "$self->{'dbase_config_dir'}/$self->{'instance'}/banner.html";
	if ( -e $bannerfile ) {
		print "<div class=\"box\" id=\"banner\">\n";
		$self->print_file($bannerfile);
		print "</div>\n";
	}
	return;
}

sub print_page_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	$" = ' ';    ##no critic #ensure reset when running under mod_perl
	if ( $q->param('page') && $q->param('page') eq 'plugin' ) {

		#need to determine if tooltips should be displayed since this is set in the <HEAD>;
		if ( $self->{'prefstore'} ) {
			my $guid = $self->get_guid;
			try {
				$self->{'prefs'}->{'tooltips'} =
				  $self->{'prefstore'}->get_tooltips_pref( $guid, $self->{'system'}->{'db'} ) eq 'on' ? 1 : 0;
			}
			catch BIGSdb::DatabaseNoRecordException with {
				$self->{'prefs'}->{'tooltips'} = 1;
			}
		}
	} else {
		$self->initiate_prefs;
	}
	if ( $self->{'type'} ne 'xhtml' ) {
		my %atts;
		if ( $self->{'type'} eq 'embl' ) {
			$atts{'type'} = 'chemical/x-embl-dl-nucleotide';
			my $id = $q->param('seqbin_id') || $q->param('isolate_id') || '';
			$atts{'attachment'} = "sequence$id.embl";
		} elsif ( $self->{'type'} eq 'no_header' ) {
			$atts{'type'} = 'text/html';
		} else {
			$atts{'type'} = 'text/plain';
		}
		$atts{'expires'} = '+1h' if !$self->{'noCache'};
		print $q->header( \%atts );
		$self->print_content;
	} else {
		my $stylesheet = $self->get_stylesheet();
		if ( !$q->cookie( -name => 'guid' ) && $self->{'prefstore'} ) {
			my $guid = $self->{'prefstore'}->get_new_guid;
			push @{ $self->{'cookies'} }, $q->cookie( -name => 'guid', -value => $guid, -expires => '+10y' );
			$self->{'setOptions'} = 1;
		}
		$q->charset('UTF-8');
		my %header_options = ( -cookie => $self->{'cookies'} );
		$header_options{'expires'} = '+1h' if !$self->{'noCache'};
		print $q->header(%header_options);
		my $title   = $self->get_title;
		my $page_js = $self->get_javascript;
		my @javascript;

		if ( $self->{'jQuery'} ) {
			if ( $self->{'config'}->{'intranet'} eq 'yes' ) {
				push @javascript, ( { 'language' => 'Javascript', 'src' => "/javascript/jquery.js" } );
			} else {

				#Load jQuery library from Google CDN
				push @javascript,
				  ( { 'language' => 'Javascript', 'src' => "http://ajax.googleapis.com/ajax/libs/jquery/1.6.1/jquery.min.js" } );
			}
			foreach (qw (jquery.tooltip.js cornerz.js bigsdb.js)) {
				push @javascript, ( { 'language' => 'Javascript', 'src' => "/javascript/$_" } );
			}
			if ( $self->{'jQuery.tablesort'} ) {
				push @javascript, ( { 'language' => 'Javascript', 'src' => "/javascript/jquery.tablesorter.js?v20110725" } );
				push @javascript, ( { 'language' => 'Javascript', 'src' => "/javascript/jquery.metadata.js" } );
			}
			if ( $self->{'jQuery.jstree'} ) {
				push @javascript, ( { 'language' => 'Javascript', 'src' => "/javascript/jquery.jstree.js?v20110605" } );
				push @javascript, ( { 'language' => 'Javascript', 'src' => "/javascript/jquery.cookie.js" } );
				push @javascript, ( { 'language' => 'Javascript', 'src' => "/javascript/jquery.hotkeys.js" } );
			}
			if ( $self->{'jQuery.coolfieldset'} ) {
				push @javascript, ( { 'language' => 'Javascript', 'src' => "/javascript/jquery.coolfieldset.js" } );
			}
			push @javascript, { 'language' => 'Javascript', 'code' => $page_js } if $page_js;
		}

		#META tag inclusion code written by Andreas Tille.
		my $meta_file = "$self->{'dbase_config_dir'}/$self->{'instance'}/meta.html";
		my %meta_content;
		my %shortcut_icon;
		if ( -e $meta_file ) {
			if ( open( my $fh, '<', $meta_file ) ) {
				while (<$fh>) {
					if ( $_ =~ /<meta\s+name="([^"]+)"\s+content="([^"]+)"\s*\/?>/ ) {
						$meta_content{$1} = $2;
					}
					if ( $_ =~ /<link\s+rel="shortcut icon"\s+href="([^"]+)"\s+type="([^"]+)"\s*\/?>/ ) {
						$shortcut_icon{'-rel'}  = 'shortcut icon';
						$shortcut_icon{'-href'} = $1;
						$shortcut_icon{'-type'} = $2;
					}
				}
				close $fh;
			}
		}
		my $http_equiv;
		if ( $self->{'refresh'} ) {
			$http_equiv = "<meta http-equiv=\"refresh\" content=\"$self->{'refresh'}\" />";
		}
		my $tooltip_display = $self->{'prefs'}->{'tooltips'} ? 'inline' : 'none';
		if (%shortcut_icon) {
			print $q->start_html(
				-title => $title,
				-meta  => {%meta_content},
				-style => { -src => $stylesheet, -code => ".tooltip{display:$tooltip_display}" },
				-head   => [ CGI->Link( {%shortcut_icon} ), $http_equiv ],
				-script => \@javascript
			);
		} else {
			print $q->start_html(
				-title  => $title,
				-meta   => {%meta_content},
				-style  => { -src => $stylesheet, -code => ".tooltip{display:$tooltip_display}" },
				-script => \@javascript,
				-head   => $http_equiv
			);
		}
		$self->_print_header;
		$self->_print_login_details
		  if ( defined $self->{'system'}->{'read_access'} && $self->{'system'}->{'read_access'} ne 'public' ) || $self->{'curate'};
		$self->_print_help_panel;
		$self->print_content;
		$self->_print_footer;
		$self->_debug if $q->param('debug') && $self->{'config'}->{'debug'};
		print $q->end_html;
	}
	return;
}

sub get_stylesheet {
	my ($self) = @_;
	my $stylesheet;
	my $system   = $self->{'system'};
	my $filename = 'bigsdb.css?v=20120412';
	if ( !$system->{'db'} ) {
		$stylesheet = "/$filename";
	} elsif ( -e "$ENV{'DOCUMENT_ROOT'}$system->{'webroot'}/$system->{'db'}/$filename" ) {
		$stylesheet = "$system->{'webroot'}/$system->{'db'}/$filename";
	} else {
		$stylesheet = "$system->{'webroot'}/$filename";
	}
	return $stylesheet;
}
sub get_title     { return 'BIGSdb' }
sub print_content { }

sub _debug {
	my ($self) = @_;
	print "<pre>\n" . Dumper($self) . "</pre>\n";
	return;
}

sub _print_header {
	my ($self) = @_;
	my $system = $self->{'system'};
	my $filename = $self->{'curate'} ? 'curate_header.html' : 'header.html';
	my $header_file = "$self->{'dbase_config_dir'}/$self->{'instance'}/$filename";
	$self->print_file($header_file) if ( -e $header_file );
	return;
}

sub _print_login_details {
	my ($self) = @_;
	return if !$self->{'datastore'};
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	print "<div id=\"logindetails\">";
	if ( !$user_info ) {
		if ( !$self->{'username'} ) {
			print "<i>Not logged in.</i>\n";
		} else {
			print "<i>Logged in: <b>Unregistered user.</b></i>\n";
		}
	} else {
		print "<i>Logged in: <b>$user_info->{'first_name'} $user_info->{'surname'} ($self->{'username'}).</b></i>\n";
	}
	if ( $self->{'system'}->{'authentication'} eq 'builtin' ) {
		if ( $self->{'username'} ) {
			print " <a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=logout\">Log out</a> | ";
			print " <a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=changePassword\">Change password</a>";
		}
	}
	print "</div>\n";
	return;
}

sub _print_help_panel {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	print "<div id=\"fieldvalueshelp\">";
	if ( $q->param('page') && $q->param('page') eq 'plugin' && defined $self->{'pluginManager'} ) {
		my $plugin_att = $self->{'pluginManager'}->get_plugin_attributes( $q->param('name') );
		if ( ref $plugin_att eq 'HASH' && defined $plugin_att->{'help'} && $plugin_att->{'help'} =~ /tooltips/ ) {
			$self->{'tooltips'} = 1;
		}
	}
	if ( $self->{'tooltips'} ) {
		print "<span id=\"toggle\" style=\"display:none\">Toggle: </span><a id=\"toggle_tooltips\" href=\""
		  . "$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=options&amp;toggle_tooltips=1\" style=\"display:none; "
		  . "margin-right:1em;\">&nbsp;<i>i</i>&nbsp;</a> ";
	}
	if ( ( $self->{'system'}->{'dbtype'} // '' ) eq 'isolates' && $self->{'field_help'} ) {

		#open new page unless already on field values help page
		print $q->param('page') eq 'fieldValues'
		  ? $q->start_form( -style => 'display:inline' )
		  : $q->start_form( -target => '_blank', -style => 'display:inline' );
		print "<b>Field help: </b>";
		my ( $values, $labels ) = $self->get_field_selection_list( { 'isolate_fields' => 1, 'loci' => 1, 'scheme_fields' => 1 } );
		print $q->popup_menu( -name => 'field', -values => $values, -labels => $labels );
		print $q->submit( -name => 'Go', -class => 'fieldvaluebutton' );
		my $refer_page = $q->param('page');
		$q->param( 'page', 'fieldValues' );
		print $q->hidden($_) foreach qw (db page);
		print $q->end_form;
		$q->param( 'page', $refer_page );
	}
	print "</div>\n";
	return;
}

sub get_extended_attributes {
	my ($self) = @_;
	my $extended;
	my $sql = $self->{'db'}->prepare("SELECT isolate_field,attribute FROM isolate_field_extended_attributes ORDER BY field_order");
	eval { $sql->execute };
	$logger->error($@) if $@;
	while ( my ( $field, $attribute ) = $sql->fetchrow_array ) {
		push @{ $extended->{$field} }, $attribute;
	}
	return $extended;
}

sub get_field_selection_list {

	#options passed as hashref:
	#isolate_fields: include isolate fields, prefix with f_
	#extended_attributes: include isolate field extended attributes, named e_FIELDNAME||EXTENDED-FIELDNAME
	#loci: include loci, prefix with either l_ or cn_ (common name)
	#query_pref: only the loci for which the user has a query field preference selected will be returned
	#analysis_pref: only the loci for which the user has an analysis preference selected will be returned
	#scheme_fields: include scheme fields, prefix with s_SCHEME-ID_
	#sort_labels: dictionary sort labels
	my ( $self, $options ) = @_;
	$logger->logdie("Invalid option hashref") if ref $options ne 'HASH';
	$options->{'query_pref'}    //= 1;
	$options->{'analysis_pref'} //= 0;
	my @values;
	if ( $options->{'isolate_fields'} ) {
		my $isolate_fields = $self->_get_provenance_fields($options);
		push @values, @$isolate_fields;
	}
	if ( $options->{'loci'} ) {
		if ( !$self->{'cache'}->{'loci'} ) {
			my @locus_list;
			my $qry    = "SELECT id,common_name FROM loci WHERE common_name IS NOT NULL";
			my $cn_sql = $self->{'db'}->prepare($qry);
			eval { $cn_sql->execute };
			$logger->error($@) if $@;
			my $common_names = $cn_sql->fetchall_hashref('id');
			my $set_id       = $self->get_set_id;
			my $loci         = $self->{'datastore'}->get_loci(
				{
					query_pref    => $options->{'query_pref'},
					analysis_pref => $options->{'analysis_pref'},
					seq_defined   => 0,
					do_not_order  => 1,
					set_id        => $set_id
				}
			);
			my $set_sql;

			if ($set_id) {
				$set_sql = $self->{'db'}->prepare("SELECT * FROM set_loci WHERE set_id=? AND locus=?");
			}
			foreach my $locus (@$loci) {
				push @locus_list, "l_$locus";
				$self->{'cache'}->{'labels'}->{"l_$locus"} = $locus;
				my $set_name_is_set;
				if ($set_id) {
					eval { $set_sql->execute( $set_id, $locus ) };
					$logger->error($@) if $@;
					my $set_locus = $set_sql->fetchrow_hashref;
					if ( $set_locus->{'set_name'} ) {
						$self->{'cache'}->{'labels'}->{"l_$locus"} = $set_locus->{'set_name'};
						if ( $set_locus->{'set_common_name'} ) {
							$self->{'cache'}->{'labels'}->{"l_$locus"} .= " ($set_locus->{'set_common_name'})";
							push @locus_list, "cn_$locus";
							$self->{'cache'}->{'labels'}->{"cn_$locus"} = "$set_locus->{'set_common_name'} ($set_locus->{'set_name'})";
						}
						$set_name_is_set = 1;
					}
				}
				if ( !$set_name_is_set && $common_names->{$locus}->{'common_name'} ) {
					$self->{'cache'}->{'labels'}->{"l_$locus"} .= " ($common_names->{$locus}->{'common_name'})";
					push @locus_list, "cn_$locus";
					$self->{'cache'}->{'labels'}->{"cn_$locus"} = "$common_names->{$locus}->{'common_name'} ($locus)";
				}
			}
			if ( $self->{'prefs'}->{'locus_alias'} ) {
				my $qry       = "SELECT locus,alias FROM locus_aliases";
				my $alias_sql = $self->{'db'}->prepare($qry);
				eval { $alias_sql->execute };
				if ($@) {
					$logger->error($@);
				} else {
					my $array_ref = $alias_sql->fetchall_arrayref;
					foreach (@$array_ref) {
						my ( $locus, $alias ) = @$_;

						#if there is no label for the primary name it is because the locus
						#should not be displayed
						next if !$self->{'cache'}->{'labels'}->{"l_$locus"};
						$alias =~ tr/_/ /;
						push @locus_list, "la_$locus||$alias";
						$self->{'cache'}->{'labels'}->{"la_$locus||$alias"} =
						  "$alias [" . ( $self->{'cache'}->{'labels'}->{"l_$locus"} ) . ']';
					}
				}
			}
			@locus_list = sort { lc( $self->{'cache'}->{'labels'}->{$a} ) cmp lc( $self->{'cache'}->{'labels'}->{$b} ) } @locus_list;
			@locus_list = uniq @locus_list;
			$self->{'cache'}->{'loci'} = \@locus_list;
		}
		push @values, @{ $self->{'cache'}->{'loci'} };
	}
	if ( $options->{'scheme_fields'} ) {
		my $scheme_fields = $self->_get_scheme_fields($options);
		push @values, @$scheme_fields;
	}
	if ( $options->{'sort_labels'} ) {

		#dictionary sort
		@values = map { $_->[0] }
		  sort { $a->[1] cmp $b->[1] }
		  map {
			my $d = lc( $self->{'cache'}->{'labels'}->{$_} );
			$d =~ s/[\W_]+//g;
			[ $_, $d ]
		  } uniq @values;
	}
	return \@values, $self->{'cache'}->{'labels'};
}

sub _get_provenance_fields {
	my ( $self, $options ) = @_;
	my @isolate_list;
	my $fields     = $self->{'xmlHandler'}->get_field_list;
	my $attributes = $self->{'xmlHandler'}->get_all_field_attributes;
	my $extended   = $options->{'extended_attributes'} ? $self->get_extended_attributes : undef;
	foreach (@$fields) {
		if (
			( $options->{'sender_attributes'} )
			&& (   $_ eq 'sender'
				|| $_ eq 'curator'
				|| ( $attributes->{$_}->{'userfield'} && $attributes->{$_}->{'userfield'} eq 'yes' ) )
		  )
		{
			foreach my $user_attribute (qw (id surname first_name affiliation)) {
				push @isolate_list, "f_$_ ($user_attribute)";
				( $self->{'cache'}->{'labels'}->{"f_$_ ($user_attribute)"} = "$_ ($user_attribute)" ) =~ tr/_/ /;
			}
		} else {
			push @isolate_list, "f_$_";
			( $self->{'cache'}->{'labels'}->{"f_$_"} = $_ ) =~ tr/_/ /;
			if ( $options->{'extended_attributes'} ) {
				my $extatt = $extended->{$_};
				if ( ref $extatt eq 'ARRAY' ) {
					foreach my $extended_attribute (@$extatt) {
						push @isolate_list, "e_$_||$extended_attribute";
						$self->{'cache'}->{'labels'}->{"e_$_||$extended_attribute"} = "$_..$extended_attribute";
					}
				}
			}
		}
	}
	return \@isolate_list;
}

sub _get_scheme_fields {
	my ( $self, $options ) = @_;
	if ( !$self->{'cache'}->{'scheme_fields'} ) {
		my @scheme_field_list;
		my $set_id        = $self->get_set_id;
		my $schemes       = $self->{'datastore'}->get_scheme_list( { set_id => $set_id } );
		my $scheme_fields = $self->{'datastore'}->get_all_scheme_fields;
		my $scheme_info   = $self->{'datastore'}->get_all_scheme_info;
		my $set_sql;
		if ($set_id) {
			$set_sql = $self->{'db'}->prepare("SELECT set_name FROM set_schemes WHERE set_id=? AND scheme_id=?");
		}
		foreach my $scheme (@$schemes) {
			my ( $scheme_id, $desc ) = ( $scheme->{'id'}, $scheme->{'description'} );
			my $scheme_db = $scheme_info->{$scheme_id}->{'dbase_name'};

			#No point using scheme fields if no scheme database is available.
			if ( $self->{'prefs'}->{'query_field_schemes'}->{$scheme_id} && $scheme_db ) {
				foreach my $field ( @{ $scheme_fields->{$scheme_id} } ) {
					if ( $self->{'prefs'}->{'query_field_scheme_fields'}->{$scheme_id}->{$field} ) {
						if ($set_id) {
							eval { $set_sql->execute( $set_id, $scheme_id ) };
							$logger->error($@) if $@;
							my ($set_name) = $set_sql->fetchrow_array;
							$desc = $set_name if defined $set_name;
						}
						( $self->{'cache'}->{'labels'}->{"s_$scheme_id\_$field"} = "$field ($desc)" ) =~ tr/_/ /;
						push @scheme_field_list, "s_$scheme_id\_$field";
					}
				}
			}
		}
		$self->{'cache'}->{'scheme_fields'} = \@scheme_field_list;
	}
	return $self->{'cache'}->{'scheme_fields'};
}

sub _print_footer {
	my ($self) = @_;
	my $system = $self->{'system'};
	my $filename = $self->{'curate'} ? 'curate_footer.html' : 'footer.html';
	my $footer_file = "$self->{'dbase_config_dir'}/$self->{'instance'}/$filename";
	$self->print_file($footer_file) if ( -e $footer_file );
	return;
}

sub print_file {
	my ( $self, $file, $ignore_hashlines ) = @_;
	my $lociAdd;
	my $loci;
	my $set_id = $self->get_set_id;
	if ( $self->{'curate'} && $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		if ( $self->is_admin ) {
			my $qry = "SELECT id FROM loci";
			if ($set_id) {
				$qry .= " WHERE id IN (SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT scheme_id FROM set_schemes WHERE "
				  . "set_id=$set_id)) OR id IN (SELECT locus FROM set_loci WHERE set_id=$set_id)";
			}
			$loci = $self->{'datastore'}->run_list_query($qry);
		} else {
			my $qry =
			    "SELECT locus_curators.locus from locus_curators LEFT JOIN loci ON locus=id LEFT JOIN scheme_members on "
			  . "loci.id = scheme_members.locus WHERE locus_curators.curator_id=? AND (id IN (SELECT locus FROM scheme_members "
			  . "WHERE scheme_id IN (SELECT scheme_id FROM set_schemes WHERE set_id=$set_id)) OR id IN (SELECT locus FROM set_loci "
			  . "WHERE set_id=$set_id)) ORDER BY scheme_members.scheme_id,locus_curators.locus";
			$loci = $self->{'datastore'}->run_list_query( $qry, $self->get_curator_id );
		}
		my $first = 1;
		foreach my $locus ( uniq @$loci ) {
			my $cleaned = $self->clean_locus($locus);
			$lociAdd .= ' | ' if !$first;
			$lociAdd .= "<a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=add&amp;"
			  . "table=sequences&amp;locus=$locus\">$cleaned</a>";
			$first = 0;
		}
	}
	if ( -e $file ) {
		my $system = $self->{'system'};
		open( my $fh, '<', $file ) or return;
		while (<$fh>) {
			next if /^#/ && $ignore_hashlines;
			s/\$instance/$self->{'instance'}/;
			s/\$webroot/$system->{'webroot'}/;
			s/\$dbase/$system->{'db'}/;
			s/\$indexpage/$system->{'indexpage'}/;
			if ( $self->{'curate'} && $self->{'system'}->{'dbtype'} eq 'sequences' ) {
				if ( @$loci && @$loci < 30 ) {
					s/\$lociAdd/$lociAdd/;
				} else {
s/\$lociAdd/<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=add&amp;table=sequences">Add<\/a>/;
				}
			}
			print;
		}
		close $fh;
	} else {
		$logger->warn("File $file does not exist.");
	}
	return;
}

sub get_filter {
	my ( $self, $name, $values, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $class = $options->{'class'} || 'filter';
	( my $text = $options->{'text'} || $name ) =~ tr/_/ /;
	my ( $label, $title ) = $self->_get_truncated_label("$text: ");
	my $title_attribute = $title ? "title=\"$title\"" : '';
	my $buffer = "<label for=\"$name\_list\" class=\"$class\" $title_attribute>$label</label>\n";
	unshift @$values, '' if !$options->{'noblank'};
	$buffer .=
	  $self->{'cgi'}
	  ->popup_menu( -name => "$name\_list", -id => "$name\_list", -values => $values, -labels => $options->{'labels'}, -class => $class );
	$options->{'tooltip'} =~ tr/_/ / if $options->{'tooltip'};
	$buffer .= " <a class=\"tooltip\" title=\"$options->{'tooltip'}\">&nbsp;<i>i</i>&nbsp;</a>" if $options->{'tooltip'};
	return $buffer;
}

sub get_user_filter {
	my ( $self, $field, $table ) = @_;
	my $qry = "SELECT DISTINCT($field) FROM $table WHERE $field > 0";
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute };
	$logger->error($@) if $@;
	my @userids;
	while ( my ($value) = $sql->fetchrow_array ) {
		push @userids, $value;
	}
	$qry = "SELECT id,first_name,surname FROM users where id=?";
	$sql = $self->{'db'}->prepare($qry);
	my ( @usernames, %labels );
	foreach (@userids) {
		eval { $sql->execute($_) };
		$logger->error($@) if $@;
		while ( my @data = $sql->fetchrow_array ) {
			push @usernames, $data[0];
			$labels{ $data[0] } = $data[2] eq 'applicable' ? 'not applicable' : "$data[2], $data[1]";
		}
	}
	@usernames =
	  sort { lc( $labels{$a} ) cmp lc( $labels{$b} ) } @usernames;
	my $a_or_an = substr( $field, 0, 1 ) =~ /[aeiouAEIOU]/ ? 'an' : 'a';
	return $self->get_filter(
		$field,
		\@usernames,
		{
			'labels' => \%labels,
			'tooltip' =>
			  "$field filter - Select $a_or_an $field to filter your search to only those records that match the selected $field."
		}
	);
}

sub get_number_records_control {
	my ($self) = @_;
	if ( $self->{'cgi'}->param('displayrecs') ) {
		$self->{'prefs'}->{'displayrecs'} = $self->{'cgi'}->param('displayrecs');
	}
	my $buffer = "<span style=\"white-space:nowrap\"><label for=\"displayrecs\" class=\"display\">Display: </label>\n"
	  . $self->{'cgi'}->popup_menu(
		-name   => 'displayrecs',
		-id     => 'displayrecs',
		-values => [ '10', '25', '50', '100', '200', '500', 'all' ],
		-default => $self->{'cgi'}->param('displayrecs') || $self->{'prefs'}->{'displayrecs'}
	  )
	  . " records per page <a class=\"tooltip\" title=\"Records per page - Analyses use the full query dataset, rather "
	  . "than just the page shown.\">&nbsp;<i>i</i>&nbsp;</a>&nbsp;&nbsp;</span>";
	return $buffer;
}

sub get_scheme_filter {
	my ($self) = @_;
	if ( !$self->{'cache'}->{'schemes'} ) {
		my $set_id = $self->get_set_id;
		my $list = $self->{'datastore'}->get_scheme_list( { set_id => $set_id } );
		foreach my $scheme (@$list) {
			push @{ $self->{'cache'}->{'schemes'} }, $scheme->{'id'};
			$self->{'cache'}->{'scheme_labels'}->{ $scheme->{'id'} } = $scheme->{'description'};
		}
		push @{ $self->{'cache'}->{'schemes'} }, 0;
		$self->{'cache'}->{'scheme_labels'}->{0} = 'No scheme';
	}
	my $buffer = $self->get_filter(
		'scheme_id',
		$self->{'cache'}->{'schemes'},
		{
			text    => 'scheme',
			labels  => $self->{'cache'}->{'scheme_labels'},
			tooltip => 'scheme filter - Select a scheme to filter your search to only those belonging to the selected scheme.'
		}
	);
	return $buffer;
}

sub get_locus_filter {
	my ($self) = @_;
	my $set_id = $self->get_set_id;
	my ( $loci, $labels ) = $self->{'datastore'}->get_locus_list( { set_id => $set_id, no_list_by_common_name => 1 } );
	my $buffer =
	  $self->get_filter( 'locus', $loci, { labels => $labels, tooltip => 'locus filter - Select a locus to filter your search by.' } );
	return $buffer;
}

sub get_project_filter {
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $sql = $self->{'db'}->prepare("SELECT id, short_description FROM projects ORDER BY UPPER(short_description)");
	eval { $sql->execute };
	$logger->error($@) if $@;
	my ( @project_ids, %labels );
	while ( my ( $id, $desc ) = $sql->fetchrow_array ) {
		push @project_ids, $id;
		$labels{$id} = $desc;
	}
	if ( @project_ids && $options->{'any'} ) {
		unshift @project_ids, 'not belonging to any project';
		unshift @project_ids, 'belonging to any project';
	}
	if (@project_ids) {
		my $class = $options->{'class'} || 'filter';
		return $self->get_filter(
			'project',
			\@project_ids,
			{
				'labels'  => \%labels,
				'text'    => 'Project',
				'tooltip' => 'project filter - Select a project to filter your query to only those isolates belonging to it.',
				'class'   => $class
			}
		);
	}
}

sub get_experiment_filter {
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $experiment_list = $self->{'datastore'}->run_list_query_hashref("SELECT id,description FROM experiments ORDER BY description");
	my @experiments;
	my %labels;
	foreach (@$experiment_list) {
		push @experiments, $_->{'id'};
		$labels{ $_->{'id'} } = $_->{'description'};
	}
	if (@experiments) {
		my $class = $options->{'class'} || 'filter';
		return $self->get_filter(
			'experiment',
			\@experiments,
			{
				'labels'  => \%labels,
				'text'    => 'Experiment',
				'tooltip' => 'experiments filter - Only include sequences that have been linked to the specified experiment.',
				'class'   => $class
			}
		);
	}
}

sub get_sequence_method_filter {
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $class = $options->{'class'} || 'filter';
	return $self->get_filter(
		'seq_method',
		[SEQ_METHODS],
		{
			'text'    => 'Sequence method',
			'tooltip' => 'sequence method filter - Only include sequences generated from the selected method.',
			'class'   => $class
		}
	);
}

sub _get_truncated_label {
	my ( $self, $label ) = @_;
	my $title;
	if ( length $label > 25 ) {
		$title = $label;
		$title =~ tr/\"//;
		$label = substr( $label, 0, 20 ) . "&#133";
	}
	return ( $label, $title );
}

sub clean_locus {
	my ( $self, $locus, $options ) = @_;
	return if !defined $locus;
	$options = {} if ref $options ne 'HASH';
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	my $set_id     = $self->get_set_id;
	if ($set_id) {
		my $set_locus =
		  $self->{'datastore'}->run_simple_query_hashref( "SELECT * FROM set_loci WHERE set_id=? AND locus=?", $set_id, $locus );
		if ( $set_locus->{'set_name'} ) {
			$locus = $set_locus->{'set_name'};
			$locus .= " ($set_locus->{'set_common_name'})" if $set_locus->{'set_common_name'} && !$options->{'no_common_name'};
		}
	} else {
		$locus =~ s/^_//;    #locus names can't begin with a digit, so people can use an underscore, but this looks untidy in the interface.
		$locus .= " ($locus_info->{'common_name'})" if $locus_info->{'common_name'} && !$options->{'no_common_name'};
	}
	if ( !$options->{'text_output'} && ( $self->{'system'}->{'locus_superscript_prefix'} // '' ) eq 'yes' ) {
		$locus =~ s/^([A-Za-z]{1,3})_/<sup>$1<\/sup>/;
	}
	return $locus;
}

sub get_set_id {
	my ($self) = @_;
	if ( ( $self->{'system'}->{'sets'} // '' ) eq 'yes' ) {
		my $set_id = $self->{'system'}->{'set_id'} // $self->{'cgi'}->param('set_id');
		return $set_id if $set_id && BIGSdb::Utils::is_int($set_id);
	}
	return;
}

sub extract_scheme_desc {
	my ( $self, $scheme_data ) = @_;
	my ( @scheme_ids, %desc );
	foreach (@$scheme_data) {
		push @scheme_ids, $_->{'id'};
		$desc{ $_->{'id'} } = $_->{'description'};
	}
	return ( \@scheme_ids, \%desc );
}

sub get_db_description {
	my ($self) = @_;
	my $desc;
	my $set_id = $self->get_set_id;
	if ($set_id) {
		my $desc_ref = $self->{'datastore'}->run_simple_query( "SELECT description FROM sets WHERE id=?", $set_id );
		$desc = $desc_ref->[0] if ref $desc_ref eq 'ARRAY';
	}
	$desc = $self->{'system'}->{'description'} if !defined $desc;
	$desc =~ s/\&/\&amp;/g;
	return $desc;
}

sub get_link_button_to_ref {
	my ( $self, $ref ) = @_;
	my $buffer;
	if ( !$self->{'sql'}->{'link_ref'} ) {
		my $qry =
"SELECT COUNT(refs.isolate_id) FROM $self->{'system'}->{'view'} LEFT JOIN refs on refs.isolate_id=$self->{'system'}->{'view'}.id WHERE pubmed_id=?";
		$self->{'sql'}->{'link_ref'} = $self->{'db'}->prepare($qry);
	}
	eval { $self->{'sql'}->{'link_ref'}->execute($ref) };
	$logger->error($@) if $@;
	my ($count) = $self->{'sql'}->{'link_ref'}->fetchrow_array;
	my $plural = $count == 1 ? '' : 's';
	$buffer .= "$count isolate$plural";
	my $q = $self->{'cgi'};
	$buffer .= $q->start_form;
	$q->param( 'curate', 1 ) if $self->{'curate'};
	$q->param( 'query',
"SELECT * FROM $self->{'system'}->{'view'} LEFT JOIN refs on refs.isolate_id=$self->{'system'}->{'view'}.id WHERE pubmed_id='$ref' ORDER BY $self->{'system'}->{'view'}.id;"
	);
	$q->param( 'pmid', $ref );
	$q->param( 'page', 'pubquery' );
	$buffer .= $q->hidden($_) foreach qw(db page query curate pmid);
	$buffer .= $q->submit( -value => 'Display', -class => 'submit' );
	$buffer .= $q->end_form;
	$q->param( 'page', 'info' );
	return $buffer;
}

sub get_isolate_name_from_id {
	my ( $self, $isolate_id ) = @_;
	if ( !$self->{'sql'}->{'isolate_id'} ) {
		$self->{'sql'}->{'isolate_id'} =
		  $self->{'db'}
		  ->prepare("SELECT $self->{'system'}->{'view'}.$self->{'system'}->{'labelfield'} FROM $self->{'system'}->{'view'} WHERE id=?");
	}
	eval { $self->{'sql'}->{'isolate_id'}->execute($isolate_id) };
	$logger->error($@) if $@;
	my ($isolate) = $self->{'sql'}->{'isolate_id'}->fetchrow_array;
	return $isolate;
}

sub get_isolate_id_and_name_from_seqbin_id {
	my ( $self, $seqbin_id ) = @_;
	if ( !$self->{'sql'}->{'isolate_id_as'} ) {
		$self->{'sql'}->{'isolate_id_as'} =
		  $self->{'db'}->prepare(
"SELECT $self->{'system'}->{'view'}.id,$self->{'system'}->{'view'}.$self->{'system'}->{'labelfield'} FROM $self->{'system'}->{'view'} LEFT JOIN sequence_bin ON $self->{'system'}->{'view'}.id = isolate_id WHERE sequence_bin.id=?"
		  );
	}
	eval { $self->{'sql'}->{'isolate_id_as'}->execute($seqbin_id) };
	$logger->error($@) if $@;
	my ( $isolate_id, $isolate ) = $self->{'sql'}->{'isolate_id_as'}->fetchrow_array;
	return ( $isolate_id, $isolate );
}

sub get_record_name {
	my ( $self, $table ) = @_;
	$table ||= '';
	my %names = (
		'users'                             => 'user',
		'user_groups'                       => 'user group',
		'user_group_members'                => 'user group member',
		'loci'                              => 'locus',
		'refs'                              => 'PubMed link',
		'allele_designations'               => 'allele designation',
		'pending_allele_designations'       => 'pending allele designation',
		'scheme_members'                    => 'scheme member',
		'schemes'                           => 'scheme',
		'scheme_fields'                     => 'scheme field',
		'composite_fields'                  => 'composite field',
		'composite_field_values'            => 'composite field value',
		'isolates'                          => 'isolate',
		'sequences'                         => 'allele sequence',
		'accession'                         => 'accession number',
		'sequence_refs'                     => 'PubMed link',
		'profiles'                          => 'profile',
		'sequence_bin'                      => 'sequence (contig)',
		'allele_sequences'                  => 'allele sequence tag',
		'isolate_aliases'                   => 'isolate alias',
		'locus_aliases'                     => 'locus alias',
		'user_permissions'                  => 'user permission record',
		'isolate_user_acl'                  => 'isolate access control record',
		'isolate_usergroup_acl'             => 'isolate group access control record',
		'client_dbases'                     => 'client database',
		'client_dbase_loci'                 => 'locus to client database definition',
		'client_dbase_schemes'              => 'scheme to client database definition',
		'locus_extended_attributes'         => 'locus extended attribute',
		'projects'                          => 'project description',
		'project_members'                   => 'project member',
		'profile_refs'                      => 'Pubmed link',
		'samples'                           => 'sample storage record',
		'scheme_curators'                   => 'scheme curator access record',
		'locus_curators'                    => 'locus curator access record',
		'experiments'                       => 'experiment',
		'experiment_sequences'              => 'experiment sequence link',
		'isolate_field_extended_attributes' => 'isolate field extended attribute',
		'isolate_value_extended_attributes' => 'isolate field extended attribute value',
		'locus_descriptions'                => 'locus description',
		'scheme_groups'                     => 'scheme group',
		'scheme_group_scheme_members'       => 'scheme group scheme member',
		'scheme_group_group_members'        => 'scheme group group member',
		'pcr'                               => 'PCR reaction',
		'pcr_locus'                         => 'PCR locus link',
		'probes'                            => 'nucleotide probe',
		'probe_locus'                       => 'probe locus link',
		'client_dbase_loci_fields'          => 'locus to client database isolate field definition',
		'sets'                              => 'set',
		'set_loci'                          => 'set member locus',
		'set_schemes'                       => 'set member schemes'
	);
	return $names{$table};
}

sub rewrite_query_ref_order_by {
	my ( $self, $qry_ref ) = @_;
	my $view = $self->{'system'}->{'view'};
	if ( $$qry_ref =~ /ORDER BY (s_\d+_\S+)\s/ ) {
		my $scheme_id   = $1;
		my $scheme_join = $self->_create_join_sql_for_scheme($scheme_id);
		$$qry_ref =~ s/(SELECT \.* FROM $view)/$1 $scheme_join/;
		$$qry_ref =~ s/FROM $view/FROM $view $scheme_join/;
		$$qry_ref =~ s/ORDER BY s_(\d+)_/ORDER BY ordering\./;
	} elsif ( $$qry_ref =~ /ORDER BY l_(\S+)\s/ ) {
		my $locus      = $1;
		my $locus_join = $self->_create_join_sql_for_locus($locus);
		( my $cleaned_locus = $locus ) =~ s/'/\\'/g;
		$$qry_ref =~ s/(SELECT .* FROM $view)/$1 $locus_join/;
		$$qry_ref =~
s/FROM $view/FROM $view LEFT JOIN allele_designations AS ordering ON ordering.isolate_id=$view.id AND ordering.locus=E'$cleaned_locus'/;
		my $locus_info = $self->{'datastore'}->get_locus_info($locus);
		if ( $locus_info->{'allele_id_format'} eq 'integer' ) {
			$$qry_ref =~ s/ORDER BY l_\S+\s/ORDER BY CAST(ordering.allele_id AS int) /;
		} else {
			$$qry_ref =~ s/ORDER BY l_\S+\s/ORDER BY ordering.allele_id /;
		}
	} elsif ( $$qry_ref =~ /ORDER BY f_/ ) {
		$$qry_ref =~ s/ORDER BY f_/ORDER BY $view\./;
	}
	return;
}

sub is_allowed_to_view_isolate {
	my ( $self, $isolate_id ) = @_;
	my $allowed_to_view =
	  $self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM $self->{'system'}->{'view'} WHERE id=?", $isolate_id )->[0];
	return $allowed_to_view;
}

sub _create_join_sql_for_scheme {
	my ( $self, $field ) = @_;
	my $qry;
	if ( $field =~ /s_(\d+)_([^\s;]*)/ ) {
		my $scheme_id    = $1;
		my $scheme_field = $2;
		my $loci         = $self->{'datastore'}->get_scheme_loci($scheme_id);
		foreach (@$loci) {
			$qry .= " LEFT JOIN allele_designations AS l_$_ ON l_$_\.isolate_id=$self->{'system'}->{'view'}.id AND l_$_.locus=E'$_'";
		}
		$qry .= " LEFT JOIN temp_scheme_$scheme_id AS ordering ON";
		my $first = 1;
		foreach (@$loci) {
			my $locus_info = $self->{'datastore'}->get_locus_info($_);
			$qry .= " AND" if !$first;
			if ( $locus_info->{'allele_id_format'} eq 'integer' ) {
				$qry .= " CAST(l_$_.allele_id AS integer)=ordering.$_";
			} else {
				$qry .= " l_$_.allele_id=ordering.$_";
			}
			$first = 0;
		}
	}
	return $qry;
}

sub _create_join_sql_for_locus {
	my ( $self, $locus ) = @_;
	( my $clean_locus_name = $locus ) =~ s/'/_PRIME_/g;
	$clean_locus_name =~ s/-/_/g;
	( my $escaped_locus = $locus ) =~ s/'/\\'/g;
	my $qry =
" LEFT JOIN allele_designations AS l_$clean_locus_name ON l_$clean_locus_name\.isolate_id=$self->{'system'}->{'view'}.id AND l_$clean_locus_name.locus=E'$escaped_locus'";
	return $qry;
}

sub get_update_details_tooltip {
	my ( $self, $locus, $allele_ref ) = @_;
	my $buffer;
	my $sender  = $self->{'datastore'}->get_user_info( $allele_ref->{'sender'} );
	my $curator = $self->{'datastore'}->get_user_info( $allele_ref->{'curator'} );
	$buffer = "$locus:$allele_ref->{'allele_id'} - ";
	$buffer .= "sender: $sender->{'first_name'} $sender->{'surname'}<br />";
	$buffer .= "status: $allele_ref->{'status'}<br />" if $allele_ref->{'status'};
	$buffer .= "method: $allele_ref->{'method'}<br />";
	$buffer .= "curator: $curator->{'first_name'} $curator->{'surname'}<br />";
	$buffer .= "first entered: $allele_ref->{'date_entered'}<br />";
	$buffer .= "last updated: $allele_ref->{'datestamp'}<br />";
	$buffer .= "comments: $allele_ref->{'comments'}<br />"
	  if $allele_ref->{'comments'};
	return $buffer;
}

sub _get_seq_detail_tooltip_text {
	my ( $self, $locus, $allele_ref, $alleleseq_ref, $flags_ref ) = @_;
	my $buffer = defined $allele_ref->{'allele_id'} ? "$locus:$allele_ref->{'allele_id'} - " : "$locus - ";
	my $i = 0;
	local $" = '; ';
	foreach (@$alleleseq_ref) {
		$buffer .= '<br />'      if $i;
		$buffer .= "Seqbin id:$_->{'seqbin_id'}: $_->{'start_pos'} &rarr; $_->{'end_pos'}";
		$buffer .= " (reverse)"  if $_->{'reverse'};
		$buffer .= " incomplete" if !$_->{'complete'};
		if ( ref $flags_ref->[$i] eq 'ARRAY' ) {
			my @flags = sort @{ $flags_ref->[$i] };
			$buffer .= "<br />@flags" if @flags;
		}
		$i++;
	}
	return $buffer;
}

sub get_seq_detail_tooltips {
	my ( $self, $isolate_id, $locus ) = @_;
	my $buffer          = '';
	my $alleleseq_ref   = $self->{'datastore'}->get_allele_sequence( $isolate_id, $locus );      #ref to array of hashrefs
	my $designation_ref = $self->{'datastore'}->get_allele_designation( $isolate_id, $locus );
	my $locus_info      = $self->{'datastore'}->get_locus_info($locus);
	my $designation_flags;
	my ( @all_flags, %flag_from_designation, %flag_from_alleleseq );
	if ( $locus_info->{'flag_table'} && defined $designation_ref->{'allele_id'} ) {
		$designation_flags = $self->{'datastore'}->get_locus($locus)->get_flags( $designation_ref->{'allele_id'} );
		push @all_flags, @$designation_flags;
		$flag_from_designation{$_} = 1 foreach @$designation_flags;
	}
	my ( @seqs, @flags_foreach_alleleseq, $complete );
	if (@$alleleseq_ref) {
		foreach my $alleleseq (@$alleleseq_ref) {
			my $flaglist_ref =
			  $self->{'datastore'}
			  ->get_sequence_flag( $alleleseq->{'seqbin_id'}, $alleleseq->{'locus'}, $alleleseq->{'start_pos'}, $alleleseq->{'end_pos'} );
			push @flags_foreach_alleleseq, $flaglist_ref;
			push @all_flags,               @$flaglist_ref;
			$flag_from_alleleseq{$_} = 1 foreach @$flaglist_ref;
			$complete = 1 if $alleleseq->{'complete'};
		}
	}
	@all_flags = uniq sort @all_flags;
	my $cleaned_locus = $self->clean_locus($locus);
	my $sequence_tooltip =
	  $self->_get_seq_detail_tooltip_text( $cleaned_locus, $designation_ref, $alleleseq_ref, \@flags_foreach_alleleseq );
	if (@$alleleseq_ref) {
		my $sequence_class = $complete ? 'sequence_tooltip' : 'sequence_tooltip_incomplete';
		$buffer .=
"<span style=\"font-size:0.2em\"> </span><a class=\"$sequence_class\" title=\"$sequence_tooltip\" href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=alleleSequence&amp;id=$isolate_id&amp;locus=$locus\">&nbsp;S&nbsp;</a>";
	}
	if (@all_flags) {
		my $text = "Flags - ";
		foreach my $flag (@all_flags) {
			$text .= "$flag";
			if ( $flag_from_designation{$flag} && !$flag_from_alleleseq{$flag} ) {
				$text .= " (allele designation)<br />";
			} elsif ( !$flag_from_designation{$flag} && $flag_from_alleleseq{$flag} ) {
				$text .= " (sequence tag)<br />";
			} else {
				$text .= " (designation + tag)<br />";
			}
		}
		local $" = "</a> <a class=\"seqflag_tooltip\" title=\"$text\">";
		$buffer .= "<a class=\"seqflag_tooltip\" title=\"$text\">@all_flags</a>";
	}
	return $buffer;
}

sub make_temp_file {
	my ( $self, @list ) = @_;
	my ( $filename, $full_file_path );
	do {
		$filename       = BIGSdb::Utils::get_random() . '.txt';
		$full_file_path = "$self->{'config'}->{'secure_tmp_dir'}/$filename";
	} until ( !-e $full_file_path );
	open( my $fh, '>', $full_file_path );
	local $" = "\n";
	print $fh "@list";
	close $fh;
	return $filename;
}

sub mark_cache_stale {

	#Mark all cache subdirectories as stale (each locus set will use a different directory)
	my ($self) = @_;
	my $dir = "$self->{'config'}->{'secure_tmp_dir'}/$self->{'system'}->{'db'}";
	if ( -d $dir ) {
		foreach my $subdir ( glob "$dir/*" ) {
			next if !-d $subdir;    #skip if not a dirctory
			if ( $subdir =~ /\/(all|\d+)$/ ) {
				$subdir = $1;
				my $stale_flag_file = "$dir/$subdir/stale";
				open( my $fh, '>', $stale_flag_file ) || $logger->error("Can't mark BLAST db stale.");
				close $fh;
			}
		}
	}
	return;
}

sub is_admin {
	my ($self) = @_;
	if ( $self->{'username'} ) {
		my $qry = "SELECT status FROM users WHERE user_name=?";
		my $status = $self->{'datastore'}->run_simple_query( $qry, $self->{'username'} );
		return 0 if ref $status ne 'ARRAY';
		return 1 if $status->[0] eq 'admin';
	}
	return 0;
}

sub can_modify_table {
	my ( $self, $table ) = @_;
	my $scheme_id = $self->{'cgi'}->param('scheme_id');
	my $locus     = $self->{'cgi'}->param('locus');
	return 1 if $self->is_admin;
	if ( $table eq 'users' && $self->{'permissions'}->{'modify_users'} ) {
		return 1;
	} elsif ( ( $table eq 'user_groups' || $table eq 'user_group_members' ) && $self->{'permissions'}->{'modify_usergroups'} ) {
		return 1;
	} elsif (
		$self->{'system'}->{'dbtype'} eq 'isolates' && (
			any {
				$table eq $_;
			}
			qw(isolates isolate_aliases refs)
		)
		&& $self->{'permissions'}->{'modify_isolates'}
	  )
	{
		return 1;
	} elsif ( ( $table eq 'isolate_user_acl' || $table eq 'isolate_usergroup_acl' ) && $self->{'permissions'}->{'modify_isolates_acl'} ) {
		return 1;
	} elsif ( ( $table eq 'allele_designations' || $table eq 'pending_allele_designations' )
		&& $self->{'permissions'}->{'designate_alleles'} )
	{
		return 1;
	} elsif (
		(
			$self->{'system'}->{'dbtype'} eq 'isolates' && (
				any {
					$table eq $_;
				}
				qw (sequence_bin accession experiments experiment_sequences )
			)
		)
		&& $self->{'permissions'}->{'modify_sequences'}
	  )
	{
		return 1;
	} elsif ( $self->{'system'}->{'dbtype'} eq 'sequences' && ( $table eq 'sequences' || $table eq 'locus_descriptions' ) ) {
		if ( !$locus ) {
			return 1;
		} else {
			return $self->{'datastore'}->is_allowed_to_modify_locus_sequences( $locus, $self->get_curator_id );
		}
	} elsif ( $table eq 'allele_sequences' && $self->{'permissions'}->{'tag_sequences'} ) {
		return 1;
	} elsif ( $table eq 'profile_refs' ) {
		my $allowed =
		  $self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM scheme_curators WHERE curator_id=?", $self->get_curator_id )->[0];
		return $allowed;
	} elsif ( ( $table eq 'profiles' || $table eq 'profile_fields' || $table eq 'profile_members' ) ) {
		return 0 if !$scheme_id;
		my $allowed =
		  $self->{'datastore'}
		  ->run_simple_query( "SELECT COUNT(*) FROM scheme_curators WHERE scheme_id=? AND curator_id=?", $scheme_id, $self->get_curator_id )
		  ->[0];
		return $allowed;
	} elsif (
		(
			any {
				$table eq $_;
			}
			qw (loci locus_aliases client_dbases client_dbase_loci client_dbase_schemes locus_client_display_fields
			locus_extended_attributes locus_curators)
		)
		&& $self->{'permissions'}->{'modify_loci'}
	  )
	{
		return 1;
	} elsif ( ( $table eq 'composite_fields' || $table eq 'composite_field_values' ) && $self->{'permissions'}->{'modify_composites'} ) {
		return 1;
	} elsif ( ( $table eq 'schemes' || $table eq 'scheme_members' || $table eq 'scheme_fields' || $table eq 'scheme_curators' )
		&& $self->{'permissions'}->{'modify_schemes'} )
	{
		return 1;
	} elsif ( ( $table eq 'projects' || $table eq 'project_members' ) && $self->{'permissions'}->{'modify_projects'} ) {
		return 1;
	} elsif ( $table eq 'samples' && $self->{'permissions'}->{'sample_management'} && @{ $self->{'xmlHandler'}->get_sample_field_list } ) {
		return 1;
	} elsif ( $self->{'system'}->{'dbtype'} eq 'sequences' && ( $table eq 'sequence_refs' || $table eq 'accession' ) ) {
		my $allowed =
		  $self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM locus_curators WHERE curator_id=?", $self->get_curator_id )->[0];
		return $allowed;
	} elsif ( $table eq 'isolate_field_extended_attributes' && $self->{'permissions'}->{'modify_field_attributes'} ) {
		return 1;
	} elsif ( $table eq 'isolate_value_extended_attributes' && $self->{'permissions'}->{'modify_value_attributes'} ) {
		return 1;
	} elsif (
		(
			any {
				$table eq $_;
			}
			qw (pcr pcr_locus probes probe_locus)
		)
		&& $self->{'permissions'}->{'modify_probes'}
	  )
	{
		return 1;
	}
	return 0;
}

sub print_warning_sign {
	my ($self) = @_;
	my $image = "$ENV{'DOCUMENT_ROOT'}$self->{'system'}->{'webroot'}/images/warning_sign.gif";
	if ( -e $image ) {
		print
"<div style=\"text-align:center\"><img src=\"$self->{'system'}->{'webroot'}/images/warning_sign.gif\" alt=\"Warning!\" /></div>\n";
	} else {
		my $image = "$ENV{'DOCUMENT_ROOT'}/images/warning_sign.gif";
		if ( -e $image ) {
			print "<div style=\"text-align:center\"><img src=\"/images/warning_sign.gif\" alt=\"Access Denied!\" /></div>\n";
		}
	}
	return;
}

sub get_curator_id {
	my ($self) = @_;
	if ( $self->{'username'} ) {
		my $qry = "SELECT id,status FROM users WHERE user_name=?";
		my $values = $self->{'datastore'}->run_simple_query( $qry, $self->{'username'} );
		return 0 if ref $values ne 'ARRAY';
		if (   $values->[1]
			&& $values->[1] ne 'curator'
			&& $values->[1] ne 'admin' )
		{
			return 0;
		}
		return $values->[0];
	} else {
		return 0;
	}
}

sub initiate_prefs {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	return if !$self->{'prefstore'};
	my ( $general_prefs, $field_prefs, $scheme_field_prefs );
	if (   $q->param('page')
		&& $q->param('page') eq 'options'
		&& $q->param('set') )
	{
		foreach (qw(displayrecs pagebar alignwidth flanking)) {
			$self->{'prefs'}->{$_} = $q->param($_);
		}

		#Switches
		foreach (qw (hyperlink_loci tooltips)) {
			$self->{'prefs'}->{$_} = ( $q->param($_) && $q->param($_) eq 'on' ) ? 1 : 0;
		}
	} else {
		return if !$self->{'pref_requirements'}->{'general'} && !$self->{'pref_requirements'}->{'query_field'};
		my $guid = $self->get_guid || 1;
		try {
			$self->{'prefstore'}->update_datestamp($guid);
		}
		catch BIGSdb::PrefstoreConfigurationException with {
			undef $self->{'prefstore'};
			$self->{'fatal'} = 'prefstoreConfig';
		};
		return if !$self->{'prefstore'};
		my $dbname = $self->{'system'}->{'db'};
		$field_prefs = $self->{'prefstore'}->get_all_field_prefs( $guid, $dbname );
		$scheme_field_prefs = $self->{'prefstore'}->get_all_scheme_field_prefs( $guid, $dbname );
		if ( $self->{'pref_requirements'}->{'general'} ) {
			$general_prefs = $self->{'prefstore'}->get_all_general_prefs( $guid, $dbname );
			$self->{'prefs'}->{'displayrecs'} = $general_prefs->{'displayrecs'} || 25;
			$self->{'prefs'}->{'pagebar'}     = $general_prefs->{'pagebar'}     || 'top and bottom';
			$self->{'prefs'}->{'alignwidth'}  = $general_prefs->{'alignwidth'}  || 100;
			$self->{'prefs'}->{'flanking'}    = $general_prefs->{'flanking'}    || 100;

			#default off
			foreach (qw (hyperlink_loci )) {
				$general_prefs->{$_} ||= 'off';
				$self->{'prefs'}->{$_} = $general_prefs->{$_} eq 'on' ? 1 : 0;
			}

			#default on
			foreach (qw (tooltips)) {
				$general_prefs->{$_} ||= 'on';
				$self->{'prefs'}->{$_} = $general_prefs->{$_} eq 'off' ? 0 : 1;
			}
		}
	}
	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		$self->_initiate_isolatedb_prefs( $general_prefs, $field_prefs, $scheme_field_prefs );
	}

	#Set dropdown status for scheme fields
	if ( $self->{'pref_requirements'}->{'query_field'} ) {
		my $guid                       = $self->get_guid || 1;
		my $dbname                     = $self->{'system'}->{'db'};
		my $scheme_ids                 = $self->{'datastore'}->run_list_query("SELECT id FROM schemes");
		my $scheme_fields              = $self->{'datastore'}->get_all_scheme_fields;
		my $scheme_field_default_prefs = $self->{'datastore'}->get_all_scheme_field_info;
		foreach my $scheme_id (@$scheme_ids) {
			foreach ( @{ $scheme_fields->{$scheme_id} } ) {
				foreach my $action (qw(dropdown)) {
					if ( defined $scheme_field_prefs->{$scheme_id}->{$_}->{$action} ) {
						$self->{'prefs'}->{"$action\_scheme_fields"}->{$scheme_id}->{$_} =
						  $scheme_field_prefs->{$scheme_id}->{$_}->{$action} ? 1 : 0;
					} else {
						$self->{'prefs'}->{"$action\_scheme_fields"}->{$scheme_id}->{$_} =
						  $scheme_field_default_prefs->{$scheme_id}->{$_}->{$action};
					}
				}
			}
		}
	}
	$self->{'datastore'}->update_prefs( $self->{'prefs'} );
	return;
}

sub _initiate_isolatedb_prefs {
	my ( $self, $general_prefs, $field_prefs, $scheme_field_prefs ) = @_;
	my $q          = $self->{'cgi'};
	my $field_list = $self->{'xmlHandler'}->get_field_list;
	my $params     = $q->Vars;
	my $extended   = $self->get_extended_attributes;

	#Parameters set by preference store via session cookie
	if (   $params->{'page'} eq 'options'
		&& $params->{'set'} )
	{

		#Switches
		foreach (
			qw ( update_details sequence_details mark_provisional mark_provisional_main sequence_details_main
			display_pending display_pending_main locus_alias scheme_members_alias sample_details undesignated_alleles)
		  )
		{
			$self->{'prefs'}->{$_} = $params->{$_} ? 1 : 0;
		}
		foreach (@$field_list) {
			if ( $_ ne 'id' ) {
				$self->{'prefs'}->{'maindisplayfields'}->{$_} = $params->{"field_$_"}     ? 1 : 0;
				$self->{'prefs'}->{'dropdownfields'}->{$_}    = $params->{"dropfield_$_"} ? 1 : 0;
				my $extatt = $extended->{$_};
				if ( ref $extatt eq 'ARRAY' ) {
					foreach my $extended_attribute (@$extatt) {
						$self->{'prefs'}->{'maindisplayfields'}->{"$_\..$extended_attribute"} =
						  $params->{"extended_$_\..$extended_attribute"} ? 1 : 0;
						$self->{'prefs'}->{'dropdownfields'}->{"$_\..$extended_attribute"} =
						  $params->{"dropfield_e_$_\..$extended_attribute"} ? 1 : 0;
					}
				}
			}
		}
		$self->{'prefs'}->{'maindisplayfields'}->{'aliases'} = $params->{"field_aliases"} ? 1 : 0;
		my $composites = $self->{'datastore'}->run_list_query("SELECT id FROM composite_fields");
		foreach (@$composites) {
			$self->{'prefs'}->{'maindisplayfields'}->{$_} = $params->{"field_$_"} ? 1 : 0;
		}
		my $schemes = $self->{'datastore'}->run_list_query("SELECT id FROM schemes");
		foreach (@$schemes) {
			my $field = "scheme_$_\_profile_status";
			$self->{'prefs'}->{'dropdownfields'}->{$field} = $params->{"dropfield_$field"} ? 1 : 0;
		}
	} else {
		my $guid             = $self->get_guid || 1;
		my $dbname           = $self->{'system'}->{'db'};
		my $field_attributes = $self->{'xmlHandler'}->get_all_field_attributes;
		if ( $self->{'pref_requirements'}->{'general'} ) {

			#default off
			foreach (qw (update_details undesignated_alleles scheme_members_alias sequence_details_main)) {
				$general_prefs->{$_} ||= 'off';
				$self->{'prefs'}->{$_} = $general_prefs->{$_} eq 'on' ? 1 : 0;
			}

			#default on
			foreach (
				qw (sequence_details sample_details mark_provisional mark_provisional_main display_pending display_pending_main locus_alias)
			  )
			{
				$general_prefs->{$_} ||= 'on';
				$self->{'prefs'}->{$_} = $general_prefs->{$_} eq 'off' ? 0 : 1;
			}
		}
		if ( $self->{'pref_requirements'}->{'query_field'} ) {
			foreach (@$field_list) {
				next if $_ eq 'id';
				if ( defined $field_prefs->{$_}->{'dropdown'} ) {
					$self->{'prefs'}->{'dropdownfields'}->{$_} = $field_prefs->{$_}->{'dropdown'};
				} else {
					$field_attributes->{$_}->{'dropdown'} ||= 'no';
					$self->{'prefs'}->{'dropdownfields'}->{$_} = $field_attributes->{$_}->{'dropdown'} eq 'yes' ? 1 : 0;
				}
				my $extatt = $extended->{$_};
				if ( ref $extatt eq 'ARRAY' ) {
					foreach my $extended_attribute (@$extatt) {
						if ( defined $field_prefs->{$_}->{'dropdown'} ) {
							$self->{'prefs'}->{'dropdownfields'}->{"$_\..$extended_attribute"} =
							  $field_prefs->{"$_\..$extended_attribute"}->{'dropdown'};
						} else {
							$self->{'prefs'}->{'dropdownfields'}->{"$_\..$extended_attribute"} = 0;
						}
					}
				}
			}
		}
		if ( $self->{'pref_requirements'}->{'main_display'} ) {
			if ( defined $field_prefs->{'aliases'}->{'maindisplay'} ) {
				$self->{'prefs'}->{'maindisplayfields'}->{'aliases'} = $field_prefs->{'aliases'}->{'maindisplay'};
			} else {
				$self->{'system'}->{'maindisplay_aliases'} ||= 'no';
				$self->{'prefs'}->{'maindisplayfields'}->{'aliases'} = $self->{'system'}->{'maindisplay_aliases'} eq 'yes' ? 1 : 0;
			}
			foreach (@$field_list) {
				next if $_ eq 'id';
				if ( defined $field_prefs->{$_}->{'maindisplay'} ) {
					$self->{'prefs'}->{'maindisplayfields'}->{$_} = $field_prefs->{$_}->{'maindisplay'};
				} else {
					$field_attributes->{$_}->{'maindisplay'} ||= 'yes';
					$self->{'prefs'}->{'maindisplayfields'}->{$_} = $field_attributes->{$_}->{'maindisplay'} eq 'no' ? 0 : 1;
				}
				my $extatt = $extended->{$_};
				if ( ref $extatt eq 'ARRAY' ) {
					foreach my $extended_attribute (@$extatt) {
						if ( defined $field_prefs->{$_}->{'maindisplay'} ) {
							$self->{'prefs'}->{'maindisplayfields'}->{"$_\..$extended_attribute"} =
							  $field_prefs->{"$_\..$extended_attribute"}->{'maindisplay'};
						} else {
							$self->{'prefs'}->{'maindisplayfields'}->{"$_\..$extended_attribute"} = 0;
						}
					}
				}
			}
			my $qry = "SELECT id,main_display FROM composite_fields";
			my $sql = $self->{'db'}->prepare($qry);
			eval { $sql->execute };
			$logger->logdie($@) if $@;
			while ( my ( $id, $main_display ) = $sql->fetchrow_array ) {
				if ( defined $field_prefs->{$id}->{'maindisplay'} ) {
					$self->{'prefs'}->{'maindisplayfields'}->{$id} = $field_prefs->{$id}->{'maindisplay'};
				} else {
					$self->{'prefs'}->{'maindisplayfields'}->{$id} = $main_display ? 1 : 0;
				}
			}
		}

		#Define locus defaults
		my $qry       = "SELECT id,isolate_display,main_display,query_field,analysis FROM loci";
		my $locus_sql = $self->{'db'}->prepare($qry);
		eval { $locus_sql->execute };
		$logger->error($@) if $@;
		my $prefstore_values = $self->{'prefstore'}->get_all_locus_prefs( $guid, $dbname );
		my $array_ref        = $locus_sql->fetchall_arrayref;
		my $i                = 1;
		foreach my $action (qw (isolate_display main_display query_field analysis)) {

			if ( !$self->{'pref_requirements'}->{$action} ) {
				$i++;
				next;
			}
			my $term = "$action\_loci";
			foreach (@$array_ref) {
				if ( defined $prefstore_values->{ $_->[0] }->{$action} ) {
					if ( $action eq 'isolate_display' ) {
						$self->{'prefs'}->{$term}->{ $_->[0] } = $prefstore_values->{ $_->[0] }->{$action};
					} else {
						$self->{'prefs'}->{$term}->{ $_->[0] } = $prefstore_values->{ $_->[0] }->{$action} eq 'true' ? 1 : 0;
					}
				} else {
					$self->{'prefs'}->{$term}->{ $_->[0] } = $_->[$i];
				}
			}
			$i++;
		}
		return if none { $self->{'pref_requirements'}->{$_} } qw (isolate_display main_display query_field analysis);
		my $scheme_ids                 = $self->{'datastore'}->run_list_query("SELECT id FROM schemes");
		my $scheme_values              = $self->{'prefstore'}->get_all_scheme_prefs( $guid, $dbname );
		my $scheme_field_default_prefs = $self->{'datastore'}->get_all_scheme_field_info;
		my $scheme_info                = $self->{'datastore'}->get_all_scheme_info;
		my $scheme_fields              = $self->{'datastore'}->get_all_scheme_fields;
		foreach my $scheme_id (@$scheme_ids) {

			foreach my $action (qw(isolate_display main_display query_field query_status analysis)) {
				if ( defined $scheme_values->{$scheme_id}->{$action} ) {
					$self->{'prefs'}->{"$action\_schemes"}->{$scheme_id} = $scheme_values->{$scheme_id}->{$action} ? 1 : 0;
				} else {
					$self->{'prefs'}->{"$action\_schemes"}->{$scheme_id} = $scheme_info->{$scheme_id}->{$action};
				}
			}
			if ( ref $scheme_fields->{$scheme_id} eq 'ARRAY' ) {
				foreach ( @{ $scheme_fields->{$scheme_id} } ) {
					foreach my $action (qw(isolate_display main_display query_field)) {
						if ( defined $scheme_field_prefs->{$scheme_id}->{$_}->{$action} ) {
							$self->{'prefs'}->{"$action\_scheme_fields"}->{$scheme_id}->{$_} =
							  $scheme_field_prefs->{$scheme_id}->{$_}->{$action} ? 1 : 0;
						} else {
							$self->{'prefs'}->{"$action\_scheme_fields"}->{$scheme_id}->{$_} =
							  $scheme_field_default_prefs->{$scheme_id}->{$_}->{$action};
						}
					}
				}
			}
			my $field = "scheme_$scheme_id\_profile_status";
			if ( defined $field_prefs->{$field}->{'dropdown'} ) {
				$self->{'prefs'}->{'dropdownfields'}->{$field} = $field_prefs->{$field}->{'dropdown'};
			} else {
				$self->{'prefs'}->{'dropdownfields'}->{$field} = $self->{'prefs'}->{'query_status_schemes'}->{$scheme_id};
			}
		}
	}
	return;
}

sub clean_checkbox_id {
	my ( $self, $var ) = @_;
	$var =~ s/'/__prime__/g;
	$var =~ s/\//__slash__/g;
	$var =~ s/,/__comma__/g;
	$var =~ s/ /__space__/g;
	$var =~ s/\(/_OPEN_/g;
	$var =~ s/\)/_CLOSE_/g;
	$var =~ s/\>/_GT_/g;
	return $var;
}

sub get_query_from_file {
	my ( $self, $filename ) = @_;
	my $full_path = "$self->{'config'}->{'secure_tmp_dir'}/$filename";
	my $qry;
	if ( -e $full_path ) {
		if ( open( my $fh, '<', $full_path ) ) {
			$qry = <$fh>;
			close $fh;
		}
	}
	return \$qry;
}

sub get_all_foreign_key_fields_and_labels {

	#returns arrayref of fields needed to order label and a hashref of labels
	my ( $self, $attribute_hashref ) = @_;
	my @fields;
	my @values = split /\|/, $attribute_hashref->{'labels'};
	foreach (@values) {
		if ( $_ =~ /\$(.*)/ ) {
			push @fields, $1;
		}
	}
	local $" = ',';
	my $qry = "select id,@fields from $attribute_hashref->{'foreign_key'}";
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute };
	$logger->error($@) if $@;
	my %desc;
	while ( my $data = $sql->fetchrow_hashref ) {
		my $temp = $attribute_hashref->{'labels'};
		foreach (@fields) {
			$temp =~ s/$_/$data->{$_}/;
		}
		$temp =~ s/[\|\$]//g;
		$desc{ $data->{'id'} } = $temp;
	}
	return ( \@fields, \%desc );
}
1;
