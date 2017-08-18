#!/usr/bin/perl -w
#
# Generic database routines
#


package Golem;
use strict;

use Golem;

# courtesy of LiveJournal.org
sub disconnect_dbs {
  foreach my $h (($Golem::DB, $Golem::PlanerDB, $Golem::CalendarDB, $Golem::OtrsDB, $Golem::SwerrsDB)) {
    if ($h) {
      $h->disconnect();
      $h = undef;
    }
  }

  print STDERR localtime() . " [$$]: closed db connections\n" if $ENV{'GOLEM_DEBUG'};
}

# build DSN connection string based on database info hashref,
# courtesy of livejournal.org
#
#  $DBINFO = {
#    'master' => {
#      'dbname' => "golem_kohts",
#      'host' => "localhost",
#      'port' => 3306,
#      'user' => "root",
#      'pass' => "",
#      'sock' => "",
#      'encoding' => "utf8",
#    },
#  };
#
sub make_dbh_fdsn {
  my ($db) = @_;
  
  my $fdsn = "DBI:mysql";
  $fdsn .= ":$db->{'dbname'}";
  $fdsn .= ";host=$db->{'host'}" if $db->{'host'};
  $fdsn .= ";port=$db->{'port'}" if $db->{'port'};
  $fdsn .= ";mysql_socket=$db->{'sock'}" if $db->{'sock'};
  $fdsn .= "|$db->{'user'}|$db->{'pass'}";
  
  return $fdsn;
}

# test if connection is still available
# (should check for replication, etc. here)
#
sub connection_bad {
  my ($dbh, $try) = @_;
  
  return 1 unless $dbh;
  
  my $ss = eval {
#
#   $dbh->selectrow_hashref("SHOW SLAVE STATUS");
#
#   on a real slave
#
# $ss = {
#          'Skip_counter' => '0',
#          'Master_Log_File' => 'ararita-bin.882',
#          'Connect_retry' => '60',
#          'Master_Host' => 'ararita.lenin.ru',
#          'Relay_Master_Log_File' => 'ararita-bin.882',
#          'Relay_Log_File' => 'laylah-relay-bin.323',
#          'Slave_IO_Running' => 'Yes',
#          'Slave_SQL_Running' => 'Yes',
#          'Master_Port' => '3306',
#          'Exec_master_log_pos' => '17720151',
#          'Relay_log_space' => '19098333',
#          'Relay_Log_Pos' => '19098333',
#          'Last_errno' => '0',
#          'Last_error' => '',
#          'Replicate_do_db' => 'prod_livejournal,prod_livejournal',
#          'Read_Master_Log_Pos' => '17720151',
#          'Master_User' => 'replication',
#          'Replicate_ignore_db' => ''
#        };
    
    $dbh->selectrow_hashref("select name from _dbi");
  };
  
  if ($dbh->err && $dbh->err != 1227) {
    print STDERR localtime() . " [$$]: " . $dbh->errstr . "\n" if $ENV{'GOLEM_DEBUG'};
    return 1;
  }
  
  if ($ss && $ss->{'name'} ne '??') {
    return 0;
  }
  elsif ($ss && $ss->{'name'} eq '??') {
    print STDERR localtime() . " [$$]: DBI returned garbage: $ss->{'name'}\n" if $ENV{'GOLEM_DEBUG'};
    return 1;
  }
  elsif (!$ss) {
    print STDERR localtime() . " [$$]: DBI returned nothing\n" if $ENV{'GOLEM_DEBUG'};
    return 1;
  }
}

# LJR modification; redefined in cgi-bin/Golem.pmGolem.pm
# so it works correctly with original LJ code
#
sub golem_get_db {
  my ($params, $opts) = @_;

  $opts = {} unless $opts;
  $params = {} unless $params;

  if ($Golem::DB) {
    if (! connection_bad($Golem::DB)) {
      return $Golem::DB;
    }
    else {
      print STDERR localtime() . " [$$]: new connection: was bad\n" if $ENV{'GOLEM_DEBUG'};
      $Golem::DB->disconnect;
    }
  }
  else {
    print STDERR localtime() . " [$$]: new connection: had none\n" if $ENV{'GOLEM_DEBUG'};
  }
  undef $Golem::DB;

  # DB connection defaults (unless programmer specified them)
  #
  $params->{'RaiseError'} = 0 unless defined($params->{'RaiseError'});
  $params->{'PrintError'} = 1 unless defined($params->{'PrintError'});
  $params->{'AutoCommit'} = 1 unless defined($params->{'AutoCommit'});

  Golem::die("No Golem::DBINFO master defined")
    unless $Golem::DBINFO->{'master'};

  my $dbinfo = $Golem::DBINFO->{'master'};
  my $fdsn = make_dbh_fdsn($dbinfo);
  
  $Golem::DB = DBI->connect($fdsn, $dbinfo->{'user'}, $dbinfo->{'pass'}, $params);
  while (!$Golem::DB && $opts->{'retry_forever'}) {
    Golem::do_log("database not available, retrying", {"stderr" => 1});
    sleep 1;
    $Golem::DB = DBI->connect($fdsn, $dbinfo->{'user'}, $dbinfo->{'pass'}, $params);
  }
  Golem::die("Unable to connect to database: " . DBI->errstr)
    unless $Golem::DB;

  $Golem::DB->do("SET NAMES " . $dbinfo->{'encoding'})
    if $dbinfo->{'encoding'};

  if (connection_bad($Golem::DB)) {
    print STDERR "got fresh new bad handle, retrying\n" if $ENV{'GOLEM_DEBUG'};
    $Golem::DB = undef;
    $Golem::DB = Golem::get_db();
  }

  $Golem::default_dc_obj = Golem::get_dc($Golem::default_dc);
  return $Golem::DB;
}

sub get_planer_db {
  my ($params) = @_;

  return $Golem::PlanerDB if $Golem::PlanerDB;

  $params = {RaiseError => 0, PrintError => 1, AutoCommit => 1}
    unless $params;

  $Golem::PlanerDB = DBI->connect("DBI:Sybase:server=argo3.yandex.ru;database=planer;",
    "helpdesk", "gkfyshfcnfvfys123", $params);

  return $Golem::PlanerDB;
}

sub get_calendar_db {
  my ($params) = @_;

  return $Golem::CalendarDB if $Golem::CalendarDB;

  $params = {RaiseError => 0, PrintError =>1, AutoCommit => 1}
    unless $params;
  
  $Golem::CalendarDB = DBI->connect("DBI:Sybase:server=argo3.yandex.ru;database=momdb;",
    "staffreader", "cegthgfhjkm678", $params);

  return $Golem::CalendarDB;
}

sub get_otrs_db {
  my ($params) = @_;

  return $Golem::OtrsDB if $Golem::OtrsDB;

  $params = {RaiseError => 0, PrintError =>1, AutoCommit => 1}
    unless $params;
  
  $Golem::OtrsDB = DBI->connect("DBI:mysql:database=otrs_utf8:host=casa.yandex.ru:port=3306",
    "userorder", "xuo9Bahf", $params);

  return $Golem::OtrsDB;
}

sub get_swerrs_db {
  my ($params) = @_;

  return $Golem::SwerrsDB if $Golem::SwerrsDB;

  $params = { RaiseError => 0, PrintError => 1, AutoCommit => 1 }
    unless $params;

  $Golem::SwerrsDB = DBI->connect("DBI:mysql:racktables:localhost:3306", "swerrs", "V7Hl}O]Usr", $params);

  return $Golem::SwerrsDB;
}


sub sth_bind_array {
  my ($sth, $bound_values) = @_;

  my $i = 0;
  foreach my $b (@{$bound_values}) {
    $i++;
    
    Golem::die("error binding params")
      unless $sth->bind_param($i, $b) ;
  }
}

# courtesy of LiveJournal.org
# see also: http://dev.mysql.com/doc/refman/5.0/en/information-functions.html#function_last-insert-id
#
sub alloc_global_counter {
  my ($tag, $recurse) = @_;
  
  my $dbh = Golem::get_db();
  my $newmax;

  # in case name `counter` is already occupied
  # by some user table
  my $counter_prefix = "";
  $counter_prefix = $Golem::counter_prefix
  	if defined($Golem::counter_prefix);
	
  my $rs = $dbh->do("UPDATE ${counter_prefix}counter SET max=LAST_INSERT_ID(max+1) WHERE tag=?", undef, $tag);
  if ($rs > 0) {
    $newmax = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
    return $newmax;
  }
  
  return undef if $recurse;

  # no prior counter rows - initialize one.

  # if this is a table then trying default id column
  if ($Golem::SCHEMA_CACHE->{'tables'}->{$tag}) {
    $newmax = $dbh->selectrow_array("SELECT MAX(id) FROM `$tag`");
  }
  else {
    Golem::die("alloc_global_counter: unknown tag [$tag], unable to get max value.");
  }

  $newmax += 0;

  $dbh->do("INSERT IGNORE INTO ${counter_prefix}counter (tag, max) VALUES (?,?)",
    undef, $tag, $newmax) || return undef;

  return Golem::alloc_global_counter($tag, 1);
}

# get schema table definition,
# prepare in-memory table structure
#
sub get_schema_table {
  my ($table_name, $opts) = @_;

  return $Golem::SCHEMA_CACHE->{'tables'}->{$table_name}
    if $Golem::SCHEMA_CACHE->{'tables'}->{$table_name} &&
      !$opts->{'force'};

  delete($Golem::SCHEMA_CACHE->{'tables'}->{$table_name})
    if $Golem::SCHEMA_CACHE->{'tables'}->{$table_name};

  $Golem::SCHEMA_CACHE->{'tables'}->{$table_name}->{'fields'} = {};
  my $t = $Golem::SCHEMA_CACHE->{'tables'}->{$table_name};

  my $dbh = Golem::get_db();
  Golem::debug_sql("describe `$table_name`");
  my $sth = $dbh->prepare("describe `$table_name`");
  $sth->execute();
  Golem::die("Error describing table [$table_name]: " . $dbh->errstr)
    if $dbh->err;

  my $select_all_sql = "";
  while (my $r = $sth->fetchrow_hashref) {
    my $field_name = $r->{'Field'};

    $t->{'fields'}->{$field_name} = $r;

    if ($r->{'Type'} =~ /^enum\((.+)\)/o) {
      my $enums = $1;
      foreach my $etype (split(/,/o, $enums)) {
        $etype =~ s/'//go;
        $t->{'fields'}->{$field_name}->{'enum'}->{$etype} = 1;
      }
    }
    
    if ($r->{'Type'} eq 'timestamp') {
      $select_all_sql .= "UNIX_TIMESTAMP(`$field_name`) as `$field_name`, ";
    }
    else {
      $select_all_sql .= "`$field_name`, ";
    }

    if ($r->{'Key'} eq 'PRI') {
      $t->{'primary_key'}->{$field_name} = 1;
    }
  }
  chop($select_all_sql);
  chop($select_all_sql);

  $Golem::SCHEMA_CACHE->{'tables'}->{$table_name}->{'select_all_sql'} = $select_all_sql;

  return $Golem::SCHEMA_CACHE->{'tables'}->{$table_name};
}

# function tells whether field is data field or some special field
# like host.id (incremented with alloc_global_counter) or
# like host.last_updated (automatically updated when record is updated)
# maybe we should filter them by name instead of using db structure hints?
sub is_data_field {
  my ($table_name, $field_name, $opts) = @_;

  $opts = {} unless $opts;

  my $table = Golem::get_schema_table($table_name);
  my $table_fields = $table->{'fields'};

  if ($table_fields->{$field_name}) {
    if ($table_fields->{$field_name}->{'Default'} &&
      $table_fields->{$field_name}->{'Default'} eq 'CURRENT_TIMESTAMP' &&
      !$opts->{'ignore_default_current_timestamp'} ) {

      return 0;
    }

#    if ($table_fields->{$field_name}->{'Key'} &&
#      $table_fields->{$field_name}->{'Key'} eq 'PRI') {
#
#      return 0;
#    }

    # we have to distinguish between host.id and host_rackmap.host;
    # both are PRIMARY keys, but
    # 1) we shouldn't ever update host.id
    # 2) we have to update host_rackmap.host with host.id
    # when creating record corresponding to host record
    if ($field_name eq "id" && !$opts->{'manual_id_management'}) {
      return 0;
    }

    return 1;
  }
  else {
    return 0;
  }
}

sub __insert {
  my ($table_name, $record_hashref, $opts) = @_;

  Golem::die("Severe programmer error: __insert expects table name as first parameter!")
    unless $table_name;
  Golem::die("Severe programmer error: __insert expects record hashref as second parameter!")
    unless ref($record_hashref) eq 'HASH';

  $opts = {} unless ref($opts) eq 'HASH';

  my $dbh;
  if ($opts->{'dbh'}) {
    $dbh = $opts->{'dbh'};
  }
  else {
    $dbh = Golem::get_db();
  }

  $dbh->{'PrintError'} = $opts->{'PrintError'}
    if defined($opts->{'PrintError'});

  my $sth;

  my $table = Golem::get_schema_table($table_name);
  my $table_fields = $table->{'fields'};

  # continue only if there's data for the table
  # or if there's a flag saying we should create
  # empty record with defaults
  my $have_data_for_the_table = 0;
  while (my ($o, $v) = each(%{$record_hashref})) {
    if (Golem::is_data_field($table_name, $o, $opts)) {
      $have_data_for_the_table = 1;
    }
  }
  unless ($have_data_for_the_table || $opts->{'create_empty_record'}) {
    return $dbh;
  }

  my @record_fields;
  my @record_values;

  foreach my $o (keys %{$record_hashref}) {
    # $record_hashref might contain more fields than present in database.
    # we only choose those which are in db
    
    if ($table_fields->{$o} && Golem::is_data_field($table_name, $o, $opts)) {
      
      # enum validation
      if ($table_fields->{$o}->{'enum'}) {
        Golem::die("Enum [$table_name.$o] value is not specified and doesn't have default value")
          if !defined($record_hashref->{$o}) && $table_fields->{$o}->{'Default'} eq '';

        Golem::die("Enum [$table_name.$o] can't be [$record_hashref->{$o}]")
          if $record_hashref->{$o} && !$table_fields->{$o}->{'enum'}->{$record_hashref->{$o}};

        # if they passed empty value for enum
        # and there's some default -- silently
        # decide to use it
        unless ($record_hashref->{$o}) {
          delete($record_hashref->{$o});
          next;
        }
      }
      
      push @record_fields, $o;
      push @record_values, $record_hashref->{$o};
    }
  }

  if ($table_fields->{"id"} && !$opts->{'manual_id_management'}) {
    if ($record_hashref->{"id"}) {
      Golem::die("Severe database structure or programmer error: __insert got id [$record_hashref->{'id'}]
when creating record for table [$table_name]; won't overwrite.\n");
    }

    $record_hashref->{"id"} = Golem::alloc_global_counter($table_name);
    
    # check that id is not taken and
    # die with severe error otherwise
    #

    my $t_id = $dbh->selectrow_array("select id from `$table_name` where id = ?",
      undef, $record_hashref->{"id"});
    if ($t_id && $t_id eq $record_hashref->{"id"}) {
      Golem::die("Severe database error: __insert got [$t_id] for table [$table_name] " .
        "from alloc_global_counter which already exists!\n" .
        "Probable somebody is populating [$table_name] without Golem::__insert()\n");
    }
    
    push @record_fields, "id";
    push @record_values, $record_hashref->{"id"};
  }

  my $sql;
  my @bound_values;

  $sql = "INSERT INTO `$table_name` ( ";
  foreach my $o (@record_fields) {
    $sql = $sql . " `$o`,";
  }
  chop($sql);

  $sql .= " ) VALUES ( ";

  my $i = 0;
  foreach my $o (@record_values) {

    # we represent timestamp datatype as unixtime (http://en.wikipedia.org/wiki/Unix_time)
    # doing all the conversions almost invisible to the end user
    #
    # if the value being written is 0 then we're not using FROM_UNIXTIME(value)
    # (which generates warnings) just value
    #
    if ($table_fields->{$record_fields[$i]}->{'Type'} eq 'timestamp' && $o && $o != 0) {
      Golem::die("Programmer error: __insert got hashref with invalid data for $table_name.$record_fields[$i] (should be unixtime)")
        unless $o =~ /^[0-9]+$/o;

      $sql = $sql . "FROM_UNIXTIME(?),";
    }
    else {
      $sql = $sql . "?,";
    }

    push @bound_values, $o;
    $i++;
  }
  chop($sql);
  $sql .= " )";

  Golem::debug_sql($sql, \@bound_values);

  $sth = $dbh->prepare($sql);
  Golem::sth_bind_array($sth, \@bound_values);
  $sth->execute();

  if ($dbh->err && $dbh->{'PrintError'}) {
    Golem::do_log("got error [" . $dbh->err . "] [" . $dbh->errstr . "]" .
      " while executing [$sql] with values (" . join(",", @bound_values) . ")",
      {'stderr' => 1});
  }

  return $dbh;
}

sub __update {
  my ($table_name, $record_hashref, $opts) = @_;

  Golem::die("Severe programmer error: __update expects table name as first parameter!")
    unless $table_name;
  Golem::die("Severe programmer error: __update expects record hashref as second parameter!")
    unless ref($record_hashref) eq 'HASH';

  $opts = {} unless ref($opts) eq 'HASH';

  my $dbh;
  if ($opts->{'dbh'}) {
    $dbh = $opts->{'dbh'};
  }
  else {
    $dbh = Golem::get_db();
  }

  my $sth;

  my $table = Golem::get_schema_table($table_name);
  my $table_fields = $table->{'fields'};
  my $unique_fields_arrayref = [keys %{$table->{'primary_key'}}];

  if ($opts->{'unique_fields'}) {
    $unique_fields_arrayref = $opts->{'unique_fields'};
  }

  # continue only if there's data for the table
  # in the in-memory hash or if there's a flag
  # saying we should create empty record with defaults
  #
  my $have_data_for_the_table = 0;
  while (my ($o, $v) = each(%{$record_hashref})) {
    if (Golem::is_data_field($table_name, $o)) {
      my $is_unique = 0;

      foreach my $u (@{$unique_fields_arrayref}) {
        if ($u eq $o) {
          $is_unique = 1;
        }
      }
      next if $is_unique;

      $have_data_for_the_table = 1;
    }
  }
  unless ($have_data_for_the_table || $opts->{'create_empty_record'}) {
    return $dbh;
  }

  my $sql;
  my @bound_values;

  $sql = "SELECT " . $table->{'select_all_sql'} . " from `$table_name` WHERE ";
  foreach my $f (@{$unique_fields_arrayref}) {
    if ($table_fields->{$f}->{'Type'} eq 'timestamp' && $record_hashref->{$f} != 0) {
      Golem::die("Programmer error: __update got hashref with invalid data for $table_name.$f (should be unixtime)")
        unless $record_hashref->{$f} =~ /^[0-9]+$/o;

      $sql .= " `$f` = FROM_UNIXTIME(?) and ";
    }
    else {
      $sql .= " `$f` = ? and ";
    }
    push @bound_values, $record_hashref->{$f};
  }
  # remove last "and "
  chop($sql);
  chop($sql);
  chop($sql);
  chop($sql);

  $sth = $dbh->prepare($sql);
  Golem::sth_bind_array($sth, \@bound_values);
  $sth->execute();

  # create record if it doesn't exist: useful when updating
  # records in dependent tables (hosts_resps, hosts_netmap, host_rackmap)
  # when master table exists.
  unless ($sth->rows) {
    if ($opts->{"create_nonexistent"}) {
      $dbh = Golem::__insert($table_name, $record_hashref, $opts);
      return $dbh;
    }
    else {
      Golem::die("Programmer error: requested to update non-existent record with no create_nonexistent option");
    }
  }

  my $existing_row;
  while(my $r = $sth->fetchrow_hashref()) {
    Golem::debug_sql($sql, \@bound_values);
    Golem::die("more than 1 record fetched with should-be-unique lookup")
      if $existing_row;

    $existing_row = $r;
  }
  
  # check that existing record differs somehow from record to be written
  my $records_differ = 0;
  while (my ($k, $v) = each %{$existing_row}) {
    if (Golem::is_data_field($table_name, $k)) {
      
      # what a mess!
      utf8::decode($record_hashref->{$k});
      utf8::decode($v);
      
      if (
          ($record_hashref->{$k} && $v && $v ne $record_hashref->{$k}) ||
          (! $record_hashref->{$k} && $v) ||
          ($record_hashref->{$k} && ! $v)
        ) {

        Golem::debug_sql("in-memory [$table_name] object field [$k] differs: [" .
          ($record_hashref->{$k} ? $record_hashref->{$k} : "") . "
          ] -- [" .
          ($v ? $v : "") .
          "]");

        $records_differ = 1;
        last;
      }
    }
  }

  # don't update database if that wouldn't actually
  # change any data; we should save A LOT of time here
  #
  return $dbh unless $records_differ;

  @bound_values = ();
  $sql = "";
  while (my ($o, $v) = each(%{$record_hashref})) {
    # $record_hashref might contain more fields than present in database.
    # we only choose those which are in db
    if ($table_fields->{$o} && Golem::is_data_field($table_name, $o)) {
      if ($table_fields->{$o}->{'Type'} eq 'timestamp' && $record_hashref->{$o} && $record_hashref->{$o} != 0) {
        Golem::die("Programmer error: __update got hashref with invalid data for $table_name.$o (should be unixtime)")
          unless $record_hashref->{$o} =~ /^[0-9]+$/o;

        $sql = $sql . " `$o` = FROM_UNIXTIME(?),";
      }
      else {
        $sql = $sql . " `$o` = ?,";
      }
      push @bound_values, $record_hashref->{$o};
    }
  }
  chop($sql);

  $sql = "UPDATE `$table_name` SET " . $sql . " WHERE ";
  foreach my $f (@{$unique_fields_arrayref}) {
    $sql .= " `$f` = ? and ";
    push @bound_values, $record_hashref->{$f};
  }
  # remove last "and "
  chop($sql);
  chop($sql);
  chop($sql);
  chop($sql);

  Golem::debug_sql($sql, \@bound_values);

  $sth = $dbh->prepare($sql);
  Golem::sth_bind_array($sth, \@bound_values);
  $sth->execute();

  if ($dbh->err) {
    Golem::do_log("error executing: $sql; bound values: " . join(",", @bound_values), {"stderr" => 1});
  }

  return $dbh;
}


sub __delete {
  my ($table_name, $record_hashref, $opts) = @_;

  Golem::die("Severe programmer error: __delete expects table name as first parameter!")
    unless $table_name;
  Golem::die("Severe programmer error: __delete expects record hashref as second parameter!")
    unless ref($record_hashref) eq 'HASH';
  
  $opts = {} unless ref($opts) eq 'HASH';

  my $dbh;
  if ($opts->{'dbh'}) {
    $dbh = $opts->{'dbh'};
  }
  else {
    $dbh = Golem::get_db();
  }

  my $sth;
  
  my $table = Golem::get_schema_table($table_name);
  my $table_fields = $table->{'fields'};
  my $unique_fields_arrayref = [keys %{$table->{'primary_key'}}];

  if ($opts->{'unique_fields'}) {
    $unique_fields_arrayref = $opts->{'unique_fields'};
  }

  my @bound_values = ();
  my $sql = "DELETE FROM `$table_name` WHERE ";

  foreach my $f (@{$unique_fields_arrayref}) {
    $sql .= " `$f` = ? and ";
    push @bound_values, $record_hashref->{$f};
  }
  # remove last "and "
  chop($sql);
  chop($sql);
  chop($sql);
  chop($sql);

  $sth = $dbh->prepare($sql);
  Golem::sth_bind_array($sth, \@bound_values);
  $sth->execute();

  if ($dbh->err) {
    Golem::do_log("error executing: $sql; bound values: " . join(",", @bound_values), {"stderr" => 1});
  }

  return $dbh;
}


1;
