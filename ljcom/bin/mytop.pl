#!/usr/bin/perl -w
#
# $Id: mytop.pl,v 1.2 2002/02/11 05:48:56 bradfitz Exp $

=pod

=head1 NAME

mytop - display MySQL server performance info like `top'

=cut

use 5.004;
use strict;
use DBI;
use Getopt::Long;
use Term::ReadKey;

$|++;

## Test for color support.

eval { require Term::ANSIColor; };

my $HAS_COLOR = $@ ? 0 : 1;

## Try to lower our priority (which, who, pri)

setpriority(0,0,10);

## Default Config Values

my %config = (
              delay       => 5,
              host        => 'localhost',
              db          => 'test',
              user        => 'root',
              pass        => '',
              port        => 3306,
              socket      => '',
              batchmode   => 0,
              header      => 1,
              color       => 1,
             );

my $CLEAR = `clear`;

my $VERSION = "0.3";

## Term::ReadKey values

my $RM_RESET   = 0;
my $RM_NOBLKRD = 3; ## using 4 traps Ctrl-C :-(

## Read the user's config file, if it exists.

my $config = "$ENV{HOME}/.mytop";

if (-e $config)
{
    if (open CFG, "<$config")
    {
        while (<CFG>)
        {
            next if /^\s*$/;  ## skip blanks
            next if /^\s*#/;  ## skip comments

            chomp;

            if (/(\S+)\s*=\s*(\S+)/)
            {
                $config{lc $1} = $2 if exists $config{lc $1};
            }
        }

        close CFG;
    }
}

## Command-line args.

use vars qw($opt_foo);

GetOptions( "color!"              => \$config{color},
            "user|u=s"            => \$config{user},
            "pass|p=s"            => \$config{pass},
            "database|db|d=s"     => \$config{db},
            "host|h=s"            => \$config{host},
            "port=i"              => \$config{port},
            "socket|S=s"          => \$config{socket},
            "delay|s=i"           => \$config{delay},
            "batch|batchmode|b!"  => \$config{batchmode},
            "header!"             => \$config{header},
          );

## User may have put the port with the host.

if ($config{host} =~ s/:(\d+)$//)
{
    $config{port} = $1;
}

## User may want to disable color.

if ($HAS_COLOR and not $config{color})
{
    $HAS_COLOR = 0;
}

if ($HAS_COLOR)
{
    import Term::ANSIColor ':constants';
}
else
{
    *RESET  = sub { };
    *YELLOW = sub { };
    *RED    = sub { };
    *GREEN  = sub { };
    *BLUE   = sub { };
    *WHITE  = sub { };
    *BOLD   = sub { };
}

my $RESET  = RESET()   || '';
my $YELLOW = YELLOW()  || '';
my $RED    = RED()     || '';
my $GREEN  = GREEN()   || '';
my $BLUE   = BLUE()    || '';
my $WHITE  = WHITE()   || '';
my $BOLD   = BOLD()    || '';

## Connect

my $dsn;

## Socket takes precedence.

$dsn ="DBI:mysql:database=$config{db};";

if ($config{socket} and -S $config{socket})
{
    $dsn .= "mysql_socket=$config{socket}";
}
else
{
    $dsn .= "host=$config{host};port=$config{port}";
}


my $dbh = DBI->connect($dsn, $config{user}, $config{pass},
                       { PrintError => 0 });

if (not ref $dbh)
{
    my $Error = <<EODIE
Cannot connect to MySQL server. Please check the:

  * database you specified "$config{db}" (default is "test")
  * username you specified "$config{user}" (default is "root")
  * password you specified "$config{pass}" (default is "")
  * hostname you specified "$config{host}" (default is "localhost")
  * hostname you specified "$config{port}" (default is 3306)
  * socket you specified "$config{socket}" (default is "")

The options my be specified on the command-line or in a ~/.mytop
config file. See the manual (perldoc mytop) for details.

Here's the exact error from DBI. It might help you debug:

$DBI::errstr

EODIE
;

    die $Error;

}

ReadMode($RM_RESET);

## Get static data

my $db_version;

my @variables = Hashes("show variables");

foreach (@variables)
{
    next unless $_->{Variable_name} eq "version";
    $db_version = $_->{Value};
    last;
}

## The main loop

ReadMode($RM_NOBLKRD);

while (1)
{
    Clear() unless $config{batchmode};
    GetData();
    last if $config{batchmode};
    my $key = ReadKey $config{delay};

    next unless $key;

    ## quit

    if ($key =~ /q/i)
    {
        ReadMode($RM_RESET);
        print "\n";
        exit;
    }

    ## seconds of delay

    if ($key =~ /s/)
    {
        ReadMode($RM_RESET);

        print RED(), "Seconds of Delay: ", RESET();
        my $secs = ReadLine(0);

        if ($secs =~ /^\s*(\d+)/)
        {
            $config{delay} = $1;

            if ($config{delay} < 1)
            {
                $config{delay} = 1;
            }

        }

        ReadMode($RM_NOBLKRD);
        next;
    }

    ## pause

    if ($key =~ /p/i)
    {
        print RED(), "-- paused. press any key to resume --", RESET();
        ReadKey(0);
        next;
    }

    ## help (?)

    if ($key eq '?')
    {
        Clear();
        PrintHelp();
        ReadKey(0);
        next;
    }

    ## kill

    if ($key =~ /k/i)
    {
        ReadMode($RM_RESET);

        print RED(), "Thread id to kill: ", RESET();
        my $id = ReadLine(0);

        $id =~ s/\s//g;

        if ($id =~ /^\d+$/)
        {
            Execute("KILL $id");
        }
        else
        {
            print RED(), "-- invalid thread id --", RESET();
            sleep 2;
        }

        ReadMode($RM_NOBLKRD);
        next;
    }

    ## full info

    if ($key =~ /f/i)
    {
        print RED(), "Full query info not yet implemented.", RESET();
        sleep 2;
        next;
    }

    ## reset status counters

    if ($key =~ /r/i)
    {
        Execute("FLUSH STATUS");
        print RED(), "-- counters reset --", RESET();
        sleep 2;
        next;
    }

    ## header toggle

    if ($key =~ /h/i)
    {
        if ($config{header})
        {
            $config{header} = 0;
        }
        else
        {
            $config{header}++;
        }
    }

}

ReadMode($RM_RESET);

exit;

#######################################################################

sub Clear()
{
    print "$CLEAR";
}

sub GetData()
{
    ## Get terminal info

    my ($width, $height, $wpx, $hpx) = GetTerminalSize();

    my $lines_left = $height - 2;

    if ($config{batchmode})
    {
        $height = 999_999; ## I hope you don't have more than that!
    }

    ##
    ## Header stuff.
    ##

    if ($config{header})
    {
        my @recs = Hashes("show status");

        my %S;

        foreach my $ref (@recs)
        {
            my $key = $ref->{Variable_name};
            my $val = $ref->{Value};

            $S{$key} = $val;
        }

        ## Compute Key Cache Hit Stats

        $S{Key_read_requests} ||= 1; ## can't divide by zero next

        my $cache_hits_percent = (100-($S{Key_reads}/$S{Key_read_requests}) * 100);
        $cache_hits_percent = sprintf("%2.2f",$cache_hits_percent);

        ## Server Uptime in meaningful terms...

        my $time         = $S{Uptime};
        my ($d,$h,$m,$s) = (0, 0, 0, 0);

        $d += int($time / (60*60*24)); $time -= $d * (60*60*24);
        $h += int($time / (60*60));    $time -= $h * (60*60);
        $m += int($time / (60));       $time -= $m * (60);
        $s += int($time);

        my $uptime = sprintf("%d+%02d:%02d:%02d", $d, $h, $m, $s);

        ## Queries per second...

        my $avg_queries_per_sec  = sprintf("%.2f", $S{Questions} / $S{Uptime});
        my $num_queries          = $S{Questions};

        my @t = localtime(time);

        my $current_time = sprintf "[%02d:%02d:%02d]", $t[2], $t[1], $t[0];

        my $host_width = 55;
        my $up_width   = $width - $host_width;

        print RESET();

        printf "%-${host_width}s%${up_width}s\n",
            "MySQL on $config{host} ($db_version)", "up $uptime $current_time";

        $lines_left--;

        printf " Queries Total: %-13s  ", commify($num_queries);
        printf "Avg/Sec: %-4.2f  ", $avg_queries_per_sec;
        printf "Slow: %s\n", commify($S{Slow_queries});

        $lines_left--;

        printf " Threads Total: %-5s     Active: %-5s Cached: %-5s\n",
            commify($S{Threads_connected}), commify($S{Threads_running}),
                commify($S{Threads_cached});

        $lines_left--;

        printf " Key Efficiency: %2.2f%%  Bytes in: %s  Bytes out: %s\n\n",
            $cache_hits_percent, commify($S{Bytes_received}),
                commify($S{Bytes_sent});

        $lines_left--;

    }


    ##
    ## Threads
    ##

    #my $sz = $width - 52;
    my @sz   = (6, 8, 10, 10, 6, 8);
    my $used = scalar(@sz) + Sum(@sz);
    my $free = $width - $used;

    print BOLD();

    printf "%6s %8s %10s %10s %6s %8s %-${free}s\n",
        'Id','User','Host','Dbase','Idle', 'Command', 'Query Info';

    print RESET();

    printf "%6s %8s %10s %10s %6s %8s %-${free}s\n",
        '--','----','----','-----','----', '-------', '----------';

    $lines_left -= 2;

    my @data = Hashes("show processlist");

    foreach my $thread (@data)
    {
        last if not $lines_left;

        ## Drop Domain Name

        $thread->{Host} =~ s/^([^.]+).*/$1/;

        ## Fix possible undefs

        $thread->{db}      ||= '';
        $thread->{Info}    ||= '';
        $thread->{Time}    ||= 0 ;
        $thread->{Id}      ||= 0 ;
        $thread->{User}    ||= 0 ;
        $thread->{Command} ||= '';
        $thread->{Host}    ||= '';

        ## Normalize spaces

        $thread->{Info} =~ s/[\n\r]//g;
        $thread->{Info} =~ s/\s+/ /g;
        $thread->{Info} =~ s/^\s*//;
    }

    ## Sort by idle time (closest thing to CPU usage I can think of).

    ## unauthenticated user

    foreach my $thread (sort { $a->{Time} <=> $b->{Time} } @data)
    {

        my $smInfo = substr $thread->{Info}, 0, $free;

        if ($HAS_COLOR)
        {
            print YELLOW() if $thread->{Command} eq 'Query';
            print WHITE()  if $thread->{Command} eq 'Sleep';
            print GREEN()  if $thread->{Command} eq 'Connect';
        }

        printf "%6d %8.8s %10.10s %10.10s %6d %8.8s %-${free}.${free}s\n",
            $thread->{Id}, $thread->{User}, $thread->{Host}, $thread->{db},
            $thread->{Time}, $thread->{Command}, $smInfo;


        print RESET() if $HAS_COLOR;

        $lines_left--;

        last if $lines_left == 0;

    }

}

###########################################################################
###########################################################################
###########################################################################

sub PrintHelp()
{
    print<<EOHELP;
This is help for mytop version $VERSION by Jeremy D. Zawodny <${YELLOW}jzawodn\@yahoo-inc.com${RESET}>

  ? - display this screen
  s - change the delay between screen updates
  k - kill a thread
  h - toggle the mytop header
  p - pause the display
  r - reset the status counters (via FLUSH STATUS on your server)
  f - full query info (NOT IMPLEMENTED)
  q - quit

mytop man page is available via `${RED}perldoc mytop${RESET}'

   database: $config{db}
   username: $config{user}
   hostname: $config{host}
       port: $config{port}
     socket: $config{socket}
      delay: $config{delay} seconds

${GREEN}http://public.yahoo.com/~jzawodn/mytop/${RESET}

(press any key to return)
EOHELP
}

sub Sum(@)
{
    my $sum;

    while (my $val = shift @_)
    {
        $sum += $val;
    }

    return $sum;
}

## A useful routine from perlfaq

sub commify($)
{
    local $_  = shift;
    return 0 unless defined $_;
    1 while s/^([-+]?\d+)(\d{3})/$1,$2/;
    return $_;
}

## Run a query and return the records has an array of hashes.

sub Hashes($)
{
    my $sql   = shift;

    my @records;

    if (my $sth = Execute($sql))
    {
        while (my $ref = $sth->fetchrow_hashref)
        {
            push @records, $ref;
        }

    }
    return @records;
}

## Execute an SQL query and return the statement handle.

sub Execute($)
{
    my $sql = shift;

    ##
    ## Prepare the statement
    ##
    my $sth = $dbh->prepare($sql);

    if (not $sth)
    {
        die $DBI::errstr;
    }

    ##
    ## Execute the statement.
    ##

    my $ReturnCode = $sth->execute;

    if (not $ReturnCode)
    {
        return undef;
    }

    return $sth;
}

=pod

=head1 SYNOPSIS

B<mytop> [options]

=head1 AVAILABILITY

The latest version of B<mytop> is available from
http://public.yahoo.com/~jzawodn/mytop/

=head1 REQUIREMENTS

In order for B<mytop> to function properly, you must have the
following:

  * Perl 5.005 or newer
  * Getopt::Long
  * DBI and DBD::mysql
  * Term::ReadKey from CPAN

Most systems are likely to have all of those installed--except for
Term::ReadKey. You will need to pick that up from the CPAN. You can
pick up Term::ReadKey here:

    http://search.cpan.org/search?dist=TermReadKey

And you obviously need access to a MySQL server (version 3.22.x or
3.23.x) with the necessary security to run the I<SHOW PROCESSLIST> and
I<SHOW STATUS> commands.

=head2 Optional Color Support

In additon, if you want a color B<mytop> (recommended), install
Term::ANSIColor from the CPAN:

    http://search.cpan.org/search?dist=ANSIColor

Once you do, B<mytop> will automatically use it.

=head2 Platforms

B<mytop> is known to work on:

  * Linux (2.2.x)
  * FreeBSD (2.2, 3.x, 4.x)
  * BSDI 4.x
  * Solaris 2.x

If you find that it works on another platform, please let me
know. Given that it is all Perl code, I expect it to be rather
portable to Unix and Unix-like systems. Heck, it I<might> even work on
Win32 systems.

=head1 DESCRIPTION

This software is subject to change. It is currently I<beta> quality
software with known problems and incompatibilities, so please keep
that in mind.

It is, however, stable. There's little damage you can do by running
B<mytop>.

Help is always welcome in improving this software. Feel free to
contact the author (see L<"AUTHOR"> below) with bug reports, fixes,
suggestions, and comments. Additionally L<"BUGS"> will provide a list
of things this software is not able to do yet.

Having said that, here are the details on how it works and what you can
do with it.

=head2 Basics

B<mytop> was inspired by the system monitoring tool B<top>. I
routinely use B<top> on Linux, FreeBSD, and Solaris. You are likely to
notice features from each of them here.

B<mytop> will connect to a MySQL server and periodically run the
I<SHOW PROCESSLIST> and I<SHOW STATUS> commands and attempt to
summarize the information from them in a useful format.

=head2 The Display

The B<mytop> display screen is really broken into two parts. The top 4
lines (header) contain summary information about your MySQL
server. For example, you might see something like:

  MySQL on localhost (3.22.32)              up 3+23:14:20 [23:54:52]
   Queries Total: 617            Avg/Sec: 0.00  Slow: 0
   Threads Total: 1         Active: 1     Cached: 0
   Key Efficiency: 88.38%  Bytes in: 0  Bytes out: 0

The first line identified the hostname of the server (localhost) and
the version of MySQL it is running. The right had side shows the
uptime of the MySQL server process in days+hours:minutes:seconds
format (much like FreeBSD's top) as well as the current time.

The second line displays the total number of queries the server has
processed, the average number of queries per second, and the number of
slow queries.

The third line deals with threads. Versions of MySQL before 3.23.x
didn't give out this information, so you'll see all zeros.

And the fourth line displays key buffer efficiency (how often keys are
read from the buffer rather than disk) and the number of bytes that
MySQL has sent and received.

You can toggle the header by hitting B<h> when running B<mytop>.

The second part of the display lists as many threads as can fit on
screen. By default they are sorted according to their idle time (least
idle first). The display looks like:

    Id     User       Host      Dbase   Idle  Command Query Info
    --     ----       ----      -----   ----  ------- ----------
    61  jzawodn  localhost      music      0    Query show processlist

As you can see, the thread id, username, host from which the user is
connecting, database to which the user is connected, number of seconds
of idle time, the command the thread is executing, and the query info
are all displayed.

Often times the query info is what you are really interested in, so it
is good to run B<mytop> in an xterm that is wider than the normal 80
columns if possible.

The thread display color-codes the threads if you have installed color
support. The current color scheme only works well in a window with a
dark (like black) background. The colors are selected according to the
C<Command> column of the display:

    Query    Yellow
    Sleep    White
    Connect  Green

Those are purely arbitrary and will be customizable in a future
release. If they annoy you just start B<mytop> with the B<-nocolor>
flag or adjust your config file appropriately.

=head2 Arguments

B<mytop> handles long and short command-line arguments. Not all
options have both long and short formats, however. The long arguments
can start with one or two dashes `-' or `--'. They are shown here with
just one.

=over

=item B<-u> or B<-user> username

Username to use when logging in to the MySQL server. Default: ``root''.

=item B<-p> or B<-password> password

Password to use when logging in to the MySQL server. Default: none.

=item B<-h> or B<-host> hostname[:port]

Hostname of the MySQL server. The hostname may be followed by an
option port number. Note that the port is specified separate from the
host when using a config file. Default: ``localhost''.

=item B<-port> port

If you're running MySQL on a non-standard port, use this to specify
the port number. Default: 3306.

=item B<-s> or B<-delay> seconds

How long between display refreshes. Default: 5

=item B<-d> or B<-db> or B<-database> database

Use if you'd like B<mytop> to connect to a specific database by
default. Default: ``test''.

=item B<-b> or B<-batch> or B<-batchmode>

In batch mode, mytop runs only once, does not clear the screen, and
places no limit on the number of lines it will print. This is suitable
for running periodically (perhaps from cron) to capture the
information into a file for later viewing. You might use batch mode in
a CGI script to occasionally display your MySQL server status on the
web.

Default: unset.

=item B<-S> or B<-socket> /path/to/socket

If you're running B<mytop> on the same host as MySQL, you may wish to
have it use the MySQL socket directly rather than a standard TCP/IP
connection. If you do,just specify one.

Note that specifying a socket will make B<mytop> ignore any host
and/or port that you might have specified. If the socket does not
exist (or the file specified is not a socket), this option will be
ignored and B<mytop> will use the hostname and port number instead.

Default: none.

=item B<-header> or B<-noheader>

Sepcify if you want the header to display or not. You can toggle this
with the B<h> key while B<mytop> is running.

Default: header.

=item B<-color> or B<-nocolor>

Specify if you want a color display. This has no effect if you don't
have color support available.

Default: If you have color support, B<mytop> will try color unless you
tell it not to.

=back

Command-line arguments will always take precedence over config file
options. That happens because the config file is read I<BEFORE> the
command-line arguments are applied.

=head2 Config File

Instead of always using bulky command-line parameters, you can also
use a config file in your home directory (C<~/.mytop>). If present,
B<mytop> will read it automatically. It is read I<before> any of your
command-line arguments are processed, so your command-line arguments
will override directives in the config file.

Here is a sample config file C<~/.mytop> which implements the defaults
described above.

  user=root
  pass=
  host=localhost
  db=test
  delay=5
  port=3306
  socket=
  batchmode=0
  header=1
  color=1

Using a config file will help to ensure that your database password
isn't visible to users on the command-line. Just make sure that the
permissions on C<~/.mytop> are such that others cannot read it (unless
you want them to, of course).

You may have white space on either side of the C<=> in lines of the
config file.

=head2 Shortcut Keys

The following keys perform various actions while B<mytop> is
running. Those which have not been implemented are listed as
such. They are included to give the user idea of what is coming.

=over

=item B<s>

Change the sleep time (number of seconds between display refreshes).

=item B<q>

Quit B<mytop>

=item B<k>

Kill a thread.

=item B<r>

Reset the server's status counters via a I<FLUSH STATUS> command.

=item B<f>

Full query info. (Not Implemented)

=item B<p>

Pause display.

=item B<h>

Toggle the header display. You can also specify either C<header=0> or
C<header=1> in your config file to set the default behavior.

=item B<?>

Display help.

=back

The B<s> key has a command-line counterpart: B<-s>.

The B<h> key has two command-line counterparts: B<-header> and
B<-noheader>.

=head1 BUGS

This is more of a BUGS + WishList.

Some performance information is not available when talking to a
version 3.22.x MySQL server. Additional information (about threads
mostly) was added to the output of I<SHOW STATUS> in MySQL 3.23.x and
B<mytop> makes use of it. If the information is not available, you
will simply see zeros where the real numbers should be.

Simply running this program will increase your overall counters. But
you may or may not view that as a bug.

B<mytop> consumes too much CPU time when running (verified on Linux
and FreeBSD). It's likely a problem related to Term::ReadKey. I
haven't had time to investigate yet, so B<mytop> now automatically
lowers its priority when you run it. You may also think about running
B<mytop> on another workstation instead of your database server.

You can't easily toggle the sorting order of the threads or filter the
information (yet). Ideally you should be able to view only threads
belonging to a particular user or those which are using a particular
database, and so on. That functionality is on the TODO list that I
haven't committed to disk yet.

You can't specify the maximum number of threads to list. If you have
many threads and a tall xterm, B<mytop> will always try to display as
many as it can fit.

The size of most of the columns in the display has a small maximum
width. If you have fairly long database/user/host names the display
may appear odd. I have no good idea as to how best to deal with that
yet. Suggestions are welcome.

Full query info is not implemented. I'd like to be able to show the
whole query for a given thread. This will be especially useful in
tracking slow queries.

It'd be cool if you could just add B<mytop> configuration directives
in your C<my.cnf> file instead of having a separate config file.

=head1 AUTHOR

mytop was developed and is maintained by Jeremy D. Zawodny
(jzawodn@yahoo-inc.com).

If you wish to e-mail me regarding this software, B<PLEASE> prefix the
Subject line of your message with ``mytop'' so that my mail filter
will notice it. I will be able to respond more quickly and it will
show that you bothered to read the documentation first.

=head1 DISCLAIMER

While I use this software in my job at Yahoo!, I am solely responsible
for it. Yahoo! does not support this software in any way. It is merely
a personal idea which happened to be very useful in my job.

=head1 RECRUITING

If you hack Perl and grok MySQL, come work at Yahoo! Contact me for
details. Or just send me your resume.

=head1 SEE ALSO

Please check the MySQL manual if you're not sure where some of the
output of B<mytop> is coming from.

=head1 COPYRIGHT

Copyright (C) 2000, Jeremy D. Zawodny.

=head1 CREDITS

Fix a bug. Add a feature. See your name here!

Many thanks go to these fine folks:

=over

=item Jan Willamowius (jan@janhh.shnet.org)

Mirnor bug report. Documentation fixes.

=item Alex Osipov (alex@acky.net)

Long command-line options, Unix socket support.

=item Stephane Enten (tuf@grolier.fr)

Suggested batch mode.

=item Richard Ellerbrock (richarde@eskom.co.za)

Bug reports and usability suggestions.

=item William R. Mattil (wrm@newton.irngtx.tel.gte.com)

Bug report about empty passwords not working.

=back

See the Changes file on the B<mytop> distribution page for more
details on what has changed.

=head1 LICENSE

B<mytop> is licensed under the GNU General Public License version
2. For the full license information, please visit
http://www.gnu.org/copyleft/gpl.html

=cut

__END__



