#!/usr/bin/perl
#
#	Perl Makefile for DDLockClient/DDLock
#	$Id: Makefile.PL,v 1.2 2004/05/27 22:08:51 deveiant Exp $
#
#	Invoke with 'perl Makefile.PL'
#
#	See ExtUtils::MakeMaker (3) for more information on how to influence
#	 the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;
my $version = do { my @r = (q$Revision: 1.2 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

my %config = (
	NAME			=> 'DDLockClient',
	VERSION			=> "0." . $version,
	AUTHOR			=> 'Brad Fitzpatrick <brad@danga.com>',
	ABSTRACT		=> 'A lock client for the distributed lock daemon ddlockd',
	PREREQ_PM		=> {
		Socket	=> 0,
	},
	dist			=> {
		CI				=> "cvs commit",
		RCS_LABEL		=> 'cvs tag r$(VERSION_SYM)',
		SUFFIX			=> ".bz2",
		DIST_DEFAULT	=> 'all tardist',
		COMPRESS		=> "bzip2",
	},
   );


WriteMakefile( %config );
