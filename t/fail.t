#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 17;

our $UNDEF = qr{^Can't call method "private" on an undefined value };
our $NONREF = qr{^Can't call method "private" without a package or object reference };
our $UNBLESSED = qr{^Can't call method "private" on unblessed reference };
our $GLOB = qr{^Can't locate object method "private" via package "IO::Handle" };

{
    use Method::Lexical 'UNIVERSAL::private' => sub { 'private!' };

    my $self = bless {};
    my $private = 'private';
    my $undef = undef;
    my $nonref = 42;
    my $unblessed = [];
    my $stdout = *STDOUT;

    is($self->private(), 'private!', 'lexical methods works for blessed reference');

    eval { undef->private() };
    like($@, $UNDEF, 'method call on undefined literal passed through to pp_method_named');

    eval { $undef->private() };
    like($@, $UNDEF, 'method call on undefined variable passed through to pp_method_named');

    eval { undef->$private() };
    like($@, $UNDEF, 'method call on undefined literal passed through to pp_method');

    eval { $undef->$private() };
    like($@, $UNDEF, 'method call on undefined variable passed through to pp_method');

    eval { 42->private() };
    like($@, $NONREF, 'method call on a non-reference literal passed through to pp_method_named');

    eval { $nonref->private() };
    like($@, $NONREF, 'method call on a non-reference variable passed through to pp_method_named');

    eval { 42->$private() };
    like($@, $NONREF, 'method call on a non-reference literal passed through to pp_method');

    eval { $nonref->$private() };
    like($@, $NONREF, 'method call on a non-reference variable passed through to pp_method');

    eval { []->private() };
    like($@, $UNBLESSED, 'method call on unblessed reference literal passed through to pp_method_named');

    eval { $unblessed->private() };
    like($@, $UNBLESSED, 'method call on unblessed reference variable passed through to pp_method_named');

    eval { []->$private() };
    like($@, $UNBLESSED, 'method call on unblessed reference literal passed through to pp_method');

    eval { $unblessed->$private() };
    like($@, $UNBLESSED, 'method call on unblessed reference variable passed through to pp_method');

    eval { *STDOUT->private() };
    like($@, $GLOB, 'method call on GVIO literal passed through to pp_method_named');

    eval { $stdout->private() };
    like($@, $GLOB, 'method call on GVIO variable passed through to pp_method_named');

    eval { *STDOUT->$private() };
    like($@, $GLOB, 'method call on GVIO literal passed through to pp_method');

    eval { $stdout->$private() };
    like($@, $GLOB, 'method call on GVIO variable passed through to pp_method');
}
