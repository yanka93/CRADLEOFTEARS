#!/usr/bin/perl -w
#
#--------------------------------------------------

=head1 Description

This class will make a proper daemon out of an arbitrary subroutine.
Your script will automatically inherit daemon command line flags, that
can intermix with your existing flags.  (As long as you use Getopt!)

=head1 Examples

=head2 Basic usage
 
 use Danga::Daemon;

 Danga::Daemon::daemonize( \&worker );

 sub worker
 {
    # do something
 }

=head2 Advanced usage

 # This spawns a listener on localhost:2000, adds a command to the CLUI,
 # and does the daemon work as user 'nobody' 4 times a second:

 Danga::Daemon::daemonize( 
         \&worker,
         {
             interval   => .25,
             shedprivs  => 'nobody',
 
             listenport => 2000,
             bindaddr   => '127.0.0.1',
             listencode => \&cmd,
         }
 );

 sub cmd
 {
    my ( $line, $s, $c, $codeloop, $codeopts ) = @_;

    if ($line =~ /newcommand/i) {
        # do something
        print $c ".\nOK\n";
        return 1;
    }

    return;
 }

=head1 Command line switches

=over 4

=item --foreground

Run the script without daemon code, and print output to screen.

=item --stop

Stop an existing daemon.

=item --pidfile

Store the pidfile in a location other than /var/run.  Useful if you are
running the script as a non-root user.  Use the string 'none' to disable
pidfiles entirely.

=back

=head1 Options list

Options are passed as the second argument to daemonize(), in the form of
a hashref.

=over 4

=item args [ array of args ]

A normal list of arguments that will be passed to the worker subroutine.

=item bindaddr [ ip address ]

If using a listener, bind to a specific IP.  Not defining this will let
the listener bind to all IPs.

=item chdir [ directory ]

Tell the worker where to 'live'.  Listener also, if one exists.
Defaults to '/'.

=item interval [ number in fractional seconds ]

Default eventloop time is 1 minute.  Set this to override, in seconds,
or fractions thereof.

=item listenport [ port ]

The port the listener will bind to.  Setting this option is also the
switch to enable a listener.

=item listencode [ coderef ]

An optional coderef that can add to the existing default command line
options. See the above example.

=item override_loop [ boolean ]

Your daemon may need to base its looping on something other than a time
value.  Setting this puts the looping burden on the caller.  Note in
this instance, the 'interval' option has no meaning.

=item shedprivs [ system username ]

If starting up as root, automatically change process ownership after
daemonizing.

=item shutdowncode [ coderef ]

If your child is doing special processing and needs to know when it's
being killed off, provide a coderef here.  It will be called right before
the worker process exits.

=back

=head1 Default telnet commands

These commands only apply if you use the 'listenport' option.

=over 4

=item pids

Report the pids in use.  First pid is the listener.  Any remaining are
workers.

=item ping

Returns the string 'pong' along with the daemon name.

=item reload

Kill off any workers, and reload them.  An easy way to restart a worker
if library code changes.

=item stop

Shutdown the entire daemon.

=back

=cut

#--------------------------------------------------
package Danga::Daemon;

use strict;
use Carp qw/ confess /;
use Getopt::Long qw/ :config pass_through /;
use POSIX 'setsid';
use FindBin qw/ $RealBin $RealScript /;

use vars qw/ $busy $stop $opt $pidfile $pid $shutdowncode /;

# Make daemonize() and debug() available to the caller
*main::debug = \&Danga::Daemon::debug;
*main::daemonize = \&Danga::Daemon::daemonize;

# Insert global daemon command line opts before script specific ones,
# With the addition of Getopt::Long's 'config pass_through', this
# essentially merges the command line options.
BEGIN {
    $opt = {};
    GetOptions $opt, qw/ stop foreground pidfile=s /;
}

# put arbitrary code into a loop after forking into the background.
sub daemonize
{
    my $codeloop = shift || confess "No coderef loop supplied.\n";
    confess "Invalid coderef\n" unless ref $codeloop eq 'CODE';
    my $codeopts = shift || {};

    $SIG{$_} = \&stop_parent foreach qw/ INT TERM /;
    $SIG{CHLD} = 'IGNORE';
    $pidfile = $opt->{'pidfile'} || "/var/run/$RealScript.pid";
    $| = 1;

    # setup shutdown ref if necessary
    if ( $codeopts->{'shutdowncode'} && ref $codeopts->{'shutdowncode'} eq 'CODE' ) {
        $shutdowncode = $codeopts->{'shutdowncode'};
    }

    # shutdown existing daemon?
    if ( $opt->{'stop'} ) {
        if ( -e $pidfile ) {
            open( PID, $pidfile );
            chomp( $pid = <PID> );
            close PID;
        }
        else {
            confess "No pidfile, unable to stop daemon.\n";
        }

        if ( kill 15, $pid ) {
            print "Shutting down daemon.";
            unlink $pidfile;
        }
        else {
            print "Daemon not running?\n";
            exit 0;
        }

        # display something while we're waiting for a
        # busy daemon to shutdown
        while ( kill 0, $pid ) { sleep 1 && print '.'; }
        print "\n";
        exit 0;
    }

    # daemonize.
    if ( !$opt->{'foreground'} ) {

        if ( -e $pidfile ) {
            print "Pidfile already exists! ($pidfile)\nUnable to start daemon.\n";
            exit 0;
        }

        fork && exit 0;
        POSIX::setsid() || confess "Unable to become session leader: $!\n";

        $pid = fork;
        confess "Couldn't fork.\n" unless defined $pid;

        if ( $pid != 0 ) {    # we are the parent
            unless ($pidfile eq 'none') {
                unless ( open( PID, ">$pidfile" ) ) {
                    kill 15, $pid;
                    confess "Couldn't write PID file.  Exiting.\n";
                }
                print PID ($codeopts->{listenport} ? $$ : $pid) . "\n";
                close PID;
            }
            print "daemon started with pid: $pid\n";

            # listener port supplied? spawn a listener!
            spawn_listener( $codeloop, $codeopts )
                if $codeopts->{listenport};
            exit 0;  # exit from parent if no listener
        }

        # we're the child from here on out.
        child_actions( $codeopts );
    }

    # the event loop
    if ( $codeopts->{override_loop} ) {

        # the caller subref has its own idea of what
        # a loop is defined as.
        chdir ( $codeopts->{chdir} || '/') or die "Can't chdir!";
        $codeloop->( $codeopts->{args} );

    }
    else {

        # a loop is just a time interval inbetween
        # code executions
        return eventloop( $codeloop, $codeopts );
    }

    return 1;
}

sub eventloop
{
    my $codeloop = shift || confess "No coderef loop supplied.\n";
    confess "Invalid coderef\n" unless ref $codeloop eq 'CODE';
    my $codeopts = shift || {};

    chdir ( $codeopts->{chdir} || '/') or die "Can't chdir!";

    {
        no warnings;
        $SIG{CHLD} = undef;
    }

    while (1) {

        $busy = 1;
        $codeloop->( $codeopts->{args} );
        $busy = 0;

        last if $stop;
        select undef, undef, undef, ( $codeopts->{interval} || 60 );
    }

    return 0;
}

sub child_actions
{
    my $codeopts = shift || {};

    $SIG{$_} = \&stop_child foreach qw/ INT TERM /;
    $0 = $RealScript . " - worker";
    umask 0;
    chdir ( $codeopts->{chdir} || '/') or die "Can't chdir!";

    # shed root privs
    if ( $codeopts->{shedprivs} ) {
        my $uid = getpwnam( $codeopts->{shedprivs} );
        $< = $> = $uid if $uid && ! $<;
    }

    {
        no warnings;
        close STDIN  && open STDIN,  "</dev/null";
        close STDOUT && open STDOUT, "+>&STDIN";
        close STDERR && open STDERR, "+>&STDIN";
    }

    return;
}

sub spawn_listener
{
    my $codeloop = shift || confess "No coderef loop supplied.\n";
    confess "Invalid coderef\n" unless ref $codeloop eq 'CODE';
    my $codeopts = shift || {};

    use IO::Socket;
    $0 = $RealScript . " - listener";

    my ( $s, $c );
    $s = IO::Socket::INET->new(
            Type      => SOCK_STREAM,
            LocalAddr => $codeopts->{bindaddr}, # undef binds to all
            ReuseAddr => 1,
            Listen    => 2,
            LocalPort => $codeopts->{listenport},
            );
    unless ($s) {
        kill 15, $pid;
        unlink $pidfile;
        confess "Unable to start listener.\n";
    }

    # pass incoming connections to listencode()
    while ($c = $s->accept()) {
        default_cmdline( $s, $c, $codeloop, $codeopts );
    } 

    # shouldn't reach this.
    close $s;
    exit 0;
}

sub stop_parent
{
    debug("Shutting down...\n");

    if ($pid) {    # not used in foreground
        kill 15, $pid;
        waitpid $pid, 0;
        unlink $pidfile;
    }

    exit 0 unless $busy;
    $stop = 1;
}

sub stop_child
{
    # call our children to have them shut down
    $shutdowncode->() if $shutdowncode;

    exit 0 unless $busy;
    $stop = 1;
}

sub debug
{
    return unless $opt->{'foreground'};
    print STDERR (shift) . "\n";
}

# shutdown daemon remotely
sub default_cmdline
{
    my ( $s, $c, $codeloop, $codeopts ) = @_;

    while ( <$c> ) {
        # remote commands
        next unless /\w/;

        if (/pids/i) {
            print $c "OK $$ $pid\n";
            next;
        }

        elsif (/ping/i) {
            print $c "OK pong $0\n";
            next;
        }

        elsif (/(?:stop|shutdown)/) {
            kill 15, $pid;
            unlink $pidfile;
            print $c "OK SHUTDOWN\n";
            exit 0;
        }

        elsif (/(?:restart|reload)/i) {
            # shutdown existing worker
            # wait for it to completely exit
            kill 15, $pid;
            wait;

            # re-fork a new worker (no listener)
            my $newpid = fork;
            unless ($newpid) {
                close $s;
                $0 =~ s/listener/worker/;
                child_actions( $codeopts );
                eventloop( $codeloop, $codeopts );
                exit 0;
            }

            # remember the new child pid for
            # future restarts
            $pid = $newpid;
            print $c "OK $pid\n";
            next;
        }

        else {

            next if
                $codeopts->{listencode} &&
                ref $codeopts->{listencode} eq 'CODE' &&
                $codeopts->{listencode}->( $_, $s, $c, $codeloop, $codeopts );

            if (/help/i) {
                foreach (sort qw/ ping stop pids reload /) {
                    print $c "\t$_\n";
                }
                print $c ".\nOK\n";
                next;
            }

            print $c "ERR unknown command\n";
            next;
        }
    }
    return;
}

1;

