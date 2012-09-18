use Test::More;
use Test::Exception;
use strict;
use v5.10;

{
    package PICA::Modification::Queue::WrapApp;

    use parent 'PICA::Modification::Queue';

    use Scalar::Util qw(reftype);
    use IO::Capture::Stdout;
    use IO::Scalar;
    use JSON;

    sub new { 
        my ($class, $app) = @_;
        bless [$app], $class;
    }

    sub insert {   # picamod insert < mod.json
        my ($self, $mod) = @_;
        my $json = JSON->new->encode( $mod->attributes );
        $self->run({}, 'request', \$json);
    }

    sub list {     # picamod list [options]
        my ($self, %options) = @_;
        my $list = $self->run( \%options, 'list' ) // "[]";
        return JSON->new->decode($list);
    }

    sub get {      # picamod get {id}
        my ($self, $id) = @_;
        my $got = $self->run({}, 'get', $id) // return;
        return JSON->new->decode($got);
    }

    sub delete {   # picamod delete {id}
        my ($self, $id) = @_;
        return $self->run({}, 'delete', $id);
    }

    sub update {   # picamod replace {id} < mod.json
        my ($self, $id, $mod) = @_;
        my $json = JSON->new->encode( $mod->attributes );
        $self->run({}, 'replace', $id, \$json);
    }

    # run app, optionally provide STDIN, capture and return output
    sub run {
        my $self    = shift;
        my $options = shift;
        my $app = $self->[0];

        local *STDIN;
        open (STDIN, '<', pop) if (@_ and reftype($_[$#_]) // '') eq 'SCALAR';

        my $capture = IO::Capture::Stdout->new();
        $capture->start;
        $app->run( $options, @_ );
        $capture->stop;

        my $out = join('', $capture->read);
        return $out eq '' ? undef : $out;
    }

    1;
}

use App::Picamod;
use PICA::Modification::TestQueue;

use File::Temp qw(tempfile);
use PICA::Record;

#$ENV{PICAMOD_UPTO} = 'DEBUG';
#$ENV{PICA_QUEUE_UPTO} = 'TRACE';

my $dbfile;
(undef,$dbfile) = tempfile();
my $dsn = "dbi:SQLite:dbname=$dbfile";

my $unapi = sub { 
    my $id = shift;
    return unless $id =~ /ppn:([^:]+)$/;
    return PICA::Record->new( '003@ $0'.$1 );
};

my $app = App::Picamod->new;
$app->init( { unapi => $unapi, 
    type => 'Database', queue => { dsn => $dsn },
} );

my $wrap = new_ok('PICA::Modification::Queue::WrapApp' => [ $app ]);

is $wrap->run({},'list'), undef, 'empty list';

test_queue $wrap, 'App::Picamod';

done_testing;
