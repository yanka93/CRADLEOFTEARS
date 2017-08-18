#!/usr/bin/perl -w
#
#   Learning Text::CPP... conclusion: not what I need.
#
#

package cpptokenizer;

use Text::CPP;
use Data::Dumper;

$Data::Dumper::TERSE = 1;
$Data::Dumper::INDENT = 1;

my $reader = new Text::CPP ( Language => "GNUC99" );

my ( $text, $type, $prettytype, $flags );

foreach my $file ( @ARGV ) {
    print "File: $file\n", '-' x 70, "\n";

    $reader->read( $file );

    #print join("\n", $reader->tokens);

    while ( ($text, $type, $flags) = $reader->token ) {
        $prettytype = $reader->type( $type );
        chomp( $text );
        #print "$prettytype: $text ($type) +$flags\n";
        print Data::Dumper->Dumpxs( [$text,$type,$flags,$prettytype],
                                    [qw{text type flags prettytype}] ), "\n";
        print "---\n";
    }

    print "\n\n";
}


