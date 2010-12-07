
use strict;
use warnings;

BEGIN { require 5.006; }

use ExtUtils::MakeMaker 6.31;



my %WriteMakefileArgs = (
  'ABSTRACT' => 'Turnkey CPAN Testers smoking',
  'AUTHOR' => 'David Golden <dagolden@cpan.org>',
  'BUILD_REQUIRES' => {
    'CPAN::Checksums' => '0',
    'Cwd' => '3.27',
    'File::Find' => '0',
    'File::Path' => '0',
    'IO::CaptureOutput' => '1.06',
    'IO::File' => '0',
    'Test::More' => '0.62',
    'vars' => '0'
  },
  'CONFIGURE_REQUIRES' => {
    'ExtUtils::MakeMaker' => '6.31'
  },
  'DISTNAME' => 'CPAN-Reporter-Smoker',
  'EXE_FILES' => [],
  'LICENSE' => 'apache',
  'NAME' => 'CPAN::Reporter::Smoker',
  'PREREQ_PM' => {
    'CPAN' => '1.93',
    'CPAN::HandleConfig' => '0',
    'CPAN::Reporter::History' => '1.1702',
    'CPAN::Tarzip' => '0',
    'Carp' => '0',
    'Compress::Zlib' => '1.2',
    'Config' => '0',
    'Exporter' => '0',
    'ExtUtils::MakeMaker' => '6.46',
    'Fcntl' => '0',
    'File::Basename' => '0',
    'File::Spec' => '3.27',
    'File::Temp' => '0.20',
    'Module::Build' => '0.30',
    'Probe::Perl' => '0.01',
    'Term::Title' => '0.01',
    'Test::Reporter' => '1.54'
  },
  'VERSION' => '0.22',
  'test' => {
    'TESTS' => 't/*.t'
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



