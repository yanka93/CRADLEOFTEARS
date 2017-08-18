#!/usr/bin/perl -w

# * Diff selected files.
#
# * Push selected files live.
#
# * Invoke $EDITOR and parse the resulting output, selecting all files which
#   match.
#
# * Deselect all files.
#
#

package MultiCvsUI;
use strict;

BEGIN {
    # Versioning stuff and custom includes
    use vars qw{$VERSION $RCSID};

    $VERSION    = do { my @r = (q$Revision: 1.3 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };
    $RCSID      = q$Id: mcvsui.pl,v 1.3 2004/04/21 00:19:14 deveiant Exp $;

    if ( ! $ENV{HOME} || ! -d $ENV{HOME} ) {
        die "LJHOME not set or invalid";
    }
    use lib ("$ENV{LJHOME}/cgi-bin", "$ENV{LJHOME}/cvs/wcmtools/lib");

    use Carp            qw{confess croak};
    use Curses::UI      qw{};
    use Cwd             qw{getcwd};
    use Data::Dumper    qw{};
    use IO::File        qw{};
    use IO::Handle      qw{};
    use List::Util      qw{max min};
    use File::Temp      qw{tempfile tempdir};
    use File::Spec      qw{};
    use Fcntl           qw{SEEK_SET};

    use MultiCVS        qw{};

    $Data::Dumper::Indent = 1;
    $Data::Dumper::Terse = 1;
}


our ( $MultiCvsConf, $GoLive, %Keynames, %WindowOptions, %KeyBindings );

# The path to the multicvs config
$MultiCvsConf = $ENV{LJHOME} . "/cvs/multicvs.conf";

# The path to the golive program
$GoLive = $ENV{LJHOME} . "/bin/golive";

# Map of keys to human-readable names for onscreen keybinding documentation
%Keynames = (
    "\t"    => "<tab>",
    "\n"    => "<ret>",
    "\e"    => "<esc>",
);


%WindowOptions = (
    mainWindow => [
        mainWindow      => 'Window',
        -title          => "MultiCVS UI $VERSION",
        -titlereverse   => 0,
        -border         => 1,
        #-padbottom      => 5,
    ],

    selectionList => [
        selList         => 'Listbox',
        -multi          => 1,
        -values         => [],
        -labels         => {},
        -border         => 1,
        -vscrollbar     => 1,
        -htmltext       => 1,
        -ipadleft       => 2,
        -ipadright      => 2,
        -ipadtop        => 1,
        -ipadbottom     => 1,
        -padbottom      => 5,
    ],

    helpPane => [
        ''              => 'Label',
        -border         => 0,
        -width          => -1,
        #-height         => -1,
        -y              => -1,
        -ipad           => 1,
        -paddingspaces  => 1,
    ],

    logWindow => [
        logWindow       => 'Window',
        -title          => 'Log',
        -border         => 1,
        -titlereverse   => 0,
        -padtop         => 2,
        -padleft        => 1,
        -padright       => 1,
        -padbottom      => 6,
        -ipad           => 1,
    ],

    logViewer => [
        logViewer       => 'TextViewer',
        title           => "Log",
        -text           => "",
        -wrapping       => 1,
    ],

    pagerWindow => [
        pagerWindow     => 'Window',
        -title          => "Pager",
        -border         => 1,
        -titlereverse   => 0,
        -padtop         => 2,
        -padleft        => 1,
        -padright       => 1,
        -padbottom      => 6,
        -ipad           => 1,
    ],

    pager => [
        pager           => 'TextViewer',
        -text           => "",
        -wrapping       => 0,
        -showoverflow   => 1,
    ],

    applyDialog => [
        applyDialog     => "Dialog::Basic",
        -title          => "Apply",
        -message        => "Command? (d)iff, (g)olive, (u)nmark",
        -buttons        => ['cancel'],
    ],
);

# App keybindings
%KeyBindings = (

    # 'l': Switch focus to the log viewer
    "l"    => {
        desc        => "Show/hide the log",
        handler     => "showLog",
        applyable   => 0,
    },

    # 'a': Apply (aggregate) next command
    a       => {
        desc        => "Apply",
        handler     => "applyCommand",
        applyable   => 0,
    },

    # 'd': Show diffs for current selection
    d       => {
        desc        => "Diff",
        handler     => "showDiff",
        applyable   => 1,
    },

    # 'g': Push files up to the live site
    g       => {
        desc        => "Golive",
        handler     => "pushFilesLive",
        applyable   => 1,
    },

    # 'e': Edit the list of selected files
    e       => {
        desc        => "Edit Selection",
        handler     => "editSelection",
        applyable   => 0,
    },

    # 'u': Unmark all selected files
    u       => {
        desc        => "Unmark All",
        handler     => "unmarkAll",
        applyable   => 1,
    },

);



#####################################################################
### M A I N   B O D Y
#####################################################################

### (CLASS) METHOD: new( undef )
### Instantiate and return a new CvsReportShell.
sub new {
    my $proto = shift;
    my $class = ref $proto || $proto;

    my $self = bless {
        mainWindow  => undef,   # Main enclosing window
        selList     => undef,   # Selection list (holds files)
        logWindow   => undef,   # Logging window
        logViewer   => undef,   # Log viewer window
        pagerWindow => undef,   # Pager top-level window
        pager       => undef,   # Pager scrolling container

        display     => 'cvs',   # Display 'cvs', 'live', or 'both' updates?

        _log        => undef,
       }, $class;

    # Open the logfile and append to it.
    open $self->{_log}, ">>mcvsui.log" or die "Failed to open log: $!";
    $self->logmsg( "\n\n>>> Starting shell at %s\n\n", scalar localtime );

    # Get the interface object to the multicvs layout
    die "Cannot find multicvs.conf: Is your \$LJHOME set correctly?\n"
        unless -e $MultiCvsConf;
    $self->{multicvs} = new MultiCVS ($MultiCvsConf)
        or die "Failed to create multicvs interface";

    # Create the UI object
    $self->{ui} = new Curses::UI( -color_support => 0 );
    $self->setupWindows;

    # Circular reference: Be sure to break this association if the object needs
    # to be destroyed.
    $self->{ui}->userdata( $self );

    return $self;
}


### METHOD: run( undef )
### Run the shell.
sub run {
    my $self = shift or confess "Cannot be used as a function";

    my (
        %bindings,
        @keydocs,
       );

    $self->logmsg( "Running the shell." );

    # Global keybindings
    $self->{ui}->set_binding( sub {$self->exitDialog}, "\cq" );
    $self->{ui}->set_binding( sub {$self->exitDialog}, "\cc" );

    # Log viewer keybindings
    $self->{logViewer}->set_binding( sub {$self->{selList}->focus}, "\t" );

    # Add a binding and documentation for each key
    foreach my $key ( keys %KeyBindings ) {
        my $code;

        # Either build a callback to invoke the handler by name or use an
        # explicit CODE ref if present
        if ( ! exists $KeyBindings{$key}{code} ) {
            my $method = $KeyBindings{$key}{handler};
            $code = sub { $self->$method() };
        } else {
            $code = $KeyBindings{$key}{code};
        }

        $self->{selList}->set_binding( $code, $key );
    }

    # List the keybindings in the help window
    $self->makeHelpPane( \%KeyBindings );

    # Read cvsreport's output and put it in the selectlist
    $self->populateSelectionList;

    # Start the main event loop
    $self->{selList}->focus;
    $self->{ui}->mainloop;
}


### METHOD: showLog( undef )
### Show the log viewer window.
sub showLog {
    my $self = shift or confess "Cannot be used as a function";
    $self->{logViewer}->focus;
}


### METHOD: applyCommand( undef )
### Apply a command to all selected files.
sub applyCommand {
    my $self = shift or confess "Cannot be used as a function";
    my $list = $self->{selList};
    my @selections = $list->get;

    my $dialog = $self->{ui}->add( @{$WindowOptions{applyDialog}} );

    # Add a binding and documentation for each key
    foreach my $key ( keys %KeyBindings ) {
        next unless $KeyBindings{$key}{applyable};
        my $code;

        # Either build a callback to invoke the handler by name or use an
        # explicit CODE ref if present
        if ( ! exists $KeyBindings{$key}{code} ) {
            # Call the handler with a true value to set 'apply mode'
            my $method = $KeyBindings{$key}{handler};
            $code = sub {
                $dialog->lose_focus;
                $self->$method(1);
            };
        } else {
            $code = sub {
                $dialog->lose_focus;
                $KeyBindings{$key}{code}->(1);
            };
        }

        $dialog->set_binding( $code, $key );
    }

    $dialog->set_binding( sub {}, "\e" );

    $dialog->modalfocus;
    $dialog->lose_focus;
    $self->{ui}->delete( $WindowOptions{applyDialog}[0] );
}


### METHOD: makeHelpPane( \%KeyBindings )
### Given a hashref of keybindings, write the list of documentation for them to
### the help window.
sub makeHelpPane {
    my $self = shift        or throw Exception::MethodError;
    my $bindings = shift    or return ();

    my (
        @keydocs,
        $keyhelp,
        $cols,
        $colwidth,
        $colpat,
        $rows,
        $helptext,
        $curcol,
       );

    $self->logmsg( "Building keyhelp" );

    $colwidth = 0;
    foreach my $key ( keys %$bindings ) {
        #$self->logmsg( "Generating key help for %s: %s", $key, $bindings->{$key} );
        if ( exists $Keynames{$key} ) {
            $keyhelp = sprintf( '%5s %s', $Keynames{$key}, $bindings->{$key}{desc} );
        } else {
            $keyhelp = sprintf( ' <%s>  %s', $key, $bindings->{$key}{desc} );
        }

        push @keydocs, $keyhelp;
        $colwidth = length $keyhelp if length $keyhelp > $colwidth;
    }

    # Make all the column widths the same by padding with spaces.
    $colpat = "\%${colwidth}s";
    @keydocs = map { sprintf $colpat, $_ } @keydocs;

    # Calculate columns and rows
    $cols = int( $self->{helpPane}->canvaswidth / $colwidth + 2 );
    $rows = min( (int(scalar @keydocs / $cols) || 1), $self->{helpPane}->canvasheight );
    return () if $cols < 1 || $rows < 1;

    # Build the actual text rows
    $helptext = '';
    foreach my $row ( 0 .. ($rows - 1) ) {
        $curcol = $cols * $row;
        $helptext .= " " . join(' ', @keydocs[$curcol .. $curcol + $cols]) . " \n";
    }

    $self->{helpPane}->text( $helptext );
}



### METHOD: editSelection( @items )
### Edit the list of the selected items as text, making any changes necessary to
### reflect the changes made in the file.
sub editSelection {
    my $self = shift or confess "Cannot be used as a function";
    my $list = $self->{selList};
    my @items = $list->get;
    my @newItems = $self->forkEditor( join("\n", @items) . "\n" );

    # Explode space-separated lines into multiple entries, discarding null
    # entries.
    @newItems = grep { defined } map { split /(?!<\\)\s+/, $_ } @newItems;
    #$self->logmsg( "Got modified selection list: %s", \@newItems );

    $self->populateSelectionList( @newItems );
}


### METHOD: pushFilesLive( @files )
### Ask the golive script to publish the specified I<files>.
sub pushFilesLive {
    my $self = shift or confess "Cannot be used as a function";
    my $applyMode = shift || 0;

    my $list = $self->{selList};
    my @files = ();

    if ( $applyMode ) {
        @files = $list->get;
    } else {
        @files = ( $list->get_active_value );
    }

    $self->{ui}->status( sprintf("Pushing %d files live.", scalar @files) );
    my @output = $self->forkRead( $GoLive, @files );
    $self->logmsg( "Output from golive:\n%s", join('', @output) );
    $self->{ui}->nostatus;

    $self->populateSelectionList;
}


### METHOD: unmarkAll( undef )
### Unmark all marked files.
sub unmarkAll {
    my $self = shift or confess "Cannot be used as a function";

    $self->{selList}->clear_selection;
    $self->populateSelectionList;
}


### METHOD: showDiff( @files )
### Ask cvsreport for a diff and display it in the pager window.
sub showDiff {
    my $self = shift or confess "Cannot be used as a function";
    my $applyMode = shift || 0;

    my $list = $self->{selList};
    my @files = ();

    if ( $applyMode ) {
        @files = $list->get;
    } else {
        @files = ( $list->get_active_value );
    }

    $self->logmsg( "Got list of files to diff: %s", \@files );

    # Slice out just the tuples that are needed for the diff
    my @tuples = @{$self->{changes}}{ @files };
    $self->logmsg( "Got list of tuples for files to diff: %s", \@tuples );

    # Get unified diffs
    #$self->{multicvs}{_debug} = 1;
    my @diffs = $self->{multicvs}->get_diffs( ['-u'], @tuples );
    #$self->{multicvs}{_debug} = 0;
    $self->logmsg( "Got diffs: %s", \@diffs );

    my $title = sprintf( "Differences (%d files)", scalar @files );
    $self->showPager( $title, @diffs );
}


### METHOD: showPager( $text )
### Fork an instance of the user's pager as defined by C<$PAGER> and pipe the
### given I<text> to it after temporarily leaving curses mode.
sub showPager {
    my $self = shift or confess "Cannot be used as a function";
    my $title = shift;
    my $text = join '', @_;

    # If they have a pager configured, use that to display the output
    if ( ($ENV{PAGER} || $ENV{MCVSUI_PAGER}) && $ENV{MCVSUI_PAGER} ne 'builtin' ) {
        $self->forkWrite( $text, $ENV{MCVSUI_PAGER}||$ENV{PAGER} );
    }

    # Otherwise use the built-in page
    else {
        $self->{pagerWindow}->title( $title || 'Pager' );
        $self->{pager}->text( $text );
        $self->{pager}->focus;
    }
}




#   'htdocs/site/free.bml' => {
#     'cvs_time' => 1075506514,
#     'to' => '/Library/LiveJournal/cvs/local/htdocs/site/free.bml',
#     'type' => 'l',
#     'from' => '/Library/LiveJournal/htdocs/site/free.bml',
#     'module' => 'local',
#     'live_time' => 1075935006
#   },


### METHOD: populateSelectionList( @selected )
### Run cvsreport and populate the selectlist with the files which are reported
### as actionable. Files in I<selected> will be pre-selected.
sub populateSelectionList {
    my $self = shift or confess "Cannot be used as a function";
    my @selected = @_;

    my (
        $maxlength,
        $changes,
        @displayKeys,
        @values,
        %labels,
        %selectPositions,
        $count,
       );

    $changes = $self->{multicvs}->find_changed_files;

    # Get the list of relpaths to display based on the current view mask
    @displayKeys = grep {
        $self->{display} eq 'both'
            or
        ( $self->{display} eq 'cvs' && $changes->{$_}{type} eq 'c' )
            or
        $self->{display} eq 'live'
    } sort keys %$changes;

    $self->logmsg( "Selected %d '%s' changes of %d total",
                   scalar @displayKeys,
                   $self->{display},
                   scalar keys %$changes );

    # If there were changes to list, list 'em
    if ( @displayKeys ) {
        $maxlength = max map { length $_ } @displayKeys;

        $self->logmsg( "Got %d items to set in the select list.", scalar @displayKeys );
        $count = 0;

        # For each file cvsreport says needs moving, add the filename to the
        # list of raw items, make a label for display purposes, and note the
        # item's position so it can be highlighted later.
        foreach my $relpath ( @displayKeys ) {
            $labels{ $relpath } =
                sprintf( "%-*s  [%s]", $maxlength, $relpath,
                         $changes->{$relpath}{module} );
            $selectPositions{ $relpath } = $count;
            $count++;
        }

        # Stuff the items into the select list. Merge the selected item
        # filenames with the map of their indexes.
        $self->logmsg( "Setting the select list to: %s", \@displayKeys );
        $self->{changes} = $changes;
        $self->{selList}->values( \@displayKeys );
        $self->{selList}->labels( \%labels );
        $self->{selList}->set_selection( @selectPositions{@selected} );
        $self->{selList}->title( scalar @displayKeys . " Pending Files" );
    } else {
        $self->{changes} = undef;
        $self->{selList}->values();
        $self->{selList}->labels( {} );
        $self->{selList}->set_selection();
        $self->{selList}->title( "No Pending Files" );
    }
}


### METHOD: logmsg( $fmt, @args )
### Write a message to a logfile and to the log window if it's been created
### already. The I<fmt> is a C<printf>-style output format, and I<args> is a
### list of arguments to the C<sprintf> call, with the additional functionality
### of dumping references instead of just stringifying them as-is for C<%s>.
sub logmsg {
    my $self = shift or confess "Can't be used as a function";
    my ( $format, @args ) = @_;

    chomp( $format );
    $format .= "\n";

    for ( my $i = 0; $i <= $#args; $i++ ) {
        next unless ref $args[$i];
        $args[$i] = Data::Dumper->Dumpxs( [$args[$i]], [qw{$i}] );
    }

    $self->{_log}->printf( $format, @args ) if $self->{_log};
    $self->appendToLogWindow( sprintf($format, @args) );
}


### METHOD: appendToLogWindow( $text )
### Append the specified I<text> to the log window if it's been created already.
sub appendToLogWindow {
    my $self = shift or confess "Cannot be used as a function";
    my $text = shift;

    my $lv = $self->{logViewer} or return ();
    $lv->text( $lv->get . $text );
    $lv->cursor_to_end;
}


### METHOD: forkRead( $cmd, @args )
### Fork and exec the specified I<cmd>, giving it the specified I<args>, and
### return the output of the command as a list of lines.
sub forkRead {
    my $self = shift or confess "Cannot be used as a function";
    my ( $cmd, @args ) = @_;

    my (
        $fh,
        @lines,
        $pid,
       );

    #$self->logmsg( "Reading from a forked child." );

    # Fork-open and read the child's output as the parent
    if (( $pid = open($fh, "-|") )) {
        @lines = <$fh>;
        $fh->close;
    }

    # Child - capture output for diagnostics and progress display stuff.
    else {
        die "Couldn't fork: $!" unless defined $pid;
        $self->{ui}->clear_on_exit( 0 );

        open STDERR, ">&STDOUT" or die "Can't dup stdout: $!";
        { exec $cmd, @args };

        # Only reached if the exec() fails.
        close STDERR;
        close STDOUT;
        exit 1;
    }

    #$self->logmsg( "Read %d lines from '%s'", scalar @lines, $cmd );
    return @lines;
}


### METHOD: forkWrite( $output, $cmd, @args )
### Fork and exec the specified I<cmd> with the specified I<args> and
### print the given I<output> to it.
sub forkWrite {
    my $self = shift or confess "Cannot be used as a function";
    my ( $output, $cmd, @args ) = @_;

    my (
        $fh,
        $pid,
       );

    $self->logmsg( "Leaving curses..." );
    $self->{ui}->leave_curses;

    # Fork-open and read the child's output as the parent
    if (( $pid = open($fh, "|-") )) {
        print $fh $output;
        $fh->close;
    }

    # Child - capture output for diagnostics and progress display stuff.
    else {
        die "Couldn't fork: $!" unless defined $pid;

        { exec $cmd, @args };

        # Only reached if the exec() fails.
        exit 1;
    }

    $self->{ui}->reset_curses;
    $self->logmsg( "Curses restored." );
}


### METHOD: forkEditor( $content )
### Write the given I<content> to a tempfile and invoke $ENV{EDITOR} on it,
### returning whatever was left in it after the editor returns.
sub forkEditor {
    my $self = shift or confess "Cannot be used as a function";
    my $content = shift || '';

    my (
        $editor,
        $tempdir,
        $tempfile,
        $fname,
        $fh,
        $pid,
        @rlines,
       );

    # Pick the editor based on the environment or a sensible default
    $editor = $ENV{EDITOR} || $ENV{VISUAL} || 'vi';

    # Pick a temporary directory on this platform
    $tempdir = File::Spec->tmpdir;

    # Open a tempfile and write the conte to it
    ( $tempfile, $fname ) = tempfile( "mcvsui.XXXXX", DIR => $tempdir );
    $self->logmsg( "Writing %d bytes to '%s'", length $content, $fname );
    $tempfile->print( $content );
    $tempfile->close;

    # Switch off curses
    $self->logmsg( "Leaving curses..." );
    $self->{ui}->leave_curses;

    # Invoke the editor on the tempfile
    unless ( system($editor, $fname) == 0 ) {
        die "Could not invoke '$editor': Error $?\n\n";
    }

    # Restore the curses ui
    $self->{ui}->reset_curses;
    $self->logmsg( "Curses restored." );

    # Rewind and re-read the tempfile back in
    $tempfile = new IO::File( $fname, "r" )
        or die "open: $fname: $!";
    @rlines = <$tempfile>;
    $tempfile->close;
    unlink $fname if -e $fname;

    chomp( @rlines );
    $self->logmsg( "Read in:\n%s", \@rlines );

    return @rlines;
}


### METHOD: setupWindows( undef )
### Set up all the initial windows.
sub setupWindows {
    my $self = shift or confess "Cannot be used as a function";

    # Create the main window
    $self->{mainWindow} = $self->{ui}->add( @{$WindowOptions{mainWindow}} );
    $self->{selList} = $self->{mainWindow}->add( @{$WindowOptions{selectionList}} );
    $self->{helpPane} = $self->{mainWindow}->add( @{$WindowOptions{helpPane}} );
    $self->logmsg( "Created main window." );

    # Create the log window at the bottom of the screen and put a text viewer in
    # it.
    $self->{logWindow} = $self->{ui}->add( @{$WindowOptions{logWindow}} );
    $self->{logViewer} = $self->{logWindow}->add( @{$WindowOptions{logViewer}} );
    $self->{logViewer}->set_binding( sub {$self->{mainWindow}->focus} => 'q' );
    $self->logmsg( "Created log window." );

    # Create the pager window and widget
    $self->{pagerWindow} = $self->{ui}->add( @{$WindowOptions{pagerWindow}} );
    $self->{pager} = $self->{pagerWindow}->add( @{$WindowOptions{pager}} );
    $self->{pager}->set_binding( sub {$self->{mainWindow}->focus} => "q" );
    $self->logmsg( "Create the pager window." );

}


### METHOD: exitDialog( undef )
### Display an confirmation dialog and quit if the user confirms.
sub exitDialog {
    my $self = shift or confess "Cannot be used as a function";

    exit( 0 );
    #my $return = $self->{ui}->dialog(
    #    -message   => "Really quit?",
    #    -title     => "Confirm",
    #    -buttons   => ['yes', 'no'],
    #   );
    #
    #exit(0) if $return;
}







#####################################################################
### C L E A N U P
#####################################################################
END {
    #Cdk::end();
}



package mcvsui;
use strict;

open STDERR, ">err.out" or die "open: STDERR: $!";

my $sh = new MultiCvsUI;
$sh->run;
