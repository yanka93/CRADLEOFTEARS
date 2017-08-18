#!/usr/bin/perl
#

use SOAP::Lite;

sub SOAP::Transport::HTTP::Client::get_basic_credentials
{       
    return $LJ::BIGIP_USER => $LJ::BIGIP_PASS;
}

$maint{'echo'} = sub
{
    my (@args) = @_;
    print "echo: @args\n";
};

$maint{'echosleep'} = sub
{
    my ($sleep, @args) = @_;
    print "echosleep: @args\n";
    sleep $sleep;
};

$maint{'debug'} = sub
{
    my (@args) = @_;
    print "debug: @args\n";
    print "\$LJ::HOME = $LJ::HOME\n";
    print "whoami? ", `whoami`;
    print "\$< = $<, \$> = $>\n";
    print "ENV:\n";
    foreach (keys %ENV) {
        print "  $_ = $ENV{$_}\n";
    }
};

$maint{'apgrace'} = sub
{
  unless ($> == 0) {
    print "Only root can restart apache\n";
    return 0;
  }

  print "Gracefully restarting apache...\n";
  system("/usr/sbin/apachectl", "graceful");
  print "Done.\n";
};

$maint{'appgrace'} = sub
{
  unless ($> == 0) {
    print "Only root can restart apache-perl\n";
    return 0;
  }

  print "Gracefully restarting apache-perl...\n";
  system("/usr/sbin/apache-perl-ctl", "graceful");
  print "Done.\n";
};

$maint{'appss'} = sub
{
  unless ($> == 0) {
    print "Only root can stop/start apache-perl\n";
    return 0;
  }

  open (BC, "$ENV{'LJHOME'}/.bigip_soap.conf");
  my $line = <BC>;
  chomp $line;
  ($LJ::BIGIP_HOST, $LJ::BIGIP_PORT, $LJ::BIGIP_USER, $LJ::BIGIP_PASS) 
      = split(/\s+/, $line);
  close BC;
  my $soap;
  if ($LJ::BIGIP_HOST) {
      $soap = SOAP::Lite
          -> uri('urn:iControl:ITCMLocalLB/Node')
          -> readable(1)
          -> proxy("https://${LJ::BIGIP_HOST}:${LJ::BIGIP_PORT}/iControl/iControlPortal.cgi");
  }
  
  my $ifconfig = `/sbin/ifconfig -a`;
  my $ip;
  if ($ifconfig =~ /addr:(10\.0\.\S+)/) {
      $ip = $1;
  }

  my $node_config = sub {
      return 0 unless $soap && $ip;
      my $state = shift;
      $state = $state ? 1 : 0;

      my $node_definition = { address => $ip, port => 80 };
      my $soap_response = $soap->set_state(SOAP::Data->name(node_defs => ( [$node_definition] )),
                                           SOAP::Data->name(state => $state));
      if ($soap_response->fault) {
          print $soap_response->faultcode, " ", $soap_response->faultstring, "\n";
          return 0;
      }
      return 1;
  };

  print "Stopping & starting apache-perl...\n";
  if ($node_config->(0)) {
      print "Node disabled on BIG-IP.\n";
  }
  system("/usr/sbin/apache-perl-ctl", "stop");
  while (-e "/var/run/apache-perl.pid") {
      sleep 1;
  }
  system("/usr/sbin/apache-perl-ctl", "start");
  if ($node_config->(1)) {
      print "Node enabled on BIG-IP.\n";
  }
  print "Done.\n";
};

$maint{'sshkick'} = sub
{
  unless ($> == 0) {
    print "Only root can stop/start ssh\n";
    return 0;
  }

  print "Stopping & starting ssh...\n";
  system("/etc/init.d/ssh", "restart");
  print "Done.\n";
};

$maint{'statscaster_restart'} = sub
{
  unless ($> == 0) {
    print "Only root can stop/start statscaster\n";
    return 0;
  }

  print "Stopping & starting statscaster...\n";
  system("cp", "$ENV{LJHOME}/bin/lj-init.d/ljstatscasterd", "/etc/init.d/ljstatscasterd");
  system("chmod", "+x", "/etc/init.d/ljstatscasterd");
  system("/etc/init.d/ljstatscasterd", "restart");
  print "Done.\n";
};

$maint{'aprestart'} = sub
{
  unless ($> == 0) {
    print "Only root can restart apache\n";
    return 0;
  }

  print "Restarting apache...\n";
  system("/usr/sbin/apachectl", "restart");
  print "Done.\n";
};

$maint{'hupcaches'} = sub
{
    if ($> == 0) {
        print "Don't run this as root.\n";
        return 0;
    }
    foreach my $proc (qw(404notfound.cgi users customview.cgi bmlp.pl interface))
    {
        print "$proc...";
        print `$LJ::BIN/hkill $proc | wc -l`;
    }
};

$maint{'restartapps'} = sub
{
    if ($> == 0) {
        print "Don't run this as root.\n";
        return 0;
    }
    my $pid;
    if ($pid = fork) 
    {
        print "Started.\n";
        return 1;
    }

    foreach my $proc (qw(404notfound.cgi users customview.cgi interface)) {
        system("$LJ::BIN/pkill", $proc);
    }
};

$maint{'load'} = sub
{
    print ((`w`)[0]);
   
};

$maint{'date'} = sub
{
    print ((`date`)[0]);
   
};

$maint{'exposeconf'} = sub
{
    print "-I- Copying configuration files to /misc/conf\n";
    my @files = qw(
                   /usr/src/sys/i386/conf/KENNYSMP   kernel-config.txt
                   /etc/postfix/main.cf              postfix-main.cf.txt
                   /etc/postfix/master.cf            postfix-master.cf.txt
                   );
                   
    while (@files) {
        my $src = shift @files;
        my $dest = shift @files;
        print "$src -> $dest\n";
        system("cp", $src, "$LJ::HTDOCS/misc/conf/$dest");
    }
    print "done.\n";
};
