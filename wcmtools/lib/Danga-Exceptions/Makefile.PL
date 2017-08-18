#!/usr/bin/perl
#
#   Perl Makefile for Danga-Exceptions
#   $Id: Makefile.PL,v 1.1 2004/06/04 22:06:28 deveiant Exp $
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'Danga::Exceptions',
    VERSION_FROM            => 'lib/Danga/Exceptions.pm', # finds $VERSION
    AUTHOR                  => 'Michael Granger <ged@danga.com>',
    ABSTRACT                => 'Exception library',
    PREREQ_PM               => {
		Scalar::Util	=> 0,
		Carp			=> 0,
		overload		=> 0,
    },
    dist                    => {
        CI                      => "cvs commit",
        RCS_LABEL               => 'cvs tag RELEASE_$(VERSION_SYM)',
        SUFFIX                  => ".bz2",
        DIST_DEFAULT            => 'all tardist',
        COMPRESS                => "bzip2",
    },

);

