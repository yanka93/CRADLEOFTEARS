#!/usr/bin/perl
#
#	Perl Makefile for BML
#	$Id: Makefile.PL,v 1.1 2004/05/26 17:33:51 deveiant Exp $
#
#	Invoke with 'perl Makefile.PL'
#
#	See ExtUtils::MakeMaker (3) for more information on how to influence
#	 the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;
my $version = do { my @r = (q$Revision: 1.1 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

my %config = (
	NAME			=> 'BML',
	VERSION			=> "0." . $version,
	AUTHOR			=> 'Brad Fitzpatrick <brad@danga.com>',
	ABSTRACT		=> 'a server-side markup language',
	PREREQ_PM		=> {
		Apache			=> 0,
		Apache::URI		=> 0,
		Digest::MD5		=> 0,
		File::Spec		=> 0,
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
