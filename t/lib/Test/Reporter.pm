#
# This file is part of CPAN-Reporter-Smoker
#
# This software is Copyright (c) 2011 by David Golden.
#
# This is free software, licensed under:
#
#   The Apache License, Version 2.0, January 2004
#
# Mock Test::Reporter -- don't actually send anything
# Adapated from helper test code in CPAN::Reporter
package Test::Reporter;
our $VERSION = 1.54;

use Config;

use vars qw/$AUTOLOAD/;

sub new { return bless {}, shift }

# always pretend to be successful sending
sub send { 
    return 1 
} 

sub address {
    return "nowhere"
}

sub subject {
    my $self = shift;
    return uc($self->grade) . ' ' . $self->distribution .
        " $Config{archname} $Config{osvers}";
}

# handle all other properties
sub AUTOLOAD {
    my $self = shift;
    if ( @_ ) {
        $self->{ $AUTOLOAD } = shift;
    }
    return $self->{ $AUTOLOAD };
}

1;

