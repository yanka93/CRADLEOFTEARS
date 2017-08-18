#!/usr/bin/perl -w
#
# Text manipulation routines
#
#   parts courtesy of LiveJournal.org
#

package Golem;
use strict;

use Golem;

# <LJFUNC>
# name: LJ::decode_url_string
# class: web
# des: Parse URL-style arg/value pairs into a hash.
# args: buffer, hashref
# des-buffer: Scalar or scalarref of buffer to parse.
# des-hashref: Hashref to populate.
# returns: boolean; true.
# </LJFUNC>
sub decode_url_string
{
    my $a = shift;
    my $buffer = ref $a ? $a : \$a;
    my $hashref = shift;  # output hash
    my $keyref  = shift;  # array of keys as they were found

    my $pair;
    my @pairs = split(/&/, $$buffer);
    @$keyref = @pairs;
    my ($name, $value);
    foreach $pair (@pairs)
    {
        ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $name =~ tr/+/ /;
        $name =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $hashref->{$name} .= $hashref->{$name} ? ",$value" : $value;
    }
    return 1;
}


# <LJFUNC>
# name: LJ::ehtml
# class: text
# des: Escapes a value before it can be put in HTML.
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </LJFUNC>
sub ehtml
{
    # fast path for the commmon case:
    return $_[0] unless $_[0] =~ /[&\"\'<>]/o;

    # this is faster than doing one substitution with a map:
    my $a = $_[0];
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&\#39;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;
}

sub esql {
  return $_[0] unless $_[0] =~ /[\'\"\\]/o;

  my $a = $_[0];
  $a =~ s/\'//go;
  $a =~ s/\"//go;
  $a =~ s/\\//go;
  return $a;
}

# <LJFUNC>
# name: LJ::is_ascii
# des: checks if text is pure ASCII.
# args: text
# des-text: text to check for being pure 7-bit ASCII text.
# returns: 1 if text is indeed pure 7-bit, 0 otherwise.
# </LJFUNC>
sub is_ascii {
    my $text = shift;
    return ($text !~ m/[^\x01-\x7f]/o);
}

sub is_digital {
  my $text = shift;
  return ( $text =~ /\d+/o );
}

# tests if there's data in configuration file string:
# i.e. if it's not empty and is not commented
#
sub have_data {
  my ($line) = @_;

  if ($line =~ /^\s*#/o || $line =~ /^[\s]*$/o) {
    return 0;
  }

  return 1;
}

# fixes user input strings (passed as array of references),
# currently only trims
#
# used when importing:
#   - 1C data
#
sub fix_input {
  my (@i) = @_;
  
  foreach my $v (@i) {
    Golem::die("Programmer error: check_input expects only scalar references")
      unless ref($v) eq 'SCALAR';

    Golem::do_log("Inaccurate spacing trimmed [$$v]", {"stderr" => 1})
      if Golem::trim($v);
  }
}

# given scalar string trims white space
# at the beginning and in the end and
# returns trimmed string
#
# given scalar reference trims white space
# at the beginning and in the end and
# returns true if trimming occured and false otherwise
# NOTE: modifies the original string
# reference to which was given as input parameter
sub trim {
  my ($string) = @_;
  
  if (ref($string) eq 'SCALAR') {
    my $tstr = $$string;
    
    return 0 if $tstr eq ''; # nothing to trim, do not waste cpu cycles
    
    $tstr =~ s/^\s+//so;
    $tstr =~ s/\s+$//so;
    
    if ($tstr ne $$string) {
      $$string = $tstr;
      return 1;
    }
    else {
      return 0;
    }
  }
  else {
    return "" if $string eq ''; # nothing to trim, do not waste cpu cycles

    $string =~ s/^\s+//so;
    $string =~ s/\s+$//so;
    return $string;
  }
}

# same as standard perl join except for it doesn't
# output "uninitialized value in join" when joining
# list with undef values; and we use those lists
# when binding params to DBI query
#
sub safe_join {
  my ($delimiter, @arr) = @_;

  my $joined_text = "";
  $delimiter = "" unless $delimiter;

  foreach my $bv (@arr) {
    $joined_text .= ($bv ? $bv : "") . $delimiter;
  }
  
  my $i;
  for ($i = 0; $i < length($delimiter); $i++) {
    chop($joined_text);
  }

  return $joined_text;
}

# should be used when you need to concatenate string
# which might be undefined and you want empty string ("")
# instead of perl warnings about uninitialized values
#
sub safe_string {
  my ($str) = @_;

  if ($str) {
    return $str;
  }
  else {
    return "";
  }
}

# inserts $symbol every $range characters in a $line
sub div_line {
  my ($line, $range, $symbol) = @_;
  
  Golem::die("Programmer error: div_line expects at least string")
    unless $line;
  
  $range = 70 unless $range;
  $symbol = ' ' unless $symbol;

  my $result = '';
  for (my $i = 0 ; $i <= int(length($line)/$range) ; $i++) {
    $result .= substr($line,$i*$range,$range) . $symbol;
  }
  chop($result);
  
  return $result;
}


1;
