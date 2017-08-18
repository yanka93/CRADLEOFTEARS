#!/usr/bin/perl -w
#
# Logging related routines
#


package Golem;
use strict;

use Golem;
use Data::Dumper;


sub dumper {
  my ($v) = @_;

  return Dumper($v);
}

sub debug_sql {
  my ($text, $bound_values, $opts) = @_;

  if ($Golem::debug_sql) {
    $opts = {} unless $opts;

    $text = "SQL: [" . ($text ? $text : "") . "]";
    
    if ($bound_values && ref($bound_values) eq 'ARRAY') {
      $text .= " bound_values [" . Golem::safe_join(",", @{$bound_values}) . "]";
    }

    if ($opts->{'stderr'}) {
      print STDERR localtime() . " " . $text . "\n";
    }
    else {
      print localtime() . " " . $text . "\n";
    }
  }
}

sub debug2 {
  my ($text, $opts) = @_;
  
  if ($Golem::debug2) {
    debug($text, $opts);
  }
}

sub debug {
  my ($text, $opts) = @_;

  $opts = {} unless $opts;

  if ($Golem::debug) {
    my $stamp = localtime() . ": ";

    utf8::encode($text) if utf8::is_utf8($text);
    
    if ($opts->{'stderr'}) {
      if (ref($text)) {
        print STDERR join("", map { "$stamp$_\n" } Dumper($text));
      }
      else {
        print STDERR $stamp . ($text ? $text : "") . "\n";
      }
    }
    else {
      if (ref($text)) {
        print join("", map { "$stamp$_\n" } Dumper($text));
      }
      else {
        print $stamp . ($text ? $text : "") . "\n";
      }
    }
  }
}

# safe_open and safe_close are copied
# from ps_farm.pm (should be one library actually)
sub safe_open {
  my ($filename, $mode, $timeout) = @_;

  $timeout = 30 unless $timeout;
  $mode = "open" unless $mode;

  if ($mode eq "overwrite" || $mode eq ">") {
    $mode = ">";
  }
  elsif ($mode eq "append" || $mode eq ">>") {
    $mode = ">>";
  }
  else {
    $mode = "";
  }

  my $fh;
  my $i=0;
  while (! open($fh, "${mode}${filename}")) {
    if ($i > $timeout) {
      print STDERR "Unable to open $filename\n";
      return 0;
    }

    print STDERR "still trying to open $filename\n";
    $i = $i + 1;
    sleep 1;
  }

  while (! flock($fh, 2)) {
    if ($i > $timeout) {
      print STDERR "Unable to lock $filename\n";
      return 0;
    }

    print STDERR "still trying to lock $filename\n";
    $i = $i + 1;
    sleep 1;
  }

  my $fh1;
  if (!open($fh1, "${mode}${filename}")) {
    $i = $i + 1;

    if ($i > $timeout) {
      print STDERR "Unable to open and lock $filename\n";
      return 0;
    }

    print STDERR "Locked $filename, but it's gone. Retrying...\n";
    return safe_open($filename, $mode, $timeout - 1);
  }
  else {
    close($fh1);
    return $fh;
  }
}

sub safe_close {
  my ($fh) = @_;
  return flock($fh, 8) && close($fh);
}

sub do_log {
    my ($message, $opts) = @_;
    
    my $module;
    my $stderr = 0;
    
    if (ref($opts) eq 'HASH') {
      if ($opts->{'module'}) {
        $module = "[$opts->{'module'}] ";
      }
      if ($opts->{'stderr'}) {
        $stderr = $opts->{'stderr'};
      }
    }
    else {
      $module = $opts;
      $module = "[$module] " if $module;
    }
    
    $message = "" unless $message;

    utf8::encode($message) if utf8::is_utf8($message);
    
    $module = "[" . $0 . "] " unless $module;

    my $message_eol = chop($message);
    
    my $message_formatted =
      localtime() . " " . $module .
      $message .
      $message_eol .
      ($message_eol eq "\n" ? "" : "\n");
    
    if ($stderr) {
      print STDERR $message_formatted;
    }
    elsif ($Golem::debug) {
      print $message_formatted;
    }
    
    if (defined($Golem::LOG)) {
	    my $fh = safe_open($Golem::LOG, ">>");
	    Golem::die ("Unable to open $Golem::LOG\n") unless $fh;
#    binmode($fh, ":utf8");
	    print $fh $message_formatted;
  	  safe_close($fh);
  	}
  	else {
  		print STDERR "No Golem::LOG is configured. Logging to STDERR\n";
  		print STDERR $message_formatted;
  	}
}


1;
