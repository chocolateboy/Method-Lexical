use 5.8.1;

use strict;
use warnings;

use ExtUtils::MakeMaker;
use Config;

my $optimize;

if ($Config{gccversion}) {
    $optimize = '-O3 -Wall -Wextra';
    $optimize .= ' -g' if (-d '.svn');
} elsif ($Config{osname} eq 'MSWin32') {
    $optimize = '-O2 -W4';
} else {
    $optimize = $Config{optimize};
}

my $XS_DEPENDENCIES = eval {
    require ExtUtils::Depends;
    my %hash = ExtUtils::Depends->new(
        'Method::Lexical' => 'B::Hooks::OP::Check',
                             'B::Hooks::OP::Annotation'
    )->get_makefile_vars();

    \%hash
} || {};

warn $@ if ($@);

WriteMakefile(
    NAME          => 'Method::Lexical',
    VERSION_FROM  => 'lib/Method/Lexical.pm',
    PREREQ_PM => {
        'B::Hooks::EndOfScope'     => '0.05',
        'B::Hooks::OP::Check'      => '0.14',    # The last version that works with 5.8.0
        'B::Hooks::OP::Annotation' => '0.31',
        'Devel::Pragma'            => '0.40',
        'ExtUtils::Depends'        => '0.301',
    },
    ABSTRACT_FROM => 'lib/Method/Lexical.pm',
    AUTHOR        => 'chocolateboy <chocolate@cpan.org>',
    LIBS          => [''],
    DEFINE        => '',
    INC           => '-I.',
    OPTIMIZE      => $optimize,
    ($ExtUtils::MakeMaker::VERSION >= 6.31 ? (LICENSE => 'perl') : ()),
    %$XS_DEPENDENCIES,
);
