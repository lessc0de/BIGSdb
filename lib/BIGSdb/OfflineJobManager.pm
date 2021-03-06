#Written by Keith Jolley
#(c) 2011-2013, University of Oxford
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
package BIGSdb::OfflineJobManager;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Application);
use Error qw(:try);
use Digest::MD5;
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Job');
use constant DBASE_QUOTA_EXCEEDED => 1;

sub new {

	#The job manager uses its own Dataconnector since it may be called by a stand-alone script.
	my ( $class, $options ) = @_;
	my $self = {};
	$self->{'system'}        = $options->{'system'} // {};
	$self->{'host'}          = $options->{'host'};
	$self->{'port'}          = $options->{'port'};
	$self->{'user'}          = $options->{'user'};
	$self->{'password'}      = $options->{'password'};
	$self->{'xmlHandler'}    = undef;
	$self->{'dataConnector'} = BIGSdb::Dataconnector->new;
	bless( $self, $class );
	$self->_initiate( $options->{'config_dir'} );
	$self->_db_connect;
	return $self;
}

sub _initiate {
	my ( $self, $config_dir ) = @_;
	$self->read_config_file($config_dir);
	return;
}

sub _db_connect {
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $initiate_logger = get_logger('BIGSdb.Application_Initiate');
	if ( !$self->{'config'}->{'jobs_db'} ) {
		$initiate_logger->fatal("jobs_db not set in config file.");
		return;
	}
	my %att = (
		dbase_name => $self->{'config'}->{'jobs_db'},
		host       => $self->{'host'},
		port       => $self->{'port'},
		user       => $self->{'user'},
		password   => $self->{'password'},
	);
	if ( $options->{'reconnect'} ) {
		$self->{'db'} = $self->{'dataConnector'}->drop_connection( \%att );
	}
	try {
		$self->{'db'} = $self->{'dataConnector'}->get_connection( \%att );
	}
	catch BIGSdb::DatabaseConnectionException with {
		$initiate_logger->error("Can not connect to database '$self->{'config'}->{'jobs_db'}'");
		return;
	};
	return;
}

sub add_job {

	#Required params:
	#dbase_config: name of db configuration direction in /etc/dbases
	#ip_address: connecting address
	#module: Plugin module name
	#function: Function in module to call
	#
	#Optional params:
	#username and email of user
	#priority: (highest 1 - lowest 9)
	#parameters: any additional parameters needed by plugin (hashref)
	my ( $self, $params ) = @_;
	foreach (qw (dbase_config ip_address module)) {
		if ( !$params->{$_} ) {
			$logger->error("Parameter $_ not passed");
			throw BIGSdb::DataException("Parameter $_ not passed");
		}
	}
	my $priority;
	if ( $self->{'system'}->{'job_priority'} && BIGSdb::Utils::is_int( $self->{'system'}->{'job_priority'} ) ) {
		$priority = $self->{'system'}->{'job_priority'};    #Database level priority
	} else {
		$priority = 5;
	}
	$priority += $params->{'priority'} if $params->{'priority'} && BIGSdb::Utils::is_int( $params->{'priority'} );    #Plugin level priority
	my $id         = BIGSdb::Utils::get_random();
	my $cgi_params = $params->{'parameters'};
	$logger->logdie("CGI parameters not passed as a ref") if ref $cgi_params ne 'HASH';
	foreach my $key ( keys %$cgi_params ) {
		delete $cgi_params->{$key} if BIGSdb::Utils::is_int($key);    #Treeview implementation has integer node ids.
	}
	delete $cgi_params->{$_} foreach qw(submit page update_options format dbase_config_dir instance);
	my $fingerprint = $self->_make_job_fingerprint( $cgi_params, $params );
	my $duplicate_job = $self->_get_duplicate_job( $fingerprint, $params->{'username'}, $params->{'ip_address'} );
	my $quota_exceeded = $self->_is_quota_exceeded($params);
	my $status;
	if ($duplicate_job) {
		$status = "rejected - duplicate job ($duplicate_job)";
	} elsif ($quota_exceeded) {
		if ( $quota_exceeded == DBASE_QUOTA_EXCEEDED ) {
			my $plural = $self->{'system'}->{'job_quota'} == 1 ? '' : 's';
			$status = "rejected - database jobs exceeded. This database has a quota of $self->{'system'}->{'job_quota'} "
			  . "concurrent job$plural.  Please try again later.";
		}
	} else {
		$status = 'submitted';
	}
	eval {
		$self->{'db'}->do(
			"INSERT INTO jobs (id,dbase_config,username,email,ip_address,submit_time,module,status,percent_complete,"
			  . "priority,fingerprint) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
			undef,
			$id,
			$params->{'dbase_config'},
			$params->{'username'},
			$params->{'email'},
			$params->{'ip_address'},
			'now',
			$params->{'module'},
			$status,
			0,
			$priority,
			$fingerprint
		);
		my $param_sql = $self->{'db'}->prepare("INSERT INTO params (job_id,key,value) VALUES (?,?,?)");
		local $" = '||';
		foreach ( keys %$cgi_params ) {
			if ( defined $cgi_params->{$_} && $cgi_params->{$_} ne '' ) {
				my @values = split( "\0", $cgi_params->{$_} );
				$param_sql->execute( $id, $_, "@values" );
			}
		}
		if ( defined $params->{'isolates'} && ref $params->{'isolates'} eq 'ARRAY' ) {

			#Benchmarked quicker to use single insert rather than multiple inserts, ids are integers so no problem with escaping values.
			my @checked_list;
			foreach my $id ( @{ $params->{'isolates'} } ) {
				push @checked_list, $id if BIGSdb::Utils::is_int($id);
			}
			local $" = "),('$id',";
			if (@checked_list) {
				my $sql = $self->{'db'}->prepare("INSERT INTO isolates (job_id,isolate_id) VALUES ('$id',@checked_list)");
				$sql->execute;
			}
		}
		if ( defined $params->{'profiles'} && ref $params->{'profiles'} eq 'ARRAY' && $cgi_params->{'scheme_id'} ) {

			#Safer to use placeholders and multiple inserts for profiles and loci though.
			my @list = @{ $params->{'profiles'} };
			my $sql  = $self->{'db'}->prepare("INSERT INTO profiles (job_id,scheme_id,profile_id) VALUES (?,?,?)");
			$sql->execute( $id, $cgi_params->{'scheme_id'}, $_ ) foreach @{ $params->{'profiles'} };
		}
		if ( defined $params->{'loci'} && ref $params->{'loci'} eq 'ARRAY' ) {
			my $sql = $self->{'db'}->prepare("INSERT INTO loci (job_id,locus) VALUES (?,?)");
			$sql->execute( $id, $_ ) foreach @{ $params->{'loci'} };
		}
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return $id;
}

sub _make_job_fingerprint {
	my ( $self, $cgi_params, $params ) = @_;
	my $buffer;
	foreach my $key ( sort keys %$cgi_params ) {
		$buffer .= "$key:$cgi_params->{$key};" if ( $cgi_params->{$key} // '' ) ne '';
	}
	local $" = ',';
	$buffer .= "isolates:@{ $params->{'isolates'} };" if defined $params->{'isolates'} && ref $params->{'isolates'} eq 'ARRAY';
	$buffer .= "profiles:@{ $params->{'profiles'} };" if defined $params->{'profiles'} && ref $params->{'profiles'} eq 'ARRAY';
	$buffer .= "loci:@{ $params->{'loci'} };"         if defined $params->{'loci'}     && ref $params->{'loci'}     eq 'ARRAY';
	my $fingerprint = Digest::MD5::md5_hex($buffer);
	return $fingerprint;
}

sub _is_quota_exceeded {
	my ( $self, $params ) = @_;
	if ( BIGSdb::Utils::is_int( $self->{'system'}->{'job_quota'} ) ) {
		my $qry = "SELECT COUNT(*) FROM jobs WHERE dbase_config=? AND status IN ('submitted','started')";
		my $sql = $self->{'db'}->prepare($qry);
		eval { $sql->execute( $params->{'dbase_config'} ) };
		$logger->error($@) if $@;
		my ($job_count) = $sql->fetchrow_array;
		return DBASE_QUOTA_EXCEEDED if $job_count >= $self->{'system'}->{'job_quota'};
	}
	return 0;
}

sub _get_duplicate_job {
	my ( $self, $fingerprint, $username, $ip_address ) = @_;
	my $qry = "SELECT id FROM jobs WHERE fingerprint=? AND (status='started' OR status='submitted') AND ";
	$qry .= $self->{'system'}->{'read_access'} eq 'public' ? 'ip_address=?' : 'username=?';
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute( $fingerprint, ( $self->{'system'}->{'read_access'} eq 'public' ? $ip_address : $username ) ) };
	$logger->error($@) if $@;
	my ($job_id) = $sql->fetchrow_array;
	return $job_id;
}

sub cancel_job {
	my ( $self, $id ) = @_;
	eval { $self->{'db'}->do( "UPDATE jobs SET status='cancelled',cancel=true WHERE id=?", undef, $id ) };
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub update_job_output {
	my ( $self, $job_id, $output_hash ) = @_;
	if ( ref $output_hash ne 'HASH' ) {
		$logger->error("status hash not passed as a ref");
		throw BIGSdb::DataException("status hash not passed as a ref");
	}
	if ( $output_hash->{'compress'} ) {
		my $full_path = "$self->{'config'}->{'tmp_dir'}/$output_hash->{'filename'}";
		if ( -s $full_path > ( 10 * 1024 * 1024 ) ) {    #>10 MB
			if ( $output_hash->{'keep_original'} ) {
				system("gzip -c $full_path > $full_path\.gz");
			} else {
				system( 'gzip', $full_path );
			}
			if ( $? == -1 ) {
				$logger->error("Can't gzip file $full_path: $!");
			} else {
				$output_hash->{'filename'}    .= '.gz';
				$output_hash->{'description'} .= ' [gzipped file]';
			}
		}
	}
	eval {
		$self->{'db'}->do(
			"INSERT INTO output (job_id,filename,description) VALUES (?,?,?)",
			undef, $job_id,
			$output_hash->{'filename'},
			$output_hash->{'description'}
		);
		$logger->debug( $output_hash->{'filename'} . '; ' . $output_hash->{'description'} . "; $job_id" );
	};
	if ($@) {
		$logger->logcarp($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub update_job_status {
	my ( $self, $job_id, $status_hash ) = @_;
	if ( ref $status_hash ne 'HASH' ) {
		$logger->error("status hash not passed as a ref");
		throw BIGSdb::DataException("status hash not passed as a ref");
	}

	#Exceptions in BioPerl appear to sometimes cause the connection to the jobs database to be broken
	#No idea why - so reconnect if status is 'failed'.
	$self->_db_connect( { reconnect => 1 } ) if ( $status_hash->{'status'} // '' ) eq 'failed';
	my ( @keys, @values );
	foreach my $key ( sort keys %$status_hash ) {
		push @keys,   $key;
		push @values, $status_hash->{$key};
	}
	local $" = '=?,';
	my $qry = "UPDATE jobs SET @keys=? WHERE id=?";
	if ( !$self->{'sql'}->{$qry} ) {

		#Prepare and cache statement handle.  Previously, using DBI::do resulted in continuously increasing memory use.
		$self->{'sql'}->{$qry} = $self->{'db'}->prepare($qry);
	}
	eval { $self->{'sql'}->{$qry}->execute( @values, $job_id ) };
	if ($@) {
		$logger->logcarp($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return if ( $status_hash->{'status'} // '' ) eq 'failed';
	my $job = $self->get_job_status($job_id);
	if ( $job->{'status'} && $job->{'status'} eq 'cancelled' || $job->{'cancel'} ) {
		system( 'kill', $job->{'pid'} ) if $job->{'pid'};
	}
	return;
}

sub get_job_status {
	my ( $self, $job_id ) = @_;
	if ( !$self->{'sql'}->{'get_job_status'} ) {
		$self->{'sql'}->{'get_job_status'} = $self->{'db'}->prepare("SELECT status,cancel,pid FROM jobs WHERE id=?");
	}
	eval { $self->{'sql'}->{'get_job_status'}->execute($job_id) };
	$logger->error($@) if $@;
	return $self->{'sql'}->{'get_job_status'}->fetchrow_hashref;
}

sub get_job {
	my ( $self, $job_id ) = @_;
	if ( !$self->{'sql'}->{'get_job'} ) {
		$self->{'sql'}->{'get_job'} =
		  $self->{'db'}->prepare( "SELECT *,extract(epoch FROM now() - start_time) AS elapsed,extract(epoch FROM "
			  . "stop_time - start_time) AS total_time, localtimestamp AS query_time FROM jobs WHERE id=?" );
	}
	eval { $self->{'sql'}->{'get_job'}->execute($job_id) };
	if ($@) {
		$logger->error($@);
		return;
	}
	return $self->{'sql'}->{'get_job'}->fetchrow_hashref;
}

sub get_job_params {
	my ( $self, $job_id ) = @_;
	my $sql = $self->{'db'}->prepare("SELECT key,value FROM params WHERE job_id=?");
	my $params;
	eval { $sql->execute($job_id) };
	if ($@) {
		$logger->error($@);
		return;
	}
	while ( my ( $key, $value ) = $sql->fetchrow_array ) {
		$params->{$key} = $value;
	}
	return $params;
}

sub get_job_output {
	my ( $self, $job_id ) = @_;
	my $sql = $self->{'db'}->prepare("SELECT filename,description FROM output WHERE job_id=?");
	eval { $sql->execute($job_id) };
	if ($@) {
		$logger->error($@);
		return;
	}
	my $output;
	while ( my ( $filename, $desc ) = $sql->fetchrow_array ) {
		$output->{$desc} = $filename;
	}
	return $output;
}

sub get_job_isolates {
	my ( $self, $job_id ) = @_;
	my $sql = $self->{'db'}->prepare("SELECT isolate_id FROM isolates WHERE job_id=? ORDER BY isolate_id");
	eval { $sql->execute($job_id) };
	$logger->error($@) if $@;
	my @isolate_ids;
	while ( my ($isolate_id) = $sql->fetchrow_array ) {
		push @isolate_ids, $isolate_id;
	}
	return \@isolate_ids;
}

sub get_job_profiles {
	my ( $self, $job_id, $scheme_id ) = @_;
	my $sql = $self->{'db'}->prepare("SELECT profile_id FROM profiles WHERE job_id=? AND scheme_id=? ORDER BY profile_id");
	eval { $sql->execute( $job_id, $scheme_id ) };
	$logger->error($@) if $@;
	my @profile_ids;
	while ( my ($profile_id) = $sql->fetchrow_array ) {
		push @profile_ids, $profile_id;
	}
	return \@profile_ids;
}

sub get_job_loci {
	my ( $self, $job_id ) = @_;
	my $sql = $self->{'db'}->prepare("SELECT locus FROM loci WHERE job_id=? ORDER BY locus");
	eval { $sql->execute($job_id) };
	$logger->error($@) if $@;
	my @loci;
	while ( my ($locus) = $sql->fetchrow_array ) {
		push @loci, $locus;
	}
	return \@loci;
}

sub get_user_jobs {
	my ( $self, $instance, $username, $days ) = @_;
	my $sql =
	  $self->{'db'}->prepare( "SELECT *,extract(epoch FROM now() - start_time) AS elapsed,extract(epoch FROM stop_time - "
		  . "start_time) AS total_time FROM jobs WHERE dbase_config=? AND username=? AND (submit_time > now()-interval '$days days' "
		  . "OR stop_time > now()-interval '$days days' OR status='started' OR status='submitted') ORDER BY submit_time" );
	eval { $sql->execute( $instance, $username ) };
	if ($@) {
		$logger->error($@);
		return;
	}
	my @jobs;
	while ( my $job = $sql->fetchrow_hashref ) {
		push @jobs, $job;
	}
	return \@jobs;
}

sub get_jobs_ahead_in_queue {
	my ( $self, $job_id ) = @_;
	my $sql =
	  $self->{'db'}->prepare( "SELECT COUNT(j1.id) FROM jobs AS j1 INNER JOIN jobs AS j2 ON (j1.submit_time < j2.submit_time AND "
		  . "j2.priority <= j1.priority) OR j2.priority > j1.priority WHERE j2.id = ? AND j2.id != j1.id AND j1.status='submitted'" );
	eval { $sql->execute($job_id) };
	if ($@) {
		$logger->error($@);
		return;
	}
	my ($jobs) = $sql->fetchrow_array;
	return $jobs;
}

sub get_next_job_id {
	my ($self) = @_;
	my $sql = $self->{'db'}->prepare("SELECT id FROM jobs WHERE status='submitted' ORDER BY priority asc,submit_time asc LIMIT 1");
	eval { $sql->execute };
	if ($@) {
		$logger->error($@);
		return;
	}
	my ($job) = $sql->fetchrow_array;
	return $job;
}
1;
