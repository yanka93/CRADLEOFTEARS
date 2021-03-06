#!/usr/bin/perl
#
#   Perl Makefile for Danga-Socket
#   $Id: Makefile.PL,v 1.1 2005/02/01 01:17:53 bradfitz Exp $
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

my $exefiles = ["mogstored", "mogilefsd"];
$exefiles = ["mogstored"] if exists $ENV{DANGABUILD_MOGSTOREDONLY};
$exefiles = ["mogilefsd"] if exists $ENV{DANGABUILD_MOGILEFSDONLY};

WriteMakefile(
    NAME                    => 'mogilefs-server',
    VERSION                 => '1.00',
    AUTHOR                  => 'Brad Fitzpatrick <brad@danga.com>',
    ABSTRACT                => 'MogileFS server components',
    EXE_FILES               => $exefiles,
    PREREQ_PM               => {
        'Danga::Socket'    => '1.22',
        'Perlbal'          => 0,    # FIXME: add version to Perlbal
        'Linux::AIO'       => '1.3',
        'Sys::Syslog'      => 0,
        'Getopt::Long'     => 0,
        'Symbol'           => 0,
        fields            => 0,
    },
    dist                    => {
        CI                      => "cvs commit",
        RCS_LABEL               => 'cvs tag RELEASE_$(VERSION_SYM)',
        SUFFIX                  => ".gz",
        DIST_DEFAULT            => 'all tardist',
        COMPRESS                => "gzip",
    },

);

