#!/usr/bin/perl
#
#
#
#

{
  package LJ;

  %LJR_REVERSE_PROXIES = (
    "127.0.0.1" => 1,
    "127.0.0.2" => 1,
  );
  eval {
    open (t1, "cat $ENV{'LJHOME'}/etc/reverse-proxy.conf 2> /dev/null | ");
    while(<t1>) {
      my $cline = $_;
      $cline =~ s/(#.*)//;
      if ($cline =~ /([\d]+\.[\d]+\.[\d]+\.[\d]+)/) {
        $LJR_REVERSE_PROXIES{$1} = 1;
      }
    }
    close t1;
  };

  sub get_real_remote_ip {
    my @ips_in = @_;

    my @ips;
    foreach my $i (@ips_in) {
      while ($i =~ /([\d]+\.[\d]+\.[\d]+\.[\d]+)/g) {
        push @ips, $1;
      }
    }
    my $ip;
    foreach $ip (@ips) {
      if (scalar(%LJ::LJR_REVERSE_PROXIES)) {
        if ($LJ::LJR_REVERSE_PROXIES{$ip}) {
          next;
        }
        return $ip;
      }
      else {
        return $ip;
      }
    }
    return $ip; # in case we access server right from the proxy
  }

  sub filter_out_ip {
    my ($real_ip, @ips_in) = @_;
    my @ips;
    foreach my $i (@ips_in) {
      while ($i =~ /([\d]+\.[\d]+\.[\d]+\.[\d]+)/g) {
        my $t = $1;
        if ($t ne $real_ip) {
          push @ips, $t;
        }
      }
    }
    return @ips;
  }

}

return 1;
