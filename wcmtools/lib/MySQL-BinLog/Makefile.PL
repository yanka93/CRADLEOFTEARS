#!/usr/bin/perl
#
#   Perl Makefile for MySQL-BinLog
#   $Id: Makefile.PL,v 1.2 2004/11/17 01:45:16 marksmith Exp $
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'MySQL::BinLog',
    VERSION_FROM            => 'lib/Mysql/BinLog.pm', # finds $VERSION
    AUTHOR                  => 'Michael Granger <ged@danga.com>',
    ABSTRACT                => 'MySQL Replication Binlog Reader Library',
    PREREQ_PM               => {
        'Net::MySQL'      => 0,
        'Scalar::Util'    => 0,
        fields            => 0,
    },
    dist                    => {
        CI                      => "cvs commit",
        RCS_LABEL               => 'cvs tag RELEASE_$(VERSION_SYM)',
        SUFFIX                  => ".bz2",
        DIST_DEFAULT            => 'all tardist',
        COMPRESS                => "bzip2",
    },

);

