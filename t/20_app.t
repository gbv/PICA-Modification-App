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

    sub insert {   # picamod insert < edit
        my ($self, $mod) = @_;
        my $json = JSON->new->encode( $mod->attributes );
        return $self->run('request', \$json);
    }

    sub list {     # picamod list [options]
        my ($self, %options) = @_;

        my $list = $self->run('list'); # TODO: sort, limit etc.

        return JSON->new->decode($list);
    }

    sub get {
        my ($self, $id) = @_;

        $self->run('check', $id);
    }

    sub update {
    }

    # run app, optionally provide STDIN, capture and return output
    sub run {
        my $self = shift;
        my $app = $self->[0];

        local *STDIN;
        open (STDIN, '<', pop) if (@_ and reftype($_[$#_]) // '') eq 'SCALAR';

        my $capture = IO::Capture::Stdout->new();
        $capture->start;
        $app->run( {}, @_ );
        $capture->stop;

        return join('', $capture->read);
    }

    1;
}

use App::Picamod;
use PICA::Modification::TestQueue;

use File::Temp qw(tempfile);
use PICA::Record;

#$ENV{PICAMOD_UPTO} = 'TRACE';
#$ENV{PICA_QUEUE_UPTO} = 'TRACE';

my $dbfile;
(undef,$dbfile) = tempfile();
my $dsn = "dbi:SQLite:dbname=$dbfile";

my $app = App::Picamod->new;
$app->init( { unapi => sub { 
    my $id = shift;
    return unless $id =~ /ppn:([^:]+)$/;
    return PICA::Record->new( '003@ $0'.$1 );
},
    type => 'Database', queue => { database =>{ dsn => $dsn } },
 } );

my $q = PICA::Modification::Queue::WrapApp->new( $app );

my $id = $q->insert( PICA::Modification->new( add => '012A $xfoo', id => 'foo:ppn:789' ) );
ok($id, "inserted: $id");

#test_queue 'App::Picamod' => $queue;

my $l = $q->list(); # should be REQUESTs when using a Database
use Data::Dumper; say Dumper($l);
#explain($l);

$q->get(1);

done_testing;
