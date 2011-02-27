Important notes about upgrading
-------------------------------

Version 1.1: Offline job manager - set up new user account and cron job.
Version 1.2: Change of isolate database structure.

Details can be found below.


Version 1.1
-----------
Version 1.1 introduces an offline job manager.  This is required to control
analyses that take a long time for which it is inappropriate to require the
browser remains connected.  When upgrading to version 1.1, you will need to
do the following:

1) Create a 'bigsdb' UNIX user, e.g.

sudo useradd -s /bin/sh bigsdb

2) As the postgres user, create a 'bigsdb' user and create a bigsdb_jobs 
database using the jobs.sql SQL file, e.g.

createuser bigsdb [no need for special priveleges]
createdb bigsdb_jobs
psql -f jobs.sql bigsdb_jobs

3) Set up the jobs parameters in the /etc/bigsdb/bigsdb.conf file, e.g.

jobs_db=bigsdb_jobs
max_load=8

The jobs script will not process a job if the server's load average (over the
last minute) is higher than the max_load parameter.  This should be set higher
than the number of processor cores or you may find that jobs never run on a
busy server.  Setting it to double the number of cores is probably a good
starting point.  

4) Copy the job_logging.conf file to the /etc/bigsdb directory.

5) Set the script to run frequently (preferably every minute) from CRON. Note
that CRON does not like '.' in executable filenames, so either rename the
script to 'bigsjobs' or create a symlink and call that from CRON, e.g.

copy bigsjobs.pl to /usr/local/bin
sudo ln -s /usr/local/bin/bigsjobs.pl /usr/local/bin/bigsjobs

Add the following to /etc/crontab:

* *    * * *	bigsdb  /usr/local/bin/bigsjobs

(set to run every minute from the 'bigsdb' user account).

6) Create a log file, bigsdb_jobs.log, in /var/log owned by 'bigsdb',
 e.g.

sudo touch /var/log/bigsdb_jobs.log
sudo chown bigsdb /var/log/bigsdb_jobs.log 

Version 1.2
-----------
This version requires changes to the structure of isolate databases to 
accommodate in silico PCR and hybridization reaction filtering. Please run the
isolatedb_v1.2.sql script, found in the sql/upgrade directory, against your
isolate databases.
