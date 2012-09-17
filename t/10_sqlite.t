use Test::More;
use Test::Exception;
use strict;

use PICA::Modification::Queue;
use PICA::Modification::TestQueue;

use File::Temp qw(tempfile);
use DBI;

BEGIN {
    eval {
        require DBD::SQLite;
        DBD::SQLite->import();
        1;
    } or do {
        plan skip_all => "DBD::SQLite missing";
    }
}

## test database configuration

my $dbfile;
(undef,$dbfile) = tempfile();
my $dsn = "dbi:SQLite:dbname=$dbfile";
my $dbh = DBI->connect($dsn,"",""); 

new_ok 'PICA::Modification::Queue' => [ 
    'Database', database => $dbh 
];

my $q = new_ok 'PICA::Modification::Queue' => [ 
    'Database', database => { dsn => $dsn } 
];
test_queue $q, 'PICA::Modification::Queue::DB';

done_testing;
