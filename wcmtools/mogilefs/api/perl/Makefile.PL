#!/usr/bin/perl
#
#   Perl Makefile for Danga-Socket
#   $Id: Makefile.PL,v 1.2 2005/02/01 01:15:26 bradfitz Exp $
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'MogileFS',
    VERSION                 => '1.00',
    AUTHOR                  => 'Brad Whitaker <whitaker@danga.com>',
    ABSTRACT                => 'MogileFS client library',
    PREREQ_PM               => {
        'IO::WrapTie'     => '2.102',
        'LWP::Simple'     => 0,
        fields            => 0,
        'Test::More'      => 0,
    },
    dist                    => {
        CI                      => "cvs commit",
        RCS_LABEL               => 'cvs tag RELEASE_$(VERSION_SYM)',
        SUFFIX                  => ".gz",
        DIST_DEFAULT            => 'all tardist',
        COMPRESS                => "gzip",
    },

);

