package Method::Lexical;

use 5.008001;

use strict;
use warnings;

use B::Hooks::EndOfScope;
use B::Hooks::OP::Check;
use B::Hooks::OP::Annotation;
use Carp qw(croak carp);
use Devel::Pragma ':all';
use XSLoader;

our $VERSION = '0.01';
our @CARP_NOT = qw(B::Hooks::EndOfScope);

XSLoader::load(__PACKAGE__, $VERSION);

my $DEBUG = xs_get_debug(); # flag indicating whether debug messages should be printed

# The key under which the $installed hash is installed in %^H i.e. 'Method::Lexical'
# Defined as a preprocessor macro in Lexical.xs to ensure the Perl and XS are kept in sync
my $METHOD_LEXICAL = xs_signature();

# accessors for the debug flags - note there is one for Perl ($DEBUG) and one defined
# in the XS (METHOD_LEXICAL_DEBUG). The accessors ensure that the two are kept in sync
sub get_debug()   { $DEBUG }
sub set_debug($)  { xs_set_debug($DEBUG = shift || 0) }
sub start_trace() { set_debug(1) } # undocumented
sub stop_trace()  { set_debug(0) } # undocumented

# This logs method installations/uninstallations
sub debug($$$$$) {
    my ($class, $action, $fqname) = @_;
    carp "$class: $action $fqname";
}

# return true if $ref ISA $class - works with non-references, unblessed references and objects
sub _isa($$) {
    my ($ref, $class) = @_;
    return Scalar::Util::blessed(ref) ? $ref->isa($class) : ref($ref) eq $class;
}

# croak with the name of this package prefixed
sub pcroak($$) {
    my ($class, $msg) = @_;
    croak "$class: $msg";
}

# split "Foo::Bar::baz" into the stash (Foo::Bar) and the name (baz)
sub _split($) {
    my @split = $_[0] =~ /^(.*)::([^:]+)$/; 
    return wantarray ? @split : \@split;
}

# load a perl module
sub load($$) {
    my ($class, $symbol) = @_;
    my $module = _split($symbol)->[0];
    eval "require $module";
    $class->pcroak("can't load $module: $@") if ($@);
}

# install one or more lexical methods in the current scope
#
# import() has to keep track of two things:
#
# 1) $installed keeps track of *all* currently active lexical methods so that Lexical.xs
#    can track them without needing to know the subclass of Method::Lexical that installed them
# 2) $class_data keeps track of which subs have been installed by this class (which may be a subclass of
#    Method::Lexical) in this scope, so that they can be unimported with "no MyPragma (...)"

sub import {
    my ($class, %bindings) = @_;

    return unless (%bindings);

    my $autoload = delete $bindings{-autoload};
    my $debug = delete $bindings{-debug};
    my $hints = my_hints;
    my $caller = ccstash();
    my $installed;

    if (defined $debug) {
        my $old_debug = get_debug();
        if ($debug != $old_debug) {
            set_debug($debug);
            on_scope_end { set_debug($old_debug) };
        }
    }

    if (new_scope($METHOD_LEXICAL)) {
        my $top_level = 0;
        my $temp = $hints->{$METHOD_LEXICAL};

        if ($temp) {

            # the hash is cloned to ensure that inner/nested scopes don't clobber/contaminate
            # outer/previous scopes with their new bindings. Likewise, unimport installs
            # a new hash to ensure that previous bindings aren't clobbered e.g.
            #
            #   {
            #        package Foo;
            #
            #        use Method::Lexical bar => sub { ... };
            #
            #        Foo->new->bar();
            #
            #        no Method::Lexical; # don't clobber the bindings associated with the previous method call
            #   }

            $installed = $hints->{$METHOD_LEXICAL} = { %$temp }; # clone
        } else {
            $top_level = 1;
            $installed = $hints->{$METHOD_LEXICAL} = {}; # create
            # disable Method::Lexical altogether when we leave the top-level scope in which it was enabled
            on_scope_end \&xs_leave if ($top_level);
            xs_enter();
        }
    } else {
        $installed = $hints->{$METHOD_LEXICAL}; # augment
    }

    # Note: the class-specific data is stored under "Method::Lexical($subclass)" rather than
    # $subclass. The subclass might well have its own uses for $^H{$subclass}, so we keep
    # our mitts off it
    #
    # Also, the unadorned class can't be used as a key if $METHOD_LEXICAL is 'Method::Lexical' (which
    # it is) as the two uses conflict with and clobber each other

    my $subclass = "$METHOD_LEXICAL($class)";
    my $class_data;

    # never use $class as the identifier for new_scope() here - see above
    if (new_scope($subclass)) {
        my $temp = $hints->{$subclass};

        $class_data = $hints->{$subclass} = $temp ? { %$temp } : {}; # clone/create
    } else {
        $class_data = $hints->{$subclass}; # augment
    }

    for my $name (keys %bindings) {
        my $sub = $bindings{$name};

        # normalize bindings
        unless (_isa($sub, 'CODE')) {
            $sub = do {
                $class->load($sub) if (($sub =~ s/^\+//) || $autoload);
                no strict 'refs';
                *{$sub}{CODE}
            } || $class->pcroak("can't find subroutine: '$sub'");
        }

        my $fqname = fqname($name, $caller);

        if (exists $installed->{$fqname}) {
            $class->debug('redefining', $fqname) if ($DEBUG);
            $installed->{$fqname} = $sub;
        } else {
            $class->debug('creating', $fqname) if ($DEBUG);
            $installed->{$fqname} = $sub;
        }

        $class_data->{$fqname} = $sub;
    }
}
   
# uninstall one or more lexical subs from the current scope
sub unimport {
    my $class = shift;
    my $hints = my_hints;
    my $subclass = "$METHOD_LEXICAL($class)";
    my $class_data;

    return unless (($^H & 0x20000) && ($class_data = $hints->{$subclass}));

    my $caller = ccstash();
    my @subs = @_ ? (map { scalar(fqname($_, $caller)) } @_) : keys(%$class_data);
    my $installed = $hints->{$METHOD_LEXICAL};
    my $new_installed = { %$installed }; # clone
    my $deleted = 0;

    for my $fqname (@subs) {
        my $sub = $class_data->{$fqname};

        if ($sub) { # the coderef of the method this subclass installed
            # if the current sub ($installed->{$fqname}) is the sub this module installed ($class_data->{$fqname})
            if (Scalar::Util::refaddr($sub) == Scalar::Util::refaddr($installed->{$fqname})) {
                $class->debug('unimporting', $fqname) if ($DEBUG);

                # what import adds, unimport taketh away
                delete $new_installed->{$fqname};
                delete $class_data->{$fqname};

                ++$deleted;
            } else {
                carp "$class: attempt to unimport a shadowed lexical method: $fqname";
            }
        } else {
            carp "$class: attempt to unimport an undefined lexical method: $fqname";
        }
    }

    if ($deleted) {
        $hints->{$METHOD_LEXICAL} = $new_installed;
    }
}

1;

__END__

=head1 NAME

Method::Lexical - private methods and lexical method overrides

=head1 SYNOPSIS

    my $test = Test::Lexical->new();

    $test->call_private(); # OK
    $test->call_dump();    # OK

    eval { $test->private() };
    warn $@; # Can't locate object method "private" via package "Test::Lexical"

    eval { $test->dump() };
    warn $@; # Can't locate object method "dump" via package "Test::Lexical"

    {
        package Test::Lexical;

        use feature qw(:5.10);

        sub new { bless {} }

        use Method::Lexical
             private          => sub { 'private' },
            'UNIVERSAL::dump' => '+Data::Dump::dump'
        ;

        sub call_private {
            my $self = shift;
            say $self->private();
        }

        sub call_dump {
            my $self = shift;
            say $self->dump();
        }
    }

=head1 DESCRIPTION

C<Method::Lexical> is a lexically-scoped pragma that implements lexical methods i.e. methods
whose use is restricted to the lexical scope in which they are defined.

The C<use Method::Lexical> statement takes a list of key/value pairs in which the keys are method
names and the values are subroutine references or strings containing the package-qualified name of the
method to be called. The following example summarizes the type of keys and values that
can be supplied.

    use Method::Lexical
      foo              => sub { print "foo", $/ }, # anonymous sub value
      bar              => \&bar,                   # code ref value
      new              => 'main::new',             # sub name value
      dump             => '+Data::Dump::dump',     # autoload Data::Dump
     'My::foo'         => \&foo,                   # override/define My::foo
     'UNIVERSAL::dump' => \&Data::Dump::dump,      # define UNIVERSAL::dump
     'UNIVERSAL::isa'  => \&my_isa,                # override UNIVERSAL::isa
     -autoload         => 1,                       # autoload all subs passed by name
     -debug            => 1;                       # show diagnostic messages

In addition, the following options are supported.

=head1 OPTIONS

C<Method::Lexical> options are prefixed with a C<-> to distinguish them from method names.

=head2 -autoload

If the C<value> is a string containing a package-qualified subroutine name, then the subroutine's module can
be automatically loaded. This can either be done on a per-method basis by prefixing the C<value>
with a C<+>, or for all named C<value> arguments by supplying the C<-autoload> option with a true value e.g.

    use Method::Lexical
         foo      => 'MyFoo::foo',
         bar      => 'MyBar::bar',
         baz      => 'MyBaz::baz',
        -autoload => 1;
or

    use MyFoo;
    use MyBaz;

    use Method::Lexical
         foo =>  'MyFoo::foo',
         bar => '+MyBar::bar', # autoload MyBar
         baz =>  'MyBaz::baz';

=head2 -debug

A trace of the module's actions can be enabled or disabled lexically by supplying the C<-debug> option
with a true or false value. The trace is printed to STDERR.

Tracing can be enabled globally by defining METHOD_LEXICAL_DEBUG as an environment variable

e.g.

    use Method::Lexical
         foo   => \&foo,
         bar   => sub { ... },
        -debug => 1;

=head1 METHODS

=head2 import

C<mysub::import> can be called indirectly via C<use Method::Lexical> or can be overridden by subclasses to create
lexically-scoped pragmas that export methods whose use is restricted to the calling scope e.g.

    package Universal::Dump;

    use base qw(Method::Lexical);

    use Data::Dump qw(dump);

    sub import { shift->SUPER::import('UNIVERSAL::dump' => \&dump) }

    1;

Client code can then import lexical methods from the module:

    #!/usr/bin/env perl

    use feature qw(:5.10);

    use FileHandle;

    {
        use Universal::Dump;

        say FileHandle->new->dump; # OK
    }

    eval { FileHandle->new->dump };
    warn $@; # Can't locate object method "dump" via package "FileHandle"

=head2 unimport

C<Method::Lexical::unimport> removes the specified lexical methods from the current scope, or all lexical methods 
if no arguments are supplied.

    use Foo;
    use Method::Lexical foo => \&foo;

    {
        use Method::Lexical
             bar => sub { ... },
            'UNIVERSAL::baz' => sub { ... }

        my $self = bless {};

        $self->foo(...); # OK
        main->bar(...);  # OK
        Foo->new->baz(); # OK

        no Method::Lexical qw(foo);

        eval { $self->foo() };
        warn $@; # Can't locate object method "foo" via package "main"

        $self->bar(...); # OK
        Foo->new->baz(); # OK

        no Method::Lexical;

        eval { $self->bar(...) };
        warn $@; # Can't locate object method "bar" via package "main"

        eval { Foo->new->baz() };
        warn $@; # Can't locate object method "baz" via package "Foo"
    }

    $self->foo(); # OK

Unimports are specific to the class supplied in the C<no> statement, so pragmas that subclass
C<Method::Lexical> inherit an C<unimport> method that only removes the methods they installed e.g.

    {
        use MyPragma qw(foo bar baz);

        use Method::Lexical quux => \&quux;

        $self->foo(...); # OK
        main->quux(...); # OK

        no MyPragma qw(foo); # unimports foo
        no MyPragma;         # unimports bar and baz
        no Method::Lexical;  # unimports quux
    }

=head1 CAVEATS

Lexical methods must be defined before any invocations of those methods are compiled, otherwise
those invocations will be compiled as ordinary method calls. This won't work:

    sub public {
        my $self = shift;
        $self->private(); # not a private method; compiled as an ordinary (public) method call
    }

    use Method::Lexical private => sub { ... };

This works:

    use Method::Lexical private => sub { ... };

    sub public {
        my $self = shift;
        $self->private(); # OK
    }

Calls to fully-qualified method names are interpreted as normal (public) method calls. So the following are not
interpreted as lexical method calls:

    my $method = 'Foo::Bar::baz';

    $self->Foo::Bar::baz();
    $self->SUPER::foo();
    $self->$method();

Likewise, method calls on glob or filehandle invocants are interpreted as ordinary method calls.

=head1 VERSION

0.01

=head1 SEE ALSO

=over

=item * L<mysubs|mysubs>

=item * L<Subs::Lexical|Subs::Lexical>

=item * L<Class::Fields|Class::Fields>

=back

=head1 AUTHOR

chocolateboy <chocolate@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by chocolateboy

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut