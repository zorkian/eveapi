#!/usr/bin/perl
#
# demonstration file for the EVEAPI module, please run this module from the
# root of the svn checkout, NOT from the bin directory.
# 
# Copyright (c) 2007-2009 Mark Smith <mark@xb95.com>.  All rights reserved.  This
# program is free software; you can redistribute it and/or modify it under the same
# terms as Perl itself.
#

#### SKIP THIS, GO TO THE "START HERE" SECTION ####

use strict;
use lib 'lib';
use Data::Dumper;
use EVEAPI;
use Getopt::Long;

my ( $userid, $apikey );
GetOptions(
    'userid=i' => \$userid,
    'apikey=s' => \$apikey,
) or usage();
usage() unless $userid > 0 && $apikey;

# if no /tmp/api, complain
unless ( -d "/tmp/api" ) {
    die <<EOF;
You need to make a directory (/tmp/api) and make it writable by any user that
will be using the EVEAPI module.  For now, that's how the module stores the
data that it uses to give you cached responses.

NOTE: This means that anybody with access to this system's filesystem will be
able to get userids, API keys, and data!  Be warned.

Make this directory, then run this script again.
EOF
}


#### START HERE ####


# construct the object
my $api = EVEAPI->new( userID => $userid, apiKey => $apikey, version => 2 )
    or die "failed to construct the object\n";

# let's see what characters they have!
print "Characters on account:\n";

# the URL we want from the API is http://api.eve-online.com/account/Characters.xml.aspx
# so note that we use $api->account->Characters->load which refers to that URL exactly.
my $characters = $api->account->Characters->load;

# if you look in the XML, you'll see a rowset named 'characters'.  each row has some
# columns with names: name, characterID, etc.  the module exposes those exactly as named.
my $lastchar;
foreach my $char ( @{ $characters->characters } ) {
    printf "    %s [%d] in %s [%d]\n",
           $char->name, $char->characterID,
           $char->corporationName, $char->corporationID;

    # store the last character id for later
    $lastchar = $char;
}

# now let's get some data for something that isn't rowset based...the character sheet
# has lots of data like this.  note that we do not need to add 'load' here since we
# are passing a parameter... but you can add it if you want.
my $charsheet = $api->char->CharacterSheet( characterID => $lastchar->characterID );

print "\nCharacter information:\n";
printf "    Race:   %s\n", $charsheet->race;
printf "    Blood:  %s\n", $charsheet->bloodLine;

# multi level things are easy
printf "    Memory: %d\n", $charsheet->attributes->memory;

# hopefullyt his has given you a brief tour of how to use the module ...





sub usage {
    die <<EOF;
$0 - EVEAPI module test utility

To use this module, please invoke it from the root of the SVN checkout in the
following manner:

    perl bin/test.pl --userid=123456 --apikey=a39fd9e9e099f03080d8e80b93938345

The module will then run through a series of tests and display the information.
Please see the inside of the module to see how things work.
EOF
}
