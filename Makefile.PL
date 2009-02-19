use 5.008001;

use strict;
use warnings;

use ExtUtils::MakeMaker;
use ExtUtils::Depends;
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

our %XS_DEPENDENCIES = ExtUtils::Depends->new(
    'Method::Lexical',
    'B::Hooks::OP::Annotation',
    'B::Hooks::OP::Check'
)->get_makefile_vars();

WriteMakefile(
    NAME          => 'Method::Lexical',
    VERSION_FROM  => 'lib/Method/Lexical.pm',
    PREREQ_PM => {
        'B::Hooks::EndOfScope'     => '0.06',
        'B::Hooks::OP::Annotation' => '0.31',
        'B::Hooks::OP::Check'      => '0.15',
        'Devel::Pragma'            => '0.51',
    },
    ABSTRACT_FROM => 'lib/Method/Lexical.pm',
    AUTHOR        => 'chocolateboy <chocolate@cpan.org>',
    LIBS          => [''],
    DEFINE        => '',
    INC           => '-I.',
    OPTIMIZE      => $optimize,
    ($ExtUtils::MakeMaker::VERSION >= 6.31 ? (LICENSE => 'perl') : ()),
    %XS_DEPENDENCIES,
);
