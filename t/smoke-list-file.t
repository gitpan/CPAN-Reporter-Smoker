use strict;
use warnings;

use Test::More;

use Config;
use File::Spec;
use IO::CaptureOutput qw/capture/;
use t::DotDirs;

plan tests =>  6 ;

#--------------------------------------------------------------------------#
# Setup test environment
#--------------------------------------------------------------------------#

# prepend our lib dir with mock Test::Reporter and CPAN::MyConfig
my $test_lib = File::Spec->rel2abs(File::Spec->catdir(qw/t lib/)); 
unshift @INC, $test_lib;
$ENV{PERL5LIB} = join( $Config{path_sep}, 
    $test_lib, ( defined $ENV{PERL5LIB} ? $ENV{PERL5LIB} : () )
);

# Force load early so the testing version will be found before CPAN.pm
# adds $ENV{HOME}/.cpan to @INC so we don't load the user's config by mistake
require CPAN::MyConfig;
$ENV{PERL5OPT} = join( q{ }, 
    "-I$test_lib -MCPAN::MyConfig", ( defined $ENV{PERL5OPT} ? $ENV{PERL5OPT} : () )
);

# Setup CPAN working directory
t::DotDirs->prepare_cpan;

# Setup CPAN::Reporter configuration
$ENV{PERL_CPAN_REPORTER_DIR} = t::DotDirs->prepare_cpan_reporter;

my ($stdout, $stderr);

my $list_file = File::Spec->catfile(qw/t data dist-list/);

#--------------------------------------------------------------------------#
# tests begin here
#--------------------------------------------------------------------------#

require_ok( 'CPAN::Reporter::Smoker' );

can_ok( 'CPAN::Reporter::Smoker', 'start' );

pass ("Starting simulated smoke testing");

local $ENV{PERL_CR_SMOKER_RUNONCE} = 1;

my $ran_ok;
$ran_ok = eval {
  capture sub {
    CPAN::Reporter::Smoker::start( list => $list_file )
  } => \$stdout, \$stderr;
  1;
};

ok( $ran_ok, "Finished simulated smoke testing" ) or diag $@;

# check non-blank lines for expected count
open my $dist_file, "<", $list_file;
my @lines = grep { /\S/ } <$dist_file>;
close $dist_file;

require_ok( 'CPAN::Reporter::History' );
my @results = CPAN::Reporter::History::have_tested();
is( scalar @results, scalar @lines, "Number of reports in history" );

