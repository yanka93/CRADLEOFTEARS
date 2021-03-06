#!/usr/bin/perl
#
#   Perl Makefile for Perlbal
#   $Id: Makefile.PL,v 1.7 2005/03/08 00:30:09 bradfitz Exp $
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'Perlbal',
    VERSION                 => '1.2',
    AUTHOR                  => 'Brad Fitzpatrick <brad@danga.com>',
    ABSTRACT_FROM           => 'perlbal',

    (
      exists($ENV{DANGABUILD_MODULESONLY}) ?
      () :
      (EXE_FILES               => [ 'perlbal' ]),
    ),

    PREREQ_PM               => {
        'Linux::AIO'  => '1.3',
        'Danga::Socket' => '1.36',
        'BSD::Resource' => 0,
        'Net::Netmask' => 0,
        'Test::More' => 0,
        'File::Find' => 0,
    },
    dist                    => {
        CI                      => "cvs commit",
        RCS_LABEL               => 'cvs tag RELEASE_$(VERSION_SYM)',
        SUFFIX                  => ".gz",
        DIST_DEFAULT            => 'all tardist',
        COMPRESS                => "gzip",
    },

    (
      exists($ENV{DANGABUILD_DAEMONONLY}) ?
      (PM => {}, PMLIBDIRS => []):
      (),
    ),

);

