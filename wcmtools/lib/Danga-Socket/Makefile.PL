#!/usr/bin/perl
#
#   Perl Makefile for Danga-Socket
#   $Id: Makefile.PL,v 1.6 2005/03/08 01:02:35 bradfitz Exp $
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'Danga::Socket',
    VERSION_FROM            => 'Socket.pm', # finds $VERSION
    AUTHOR                  => 'Brad Fitzpatrick <brad@danga.com>',
    ABSTRACT                => 'Async socket class',
    PREREQ_PM               => {
        'Socket'        => 0,
        'IO::Poll'      => 0,
        fields          => 0,
        'POSIX'         => 0,
        'Test::More'    => 0,
    },
    dist                    => {
        CI                      => "cvs commit",
        RCS_LABEL               => 'cvs tag RELEASE_$(VERSION_SYM)',
        SUFFIX                  => ".gz",
        DIST_DEFAULT            => 'all tardist',
        COMPRESS                => "gzip",
    },

);

