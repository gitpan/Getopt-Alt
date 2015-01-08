package Getopt::Alt;

# Created on: 2009-07-17 07:40:56
# Create by:  Ivan Wills
# $Id$
# $Revision$, $HeadURL$, $Date$
# $Revision$, $Source$, $Date$

use Moose;
use warnings;
use version;
use Carp;
use English qw/ -no_match_vars /;
use List::MoreUtils qw/uniq/;
use Getopt::Alt::Option qw/build_option/;
use Getopt::Alt::Exception;
use Try::Tiny;
use Path::Tiny;
use Config::Any;
use File::HomeDir;

use overload (
    '@{}'  => \&get_files,
    'bool' => sub { 1 },
);

Moose::Exporter->setup_import_methods(
    as_is => [qw/get_options/],
);

our $VERSION = version->new('0.2.6');
our $EXIT    = 1;

has options => (
    is      => 'rw',
    isa     => 'Str',
    default => 'Getopt::Alt::Dynamic',
);
has opt => (
    is      => 'rw',
    isa     => 'Getopt::Alt::Dynamic',
    clearer => 'clear_opt',
);
has default => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub {{}},
);
has files => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub {[]},
);
has bundle => (
    is      => 'rw',
    isa     => 'Bool',
    default => 1,
);
has ignore_case => (
    is      => 'rw',
    isa     => 'Bool',
    default => 1,
);
has help_package => (
    is      => 'rw',
    isa     => 'Str',
);
has helper => (
    is      => 'rw',
    isa     => 'Bool',
);
has cmds => (
    is      => 'rw',
    isa     => 'ArrayRef[Getopt::Alt::Command]',
    default => sub { [] },
);
has cmd => (
    is      => 'rw',
    isa     => 'Str',
    clearer => 'clear_cmd',
);
has sub_command => (
    is            => 'rw',
    #isa           => 'Bool | HashRef[ArrayRef] | CodeRef',
    predicate     => 'has_sub_command',
    documentation => <<'DOC',
if true (== 1) processing of args stops at first non-defined parameter, if
a HASH ref the keys are assumed to be the allowed sub commands and the values
are assumed to be parameters to passed to get_options where the generated
options will be a sub object of generated options object. Finally if this
is a sub ref it will be called with self and the rest of ARGV
DOC
);
has aliases => (
    is            => 'rw',
    isa           => 'HashRef[ArrayRef]',
    default       => sub {{}},
    documentation => 'Stores the list of aliases sub-commands can have',
);
has default_sub_command => (
    is        => 'rw',
    isa       => 'Str',
    predicate => 'has_default_sub_command',
);
has auto_complete => (
    is        => 'rw',
    isa       => 'CodeRef',
    predicate => 'has_auto_complete',
);
has name => (
    is      => 'rw',
    isa     => 'Str',
    default => sub { path($0)->basename },
);
has conf_prefix => (
    is      => 'rw',
    isa     => 'Str',
    default => '.',
);

my $count = 1;
around BUILDARGS => sub {
    my ($orig, $class, @params) = @_;
    my %param;

    if (ref $params[0] eq 'HASH' && ref $params[1] eq 'ARRAY') {
        %param  = %{ $params[0] };
        @params = @{ $params[1] };
    }

    if ( !exists $param{helper} || $param{helper} ) {
        unshift @params, (
            'help',
            'man',
            'VERSION',
            'auto_complete|auto-complete',
            'auto_complete_list|auto-complete-list!',
        );
    }

    if ( @params ) {
        my $class_name = 'Getopt::Alt::Dynamic::A' . $count++;
        my $object = Moose::Meta::Class->create(
            $class_name,
            superclasses => [ $param{options} || 'Getopt::Alt::Dynamic' ],
        );

        while ( my $option = shift @params ) {
            build_option($object, $option);
        }

        $param{options} = $class_name;
    }

    return $class->$orig(%param);
};

sub BUILD {
    my ($self) = @_;

    my $basename = $self->name;
    my $prefix   = $self->conf_prefix;
    my $conf = Config::Any->load_stems({
        stems   => [ "$prefix$basename", File::HomeDir->my_home . "/$prefix$basename", "/etc/$basename" ],
        use_ext => 1,
    });
    $conf = {
        map { %$_        }
        map { values %$_ }
        @{ $conf || [] }
    };

    # perlcritic is confused here combining hashes is not the same as comma separated arguments
    $self->default({ %{$self->default}, %$conf, });  ## no critic

    if ($conf->{aliases}) {
        for my $alias (keys %{ $conf->{aliases} }) {
            $self->aliases->{$alias} = [ split /\s+/, $conf->{aliases}{$alias} ];
        }
    }

    return;
}

sub get_options {  ## no critic
    my @args = @_;
    my $caller = caller;

    if ( @args > 2 && ref $args[0] eq 'HASH' && ref $args[1] ne 'ARRAY' ) {
        my $options = shift @args;
        @args = ( { default => $options}, [ @args ] );
    }

    my $self;
    try {
        $self = __PACKAGE__->new(@args);

        $self->help_package($caller) if !$self->help_package || $self->help_package eq __PACKAGE__;

        $self->process();
    }
    catch {
        if ( ref $_ && ref $_ eq 'Getopt::Alt::Exception' && $_->help ) {
            die $_;
        }

        warn $_;
        $self = __PACKAGE__->new();

        $self->help_package($caller) if !$self->help_package || $self->help_package eq __PACKAGE__;

        $self->_show_help(1);
    };

    return if !defined $self;

    return wantarray ? ( $self->opt, $self->cmd, $self ) : $self->opt;
}

sub process {
    my ($self, @args) = @_;
    my $passed_args = scalar @args;
    @args = $passed_args ? @args : @ARGV;
    $self->clear_opt;
    $self->clear_cmd;
    $self->files([]);

    my $class = $self->options;
    $self->opt( $class->new( %{ $self->default } ) );
    my @errors;

    ARG:
    while (my $arg = shift @args) {
        my $action = '';
        try {
                my ($long, $short, $data);
                if ( $arg =~ /^-- (\w[^=\s]+) (?:= (.*) )?/xms ) {
                    $long = $1;
                    $data = $2;
                }
                elsif ( $arg =~ /^- (\w) =? (.*)/xms ) {
                    $short = $1;
                    $data  = $2;
                }
                else {
                    push @{ $self->files }, $arg;
                    die $self->sub_command ? "last\n" : "next\n";
                }

                my $opt = $self->best_option( $long, $short );
                $opt->value( $self->opt->{ $opt->name } );

                my ($value, $used) = $opt->process( $long, $short, $data, \@args );
                my $opt_name = $opt->name;
                if ( $self->opt->auto_complete && $opt_name eq 'auto_complete_list' ) {
                    print join ' ', $self->list_options;
                    exit 0;
                }
                $self->opt->{$opt->name} = $value;

                if ( !$used && $short && defined $data && length $data ) {
                    unshift @args, '-' . $data;
                }
        }
        catch {
            if ( $_ eq "next\n" ) {
                $action = 'next';
            }
            elsif ( $_ eq "last\n" ) {
                # last means we have found a sub command we should see if it is an alias
                if ($self->aliases->{$arg}) {
                    $self->files->[-1] = shift @{ $self->aliases->{$arg} };
                    unshift @args, @{ $self->aliases->{$arg} };
                }

                $action = 'last';
            }
            else {
                $_ = $_->[0] if ref $_ eq 'ARRAY' && @$_ == 1;

                if ( $self->auto_complete && $self->opt->auto_complete ) {
                    push @errors, $_;
                }
                else {
                    die $_;
                }
            }
        };
        next if $action eq 'next';
        last if $action eq 'last';
    }

    $self->cmd( shift @{ $self->files } ) if @{ $self->files } && $self->sub_command;
    if ( !$passed_args && $self->files ) {
        @ARGV = ( @{ $self->files }, @args );
    }

    if ( ref $self->sub_command eq 'HASH' ) {
        my $sub = [ @{$self->sub_command->{$self->cmd}} ];
        if (!$sub) {
            warn "Unknown command '$self->cmd'!\n";
            die Getopt::Alt::Exception->new( message => "Unknown command '$self->cmd'" )
                if !$self->help_package;
            $self->_show_help(1);
        }

        if ( ref $sub eq 'ARRAY' ) {
            # check the style
            my $options  = @$sub == 2 && ref $sub->[0] eq 'HASH' && ref $sub->[1] eq 'ARRAY' ? shift @$sub : {};
            my $opt_args = %$options ? $sub->[0] : $sub;

            # build sub command object
            my $sub_obj = Getopt::Alt->new(
                {
                    %{ $options },
                    options => $self->options, # inherit this objects options
                    default => { %{ $self->opt }, %{ $options->{default} || {} } },
                },
                $opt_args
            );
            local @ARGV;
            $sub_obj->process(@args);
            $self->opt( $sub_obj->opt );
            $self->files( $sub_obj->files );
        }
    }

    if ( $self->help_package ) {
        if ( $self->opt->{VERSION} ) {
             my ($name)  = $PROGRAM_NAME =~ m{^.*/(.*?)$}mxs;
             my $version = defined $main::VERSION ? $main::VERSION : 'undef';
             die Getopt::Alt::Exception->new( message => "$name Version = $version\n", help => 1);
        }
        elsif ( $self->opt->{man} ) {
            $self->_show_help(2);
        }
        elsif ( $self->opt->{help} ) {
            $self->_show_help(1);
        }
        elsif ( $self->auto_complete && $self->opt->auto_complete ) {
            if ( $ARGV[-1] =~ /^-/ ) {
                print join ' ', $self->list_options;
            }
            else {
                # run the auto complete method
                $self->auto_complete->($self, $self->opt->auto_complete, \@errors);
            }

            # exit here as auto complete should stop processing
            exit 0;
        }
    }

    return $self;
}

sub list_options {
    my ($self) = @_;
    my @names;

    my $meta = $self->options->meta;

    for my $name ( $meta->get_attribute_list ) {
        my $opt = $meta->get_attribute($name);
        for my $name (@{ $opt->names }) {

            # skip auto-complete commands (they are hidden options)
            next if grep {$name eq $_} qw/auto_complete auto-complete auto_complete_list auto-complete-list/;
            push @names, $name
        }
    }

    return map {
            length $_ == 1 ? "-$_" : "--$_"
        }
        uniq sort { lc $a cmp lc $b } @names;
}

sub best_option {
    my ($self, $long, $short, $no) = @_;

    if ($no && $long) {
        $long =~ s/^no-//xms;
    }

    my $meta = $self->options->meta;

    for my $name ( $meta->get_attribute_list ) {
        my $opt = $meta->get_attribute($name);

        return $opt if $long && $opt->name eq $long;

        for my $name (@{ $opt->names }) {
            return $opt if $long && $name eq $long;
            return $opt if $short && $name eq $short;
        }
    }

    return $self->best_option($long, $short, 1) if !$no;

    if ( $self->help_package ) {
        die [ Getopt::Alt::Exception->new(
                message => "Unknown option '" . ($long ? "--$long" : "-$short") . "'\n",
                option  => ($long ? "--$long" : "-$short"),
            ) ]
    }
    else {
        die [ Getopt::Alt::Exception->new(
                help    => 1,
                message => "Unknown option '" . ($long ? "--$long" : "-$short") . "'\n",
                option  => ($long ? "--$long" : "-$short"),
            ) ]
    }
}

sub get_files {
    my ($self) = @_;

    return $self->files;
}

sub _show_help {
    my ($self, $verbosity, $msg) = @_;

    my %input;
    if ( $self->help_package && $self->help_package ne 1 ) {
        my $help = $self->help_package;
        if ( !-f $help ) {
            $help  .= '.pm';
            $help =~ s{::}{/}g;
        }
        %input = ( -input => $INC{$help} );
    }

    require Tie::Handle::Scalar;
    my $out = '';
    tie *FH, 'Tie::Handle::Scalar', \$out;
    require Pod::Usage;
    Pod::Usage::pod2usage(
        $msg ? ( -msg => $msg ) : (),
        -verbose => $verbosity,
        -exitval => 'NOEXIT',
        -output  => \*FH,
        %input,
    );
    die Getopt::Alt::Exception->new( message => $out, help => 1 );
}

1;

__END__

=head1 NAME

Getopt::Alt - Alternate method of processing command line arguments

=head1 VERSION

This documentation refers to Getopt::Alt version 0.2.6.

=head1 SYNOPSIS

   use Getopt::Alt;

   # Create a new options object
   my $opt = Getopt::Alt->new(
       {
           default => { string => 'default' },
       },
       [
           'string|s=s',
           ...
       ],
   );
   print "String = " . $opt->opt->{string} . "\n";

   # Getopt::Long like usage
   use Getopt::Alt qw/get_options/;

   # most basic form
   my $options = get_options(
       'string|s=s',
       'int|i=i',
       'hash|h=s%',
       'array|a=s@',
       'increment|c+',
       'nullable|n=s?',
       'negatable|b!',
   );
   print Dumper $options->opt;           # passed parameters
   print join ',', @{ $options->files }; # non option parameters

   # with defaults
   my $options = get_options(
       { negatable => 1 },
       'string|s=s',
       'int|i=i',
       'hash|h=s%',
       'array|a=s@',
       'increment|c+',
       'nullable|n=s?',
       'negatable|b!',
   );

   # with configuration
   my $options = get_options(
       {
           helper => 1, # default when using get_options
           sub_command => 1, # stop processing at first non argument parameter
       },
       [
           'string|s=s',
           'int|i=i',
           'hash|h=s%',
           'array|a=s@',
           'increment|c+',
           'nullable|n=s?',
           'negatable|b!',
       ],
   );
   print $cmd;   # sub command

   # with sub command details
   my $options = get_options(
       {
           helper => 1, # default when using get_options
           sub_command => {
               sub   => [ 'suboption' ],
               other => [ 'verbose|v' ],
           },
       },
       [
           'string|s=s',
           'int|i=i',
           'hash|h=s%',
           'array|a=s@',
           'increment|c+',
           'nullable|n=s?',
           'negatable|b!',
       ],
   );
   print Dumper $option->opt;  # command with sub command options merged in

   # auto_complete
   my $options = get_options(
       {
           helper        => 1, # default when using get_options
           auto_complete => sub {
               my ($opt, $auto) = @_;
               # ... code for auto completeion
               # called if --auto-complete specified on the command line
           },
       },
       [
           'string|s=s',
           'int|i=i',
       ],
   );

=head1 DESCRIPTION

The aim of C<Getopt::Alt> is to provide an alternative to L<Getopt::Long> that
allows a simple command line program to easily grow in complexity. It  or to a
package with multiple commands. The simple usage is quite similar to
L<Getopt::Long>:

In C<Getopt::Long> you might get your options like:

 use Getopt::Long;
 my %options = ( string => 'default' );
 GetOptions(
     \%options,
     'string|s=s',
     ...
 );

The found options are now stored in the C<%options> hash.

In C<Getopt::Alt> you might do the following:

 use Getopt::Alt qw/get_options/;
 my %default = ( string => 'default' );
 my $opt = get_options(
     \%default,
     'string|s=s',
     ...
 );
 my %options = %{ $opt->opt };

This will also result in the options stored in the C<%options> hash.

Some other differences between Getopt::Alt and Getopt::Long include:

=over 4

=item *

Bundling - is on by default

=item *

Case sensitivity is on by default

=item *

Throws error rather than returning errors.

=item *

Can work with sub commands

=back

=head1 SUBROUTINES/METHODS

=head2 Exported

=head3 C<get_options (@options | $setup, $options)>

=head3 C<get_options ($default, 'opt1', 'opt2' ... )>

This is the equivalent of calling new(...)->process but it does some extra
argument processing.

B<Note>: The second form is the same basically the same as Getopt::Long's
GetOptions called with a hash ref as the first parameter.

=head2 Class Methods

=head3 C<new ( \%config, \@optspec )>

=head4 config

=over 4

=item C<default> - HashRef

Sets the default values for all the options. The values in opt will be reset
with the values in here each time process is called

=item C<files> - ArrayRef[Str]

Any arguments that not consumed as part of options (usually files), if no
arguments were passed to C<process> then this value would also be put back
into C<@ARGV>.

=item C<bundle> - bool

Turns on bundling of arguments eg C<-rv> is equivalent to C<-r -v>. This is
on by default.

=item C<ignore_case> - bool

Turns ignoring of the case of arguments, off by default.

=item C<helper> - bool

If set to a true value this will cause the help, man, and VERSION options to
be added the end of your

=item C<help_package> -

The Perl package with the POD documentation for --help and --man, by default
it's the callers package.

=item C<cmds> - ArrayRef[Getopt::Alt::Command]

If the Getopt::Alt is being used as part of a package where individual
commands have their own modules this parameter stores an instance of each
commands. (Not yet fully implemented.

=item C<options> - ArrayRef[Getopt::Alt::Option]

The individual command option specifications processed.

=item C<opt> - HashRef

The values processed from the C<$ARGV> or arguments passed to the C<process>
method..

=item C<default> - HashRef

The default values for each option. The default value is not modified by
processing, so if set the same default will be used from call to call.

=item C<aliases> - HashRef[ArrayRef[Str]]

When using sub-commands this allows you to configure aliases for those
commands, aliases are recursed, they can have extra arguments though.
If a configuration file is used aliases can be specified in that file.

=back

Return: Getopt::Alt -

Description:

=head2 Object Methods

=head3 C<BUILD ()>

internal method

=head3 C<process ()>

=head3 C<list_options ()>

Returns a list of all command line options in the current object.

=head3 C<best_option ()>

=head3 C<get_files ()>


=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

Configuration files can be used to specify default values and aliases. They
can be located in the current directory, $HOME or /etc.The file name is
specified by the C<name> attribute (which defaults to the program's name)
and is prepended with a dot. eg:

For a program called as C<$ ./foo> or C<$ foo> C<name> would be set to foo
and possible configuration names would be

=over 4

=item *

.foo.yml

=item *

~/.foo.rc

=item *

/etc/.foo.yml

=back

See L<Config::Any> for information about config formats and file extensions.

=head1 DEPENDENCIES

=head1 INCOMPATIBILITIES

=head1 BUGS AND LIMITATIONS

There are no known bugs in this module.

Please report problems to Ivan Wills (ivan.wills@gmail.com).

Patches are welcome.

=head1 AUTHOR

Ivan Wills - (ivan.wills@gmail.com)

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009 Ivan Wills (14 Mullion Close, Hornsby Heights, NSW Australia 2077).
All rights reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself. See L<perlartistic>.  This program is
distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.

=cut
