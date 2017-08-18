#!/usr/bin/perl
#
# This program will bring your LiveJournal database schema up-to-date
#

use strict;
use lib "$ENV{LJHOME}/cgi-bin";

use Getopt::Long;
use File::Path ();
use File::Basename ();
use File::Copy ();
use Image::Size ();
BEGIN { require "ljlib.pl";
        require "ljviews.pl"; }
use LJ::S2;
use MogileFS;

my $opt_sql = 0;
my $opt_drop = 0;
my $opt_pop = 0;
my $opt_confirm = "";
my $opt_skip = "";
my $opt_help = 0;
my $cluster = 0;   # by default, upgrade master.
my $opt_listtables;
my $opt_forcebuild = 0;
my $opt_compiletodisk = 0;
my $opt_innodb;
exit 1 unless
GetOptions("runsql" => \$opt_sql,
           "drop" => \$opt_drop,
           "populate" => \$opt_pop,
           "confirm=s" => \$opt_confirm,
           "cluster=s" => \$cluster,
           "skip=s" => \$opt_skip,
           "help" => \$opt_help,
           "listtables" => \$opt_listtables,
           "forcebuild|fb" => \$opt_forcebuild,
           "ctd" => \$opt_compiletodisk,
           "innodb" => \$opt_innodb,
           );

if ($opt_help) {
    die "Usage: update-db.pl
  -r  --runsql       Actually do the SQL, instead of just showing it.
  -p  --populate     Populate the database with the latest required base data.
  -d  --drop         Drop old unused tables (default is to never)
      --cluster=<n>  Upgrade cluster number <n> (defaut,0 is global cluster)
      --cluster=<n>,<n>,<n>
      --cluster=user Update user clusters
      --cluster=all  Update user clusters, and global
  -l  --listtables   Print used tables, one per line.
";
}

## make sure $LJHOME is set so we can load & run everything
unless (-d $ENV{'LJHOME'}) {
    die "LJHOME environment variable is not set, or is not a directory.\n".
        "You must fix this before you can run this database update script.";
}

die "Can't --populate a cluster" if $opt_pop && $cluster;

my @clusters;
foreach my $cl (split(/,/, $cluster)) {
    die "Invalid cluster spec: $cl\n" unless
        $cl =~ /^\s*((\d+)|all|user)\s*$/;
    if ($cl eq "all") { push @clusters, 0, @LJ::CLUSTERS; }
    elsif ($cl eq "user") { push @clusters, @LJ::CLUSTERS; }
    else { push @clusters, $1; }
}
@clusters = (0) unless @clusters;

my %status;          # clusterid -> string
my %clustered_table; # $table -> 1
my $sth;
my %table_exists;   # $table -> 1
my %table_unknown;  # $table -> 1
my %table_create;   # $table -> $create_sql
my %table_drop;     # $table -> 1
my %table_status;   # $table -> { SHOW TABLE STATUS ... row }
my %post_create;    # $table -> [ [ $action, $what ]* ]
my %coltype;        # $table -> { $col -> $type }
my %indexname;      # $table -> "INDEX"|"UNIQUE" . ":" . "col1-col2-col3" -> "PRIMARY" | index_name
my @alters;
my $dbh;

CLUSTER: foreach my $cluster (@clusters) {
    print "Updating cluster: $cluster\n" unless $opt_listtables;
    ## make sure we can connect
    $dbh = $cluster ? LJ::get_cluster_master($cluster) : LJ::get_db_writer();
    unless ($dbh) {
        $status{$cluster} = "ERROR: Can't connect to the database (clust\#$cluster), so I can't update it.";
        next CLUSTER;
    }

    # reset everything
    %clustered_table = %table_exists = %table_unknown =
        %table_create = %table_drop = %post_create =
        %coltype = %indexname = %table_status = ();
    @alters = ();

    ## figure out what tables already exist (but not details of their structure)
    $sth = $dbh->prepare("SHOW TABLES");
    $sth->execute;
    while (my ($table) = $sth->fetchrow_array) {
        next if $table =~ /^access\d+$/;
        $table_exists{$table} = 1;
    }
    %table_unknown = %table_exists;  # for now, later we'll delete from table_unknown

    ## very important that local is run first!  (it can define tables that
    ## the site-wide would drop if it didn't know about them already)

    my $load_datfile = sub {
        my $file = shift;
        my $local = shift;
        return if $local && ! -e $file;
        open(F, $file) or die "Can't find database update file at $file\n";
        my $data;
        {
            local $/ = undef;
            $data = <F>;
        }
        close F;
        eval $data;
        die "Can't run $file: $@\n" if $@;
        return 1;
    };

    $load_datfile->("$LJ::HOME/bin/upgrading/update-db-local.pl", 1);
    $load_datfile->("$LJ::HOME/bin/upgrading/update-db-general.pl");

    foreach my $t (sort keys %table_create) {
        delete $table_drop{$t} if ($table_drop{$t});
        print "$t\n" if $opt_listtables;
    }
    exit if $opt_listtables;

    foreach my $t (keys %table_drop) {
        delete $table_unknown{$t};
    }

    foreach my $t (keys %table_unknown)
    {
        print "# Warning: unknown live table: $t\n";
    }

    ## create tables
    foreach my $t (keys %table_create)
    {
        next if $table_exists{$t};
        create_table($t);
    }

    ## drop tables
    foreach my $t (keys %table_drop)
    {
        next unless $table_exists{$t};
        drop_table($t);
    }

    ## do all the alters
    foreach my $s (@alters)
    {
        $s->($dbh, $opt_sql);
    }

    $status{$cluster} = "OKAY";
}

print "\ncluster: status\n";
foreach my $clid (sort { $a <=> $b } keys %status) {
    printf "%7d: %s\n", $clid, $status{$clid};
}
print "\n";

if ($opt_pop)
{
    my $made_system;

    # system user
    my $su = LJ::load_user("system");
    unless ($su) {
        print "System user not found. Creating with random password.\n";
        my $pass = LJ::make_auth_code(10);
        LJ::create_account({ 'user' => 'system',
                             'name' => 'System Account',
                             'password' => $pass })
            || die "Failed to create system user.";
        $su = LJ::load_user("system") || die "Failed to load the newly created system user.";
        $made_system = 1;
    }

    # S1
    print "Populating public system styles (S1):\n";
    require "$ENV{'LJHOME'}/bin/upgrading/s1style-rw.pl";
    my $ss = s1styles_read();
    foreach my $uniq (sort keys %$ss) {

        my $s = $ss->{$uniq};
        my $existing = LJ::S1::check_dup_style($su, $s->{'type'}, $s->{'styledes'});

        # update
        if ($existing) {
            if ($LJ::DONT_TOUCH_STYLES) {
                next;
            }
            if ( LJ::S1::update_style($existing->{'styleid'},
                                      { map { $_, $s->{$_} } qw(formatdata is_embedded is_colorfree) }) ) {
                print "  $uniq: ";
                print "updated \#$existing->{'styleid'}\n";
            }
            next;
        }

        # insert new
        my %opts = ( "is_public" => 'Y', "opt_cache" => 'Y',
                     map { $_, $s->{$_} } qw(styledes type formatdata is_embedded is_colorfree lastupdate));
        LJ::S1::create_style($su, \%opts)
            or die "Error: unable to create style!  Database potentially unavailable?";
        print "  $uniq: ";
        print "added\n";
    }

    # delete s1pubstyc from memcache
    LJ::MemCache::delete("s1pubstyc");

    # S2
    print "Populating public system styles (S2):\n";
    {
        my $LD = "s2layers"; # layers dir

        my $sysid = $su->{'userid'};

        # find existing re-distributed layers that are in the database
        # and their styleids.
        my $existing = LJ::S2::get_public_layers($sysid);

        my %known_id;
        chdir "$ENV{'LJHOME'}/bin/upgrading" or die;
        my %layer;    # maps redist_uniq -> { 'type', 'parent' (uniq), 'id' (s2lid) }

        my $compile = sub {
            my ($base, $type, $parent, $s2source) = @_;
            return unless $s2source =~ /\S/;

            my $id = $existing->{$base} ? $existing->{$base}->{'s2lid'} : 0;
            unless ($id) {
                my $parentid = 0;
                $parentid = $layer{$parent}->{'id'} unless $type eq "core";
                # allocate a new one.
                $dbh->do("INSERT INTO s2layers (s2lid, b2lid, userid, type) ".
                         "VALUES (NULL, $parentid, $sysid, ?)", undef, $type);
                die $dbh->errstr if $dbh->err;
                $id = $dbh->{'mysql_insertid'};
                if ($id) {
                    $dbh->do("INSERT INTO s2info (s2lid, infokey, value) VALUES (?,'redist_uniq',?)",
                             undef, $id, $base);
                }
            }
            die "Can't generate ID for '$base'" unless $id;
            
            # remember it so we don't delete it later.
            $known_id{$id} = 1;
            
            $layer{$base} = {
                'type' => $type,
                'parent' => $parent,
                'id' => $id,
            };
            
            my $parid = $layer{$parent}->{'id'};
            
            # see if source changed
            my $md5_source = Digest::MD5::md5_hex($s2source);
            my $md5_exist = $dbh->selectrow_array("SELECT MD5(s2code) FROM s2source WHERE s2lid=?", undef, $id);
            
            # skip compilation if source is unchanged and parent wasn't rebuilt.
            return if $md5_source eq $md5_exist && ! $layer{$parent}->{'built'} && ! $opt_forcebuild;

            print "$base($id) is $type";
            if ($parid) { print ", parent = $parent($parid)"; };
            print "\n";
            
            # we're going to go ahead and build it.
            $layer{$base}->{'built'} = 1;
            
            # compile!
            my $lay = {
                's2lid' => $id,
                'userid' => $sysid,
                'b2lid' => $parid,
                'type' => $type,
            };
            my $error = "";
            my $compiled;
            my $info;
            die $error unless LJ::S2::layer_compile($lay, \$error, { 
                's2ref' => \$s2source, 
                'redist_uniq' => $base,
                'compiledref' => \$compiled,
                'layerinfo' => \$info,
            });
            
            if ($info->{'previews'}) {
                my @pvs = split(/\s*\,\s*/, $info->{'previews'});
                my @vals;
                foreach my $pv (@pvs) {
                    my $from = "$LD/$pv";
                    next unless -e $from;
                    my $dir = File::Basename::dirname($pv);
                    File::Path::mkpath("$LJ::HOME/htdocs/img/s2preview/$dir");
                    my $target = "$LJ::HOME/htdocs/img/s2preview/$pv";
                    File::Copy::copy($from, $target);
                    my ($w, $h) = Image::Size::imgsize($target);
                    push @vals, "$pv|$w|$h";
                }
                $dbh->do("REPLACE INTO s2info (s2lid, infokey, value) VALUES (?,?,?)",
                         undef, $id, '_previews', join(",", @vals)) if @vals;
            }
            
            if ($opt_compiletodisk) {
                open (CO, ">$LD/$base.pl") or die;
                print CO $compiled;
                close CO;
            }
            
            # put raw S2 in database.
            $dbh->do("REPLACE INTO s2source (s2lid, s2code) ".
                     "VALUES ($id, ?)", undef, $s2source);
            die $dbh->errstr if $dbh->err;            
        };

        my @layerfiles = ("s2layers.dat");
        while (@layerfiles)
        {
            my $file = shift @layerfiles;
            next unless -e $file;
            open (SL, $file) or die;
            print "SOURCE: $file\n";
            while (<SL>)
            {
                s/\#.*//; s/^\s+//; s/\s+$//;
                next unless /\S/;
                my ($base, $type, $parent) = split;

                if ($type eq "INCLUDE") {
                    push @layerfiles, $base;
                    next;
                }
                
                if ($type ne "core" && ! defined $layer{$parent}) {
                    die "'$base' references unknown parent '$parent'\n";
                }

                # is the referenced $base file really an aggregation of
                # many smaller layers?  (likely themes, which tend to be small)
                my $multi = ($type =~ s/\+$//);
    
                my $s2source;
                open (L, "$LD/$base.s2") or die "Can't open file: $base.s2\n";

                unless ($multi) {
                    while (<L>) { $s2source .= $_; }
                    $compile->($base, $type, $parent, $s2source);
                } else {
                    my $curname;
                    while (<L>) {
                        if (/^\#NEWLAYER:\s*(\S+)/) {
                            my $newname = $1;
                            $compile->($curname, $type, $parent, $s2source);
                            $curname = $newname;
                            $s2source = "";
                        } elsif (/^\#NEWLAYER/) { 
                            die "Badly formatted \#NEWLAYER line"; 
                        } else {
                            $s2source .= $_; 
                        }
                    }
                    $compile->($curname, $type, $parent, $s2source);
                }
                close L;
            }
            close SL;
        }

        # now, delete any system layers that don't below (from previous imports?)
        my $sth = $dbh->prepare("SELECT s2lid FROM s2layers WHERE userid=?");
        $sth->execute($sysid);
        while (my $id = $sth->fetchrow_array) {
            next if $known_id{$id};
            LJ::S2::delete_layer($id);
        }
    }

    # check for old style external_foaf_url (indexed:1, cldversion:0)
    my $prop = LJ::get_prop('user', 'external_foaf_url');
    if ($prop->{indexed} == 1 && $prop->{cldversion} == 0) {
        print "Updating external_foaf_url userprop.\n";
        system("$ENV{'LJHOME'}/bin/upgrading/migrate-userprop.pl", 'external_foaf_url');
    }
    
    # base data
    foreach my $file ("base-data.sql", "base-data-local.sql") {
        my $ffile = "$ENV{'LJHOME'}/bin/upgrading/$file";
        next unless -e $ffile;
        print "Populating database with $file.\n";
        open (BD, $ffile) or die "Can't open $file file\n";
        while (my $q = <BD>)
        {
            chomp $q;  # remove newline
            next unless ($q =~ /^(REPLACE|INSERT|UPDATE)/);
            chop $q;  # remove semicolon
            $dbh->do($q);
            if ($dbh->err) {
                print "$q\n";
                die "#  ERROR: " . $dbh->errstr . "\n";
            }
        }
        close (BD);
    }

    # moods
    my $moodfile = "$ENV{'LJHOME'}/bin/upgrading/moods.dat";
    if (open(M, $moodfile)) {
        print "Populating mood data.\n";

        my %mood;   # id -> [ mood, parent_id ]
        my $sth = $dbh->prepare("SELECT moodid, mood, parentmood FROM moods");
        $sth->execute;
        while (@_ = $sth->fetchrow_array) { $mood{$_[0]} = [ $_[1], $_[2] ]; }

        my %moodtheme;  # name -> [ id, des ]
        $sth = $dbh->prepare("SELECT moodthemeid, name, des FROM moodthemes WHERE is_public='Y'");
        $sth->execute;
        while (@_ = $sth->fetchrow_array) { $moodtheme{$_[1]} = [ $_[0], $_[2] ]; }        

        my $themeid;  # current themeid (from existing db or just made)
        my %data;     # moodid -> "$url$width$height" (for equality test)

        while (<M>) {
            chomp;
            if (/^MOOD\s+(\d+)\s+(.+)\s+(\d+)\s*$/) {
                my ($id, $mood, $parid) = ($1, $2, $3);
                if (! $mood{$id} || $mood{$id}->[0] ne $mood ||
                    $mood{$id}->[1] ne $parid) {
                    $dbh->do("REPLACE INTO moods (moodid, mood, parentmood) VALUES (?,?,?)",
                             undef, $id, $mood, $parid);
                }
            }

            if (/^MOODTHEME\s+(.+?)\s*:\s*(.+)$/) {
                my ($name, $des) = ($1, $2);
                %data = ();
                if ($moodtheme{$name}) {
                    $themeid = $moodtheme{$name}->[0];
                    if ($moodtheme{$name}->[1] ne $des) {
                        $dbh->do("UPDATE moodthemes SET des=? WHERE moodthemeid=?", undef,
                                 $des, $themeid);
                    }
                    $sth = $dbh->prepare("SELECT moodid, picurl, width, height ".
                                         "FROM moodthemedata WHERE moodthemeid=?");
                    $sth->execute($themeid);
                    while (@_ = $sth->fetchrow_array) {
                        $data{$_[0]} = "$_[1]$_[2]$_[3]";
                    }
                } else {
                    $dbh->do("INSERT INTO moodthemes (ownerid, name, des, is_public) ".
                             "VALUES (?,?,?,'Y')", undef, $su->{'userid'}, $name, $des);
                    $themeid = $dbh->{'mysql_insertid'};
                    die "Couldn't generate themeid for theme $name\n" unless $themeid;
                }
                next;
            }

            if (/^(\d+)\s+(\S+)\s+(\d+)\s+(\d+)\s*$/) {
                next unless $themeid;
                my ($moodid, $url, $w, $h) = ($1, $2, $3, $4);
                next if $data{$moodid} eq "$url$w$h";
                $dbh->do("REPLACE INTO moodthemedata (moodthemeid, moodid, picurl, width, height) ".
                         "VALUES (?,?,?,?,?)", undef, $themeid, $moodid, $url, $w, $h);
                LJ::MemCache::delete([$themeid, "moodthemedata:$themeid"]);
            }
        }
        close M;
    }

    # clean out schema documentation for old/unknown tables
    foreach my $tbl (qw(schemacols schematables)) {
        my $sth = $dbh->prepare("SELECT DISTINCT tablename FROM $tbl");
        $sth->execute;
        while (my $doctbl = $sth->fetchrow_array) {
            next if $table_create{$doctbl};
            $dbh->do("DELETE FROM $tbl WHERE tablename=?", undef, $doctbl);
        }
    }

    # create/update the MogileFS database if we use it
    if (defined $LJ::MOGILEFS_CONFIG{hosts}) {
        # create an admin MogileFS object
        my $mgd = MogileFS::Admin->new(hosts => $LJ::MOGILEFS_CONFIG{hosts})
            or die "Error: Unable to initalize MogileFS connection.\n";
        my $exists = $mgd->get_domains();
        print "Verifying MogileFS configuration...\n";

        # verify domain exists?
        my $domain = $LJ::MOGILEFS_CONFIG{domain};
        unless (defined $exists->{$domain}) {
            print "\tCreating domain $domain...\n";
            $mgd->create_domain($domain)
                or die "Error: Unable to create domain.\n";
            $exists->{$domain} = {};
        }

        # now start verifying classes
        foreach my $class (keys %{$LJ::MOGILEFS_CONFIG{classes} || {}}) {
            if ($exists->{$domain}->{$class}) {
                if ($exists->{$domain}->{$class} != $LJ::MOGILEFS_CONFIG{classes}->{$class}) {
                    # update the mindevcount since it's changed
                    print "\tUpdating class $class...\n";
                    $mgd->update_class($domain, $class, $LJ::MOGILEFS_CONFIG{classes}->{$class})
                        or die "Error: Unable to update class.\n";
                }
            } else {
                # create it
                print "\tCreating class $class...\n";
                $mgd->create_class($domain, $class, $LJ::MOGILEFS_CONFIG{classes}->{$class})
                    or die "Error: Unable to create class.\n";
            }
        }
    }

    # convert users from dversion2 (no weekuserusage)
    if (my $d2 = $dbh->selectrow_array("SELECT userid FROM user WHERE dversion=2 LIMIT 1")) {
        $dbh->do("UPDATE user SET dversion=3 WHERE dversion=2");
    }

    # convert users from dversion3 (unclustered props)
    if (my $d3 = $dbh->selectrow_array("SELECT userid FROM user WHERE dversion=3 LIMIT 1")) {
        system("$ENV{'LJHOME'}/bin/upgrading/pop-clusterprops.pl", 3);
    }

    # convert users from dversion4 (unclustered s1styles)
    if (my $d4 = $dbh->selectrow_array("SELECT userid FROM user WHERE dversion=4 LIMIT 1")) {
        system("$ENV{'LJHOME'}/bin/upgrading/d4d5-global.pl");
    }

    # convert users from dversion5 (unclustered memories and friend groups)
    if (my $d5 = $dbh->selectrow_array("SELECT userid FROM user WHERE dversion=5 LIMIT 1")) {
        system("$ENV{'LJHOME'}/bin/upgrading/d5d6-mkf.pl");
    }

    # convert users from dversion6 (unclustered user pictures)
    if (my $d6 = $dbh->selectrow_array("SELECT userid FROM user WHERE dversion=6 LIMIT 1")) {
        system("$ENV{'LJHOME'}/bin/upgrading/d6d7-userpics.pl");
    }

    print "\nThe system user was created with a random password.\nRun \$LJHOME/bin/upgrading/make_system.pl to change its password and grant the necessary privileges."
        if $made_system;
    print "\nRemember to also run:\n  bin/upgrading/texttool.pl load\n\n";
}

# make sure they don't have cluster0 users (support for that will be going away)
# Note:  now cluster 0 means expunged (as well as statuvis 'X'), so there's
# an option to disable the warning if you're running new code and know what's up.
unless ($LJ::NOWARN{'cluster0'}) { 
    my $cluster0 = $dbh->selectrow_array("SELECT COUNT(*) FROM user WHERE clusterid=0");
    if ($cluster0) {
        print "\n", "* "x35, "\nWARNING: You have $cluster0 users on cluster 0.\n\n".
            "Support for that old database schema is deprecated and will be removed soon.\n".
            "You should stop updating from CVS until you've moved all your users to a cluster \n".
            "(probably cluster '1', which you can run on the same database). \n".
            "See bin/moveucluster.pl for instructions.\n" . "* "x35 . "\n\n";
    }
}

print "# Done.\n";

sub skip_opt
{
    return $opt_skip;
}

sub do_sql
{
    my $sql = shift;
    chomp $sql;
    my $disp_sql = $sql;
    $disp_sql =~ s/\bIN \(.+\)/IN (...)/g;
    print "$disp_sql;\n";
    if ($opt_sql) {
        print "# Running...\n";
        $dbh->do($sql);
        if ($dbh->err) {
            die "#  ERROR: " . $dbh->errstr . "\n";
        }
    }
}

sub try_sql
{
    my $sql = shift;
    print "$sql;\n";
    if ($opt_sql) {
        print "# Non-critical SQL (upgrading only... it might fail)...\n";
        $dbh->do($sql);
        if ($dbh->err) {
            print "#  Acceptable failure: " . $dbh->errstr . "\n";
        }
    }
}

sub do_alter
{
    my ($table, $sql) = @_;
    return if $cluster && ! defined $clustered_table{$table};

    do_sql($sql);

    # columns will have changed, so clear cache:
    clear_table_info($table);
}

sub create_table
{
    my $table = shift;
    return if $cluster && ! defined $clustered_table{$table};

    my $create_sql = $table_create{$table};
    if ($opt_innodb && $create_sql !~ /type=myisam/i) {
        $create_sql .= " TYPE=INNODB";
    }
    do_sql($create_sql);

    foreach my $pc (@{$post_create{$table}})
    {
        my @args = @{$pc};
        my $ac = shift @args;
        if ($ac eq "sql") { 
            print "# post-create SQL\n";
            do_sql($args[0]); 
        }
        elsif ($ac eq "sqltry") { 
            print "# post-create SQL (necessary if upgrading only)\n";
            try_sql($args[0]); 
        }
        elsif ($ac eq "code") {
            print "# post-create code\n";
            $args[0]->($dbh, $opt_sql);
        }
        else { print "# don't know how to do \$ac = $ac"; }
    }
}

sub drop_table
{
    my $table = shift;
    return if $cluster && ! defined $clustered_table{$table};

    if ($opt_drop) {
        do_sql("DROP TABLE $table");
    } else {
        print "# Not dropping table $table to be paranoid (use --drop)\n";
    }
}

sub mark_clustered
{
    foreach (@_) {
        $clustered_table{$_} = 1;
    }
}

sub register_tablecreate
{
    my ($table, $create) = @_;
    # we now know of it
    delete $table_unknown{$table};

    return if $cluster && ! defined $clustered_table{$table};

    $table_create{$table} = $create;
}

sub register_tabledrop
{
    my ($table) = @_;
    $table_drop{$table} = 1;
}

sub post_create
{
    my $table = shift;
    while (my ($type, $what) = splice(@_, 0, 2)) {
        push @{$post_create{$table}}, [ $type, $what ];
    }
}

sub register_alter
{
    my $sub = shift;
    push @alters, $sub;
}

sub clear_table_info
{
    my $table = shift;
    delete $coltype{$table};
    delete $indexname{$table};
    delete $table_status{$table};
}

sub load_table_info
{
    my $table = shift;

    clear_table_info($table);

    my $sth = $dbh->prepare("DESCRIBE $table");
    $sth->execute;
    while (my $row = $sth->fetchrow_hashref) {
        my $type = $row->{'Type'};
        $type .= " $1" if $row->{'Extra'} =~ /(auto_increment)/i;
        $coltype{$table}->{ $row->{'Field'} } = lc($type);
    }

    # current physical table properties
    $table_status{$table} =
        $dbh->selectrow_hashref("SHOW TABLE STATUS LIKE '$table'");

    $sth = $dbh->prepare("SHOW INDEX FROM $table");
    $sth->execute;
    my %idx_type;  # name -> "UNIQUE"|"INDEX"
    my %idx_parts; # name -> []
    while (my $ir = $sth->fetchrow_hashref) {
        $idx_type{$ir->{'Key_name'}} = $ir->{'Non_unique'} ? "INDEX" : "UNIQUE";
        push @{$idx_parts{$ir->{'Key_name'}}}, $ir->{'Column_name'};
    }

    foreach my $idx (keys %idx_type) {
        my $val = "$idx_type{$idx}:" . join("-", @{$idx_parts{$idx}});
        $indexname{$table}->{$val} = $idx;
    }
}

sub index_name
{
    my ($table, $idx) = @_;  # idx form is:  INDEX:col1-col2-col3
    load_table_info($table) unless $indexname{$table};
    return $indexname{$table}->{$idx} || "";
}

sub table_relevant
{
    my $table = shift;
    return 1 unless $cluster;
    return 1 if $clustered_table{$table};
    return 0;
}

sub column_type
{
    my ($table, $col) = @_;
    load_table_info($table) unless $coltype{$table};
    my $type = $coltype{$table}->{$col};
    $type ||= "";
    return $type;
}

sub table_status
{
    my ($table, $col) = @_;
    load_table_info($table) unless $table_status{$table};

    return $table_status{$table}->{$col} || "";
}

sub ensure_confirm
{
    my $area = shift;

    return 1 if ($opt_sql && ($opt_confirm eq "all" or
                              $opt_confirm eq $area));

    print STDERR "To proceed with the necessary changes, rerun with -r --confirm=$area\n";
    return 0;
}

sub set_dbnote
{
    my ($key, $value) = @_;
    return unless $opt_sql && $key && $value;

    return $dbh->do("REPLACE INTO blobcache (bckey, dateupdate, value) VALUES (?,NOW(),?)",
                    undef, $key, $value);
}

sub check_dbnote
{
    my $key = shift;

    return $dbh->selectrow_array("SELECT value FROM blobcache WHERE bckey=?",
                                 undef, $key);
}

