package PICA::Modification::Queue::Database;
#ABSTRACT: Manages a list of PICA edit requests in a SQL Database

use strict;
use warnings;
use v5.12;

use parent 'PICA::Modification::Queue';

use Carp;
use DBI;
use Scalar::Util qw(blessed);
use Log::Contextual::WarnLogger;
use Log::Contextual qw(:log :dlog), 
	-default_logger => Log::Contextual::WarnLogger->new({ env_prefix => 'PICA_QUEUE' });
use PICA::Modification;

=head1 DESCRIPTION

The edit queue stores a list of edit requests (L<PICA::Modification::Request>).

The current implementation is only tested with SQLite. Much code is borrowed
from L<Dancer::Plugin::Database::Handle>. A Future version may also work with
NoSQL databases, for instance L<KiokuDB>.

=method new( database => $database )

Create a new Queue. See L</database> for configuration.

=cut

sub new {
    my ($class,%config) = @_;

    my $self = bless { }, $class;
	$self->database( $config{database} );

    $self;
}

=method database( [ $dbh | { %config } | %config ] )

Get or set a database connection either as L<DBI> handle (config value C<dbh>)
or with C<dsn>, C<username>, and C<password>. One can also set the C<table>. 

=cut

sub database {
	my $self = shift;
	return $self->{db} unless @_;

	## first set database
	
	my $db = { };
	if (@_ == 1) {
		if ( blessed $_[0] and $_[0]->isa('DBI::db') ) { 
		   $db = { dbh => @_ };
		} elsif( ref $_[0] ) {
		   $db = $_[0];
		}
	} else { 
		$db = { @_ };
	}

	if ($db->{dbh}) { 
		$self->{db} = $db->{dbh};
	} elsif ($db->{dsn}) {
		$self->{db} = DBI->connect($db->{dsn}, $db->{username}, $db->{password});
		croak "failed to connect to database: ".$DBI::errstr unless $self->{db};
	} else {
		croak "missing database configuration";
	}

	$self->{table} = $db->{table} || 'changes';

	log_trace { "Connected to database" };


	## then initialize database
	my $table = $self->{db}->quote_identifier($self->{table});

    # FIXME: only tested in SQLite. See L<SQL::Translator> for other DBMS
    my $sql = <<"SQL";
create table if not exists $table (
    `id`      NOT NULL,
    `iln`,
    `epn`,
    `add`,
    `del`,
    `request` INTEGER PRIMARY KEY,
    `created` DATETIME DEFAULT CURRENT_TIMESTAMP,
    `creator`,
    `updated` DATETIME DEFAULT CURRENT_TIMESTAMP,
    `status`
);
SQL

    $self->{db}->do( $sql );

	return $self->{db};
}

=method insert( $edit, %attr )

Insert a L<PICA::Modification>. The edit is stored with a timestamp and
creator unless it is malformed. Returns an edit identifier or success. 
 
=cut

sub insert {
    my ($self, $edit, %attr) = @_;
    #croak("malformed edit") if !$edit or $edit->error;
    return if !$edit or $edit->error;

    my %data = ( map { $_ => $edit->{$_} } qw(id iln epn add del creator) );
    $data{creator} = $attr{creator} || '';
	$data{status}  = $attr{status} // 0;

    my $db    = $self->{db};
    my $table = $db->quote_identifier($self->{table});
    my $sql   = "INSERT INTO $table (" 
              . join(',', map { $db->quote_identifier($_) } keys %data)
              . ") VALUES ("
              . join(',', map { "?" } values %data)
              . ")";
    my @bind  = values %data;

    $db->do( $sql, undef, @bind );
	$db->last_insert_id(undef,undef, $self->{table}, 'request');
}

=method delete( request )

Entirely remove an edit requests. Returns the number of removed requests.

=cut

sub delete {
    my ($self, $request) = @_;

    my $db    = $self->{db};
    my $table = $db->quote_identifier($self->{table});
    my $sql   = "DELETE FROM $table WHERE "
              . $db->quote_identifier('request')
              . "=?";

    my $num = 1*$self->_dbdo( $sql, undef, $request );
	log_warn { 'edit request not found to remove' } unless $num;
	
	return ($num ? $request : undef);
}

sub _dbdo {
	my $self = shift;
	my $sql  = shift;
	my $attr = shift;
	my @bind = @_;

    my $db   = $self->{db};

	log_trace { "SQL '$sql': ".join(',',@bind) };

	my $r = $db->do( $sql, $attr, @bind );
	log_error { $DBI::errstr; } unless $r;

	return $r;
}

=method list 

...

=cut

sub list {
	my ($self, %options) = @_;

	my $pagesize = delete $options{pagesize} || 20;
    my $page     = delete $options{page} || 1;
    my $sort     = delete $options{sort} || 'updated';

    my $offset = ($page-1)*$pagesize;
    my $limit  = $pagesize;

	return [ $self->select( { %options }, { limit => $limit, orderby => $sort, offset => $offset } ) ];
}

=method select( { key => $value ... } [ , { limit => $limit } ] )

Retrieve one or multiple edit requests.

=cut

sub select {
    my ($self, $where, $opts) = @_;

    $opts ||= { };
    my $db    = $self->{db};
    my $table = $db->quote_identifier($self->{table});

    my $limit   = $opts->{limit} || (wantarray ? 0 : 1);
    my $orderby = $opts->{orderby} || 'updated';
    my $offset  = $opts->{offset} || 0;

    my $which_cols = '*';
    # $which_cols = join(',', map { $db->quote_identifier($_) } @cols);

    my @bind_params;
    ($where, @bind_params) = $self->_where_clause( $where );

    my $sql = "SELECT $which_cols FROM $table $where"
            . " ORDER BY " . $db->quote_identifier($orderby);
    $sql .= " LIMIT $limit" if $limit;
    $sql .= " OFFSET $offset" if $offset > 1 and $limit;

    log_trace { $sql };

    if ($limit == 1) {
        return $db->selectrow_hashref( $sql, undef, @bind_params );
    } else {
        return @{ $db->selectall_arrayref( $sql, { Slice => {} }, @bind_params ) };
    }
}

sub get {
	my ($self, $request) = @_;
	return $self->select( { request => $request } );
}

sub _where_clause {
    my ($self, $where) = @_;

    my $db  = $self->{db};
    my $sql = join(' AND ', map { $db->quote_identifier($_)."=? " } keys %$where);
    return ('',()) unless $sql;

    return ("WHERE $sql", values %$where);
}

=method count( { $key => $value ... } )

Return the number of edit request with given properties.

=cut

sub count {
    my ($self, $where) = @_;

    my $db    = $self->{db};
    my $table = $db->quote_identifier($self->{table});

    my @bind_params;
    ($where, @bind_params) = $self->_where_clause( $where );
    my $sql = "SELECT COUNT(*) AS C FROM $table $where";

    my ($count) = $db->selectrow_array( $sql, undef, @bind_params );
    return $count;
}

=method update( $id => $modification )


=cut

sub update {
    my ($self, $id, $modification) = @_;
    return if !$modification or $modification->error;
        # or $id ne $modification->{request};

    my $data = $modification->attributes;
    my $where = { request => $id };

    my $db    = $self->{db};
    my $table = $db->quote_identifier($self->{table});

    my @bind_params;
	($where, @bind_params) = $self->_where_clause( $where );

	my $values = join ',', map { $db->quote_identifier($_) .'=?' } keys %$data;

    my $sql = "UPDATE $table SET $values"
		. ', '.$db->quote_identifier('updated').'=CURRENT_TIMESTAMP'
		. " $where";
    log_trace { $sql };

    @bind_params = (values %$data, @bind_params);

    my $num = $self->_dbdo( $sql, undef, @bind_params );
	log_warn { 'edit request not found to update' } unless $num;
	return ($num ? 1*$num : $num);
}

1;

=head1 LOGGING

This package uses L<Log::Contextual> for logging. 

=cut
