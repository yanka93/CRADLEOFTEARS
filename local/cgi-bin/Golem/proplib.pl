#!/usr/bin/perl -w
#
# Properties manipulation routines
#
#
# This is an object property library which
# implements DB -> MEMORY (load_props)
# and MEMORY -> DB (save_props) transition
# of object properties
#
# Object is defined as a record in some TABLE
# (called owner). To be able to use properties
# for the given TABLE you should create
# another two tables: TABLEprop and TABLEpropblob
#
# Example for host object:
#
#   CREATE TABLE `hostprop` (
#     `hostid` int(11) NOT NULL,
#     `propid` smallint(6) NOT NULL default '0',
#     `propseq` int(11) NOT NULL default '0',
#     `value` varchar(1024) default NULL,
#     PRIMARY KEY  (`hostid`,`propid`,`propseq`),
#     KEY `prop` (`propid`)
#   ) ENGINE=InnoDB DEFAULT CHARSET=utf8
#
#   CREATE TABLE `hostpropblob` (
#     `hostid` int(11) NOT NULL,
#     `propid` smallint(6) NOT NULL default '0',
#     `propseq` int(11) NOT NULL default '0',
#     `value` blob,
#     PRIMARY KEY  (`hostid`,`propid`,`propseq`),
#     KEY `prop` (`propid`)
#   ) ENGINE=InnoDB DEFAULT CHARSET=utf8
#
# After that you should create "allowed" properties
# for the owner using `gconsole.pl --create-proplist`
#
# You could see all the defined properties for the owner
# using gconsole.pl --list-proplist OWNER
#
#
# For the owner (tables) which primary key is not simple
# id auto_increment (as in the example above) the following
# TABLEprop and TABLEpropblob structure should be used:
#

package Golem;
use strict;

use Golem;

use Storable;


# check that given property owner is valid
# currently there are two valid property owners: host, user
# 
sub check_prop_owner {
  my ($owner) = @_;

  Golem::die("Programmer error: check_prop_owner got empty prop owner")
    unless $owner;

  my $props = {
    "eventhistory" => 1,
    "host" => 1,
    "user" => 1,
    "net_v4" => 1,
    };

  Golem::die("Programmer error: not valid property owner [$owner]")
    unless defined($props->{$owner});
}

# get property definition record(s) from database
# for the specified owner
#
sub get_proplist {
  my ($owner, $hpname) = @_;

  Golem::die("Programmer error: get_proplist expects at least owner")
    unless $owner;

  Golem::check_prop_owner($owner);

  my $dbh = Golem::get_db();
  my $sth;
  my $ret;

  if ($hpname) {
    $sth = $dbh->prepare("SELECT * FROM proplist WHERE owner = ? and name = ?");
    $sth->execute($owner, $hpname);
    $ret = $sth->fetchrow_hashref();
    $ret = 0 unless $ret->{'id'};
  }
  else {
    $sth = $dbh->prepare("SELECT * FROM proplist where owner = ?");
    $sth->execute($owner);
    while (my $r = $sth->fetchrow_hashref()) {
      $ret->{$r->{'name'}} = $r;
    }
  }

  return $ret;
}

sub create_proplist {
  my ($owner, $op) = @_;

  Golem::die("Programmer error: create_proplist expects at least owner and property name")
    unless $owner && $op && $op->{'name'};

  Golem::check_prop_owner($owner);
    
  my $eop = Golem::get_proplist($owner, $op->{'name'});
  Golem::die("proplist record already exists [$eop->{'name'} ($eop->{'id'})]")
    if $eop;

  $op->{'owner'} = $owner;

  my $dbh = Golem::__insert("proplist", $op);
  Golem::die("Error creating proplist: " . $dbh->errstr, $op)
    if $dbh->err;

  $op->{'id'} = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
  
  Golem::do_log("new proplist record: [$op->{'owner'}/$op->{'name'}] ($op->{'id'})");
  
  return $op;
}

sub delete_proplist {
  my ($owner, $op) = @_;

  Golem::die("Programmer error: delete_proplist expects proplist record")
    unless $op && $op->{'id'} && $op->{'name'};

  Golem::check_prop_owner($owner);

  my $eop = Golem::get_proplist($owner, $op->{'name'});
  
  return Golem::err("delete_proplist: invalid proplist record")
    unless $eop;

  my $dbh = Golem::get_db();
  my $objs_with_prop =
    $dbh->selectrow_array("select count(*) from ${owner}prop where propid = ?", undef, $op->{'id'}) +
    $dbh->selectrow_array("select count(*) from ${owner}propblob where propid = ?", undef, $op->{'id'})
    ;

  return Golem::err("delete_proplist: unable to delete proplist record; $objs_with_prop records are using it")
    if $objs_with_prop;

  $dbh->do("delete from proplist where id = ?", undef, $op->{'id'});

  return Golem::err("error while deleting from proplist: " . $dbh->errstr)
    if $dbh->err;

  return {};
}

# read object properties for the given owner
# (exactly matches table name)
#
sub load_props {
  my ($owner, $o) = @_;

  Golem::die("Programmer error: load_props expects owner name and object")
    unless $owner && ref($o);

  Golem::check_prop_owner($owner);

  my $table = Golem::get_schema_table($owner);
  my $pk = $table->{'primary_key'};

  my $dbh = Golem::get_db();
  my $sth;
  
  $o->{'props'}->{'data'} = {};

  foreach my $t ("${owner}prop", "${owner}propblob") {
    my $sql = "select * from $t inner join proplist on proplist.id = $t.propid WHERE 1 ";
    my @bound_values = ();
    while (my ($pk_field, $dummy) = each %{$table->{'primary_key'}}) {
      if ($pk_field eq 'id') {
        $sql .= " and `${owner}id` = ? ";
      }
      else {
        $sql .= " and `$pk_field` = ? ";
      }

      Golem::die("Programmer error: load_props got empty value for primary key field [$pk_field] of table [$owner]")
        unless defined($o->{$pk_field});

      push (@bound_values, $o->{$pk_field});
    }
    $sth = $dbh->prepare($sql);
    Golem::sth_bind_array($sth, \@bound_values);
    $sth->execute();

    while (my $r = $sth->fetchrow_hashref()) {
      my $v;

      if ($t eq "${owner}prop") {
        $v = $r->{'value'};
      }
      if ($t eq "${owner}propblob") {
#        print STDERR Storable::thaw($r->{'value'});
        $v = Storable::thaw($r->{'value'});
      }
    
      if ($r->{'datatype'} eq 'array' || $r->{'datatype'} eq 'arrayblob') {
        $o->{'props'}->{'data'}->{$r->{'name'}} = []
          unless defined($o->{'props'}->{'data'}->{$r->{'name'}});

        push (@{$o->{'props'}->{'data'}->{$r->{'name'}}}, $v);
      }
      else {
        $o->{'props'}->{'data'}->{$r->{'name'}} = $v;
      }
    }
  }

  $o->{'props'}->{'loaded'} = 1;

  return $o;
}

# save properties from memory into database
# checks that properties were loaded using load_props
# (for advanced users: "loaded" is the key of check,
# it is set by load_props which could be emulated)
#
sub save_props {
  my ($owner, $o) = @_;

  Golem::die("Programmer error: save_props expects owner name and object")
    unless $owner && ref($o);

  Golem::check_prop_owner($owner);

  return Golem::err("Programmer error: save_props should be called only after calling load_props")
    unless $o->{'props'}->{'loaded'};

  my $table = Golem::get_schema_table($owner);
  my $pk = $table->{'primary_key'};

  my $dbh = Golem::get_db();

  while (my ($k, $v) = each %{$o->{'props'}->{'data'}}) {
    my $op = Golem::get_proplist($owner, $k);
    
    unless ($op) {
      Golem::do_log("Non-existent $owner property name [$k], skipping.", {"stderr" => 1});
      next;
    }

    my $do_save = sub {
      my ($value, $seq) = @_;

      $seq = 0 unless defined($seq);
      
      my $tpref = "";
      my $db_value;

      if ($op->{'datatype'} eq 'blob' || $op->{'datatype'} eq 'arrayblob') {
        $db_value = Storable::nfreeze($value);
        $tpref = "blob";
      }
      else {
        $db_value = $value;

        if ($op->{'datatype'} eq 'bool') {
          $db_value = $value ? 1 : 0;
        }
      }

      my $prop_ref =  {
        "propid" => $op->{'id'},
        "propseq" => $seq,
        "value" => $db_value,
        };
      
      while (my ($pk_field, $dummy) = each %{$table->{'primary_key'}}) {
        if ($pk_field eq 'id') {
          $prop_ref->{"${owner}id"} = $o->{$pk_field};
        }
        else {
          $prop_ref->{$pk_field} = $o->{$pk_field};
        }
      }

      $dbh = Golem::__update("${owner}prop${tpref}", $prop_ref, {"create_nonexistent" => 1});
      Golem::die("save_props: error while replacing ${owner} props: " . $dbh->errstr)
        if $dbh->err;
    };

    if ($op->{'datatype'} eq 'array' || $op->{'datatype'} eq 'arrayblob') {
      my $i = 0;
      foreach my $array_value (@{$v}) {
        $do_save->($array_value, $i);
        $i = $i + 1;
      }
      
      my $tpref = "";
      if ($op->{'datatype'} eq 'arrayblob') {
        $tpref = "blob";
      }

      my $sql = "delete from ${owner}prop${tpref} where 1 ";
      my @bound_values = ();
      while (my ($pk_field, $dummy) = each %{$table->{'primary_key'}}) {
        if ($pk_field eq 'id') {
          $sql .= " and ${owner}id = ? ";
        }
        else {
          $sql .= " and $pk_field = ? ";
        }
        push (@bound_values, $o->{$pk_field});
      }
      $sql .= " and propid = ? and propseq >= ?";
      push (@bound_values, $op->{'id'});
      push (@bound_values, $i);

      my $sth = $dbh->prepare($sql);
      Golem::sth_bind_array($sth, \@bound_values);
      $sth->execute();
    }
    else {
      $do_save->($v, 0);
    }
  }

  return $o;
}

# deletes object property if no objects
# are associated with the property
#
# input
#   owner type (for the listing see check_prop_owner)
#   object (with $obj->{'id'} defined)
#   property name to delete
#
sub delete_prop {
  my ($owner, $obj, $propname) = @_;

  Golem::die("Programmer error: delete_prop expects owner and object")
    unless $owner && ref($obj);

  Golem::check_prop_owner($owner);

  my $op = Golem::get_proplist($owner, $propname);
  return Golem::err("delete_prop: invalid propname [$propname]")
    unless $op;

  my $table = Golem::get_schema_table($owner);
  my $pk = $table->{'primary_key'};

  my $dbh = Golem::get_db();
  
  my $tpref = "";
  if ($op->{'datatype'} eq 'blob' || $op->{'datatype'} eq 'blobarray') {
    $tpref = "blob";
  }
  
  my $sql = "delete from ${owner}prop${tpref} where 1 ";
  my @bound_values = ();
  while (my ($pk_field, $dummy) = each %{$table->{'primary_key'}}) {
    if ($pk_field eq 'id') {
      $sql .= " and ${owner}id = ? ";
    }
    else {
      $sql .= " and $pk_field = ? ";
    }
    push (@bound_values, $obj->{$pk_field});
  }
  $sql .= " and propid = ? ";
  push (@bound_values, $op->{'id'});

  my $sth = $dbh->prepare($sql);
  Golem::sth_bind_array($sth, \@bound_values);
  $sth->execute();

  Golem::die("delete_prop: error deleting $owner [$obj->{'id'}] property [$propname]: " . $dbh->errstr)
    if $dbh->err;

  return {};
}


1;
