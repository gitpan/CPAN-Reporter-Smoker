package CPAN::Reporter::Smoker;
use 5.006;
use strict;
use warnings;
our $VERSION = '0.04'; 
$VERSION = eval $VERSION; ## no critic

use Config;
use CPAN; 
use CPAN::Tarzip;
use CPAN::HandleConfig;
use CPAN::Reporter::History;
use Compress::Zlib;
use File::Temp 0.20;
use File::Spec;
use File::Basename qw/basename/;
use Probe::Perl;

use Exporter;
our @ISA = 'Exporter';
our @EXPORT = qw/ start /; ## no critic Export

#--------------------------------------------------------------------------#
# globals
#--------------------------------------------------------------------------#

my $perl = Probe::Perl->find_perl_interpreter;
#my $tmp_dir = File::Temp->newdir( 'CPAN-Reporter-Smoker-XXXXXXX', 
#    DIR => File::Spec->tmpdir,
#    UNLINK => 0,
#);
my $tmp_dir = File::Temp::tempdir;

#--------------------------------------------------------------------------#
# start -- start automated smoking
#--------------------------------------------------------------------------#

sub start {
    print "Starting CPAN::Reporter::Smoker\n";

    # Let things know we're running automated
    local $ENV{AUTOMATED_TESTING} = 1;

    # Always accept default prompts
    local $ENV{PERL_MM_USE_DEFAULT} = 1;

    # Load CPAN configuration
    CPAN::HandleConfig->load();
    CPAN::Shell::setup_output;
    CPAN::Index->reload;

    # Get the list of distributions to process
    my $package = _get_module_index( 'modules/02packages.details.txt.gz' );
    my $find_ls = _get_module_index( 'indices/find-ls.gz' );

    $CPAN::Frontend->mywarn( "Smoker: scanning and sorting index\n");
    my $dists = _parse_module_index( $package, $find_ls );
    
    # Win32 SIGINT propogates all the way to us, so trap it before we smoke
    local $SIG{INT} = \&_prompt_quit;

    # Start smoking
    DIST:
    for my $d ( @$dists ) {
        my $dist = CPAN::Shell->expandany($d);
        my $base = $dist->base_id;
        if ( CPAN::Reporter::History::have_tested( dist => $base ) ) {
            $CPAN::Frontend->mywarn( 
                "Smoker: already tested $base\n");
            next DIST;
        }
        else {
            $CPAN::Frontend->mywarn( "Smoker: testing $base\n\n" );
            system($perl, "-MCPAN", "-e", "report( '$d' )");
            _prompt_quit( $? & 127 ) if ( $? & 127 );
        }
    }

    return;
}

#--------------------------------------------------------------------------#
# private variables and functions
#--------------------------------------------------------------------------#

sub _prompt_quit {
    my ($sig) = @_;
    # convert numeric to name
    if ( $sig =~ /\d+/ ) {
        my @signals = split q{ }, $Config{sig_name};
        $sig = $signals[$sig] || '???';
    }
    $CPAN::Frontend->myprint(
        "\nCPAN testing halted on SIG$sig.  Continue (y/n)? [n]\n"
    );
    my $answer = <>;
    exit 0 unless substr( lc($answer), 0, 1) eq 'y';
    return;
}

#--------------------------------------------------------------------------#
# _get_module_index
#
# download the 01modules index and return the local file name
#--------------------------------------------------------------------------#

sub _get_module_index {
    my ($remote_file) = @_;

    $CPAN::Frontend->mywarn( 
        "Smoker: getting $remote_file from CPAN\n");
    # CPAN.pm may not use aslocal if it's a file:// mirror
    my $aslocal_file = File::Spec->catfile( $tmp_dir, basename( $remote_file ));
    my $actual_local = CPAN::FTP->localize( $remote_file, $aslocal_file );
    if ( ! -r $actual_local ) {
        die "Couldn't get '$remote_file' from your CPAN mirror. Halting\n";
    }
    return $actual_local;
}

my $module_index_re = qr{
    ^\s href="\.\./authors/id/./../    # skip prelude 
    ([^"]+)                     # capture to next dquote mark
    .+? </a>                    # skip to end of hyperlink
    \s+                         # skip spaces
    \S+                         # skip size
    \s+                         # skip spaces
    (\S+)                       # capture day
    \s+                         # skip spaces
    (\S+)                       # capture month 
    \s+                         # skip spaces
    (\S+)                       # capture year
}xms; 

my %months = ( 
    Jan => '01', Feb => '02', Mar => '03', Apr => '04', May => '05',
    Jun => '06', Jul => '07', Aug => '08', Sep => '09', Oct => '10',
    Nov => '11', Dec => '12'
);

# standard regexes
# note on archive suffixes -- .pm.gz shows up in 02packagesf
my %re = (
    perls => qr{(?:
		  /(?:emb|syb|bio)?perl-\d 
		| /(?:parrot|ponie|kurila|Perl6-Pugs)-\d 
		| /perl-?5\.004 
		| /perl_mlb\.zip 
    )}xi,
    archive => qr{\.(?:tar\.(?:bz2|gz|Z)|t(?:gz|bz)|zip|pm.gz)$}i,
    target_dir => qr{
        ^(?:
            modules/by-module/[^/]+/./../ | 
            modules/by-module/[^/]+/ | 
            modules/by-category/[^/]+/[^/]+/./../ | 
            modules/by-category/[^/]+/[^/]+/ | 
            authors/id/./../ 
        )
    }x,
    leading_initials => qr{(.)/\1./},
);

# match version and suffix
$re{version_suffix} = qr{([-._]v?[0-9].*)($re{archive})};

# split into "AUTHOR/Name" and "Version"
$re{split_them} = qr{^(.+?)$re{version_suffix}$};

# matches "AUTHOR/tarball.suffix" or AUTHOR/modules/tarball.suffix
# and not other "AUTHOR/subdir/whatever"

# Just get AUTHOR/tarball.suffix from whatever file name is passed in
sub _get_base_id { 
    my $file = shift;
    my $base_id = $file;
    $base_id =~ s{$re{target_dir}}{};
    return $base_id;
}

sub _base_name {
    my ($base_id) = @_;
    my $base_file = basename $base_id;
    my ($base_name, $base_version) = $base_file =~ $re{split_them};
    return $base_name;
}

#--------------------------------------------------------------------------#
# _parse_module_index
#
# parse index and return array_ref of distributions in reverse date order
#--------------------------------------------------------------------------#-

sub _parse_module_index {
    my ( $packages, $file_ls ) = @_;

	# first walk the packages list
    # and build an index

    my (%valid_bases, %valid_distros, %mirror);
    my (%latest, %latest_dev);

    my $gz = Compress::Zlib::gzopen($packages, "rb")
        or die "Cannot open package list: $Compress::Zlib::gzerrno";

    my $inheader = 1;
    while ($gz->gzreadline($_) > 0) {
        if ($inheader) {
            $inheader = 0 unless /\S/;
            next;
        }

        my ($module, $version, $path) = split;
        
        my $base_id = _get_base_id("authors/id/$path");

        # skip all perl-like distros
        next if $base_id =~ $re{perls};

        $valid_distros{$base_id}++;
        my $base_name = _base_name( $base_id );
        if ($base_name) {
            $latest{$base_name} = {
                datetime => 0,
                base_id => $base_id
            };
        }
    }

    # next walk the find-ls file
    local *FH;
    tie *FH, 'CPAN::Tarzip', $file_ls;

    while ( defined ( my $line = <FH> ) ) {
        my %stat;
        @stat{qw/inode blocks perms links owner group size datetime name linkname/}
            = split q{ }, $line;
        
        unless ($stat{name} && $stat{perms} && $stat{datetime}) {
            next;
        }
        # skip directories, symlinks and things that aren't a tarball
        next if $stat{perms} eq "l" || substr($stat{perms},0,1) eq "d";
        next unless $stat{name} =~ $re{target_dir};
        next unless $stat{name} =~ $re{archive};

        # skip if not AUTHOR/tarball 
        # skip perls
        my $base_id = _get_base_id($stat{name});
        next unless $base_id; 
        
        next if $base_id =~ $re{perls};

        my $base_name = _base_name( $base_id );

        # if $base_id matches 02packages, then it is the latest version
        # and we definitely want it; also update datetime from the initial
        # assumption of 0
        if ( $valid_distros{$base_id} ) {
            $mirror{$base_id} = $stat{datetime};
            next unless $base_name;
            if ( $stat{datetime} > $latest{$base_name}{datetime} ) {
                $latest{$base_name} = { 
                    datetime => $stat{datetime}, 
                    base_id => $base_id
                };
            }
        }
        # if not in the packages file, we only want it if it resembles 
        # something in the package file and we only the most recent one
        else {
            # skip if couldn't parse out the name without version number
            next unless defined $base_name;

            # skip unless there's a matching base from the packages file
            next unless $latest{$base_name};

            # keep only the latest
            $latest_dev{$base_name} ||= { datetime => 0 };
            if ( $stat{datetime} > $latest_dev{$base_name}{datetime} ) {
                $latest_dev{$base_name} = { 
                    datetime => $stat{datetime}, 
                    base_id => $base_id
                };
            }
        }
    }

    # pick up anything from packages that wasn't found find-ls
    for my $name ( keys %latest ) {
        my $base_id = $latest{$name}{base_id};
        $mirror{$base_id} = $latest{$name}{datetime} unless $mirror{$base_id};
    }
          
    # for dev versions, it must be newer than the latest version of
    # the same base name from the packages file

    for my $name ( keys %latest_dev ) {
        if ( ! $latest{$name} ) {
            next;
        }
        next if $latest{$name}{datetime} > $latest_dev{$name}{datetime};
        $mirror{ $latest_dev{$name}{base_id} } = $latest_dev{$name}{datetime} 
    }

    return [ sort { $mirror{$b} <=> $mirror{$a} } keys %mirror ];
}

1; #modules must return true

__END__

#--------------------------------------------------------------------------#
# pod documentation 
#--------------------------------------------------------------------------#

=begin wikidoc

= NAME

CPAN::Reporter::Smoker - Turnkey CPAN Testers smoking

= VERSION

This documentation describes version %%VERSION%%.

= SYNOPSIS

    $ perl -MCPAN::Reporter::Smoker -e start

= DESCRIPTION

Rudimentary smoke tester for CPAN Testers, built upon [CPAN::Reporter].  Use
at your own risk.  It requires CPAN::Reporter 1.08 or higher.

Currently, CPAN::Reporter::Smoker requires zero independent configuration;
instead it uses configuration settings from CPAN.pm and CPAN::Reporter.

Once started, it retrieves a list of distributions from the configured CPAN
mirror and begins testing them in reverse order of upload.  It will skip any
distribution which has already had a report sent by CPAN::Reporter.  

Features (or bugs, depending on your point of view):

* No configuration needed
* Tests each distribution as a separate CPAN process -- each distribution
has prerequisites like build_requires satisfied from scratch
* Continues until finished or until interrupted with CTRL-C

Current limitations:

* Doesn't check skip files before handing off to CPAN to test
* Does not check for new distributions to test while running, only when
starting up
* Does not attempt to retest distributions that had reports discarded because 
of prerequisites that could not be satisfied

== Warning

Smoke testing downloads and runs programs other people have uploaded to CPAN.
These programs could do *anything* to your system, including deleting
everything on it.  Do not run CPAN::Reporter::Smoker unless you are prepared to
take these risks.  

= HINTS

== Selection of distributions to test

Only the most recently uploaded developer and normal releases will be
tested, and only if the developer release is newer than the regular release
indexed by PAUSE.  

For example, if Foo-Bar-0.01, Foo-Bar-0.02, Foo-Bar-0.03_01 and Foo-Bar-0.03_02
are on CPAN, only Foo-Bar-0.02 and Foo-Bar-0.03_02 will be tested, and in
reverse order of when they were uploaded.  Once Foo-Bar-0.04 is released and
indexed, Foo-Bar-0.03_02 will not longer be tested.

To avoid testing script or other tarballs, developer distributions included
must have a base distribution name that resembles a distribution tarball
already indexed by PAUSE.  If the first upload of distribution to PAUSE is a
developer release -- Baz-Bam-0.00_01.tar.gz -- it will not be tested as there
is no indexed Baz-Bam appearing in CPAN's 02packages.details.txt file.  

Unauthorized tarballs are treated like developer releases and will be tested
if they resemble an indexed distribution and are newer than the indexed
tarball.

Perl, parrot, kurila, Pugs and similar distributions will not be tested.  The
skip list is based on CPAN::Mini and matches as follows:
    
    qr{(?:
		  /(?:emb|syb|bio)?perl-\d 
		| /(?:parrot|ponie|kurila|Perl6-Pugs)-\d 
		| /perl-?5\.004 
		| /perl_mlb\.zip 
    )}xi,

== CPAN::Mini

Because distributions must be retrieved from a CPAN mirror, the smoker may
cause heavy network load and will reptitively download common build 
prerequisites.  

An alternative is to use [CPAN::Mini] to create a local CPAN mirror and to
point CPAN's {urllist} to the local mirror.

    $ cpan
    cpan> o conf urllist unshift file:///path/to/minicpan
    cpan> o conf commit

However, CPAN::Reporter::Smoker needs the {find-ls.gz} file, which
CPAN::Mini does not mirror by default.  Add it to a .minicpanrc file in your
home directory to include it in your local CPAN mirror.

    also_mirror: indices/find-ls.gz

Note that CPAN::Mini does not mirror developer versions.  Therefore, a
live, network CPAN Mirror will be needed in the urllist to retrieve these.

== Skip files

CPAN::Reporter (since 1.07_01) supports skipfiles to prevent copying authors
on reports or from sending reports at all for certain distributions or authors'
modules.  Use these to stop sending reports if someone complains.  See
[CPAN::Reporter::Config] for more details.

A future version may utilize these to avoid testing modules in the skiplist
instead of taking the time to test them and then just not send the report.

== CPAN cache bloat

CPAN will use a lot of scratch space to download, build and test modules.  
Use CPAN's built-in cache management configuration to let it purge the cache 
periodically if you don't want to do this manually.

    $ cpan
    cpan> o conf init build_cache scan_cache
    cpan> o conf commit

== CPAN verbosity

Recent versions of CPAN are verbose by default, but include some lesser
known configuration settings to minimize this for untarring distributions and
for loading support modules.  Setting the verbosity for these to 'none' will
minimize some of the clutter to the screen as distributions are tested.

    $ cpan
    cpan> o conf init /verbosity/
    cpan> o conf commit

= USAGE

== {start()}

Starts smoke testing using defaults already in CPAN::Config and
CPAN::Reporter's .cpanreporter directory.  Runs until all distributions are
tested or the process is halted with CTRL-C or otherwise killed.

= ENVIRONMENT

Automatically sets the following environment variables to true values 
while running:

* {AUTOMATED_TESTING} -- signal that tests are being run by an automated
smoke testing program (i.e. don't expect interactivity)
* {PERL_MM_USE_DEFAULT} -- accept [ExtUtils::MakeMaker] prompt() defaults

= BUGS

Please report any bugs or feature using the CPAN Request Tracker.  
Bugs can be submitted through the web interface at 
[http://rt.cpan.org/Dist/Display.html?Queue=CPAN-Reporter-Smoker]

When submitting a bug or request, please include a test-file or a patch to an
existing test-file that illustrates the bug or desired feature.

= SEE ALSO

* [CPAN]
* [CPAN::Reporter]
* [CPAN::Testers]

= AUTHOR

David A. Golden (DAGOLDEN)

= COPYRIGHT AND LICENSE

Copyright (c) 2008 by David A. Golden

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at 
[http://www.apache.org/licenses/LICENSE-2.0]

Files produced as output though the use of this software, shall not be
considered Derivative Works, but shall be considered the original work of the
Licensor.

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=end wikidoc

=cut
