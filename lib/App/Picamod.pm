package App::Picamod;
#ABSTRACT: picaedit core application

use strict;
use warnings;
use v5.10;

use Carp;
use Try::Tiny;
use Scalar::Util qw(reftype blessed);
use Log::Contextual::WarnLogger;
use Log::Contextual qw(:log :dlog), 
	-default_logger => Log::Contextual::WarnLogger->new({ env_prefix => 'PICAMOD' });

use PICA::Modification 0.132;
use PICA::Modification::Queue;

use LWP::Simple ();

use File::Slurp;
use IO::Interactive qw(is_interactive);

use JSON  -convert_blessed_universally;
our $JSON = JSON->new->utf8(1)->pretty(1)->convert_blessed;

sub new {
	my $class = shift;
	bless {@_}, $class;
}

sub init {
    my ($self,$options) = @_;

    my $queue = $options->{queue};
    my $qclass = delete $options->{type};

    $self->{queue} ||= PICA::Modification::Queue->new( $qclass, %$queue ); 
	$self->{unapi} = $options->{unapi};

    if (!ref $self->{unapi}) {
        my $unapi = $self->{unapi};
        $self->{unapi} = sub {
            my $id = shift;
            try { 
                my $url = $unapi . '?format=pp&id=' . $id;
        		log_trace { $url };
                PICA::Record->new( LWP::Simple::get( $url ) ); 
            } catch {
                undef;
            }
        };
    }

	log_trace { "initialized App::Picaedit" };
}

sub modification_request {
    my $self = shift;

    my %attr = map { $_ => $self->{$_} } grep { exists $self->{$_} }
		qw(id iln epn del add);

	if( !%attr and !is_interactive() ) { # JSON from STDIN
		my $json = do { local $/; <STDIN> };
		$json = $JSON->decode($json);
		%attr = %$json;
	}

	return PICA::Modification->new( %attr );
}

sub edit_error {
    my ($self, $msg, $edit) = @_;

    my %errors = %{$edit->{errors}};
    join "\n", map { "$msg $_: ".$errors{$_} } keys %errors;
}

# helper method
sub iterate_edits {
    my $self     = shift;
    my $callback = shift;

    log_error { "expect edit_id as argument" } unless @_;

    foreach (@_) {
        unless (/^\d+$/) {
            log_warn { "invalid edit_id: $_" };
            next;
        }
        my $edit = $self->{queue}->get( $_ );
        if ($edit) {
            $_ = $edit;
            $callback->();
        } else {
            log_warn { "edit request not found: $_" };
            next;
        }
    }
}

sub iterate_performed_edits {
    my $self     = shift;
    my $callback = shift;

    $self->iterate_edits( sub {
        my $edit = $self->retrieve_and_perform_edit( $_ );

        if ($edit->error) {
            log_error { $self->edit_error( "" => $edit ); };
			# TODO: save error object
        } else {
            $_ = $edit;
            $callback->();
        }
    } => @_ );
}

=head1 COMMAND METHODS

=cut

sub run {
	my ($self,$options,@args) = @_;

	my $cmd = shift @args || die "missing command. Use -h for help.\n";
	my $method = "command_$cmd";
	if ( $self->can($method) ) {
		my $result = $self->$method($options,@args);
		if (defined $result) {
			if (ref $result) {
				say $JSON->encode($result);
			} else {
				say $result;
			}
        }
	} else {
		die "Unknown command: $cmd. Use -h for help.\n";
	}
}

=head2 command_request

Request a new edit.

=cut

sub command_request {
    my $self    = shift;
    my $options = shift;
    my $queue = $self->{queue};

    my $edit = $self->modification_request(@_);
    Dlog_trace { "parsed modification request: $_" } $edit;

    $self->retrieve_and_perform_edit( $edit );

    if ($edit->error) {
        log_error { $self->edit_error( "malformed edit" => $edit ) };
		# TODO: emit error object
    } else {
        my $request = $queue->request( $edit );
		if ($request) {
			log_info { "New edit request accepted: $request" } 
            return $request;
		} else {
			log_error { "Failed to insert edit request" };
		}
    }
	
	undef;
}

sub command_replace {
    my $self    = shift;
    my $options = shift;
    my $id      = shift;

    my $old = $self->{queue}->get($id);
    if (!defined $old) {
        log_error { "request not found: $id" }
        return;
    }

    my $edit = $self->modification_request(@_);
    if ($edit->error) {
        log_error { $self->edit_error( "malformed edit" => $edit ) };
        return;
    }

    return $self->{queue}->update( $id => PICA::Modification->new( %{$edit->attributes} ) );
}


=head2 command_preview

Looks up an edit requests's edit, applies the edit and shows the result.

=cut

sub command_preview {
    my $self    = shift;
    my $options = shift;

	my @records;

    $self->iterate_performed_edits( sub {
        push @records, $_->{after};
    } => @_ );

	return join ("\n", @records);
}

sub command_get { 
    my $self    = shift;
    my $options = shift;

    my @mods;
    $self->iterate_edits( sub { push @mods, $_ } => @_ );

    return (scalar @mods > 1 ? \@mods : $mods[0]);
}

=head2 command_check

Check edits and mark as done on success, unless already processed.

=cut

sub command_check { 
    my $self    = shift;
    my $options = shift;

    $self->iterate_edits( sub {
		my ($status,$edit_id) = ($_->{status},$_->{edit_id});

		if ($status != 0) {
			log_info { "edit $edit_id is already status: $status" };
			return;
		}

        my $edit = $self->retrieve_and_perform_edit( $_ );
        if ($edit->error) {
			
			# TODO: save error object

            log_error { $self->edit_error( "" => $edit ); };

		} elsif ($edit->{before}->string ne $edit->{after}->string) {
            #...; # TODO:
  #          my $new = PICA::Modification::---
 #           $new->{status} = 0;
#			$self->{queue}->update( $edit_id => $new );
			log_info { "edit $edit_id has not been performed yet" };
		} else {
            #...; # TODO:
#            my $new = PICA::Modification::---
 #           $new->{status} = 1;
#			$self->{queue}->update( $edit_id => $new );
			log_info { "edit $edit_id is now done" }
		}
    } => @_ );

    # TODO: return (list of) requests

	undef;
}

sub command_reject {
    my $self    = shift;
    my $options = shift;

    $self->iterate_edits( sub {
        ...
    } => @_ );

	undef;
}

sub command_delete {
    my $self    = shift;
    my $options = shift;

    log_error { "expect edit_id as argument" } unless @_;

    my @ids;

    foreach my $id (@_) {
        unless ($id =~ /^\d+$/) {
            log_warn { "invalid edit_id: $id" };
            next;
        }
        my $is = $self->{queue}->delete( $id );
        push @ids, $is if defined $is;
    }
    return(join "\n", @ids) if @ids;

	undef;
}

sub command_list {
    my $self    = shift;
    my $options = shift;

    my $status = @_ ? shift : $options->{status};
    $status = do { given ($status) {
        when ('pending') { 0; };
        when ('rejected') { -1; };
        when ('failed') { -2; };
        when ('done') { 1; };
        default { '' };
    } };
    
    my @fields = qw(page limit sort status id request created creator updated epn iln add del);
    my @keys   = grep { 
        my $k = $_;
        grep { $k eq $_ } @fields;
    } keys %$options;

    my %where = map { $_ => $options->{$_} } @keys;
    $where{status} = $status if $status =~ /^(-1|0|1|2)$/;

    log_debug { join ' ', 'list', %where };

    my $list = $self->{queue}->list( %where );
    return unless @$list; # empty

	return $JSON->allow_blessed->convert_blessed->encode($list);
}

=method retrieve_and_perform_edit ( $edit )

Retrieve the record via unAPI. This method actually modifies the edit request,
so you should only call it once.  On success the PICA+ record before and after
modification is stored as L<PICA::Record> in the edit request. On failure, the
error is added to the edit.

=cut

sub retrieve_and_perform_edit {
    my ($self, $edit) = @_;

	unless (blessed $edit) {
		bless $edit, 'PICA::Modification';
		$edit->check;
	}
    Dlog_trace { "as_edit $_" } $edit;
    
    return $edit if $edit->error;

    my $unapi = $self->{unapi} || die "Missing unapi configuration";

    unless ($edit->{id} && $edit->{ppn}) {
        $edit->error( id => "missing record id/ppn" );
        return $edit;
    }

    my $before = $self->{unapi}->( $edit->{id} );
    if (blessed $before and $before->isa('PICA::Record')) {
	    $edit->{before} = $before;
	    $edit->{after}  = $edit->apply( $before, strict => 1 );
    } else {
        $edit->error( id => 'failed to retrieve record' ); # modifies edit
    }

    return $edit;
}

1;

=head1 DESCRIPTION

App::Picaedit is the core of the L<picaedit> command line client.  Eventually
App::Picaedit delegates commands to an instance of L<PICA::Modification::Queue>.

=head1 SEE ALSO

L<PICA::Record>, L<App::Run>

=cut
