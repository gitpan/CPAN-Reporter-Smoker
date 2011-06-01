#!/usr/bin/env perl
#
# This file is part of CPAN-Reporter-Smoker
#
# This software is Copyright (c) 2011 by David Golden.
#
# This is free software, licensed under:
#
#   The Apache License, Version 2.0, January 2004
#
use strict;
use warnings;
use CPAN::Checksums qw/updatedir/;
use File::Find;

sub wanted { 
    return unless 
        -d $File::Find::name &&
        $File::Find::name =~ m{authors/id/./../.+$};
    print "$File::Find::name\n";    
    updatedir( $File::Find::name );
}

find( { wanted => \&wanted, no_chdir => 1 }, q{.} );
