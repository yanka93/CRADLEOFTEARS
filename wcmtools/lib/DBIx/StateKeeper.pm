# A StateTracker has a real DBI $dbh handle, and knows
# what the active database is (for use with MySQL)
#
# A StateKeeper (below) mimics the $dbh interface (so it
# can be used transparently instead of a real $dbh) and
# has a StateTracker and knows what database it wants to
# use.  If the StateKeeper is ever invoked (->do(), ->prepare(),
# or whatever $dbh can do), then it checks its Tracker and
# changes the Tracker's database if it doesn't match.
#
# The point is to connect to a host that has multiple
# databases, but only use one connection, and make the
# client code oblivious to the fact one connection is
# being shared and there are multiple databases.
#
# Backing up, the point is to get more concurrency out
# out the ultra-fast MyISAM table handler by separating
# users onto separate databases on the same machine
# and across different replication clusters.  We could use
# InnoDB, which is highly concurrent, but it's pretty slow.
# Besides, we hardly ever hit the database with memcache.
# The common case for us at the moment is doing 1 or 2
# simple queries on 10+ different databases, most of which
# are on the same couple hosts.  It's a waste to use 10
# db connections.  The MySQL support people will say
# to just jack up max_connections, but we want to limit
# the max running threads (and their associated memory).
# We keep asking MySQL people for a distinction between
# threads and connections, but it's lower on their priority
# list.  This is our temporary hack.
#
#    UPDATE:  Oct-16-2003, it was announced by a MySQL
#    developer that MySQL 5.0 will have thread vs. connection
#    context separation.  See:
#        http://krow.livejournal.com/247835.html
#
# Please, do not use this in other code unless you know
# what you're doing.
#
#     -- Brad Fitzpatrick <brad@danga.com>
#

package DBIx::StateTracker;

use strict;

# if set externally, EXTRA_PARANOID will validate the
# current database before any query.  slow, but useful
# to make sure nobody is messing with the StateTracker's
# beside itself.
use vars qw($EXTRA_PARANOID);  

our %dbs_tracked;  # $dbh -> 1  (if being tracked)

sub new {
    my ($class, $dbh, $init_db) = @_;
    return undef unless $dbh;
    my $bless = ref $class || $class;
    
    my $maker;
    if (ref $dbh eq "CODE") {
        $maker = $dbh;
        $dbh = undef;
    }

    my $self = {
        'dbh' => $dbh,
        'database' => $init_db,
        'maker' => $maker,
    }; 
    bless $self, $bless;

    $self->reconnect() unless $self->{dbh};

    return $self;
}

sub reconnect {
    my $self = shift;
    die "DBIx::StateTracker: no db connector code available\n"
        unless ref $self->{maker} eq "CODE";

    # in case there was an old handle
    delete $dbs_tracked{$self->{dbh}};

    my $dbh = $self->{maker}->();
    my $db;
    die "DBIx::StateTracker: could not reconnect to database\n" 
        unless $dbh;

    $db = $dbh->selectrow_array("SELECT DATABASE()");
    die "DBIx::StateTracker: error checking current database: " . $dbh->errstr . "\n"
        if $dbh->err;

    if ($dbs_tracked{$dbh}++) {
        die "DBIx::StateTracker: database $dbh already being tracked.  ".
            "Can't have two active trackers.";
    }
    
    $self->{dbh} = $dbh;
    $self->{database} = $db;
    return $self;
}

sub disconnect {
    my $self = shift;
    delete $dbs_tracked{$self->{dbh}};
    $self->{dbh}->disconnect if $self->{dbh};
    undef $self->{dbh};
    undef $self->{database};
}

sub DESTROY {
    my $self = shift;
    delete $dbs_tracked{$self->{'dbh'}};
}

sub get_database { 
    my $self = shift;
    return $self->{'database'};
}

sub set_database {
    my ($self, $db, $second_try) = @_;  # db = desired database

    if ($self->{database} ne $db) {
        die "Invalid db name" if $db =~ /\W/;
        my $rc = $self->{'dbh'}->do("USE $db");
        if (! $rc) {
            return 0 if $second_try;
            $self->reconnect();
            return $self->set_database($db, 1);
        }
        $self->{'database'} = $db;
    }
    
    elsif ($EXTRA_PARANOID) {
        my $actual = $self->{'dbh'}->selectrow_array("SELECT DATABASE()");
        if (! defined $actual) {
            my $err = $self->{dbh}->err;
            if (! $second_try && ($err == 2006 || $err == 2013)) {
                # server gone away, or lost connection (timeout?)
                $self->reconnect();
                return $self->set_database($db, 1);
            } else {
                $@ = "DBIx::StateTracker: error discovering current database: " .
                    $self->{dbh}->errstr;
		return 0;
            }
        } elsif ($actual ne $db) {
            $@ = "Aborting without db access.  Somebody is messing with the DBIx::StateTracker ".
                "dbh that's not us.  Expecting database $db, but was actually $actual.";
	    return 0;
        }
    }

    return 1;
}

sub do_method {
    my ($self, $desired_db, $method, @args) = @_;
    unless ($method eq "quote") {
	die "DBIx::StateKeeper: unable to switch to database: $desired_db ($@)" unless
	    $self->set_database($desired_db);
    }

    my $dbh = $self->{dbh};
    #print "wantarray: ", (wantarray() ? 1 : 0), "\n";
    return $dbh->$method(@args);
}

sub get_attribute {
    my ($self, $desired_db, $key) = @_;
    die "DBIx::StateKeeper: unable to switch to database: $desired_db" unless
	$self->set_database($desired_db);

    my $dbh = $self->{dbh};
    return $dbh->{$key};
}

sub set_attribute {
    my ($self, $desired_db, $key, $val) = @_;
    die "DBIx::StateKeeper: unable to switch to database: $desired_db" unless
	$self->set_database($desired_db);

    my $dbh = $self->{dbh};
    $dbh->{$key} = $val;
}

package DBIx::StateKeeper;

use strict;
use vars qw($AUTOLOAD);

sub new {
    my ($class, $tracker, $db) = @_;
    my $bless = ref $class || $class;
    my $self = {};  # always empty.  real state is stored in tied node.
    tie %$self, $bless, $tracker, $db;
    bless $self, $bless;
    return $self;
}

sub STORE { 
    my ($self, $key, $value) = @_;
    die "Setting attributes on DBIx::StateKeeper handles not yet supported.  Use a real connection.";
    return $self->{_tracker}->set_attribute($self->{_db}, $key, $value);
}

sub DELETE { die "DELETE not implemented" }
sub CLEAR { die "CLEAR not implemented" }
sub EXISTS { die "EXISTS not implemented" }
sub FIRSTKEY { return undef; }
sub NEXTKEY { return undef; }
sub DESTROY { die "DELETE not implemented" }
sub UNTIE { }

sub set_database {
    my $self = shift;
    return $self->{_tracker}->set_database($self->{_db});
}

sub FETCH {
    my ($self, $key) = @_;

    # keys starting with underscore are our own.  otherwise
    # we forward them on to the real $dbh.
    if ($key =~ m!^\_!) {
        my $ret = $self->{$key};
        return $ret;
    }

    return $self->{_tracker}->get_attribute($self->{_db}, $key);
}

sub TIEHASH {
    my ($class, $tracker, $db) = @_;
    my $node = {
        '_tracker' => $tracker,
        '_db' => $db,
    };
    return bless $node, $class;
}

sub AUTOLOAD {
    my $self = shift;
    my $method = $AUTOLOAD;
    $method =~ s/.+:://;
    return $self->{_tracker}->do_method($self->{_db}, $method, @_);
}

1;
