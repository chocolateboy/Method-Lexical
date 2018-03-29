# Method::Lexical

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [NAME](#name)
- [SYNOPSIS](#synopsis)
- [DESCRIPTION](#description)
- [OPTIONS](#options)
  - [-autoload](#-autoload)
  - [-debug](#-debug)
- [METHODS](#methods)
  - [import](#import)
  - [unimport](#unimport)
- [CAVEATS](#caveats)
- [VERSION](#version)
- [SEE ALSO](#see-also)
- [AUTHOR](#author)
- [COPYRIGHT AND LICENSE](#copyright-and-license)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# NAME

Method::Lexical - private methods and lexical method overrides

# SYNOPSIS

```perl
package MyPragma;

use base qw(Method::Lexical);

sub import {
    shift->SUPER::import(
        'private'         => sub { ... },
        'UNIVERSAL::dump' => '+Data::Dump::pp'
    )
}
```

```perl
#!/usr/bin/env perl

my $self = bless {};

{
    use MyPragma;

    $self->private(); # OK
    $self->dump();    # OK
}

$self->private; # Can't locate object method "private" via package "main"
$self->dump;    # Can't locate object method "dump" via package "main"
```

# DESCRIPTION

`Method::Lexical` is a lexically-scoped pragma that implements lexical methods i.e. methods
whose use is restricted to the lexical scope in which they are imported or declared.

The `use Method::Lexical` statement takes a hashref or a list of key/value pairs in which the keys are method
names and the values are subroutine references or strings containing the name of the
method to be called. Unqualifed method names in keys are installed as methods in the currently-compiling package.
The following example summarizes the types of keys and values that can be supplied.

```perl
use Method::Lexical {
    foo              => \&foo,               # unqualified method-name key: installed in the currently-compiling package e.g. main::foo
    MyClass::foo     => \&foo,               # qualified method-name key: installed in the specified package
    bar              => sub { ... },         # anonymous sub value
    baz              => \&baz,               # coderef value
    quux             => 'main::quux',        # sub name value: unqualified names are resolved to the currently-compiling package
    dump             => '+Data::Dump::dump', # autoload Data::Dump
   'UNIVERSAL::dump' => \&Data::Dump::dump,  # define a universal method
   'UNIVERSAL::isa'  => \&my_isa,            # override a universal method
  '-autoload'        => 1,                   # autoload modules for all subs passed by name
  '-debug'           => 1                    # show diagnostic messages
};
```

# OPTIONS

`Method::Lexical` options are prefixed with a hyphen to distinguish them from method names.
The following options are supported.

## -autoload

If the `value` is a string containing a package-qualified subroutine name, then the subroutine's module is
automatically loaded. This can either be done on a per-method basis by prefixing the `value`
with a `+`, or for all `value` arguments with qualified names by supplying the
`-autoload` option with a true value e.g.

```perl
use Method::Lexical {
     foo       => 'MyFoo::foo',
     bar       => 'MyBar::bar',
     baz       => 'MyBaz::baz',
   '-autoload' => 1,
};
```

or:

```perl
use MyFoo;
use MyBaz;

use Method::Lexical {
     foo =>  'MyFoo::foo',
     bar => '+MyBar::bar', # autoload MyBar
     baz =>  'MyBaz::baz',
};
```

This option should not be confused with lexical AUTOLOAD methods, which are also supported e.g.

```perl
use Method::Lexical {
    AUTOLOAD             => sub { ... },
   'UNIVERSAL::AUTOLOAD' => \&autoload,
};
```

## -debug

A trace of the module's actions can be enabled or disabled lexically by supplying the `-debug` option
with a true or false value. The trace is printed to STDERR.

e.g.

```perl
use Method::Lexical {
     foo    => \&foo,
     bar    => sub { ... },
   '-debug' => 1
};
```

# METHODS

## import

`Method::Lexical::import` can be called indirectly via `use Method::Lexical` or can be overridden by subclasses to create
lexically-scoped pragmas that export methods whose use is restricted to the calling scope e.g.

```perl
package Universal::Dump;

use base qw(Method::Lexical);

sub import { shift->SUPER::import('UNIVERSAL::dump' => '+Data::Dump::dump') }

1;
```

Client code can then import lexical methods from the module:

```perl
#!/usr/bin/env perl

use CGI;

{
    use Universal::Dump;

    say CGI->new->dump; # OK
}

eval { CGI->new->dump };
warn $@; # Can't locate object method "dump" via package "CGI"
```

## unimport

`Method::Lexical::unimport` removes the specified lexical methods from the current scope, or all lexical methods
if no arguments are supplied.

```perl
use Method::Lexical foo => \&foo;

my $self = bless {};

{
    use Method::Lexical {
         bar             => sub { ... },
        'UNIVERSAL::baz' => sub { ... },
    };

    $self->foo(); # OK
    $self->bar(); # OK
    $self->baz(); # OK

    no Method::Lexical qw(foo);

    eval { $self->foo() };
    warn $@; # Can't locate object method "foo" via package "main"

    $self->bar(); # OK
    $self->baz(); # OK

    no Method::Lexical;

    eval { $self->bar() };
    warn $@; # Can't locate object method "bar" via package "main"

    eval { $self->baz() };
    warn $@; # Can't locate object method "baz" via package "main"
}

$self->foo(); # OK
```

Unimports are specific to the class supplied in the `no` statement, so pragmas that subclass
`Method::Lexical` inherit an `unimport` method that only removes the methods they installed e.g.

```perl
{
    use MyPragma qw(foo bar baz);

    use Method::Lexical quux => \&quux;

    $self->foo();  # OK
    $self->quux(); # OK

    no MyPragma qw(foo); # unimports foo
    no MyPragma;         # unimports bar and baz
    no Method::Lexical;  # unimports quux
}
```

# CAVEATS

Lexical methods must be defined before any invocations of those methods are compiled, otherwise
those invocations will be compiled as ordinary method calls. This won't work:

```perl
sub public {
    my $self = shift;
    $self->private(); # not a private method; compiled as an ordinary (public) method call
}

use Method::Lexical private => sub { ... };
```

This works:

```perl
use Method::Lexical private => sub { ... };

sub public {
    my $self = shift;
    $self->private(); # OK
}
```

Method calls on glob or filehandle invocants are interpreted as ordinary method calls.

The method resolution order for lexical method calls on pre-5.10 perls is currently fixed at depth-first search.

# VERSION

0.30

# SEE ALSO

* [mysubs](https://github.com/chocolateboy/mysubs)
* [Sub::Lexical](https://metacpan.org/pod/Sub::Lexical)
* [Class::Fields](https://metacpan.org/pod/Class::Fields)

# AUTHOR

[chocolateboy](mailto:chocolate@cpan.org)

# COPYRIGHT AND LICENSE

Copyright © 2009-2013 by chocolateboy.

This is free software; you can redistribute it and/or modify it under the terms of the
[Artistic License 2.0](http://www.opensource.org/licenses/artistic-license-2.0.php).
