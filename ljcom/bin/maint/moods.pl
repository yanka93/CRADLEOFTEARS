#!/usr/bin/perl
#

$maint{'makemoodindexes'} = sub
{
    print "-I- Making mood index files.\n" if $VERBOSE;
    system("find $LJ::HTDOCS/img/mood/ -type d -exec makemoodindex.pl {} \\;");
};

1;
