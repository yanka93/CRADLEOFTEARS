use strict;

package LJR::unicode;

use XML::Parser;
use Unicode::MapUTF8 qw(to_utf8 from_utf8 utf8_supported_charset);


sub utf8ize {
  my $text_in = shift;
  $$text_in = pack("C*", unpack("C*", $$text_in)) if $$text_in;
}


sub force_utf8 {
  my $xdata = shift;
  my %error_lines;
  my $finished = 0;
  my @xlines;
  my $orig_xdata = $$xdata;

  my $p1 = new XML::Parser ();

  while (!$finished) {
    eval { $p1->parse($$xdata); };

    if ($@ && $@ =~ /not\ well\-formed\ \(invalid\ token\)\ at\ line\ (\d+)\,/) {
      my $error_line = $1;
      $error_lines{$error_line} ++;

      if ($error_lines{$error_line} > 1) {
        $$xdata = $orig_xdata;
        $finished = 1;
      }
      else {
        @xlines = split(/\n/, $$xdata);
        my $output = to_utf8({ -string => $xlines[$error_line - 1], -charset => 'latin1' });
        $xlines[$error_line - 1] = $output;
        $$xdata = join("\n", @xlines);
      }
    }
    # unknown error or no error, doesn't matter
    elsif ($@) {
      $$xdata = $orig_xdata;
      $finished = 1;
    }
    else {
      $finished = 1;
    }
  }
}

return 1;
