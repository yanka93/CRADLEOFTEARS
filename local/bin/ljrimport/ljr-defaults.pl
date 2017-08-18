#!/usr/bin/perl

package LJR;

$LJ_CLIENT = "LJR::Import/0.01";
$USER_AGENT = "LJR::Import/0.01; http://lj.rossia.org/; lj-admin\@rossia.org";

# How much times to retry if any network related error occurs
$NETWORK_RETRIES = 10; #was: 20
  
# Hom much seconds to wait before each retry
$NETWORK_SLEEP = 30; #was: 5

$DEBUG = 1;

sub NETWORK_SLEEP {
  my $msg = shift;

  if ($msg) {
    $msg = " (" . $msg . ")";
  }
  else {
    $msg = "";
  }

  my $t = `date +"%D %T"`;
  print
    substr($t, 0, length($t) - 1) .
    " sleeping $NETWORK_SLEEP seconds due to network related error" . $msg . ".\n"
    if $DEBUG;

  sleep $NETWORK_SLEEP;
};

return 1;
