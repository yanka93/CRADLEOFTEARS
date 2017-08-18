#!/usr/bin/perl -w

use Fcntl;
use lib "blib/lib";
use DDLockClient ();
use Data::Dumper ();

$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 1;

$| = 1;

my $DDServers =  [
#	'localhost:7003',
#	'localhost:7004',
	'localhost:7002',
   ];

foreach my $servers ( $DDServers, [] ) {
	print "Creating client (@$servers)...";
	my $cl = new DDLockClient ( servers => $servers )
		or die $DDLockClient::Error;
	print "done:\n";

        for ( my $i = 0; $i < 10; $i++ ) {
            if ( my $pid = fork ) {
		print "Created child: $pid\n";
            } else {
                for ( my $ct = 0; $ct < 150; $ct++ ) {
                    my $rand = int(rand(10));
                    #print "Trying to create lock 'lock$rand' lock in process $$...\n";
                    if ( my $lock = $cl->trylock("lock$rand") ) {
                        my $file = ".stressfile-$rand";
                        my $fh = new IO::File $file, O_WRONLY|O_EXCL|O_CREAT;
                        die "Couldn't create file $file: $!" unless $fh;
                        $fh->close;
                        unlink $file;
                    }
                }
                exit 0;
            }
        }

        while ((my $pid = wait) != -1) {
            if ($? == 0) {
                print "$pid is done, okay.\n";
            } else {
                die "$pid FAILED\n";
            }
        }

	print "done.\n\n";
}




