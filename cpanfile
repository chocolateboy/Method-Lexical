on 'runtime' => sub {
    requires 'perl' => '5.008001';
    requires 'strict';
    requires 'warnings';
    requires 'B::Hooks::EndOfScope';
    requires 'B::Hooks::OP::Annotation';
    requires 'B::Hooks::OP::Check';
    requires 'Devel::Pragma';
    requires 'Exporter';
    requires 'XS::MRO::Compat';
    requires 'XSLoader' => '0.14';
};

on 'build' => sub {
    requires 'Config';
    requires 'ExtUtils::Depends';
    requires 'ExtUtils::MakeMaker';
    requires 'XS::MRO::Compat';
};

on 'configure' => sub {
    requires 'Config';
    requires 'ExtUtils::MakeMaker';
    requires 'XS::MRO::Compat';
};

on 'test' => sub {
    requires 'constant';
    requires 'Data::Dumper';
    requires 'Test::More' => '0.88';
    requires 'Test::Pod';
};

on 'develop' => sub {
    requires 'Pod::Coverage::TrustPod';
    requires 'Test::CheckManifest' => '1.29';
    requires 'Test::CPAN::Changes' => '0.4';
    requires 'Test::CPAN::Meta';
    requires 'Test::Kwalitee'      => '1.22';
    requires 'Test::Pod::Coverage';
    requires 'Test::Pod::Spelling::CommonMistakes' => '1.000';
};
