#!/usr/bin/perl

###########################################################################
# PROOF OF CONCEPT, this is one of those hacky 2AM jobs you just throw    #
# together to see shit work... forgive the lack of comments and the       #
# poorly thought out design                                               #
#                                                                         #
# This is not guaranteed to work, nor does it really have any             #
# documentation that would allow you to use it very well.  Good luck.     #
#                                                                         #
# XXX: use File::Temp or something for storing temporary files?           #
#                                                                         #
# NOTE: presently you MUST create /tmp/api and make it writable by        #
# whatever app is using this module.  I plan on implementing a caching    #
# layer but haven't gotten around to it...                                #
###########################################################################

###########################################################################
# Copyright (c) 2007-2008 Mark Smith <mark@xb95.com>.  All rights         #
# reserved.  This program is free software; you can redistribute it       #
# and/or modify it under the same terms as Perl itself.                   #
###########################################################################

package EVEAPI;

use strict;
use LWP::Simple;
use XML::Parser;
use Date::Parse;
use Date::Format;
use Data::Dumper;

our $AUTOLOAD;
our $VERSION = '0.01';

# constructor, usage:
#   my $api = EVEAPI->new( userID => 234234, apiKey => 'sdfkljsdflkj' );
sub new {
    my $class = shift;
    my %args = ( @_ );

    my $self = {};
    $self->{userID} = $args{userID}+0;
    $self->{apiKey} = $args{apiKey};
    $self->{version} = $args{version}+0 || 1;
    #die "requires userID and apiKey for construction\n"
    #    unless $self->{userID} && $self->{apiKey};

    bless $self, $class;
    return $self;
}

# called at the end of a chain when we're ready to load our data
sub load {
    my $self = shift;

    my $url = $self->{_url}
        or die "load called with no URL!\n";
    $url = "http://api.eve-online.com$url.xml.aspx?";

    my %args = ( @_, userID => $self->{userID}, apiKey => $self->{apiKey}, version => $self->{version} );
    $url .= join "&", map { "$_=" . _url_encode($args{$_}) } keys %args;

    $self->{_url} = "";

    # caching stuff, this is pretty lame but works well enough
    my $file = '';
    my $fn = "/tmp/api/" . _url_encode($url);
    if (-e $fn) {
        local $/ = undef;
        open FILE, "<$fn";
        $file = <FILE>;
        close FILE;

        # now see how old it is
        my $age = time - (stat($fn))[9];
        my $api = $self->parse($file);
        my $goodfor = (str2time($api->cachedUntil) - str2time($api->currentTime))+0;

        # if our copy is younger than it's good for, return it
        return $api if $age <= $goodfor;
    }

    # guess not, so let's get it and write it out
    $file = get($url);
    open FILE, ">$fn";
    print FILE $file;
    close FILE;

    # now we want to fart this through the parser
    return $self->parse($file);
}

# parser, takes input as XML and returns an object
sub parse {
    my ($self, $inp) = @_;
    my $res = EVEAPI::Stub->new();

    # setup our handlers
    my ($top, $stack, $cur) = ({}, [], undef);
    my $xml_start = sub {
        my ($p, $elem, %attrs) = @_;

        # first element is us basically stomping cur to top
        if (! defined $cur) {
            die "first element not <eveapi>!?\n" if $elem ne 'eveapi';
            $cur = $top;
            return;
        }

        # rowsets are special
        if ($elem eq 'rowset') {
            push @$stack, $cur;
            $cur = { _type => $attrs{name}, _rowset => 1, _rows => [] };
            return;
        }

        # nope, so pretty simple here
        push @$stack, $cur;
        $cur = { _type => $elem, _attrs => \%attrs };
    };
    my $xml_end = sub {
        my ($p, $elem) = @_;

        # if this is the last we better have no stack
        if ($elem eq 'eveapi') {
            die "found </eveapi> but still a stack!?\n" if @$stack;
            return;
        }

        die "end with no stack!?\n" unless @$stack;
        my $saved = $cur;
        $cur = pop @$stack;

        # if saved isn't a rowset, flatten attributes?
        unless ($saved->{_rowset}) {
            # if we have stuff
            foreach my $attr (keys %{$saved->{_attrs} || {}}) {
                unless (exists $saved->{$attr}) {
                    $saved->{$attr} = $saved->{_attrs}->{$attr};
                    delete $saved->{_attrs}->{$attr};
                }
            }
            delete $saved->{_attrs} unless $saved->{_attrs} && scalar(keys %{$saved->{_attrs}}) > 0;
        }

        # attach $cur into the previous
        if ($cur->{_rowset}) {
            die "can't put a $saved->{_type} into a rowset!?\n" if $saved->{_type} ne 'row';
            push @{$cur->{_rows}}, $saved;
        } else {
            die "element already contained a $saved->{_type}!?\n" if exists $cur->{$saved->{_type}};
            $cur->{$saved->{_type}} = $saved;
            delete $saved->{_type};
        }
    };
    my $xml_char = sub {
        my ($p, $str) = @_;

        die "string with no current?!\n" unless $cur;
        die "current is not a hashref!?\n" unless ref $cur eq 'HASH';
        $cur->{_content} = $str;
    };

    # the actual parsing
    my $p = XML::Parser->new(Handlers => { Start => $xml_start,
                                           End   => $xml_end,
                                           Char  => $xml_char });

    # just in case...
    eval {
        $p->parse($inp);
    };
    if ($@) {
        # parse errors pause us for 5 minutes :(
        my $err = $@;
        $err =~ s/[\r\n]+/ /gs;
        $err =~ s/^\s+//;
        $err =~ s/\s+$//;

        # munge the structure...
        $top->{error} = {
            _content => "XML parse failure: $err.",
            code => 999,
        };
        $top->{currentTime} = time2str('%Y-%m-%d %H:%M:%S', time());
        $top->{cachedUntil} = time2str('%Y-%m-%d %H:%M:%S', time() + 300);
    }

    # bail if this is an error...
    if (exists $top->{error}) {
        $res->{_cur} = _flatten($top);

        # we don't always get a cachedUntil on errors so fake it
        $res->{_cur}->{cachedUntil} ||= time2str('%Y-%m-%d %H:%M:%S', str2time($res->{_cur}->{currentTime}) + 300);
        $res->{_cur}->{errorText} = $res->{_cur}->{error}->{_content};
        $res->{_cur}->{errorCode} = $res->{_cur}->{error}->{code};
        $res->{_cur}->{isError} = 1;
        return $res;
    }

    # munge down the result...
    $top->{result}->{cachedUntil} = $top->{cachedUntil};
    $top->{result}->{currentTime} = $top->{currentTime};

    # FIXME: we're tossing data here by using the result
    $res->{_cur} = _flatten($top->{result});
    $res->{_cur}->{isError} = 0;
    return $res;
}

sub _flatten {
    my $cur = shift;
    if (scalar(keys %$cur) == 1 && exists $cur->{_content}) {
        return $cur->{_content};
    }
    foreach my $key (keys %$cur) {
        if (ref $cur->{$key} eq 'HASH') {
            $cur->{$key} = _flatten($cur->{$key});
        } elsif (ref $cur->{$key} eq 'ARRAY') {
            my $new = [];
            foreach my $hr (@{$cur->{$key}}) {
                push @$new, _flatten($hr);
            }
            $cur->{$key} = $new;
        }
    }
    return $cur;
}

sub _url_encode {
    my $x = shift;
    $x =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
    return $x;
}

# generic autoloader which is called when someone is trying to get a page,
# we construct a URL based on this and then use the input arguments to send
# to the server
sub AUTOLOAD {
    # let's just ignore this, mmkay? (basically just cleans $AUTOLOAD and appends
    # it to our growing URL)
    my $self = shift;
    { ($self->{_url} ||= "") .= '/' . ((($_ = $AUTOLOAD) =~ s/.*://) ? $_ : ""); }

    # if args, we're done; else just return our object
    return $self->load(@_) if scalar(@_) >= 1;
    return $self;
}

################################################################################
## EVEAPI::Stub
## Returned by the parser, this is just a class that does the right thing with
## the input hashref ... sort of ;)
################################################################################

package EVEAPI::Stub;

our $AUTOLOAD;

sub new { return bless {}, shift(); }

sub has {
    my ($self, $what) = @_;

    return exists $self->{_cur}->{$what} ? 1 : 0;
}

sub AUTOLOAD {
    my $self = shift;

    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if $name eq 'DESTROY';

    die "EVEAPI::Stub with no cur!?\n" unless $self->{_cur};
    die "cur is not a hashref!?\n" unless ref $self->{_cur} eq 'HASH';

    unless (exists $self->{_cur}->{$name}) {
        foreach my $key (keys %{$self->{_cur}}) {
            print "$key: $self->{_cur}->{$key}\n";
        }
        die "$name not found in cur!?\n";
    }

    my $new = $self->{_cur}->{$name};

    # fudging for returning array
    if (ref $new eq 'HASH' && $new->{_rowset}) {
        return [ map { bless { _cur => $_ }, ref $self } @{$new->{_rows}} ];
    }

    # bless...
    if (ref $new eq 'HASH') {
        return bless { _cur => $new }, ref $self;
    }

    return $new;
}

1;

