#!/usr/bin/perl -w
#
# networking related routines
#


package Golem;
use strict;

use Golem;

sub get_external_ipinfo {
  my ($ip) = @_;

  return undef unless $ip && $Golem::noc_nets_cgi;

  my $ipinfo;
  my @net_info;

  my $wget_options = "";
  $wget_options = "--timeout=${Golem::noc_nets_cgi_timeout}"
    if $Golem::noc_nets_cgi_timeout;

  open(NOCNET,"wget $wget_options -q -O - ${Golem::noc_nets_cgi}?name=$ip |");

  Golem::debug("wget $wget_options -q -O - ${Golem::noc_nets_cgi}?name=$ip |");

  my $line;
  while($line=<NOCNET>) {
    if ($line=~/^<tr align=center>/) {
      chomp($line);
      $line =~ s/<\/td><td>/\|/g;
      $line =~ s/(<td>|<tr align=center>|<\/tr>|<\/td>)//g;
      @net_info= split(/\|/,$line,5);
    }
  }
  close(NOCNET);

  if (@net_info) {
    $ipinfo->{'ip'} = $net_info[0];
    $ipinfo->{'subnet'} = $net_info[1];
    $ipinfo->{'router'} = $net_info[2];
    $ipinfo->{'iface'} = $net_info[3];

    $ipinfo->{'vlan'} = $ipinfo->{'iface'};
    $ipinfo->{'vlan'} =~ /(\d+)/;
    $ipinfo->{'vlan'} = $1;

    $ipinfo->{'router_if_addr'} = $net_info[4];
  }

  return $ipinfo;
}

# --- ghetto code
sub int2maskpart {
  my ($i) = @_;
  return "0" unless defined($i);

  my $j = 0;
  my $bits = "";
  while ($j < 8) {
    if ($i <= $j) {
      $bits .= "0";
    }
    else {
      $bits .= "1";
    }
    $j++;
  }
  return oct("0b" . $bits);
}


sub mask2netmask {
  my ($j) = @_;

  my @ip;
  my $i;
  for ($i = 1; $i <= int($j / 8); $i++) {
    push @ip, int2maskpart(8);
  }
  while ($i < 5) {
    push @ip, int2maskpart($j % 8);
    $j = 0;
    $i++;
  }

  return join(".", @ip);
}


# convert string representation of ipv4 address into integer
sub ipv4_str2int {
  my ($ip_string) = @_;

  if ($ip_string =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
    return (16777216 * $1) + (65536 * $2) + (256 * $3) + $4;
  }
  else {
    return 0;
  }
}

# convert integer representation of ipv4 address into string
sub ipv4_int2str {
  my ($ip_int) = @_;

  if ($ip_int >= 0  && $ip_int <= 4294967295) {
    my $w = ($ip_int / 16777216) % 256;
    my $x = ($ip_int / 65536) % 256;
    my $y = ($ip_int / 256) % 256;
    my $z = $ip_int % 256;

    return $w . "." . $x . "." . $y . "." . $z;
  }
  else {
    return 0;
  }
}

# /24 -> +255
# /27 -> +31
# /28 -> +15
# /29 -> +7
sub ipv4_mask2offset {
  my ($mask) = @_;
  $mask ||= 0;
  my $offset = 2 ** (32 - $mask);
  return $offset - 1;
}

sub get_net {
  my ($ip, $mask, $opts) = @_;

  Golem::trim(\$ip);
  
  Golem::die("Programmer error: get_net expects net and mask")
    unless
    	($ip && $mask && Golem::is_digital($mask)) ||
    	($ip =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d{1,2}$/);

  if ($ip =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\/(\d{1,2})$/o) {
    $ip = ipv4_str2int($1);
    $mask = $2;
  }
  elsif ($ip =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/o) {
    $ip = ipv4_str2int($1);
  }

  my $dbh = Golem::get_db();
  my $sth = $dbh->prepare("SELECT * FROM net_v4 WHERE ip = ? and mask = ?");
  $sth->execute($ip, $mask);
  my $net = $sth->fetchrow_hashref();
  $sth->finish();

  if ($net->{'id'}) {
    return Golem::get_net_by_id($net->{'id'}, $opts);
  }
  else {
    return 0;
  }
}

sub get_net_by_id {
	my ($id, $opts) = @_;

	Golem::die("Programmer error: get_net_by_id expects network id")
		unless $id;

	$opts = {} unless $opts;

  my $dbh = Golem::get_db();
  my $sth = $dbh->prepare("SELECT * FROM net_v4 WHERE id = ?");
	
  $sth->execute($id);

	my $r = $sth->fetchrow_hashref();
	if ($r->{'id'}) {
    $r->{'ip_str'} = Golem::ipv4_int2str($r->{'ip'});
    $r->{'net_with_mask'} = $r->{'ip_str'} . "/" . $r->{'mask'};
    if ($r->{'name'} =~ /VLAN([\d]+)/o) {
      $r->{'vlan'} = $1;
    }
    else {
      $r->{'vlan'} = "";
    }

	  if ($opts->{'with_props'} || $opts->{'with_all'}) {
  	  $r = Golem::load_props("net_v4", $r);
  	}

    return $r;
	}
	else {
	  return 0;
	}
}

sub insert_net {
  my ($net) = @_;

  Golem::die("Programmer error: insert_net expects net object")
    unless $net && ($net->{'ip_str'} || $net->{'ip'}) &&
      $net->{'mask'} && $net->{'name'};
  
  if ($net->{'ip_str'}) {
    $net->{'ip'} = Golem::ipv4_str2int($net->{'ip_str'});
  }

  my $enet = Golem::get_net($net->{'ip'}, $net->{'mask'});
  return Golem::err("net already exists [$enet->{'ip_str'}/$enet->{'$mask'} ($enet->{'id'})]")
    if $enet;

  my $dbh = Golem::__insert("net_v4", $net);
  return Golem::err($dbh->errstr, $net)
    if $dbh->err;

  $net->{'id'} = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");

  return Golem::get_net_by_id($net->{'id'});
}

sub save_net {
  my ($net) = @_;

  Golem::die("Programmer error: save_net expects net object")
    unless $net && $net->{'id'} &&
      ($net->{'ip_str'} || $net->{'ip'}) &&
      $net->{'mask'} && $net->{'name'};
  
  if ($net->{'ip_str'}) {
    $net->{'ip'} = Golem::ipv4_str2int($net->{'ip_str'});
  }

  my $enet = Golem::get_net($net->{'ip'}, $net->{'mask'}, {"with_all" => 1});

  if ($enet) {
    my $dbh = Golem::__update("net_v4", $net);
    return Golem::err($dbh->errstr, $net)
      if $dbh->err;

		$net = Golem::save_props("net_v4", $net);
  }
  else {
    return Golem::insert_net($net);
  }

  return $net;
}

sub delete_net {
  my ($net) = @_;

  Golem::die("Programmer error: delete_net expects net object")
    unless $net && $net->{'id'};
  
  my $dbh = Golem::get_db();

  Golem::unset_row_tag("net_v4", $net->{'id'});
  $dbh->do("DELETE from net_v4prop where net_v4id = ?", undef, $net->{'id'});
  $dbh->do("DELETE from net_v4propblob where net_v4id = ?", undef, $net->{'id'});
  
  $dbh->do("DELETE FROM net_v4 WHERE net_v4.id = ?", undef, $net->{'id'});
  return Golem::err($dbh->errstr, $net)
    if $dbh->err;

  return {};
}

sub get_containing_net {
  my ($ip, $opts) = @_;

  Golem::die("Programmer error: get_containing_net expects ip address")
    unless $ip;

  Golem::trim(\$ip);
  if ($ip =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/o) {
    $ip = Golem::ipv4_str2int($1);
  }
  
  my $dbh = Golem::get_db();
  
  # choose nearest (by ip desc) and smallest (by mask desc) known network
  my $sth = $dbh->prepare("SELECT * FROM net_v4 WHERE ip < ? and mask <> 32
    order by ip desc, mask desc");

  $sth->execute($ip);

  my $net;

  while(my $r = $sth->fetchrow_hashref()) {
    # choose first network that includes tested ip address if any
    if ($r->{'ip'} + ipv4_mask2offset($r->{'mask'}) ge $ip) {
      return Golem::get_net_by_id($r->{'id'}, $opts);
    }
  }

  return 0;
}

sub get_net_by_vlan {
  my ($vlan, $opts) = @_;

  Golem::die("Programmer error: get_net_by_vlan expects vlan name")
    unless $vlan;

  $vlan =~ s/vlan//go;
  $vlan =~ s/\s//go;

  my $dbh = Golem::get_db();
  my $sth = $dbh->prepare("SELECT * FROM net_v4 WHERE mask <> 32 and name like ? order by name");
  $sth->execute("VLAN${vlan}%");

  while (my $r = $sth->fetchrow_hashref()) {
    if ($r->{'name'} =~ /VLAN${vlan}\s/o) {
      return Golem::get_net($r->{'ip'}, $r->{'mask'}, $opts);
    }
  }

  return 0;
}

sub is_ipv4 {
  my ($str) = @_;
  return $str =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/o;
}


1;
