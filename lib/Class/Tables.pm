package Class::Tables;

use Carp;
use strict;
use warnings;
use vars qw/$AUTOLOAD $VERSION/;

$VERSION = 0.22;

our (%CLASS_INFO, %OBJ_DATA, %TABLE_MAP, %TABLE_INFO, %STUB_COUNT, $DBH);

######################
## public interface ##
######################

sub dbh {
    my (undef, $dbh) = @_;
    croak "No DBH given" unless $dbh;
    $DBH = $dbh;
    %CLASS_INFO = %OBJ_DATA = %TABLE_MAP = %TABLE_INFO = ();
    _parse_tables();
}

#############################
## inherited class methods ##
#############################

sub fetch {
    my ($pkg, $id) = @_;
    my $table = $pkg->_table_name;
    
    return undef
        unless exists $OBJ_DATA{$pkg}{$id}
        or     sql_do("select 1 from $table where id=?", $id);
    
    my $obj = $pkg->_stub($id);
    $pkg->_fill_stubs($obj);

    return $obj;
}

## I'm not 100% happy with the @binds, to get object ids by just checking
## with ref(). But it should work fine unless you pass a hash ref or
## something else that has no earthly place in an sql search.

sub search {
    my ($pkg, %clauses) = @_;
    my $table = $pkg->_table_name;
    my @cols  = grep { exists $TABLE_MAP{$table}{$_} } keys %clauses;
    my @binds = map { ref $_ ? $_->id : $_ } @clauses{@cols};
    my $sql   = sprintf( "select id from $table %s %s order by %s %s",
                    (@cols ? "where" : ""),
                    join( " and " => map { "$_=?" } @cols ),
                    ($TABLE_INFO{$table}{order_by} ||= 'id'),
                    (wantarray ? "" : "limit 1")
                );

    my $q = sql_query($sql, @binds);
    
    my @stubs = map { $pkg->_stub($_->[0]) } @{ $q->fetchall_arrayref };
    $q->finish;
   
    $pkg->_fill_stubs(@stubs);

    return wantarray ? @stubs : $stubs[0];
}

sub new {
    my ($pkg, %params) = @_;
    $params{id} = undef;
    
    my $table = $pkg->_table_name;
    my @cols  = grep { $_ ne 'id' and exists $TABLE_MAP{$table}{$_} }
                keys %params;
    my @binds = @params{@cols};
    my $sql   = sprintf( "insert into $table set %s",
                    join( "," => map { "$_=?" } @cols )
                );
                
    sql_do($sql, @binds) or return undef;
    
    my $id  = sql_insertid();
    my $obj = $pkg->_stub($id);
    @{ $OBJ_DATA{$pkg}{$id} }{@cols} = @binds;
    
    return $obj;
}

##############################
## inherited object methods ##
##############################

sub id {
    ${ $_[0] };
}

sub DESTROY {
    my $self = shift;
    my $pkg  = ref $self;
    my $id   = $self->id;

    delete $OBJ_DATA{$pkg}{$id}
        unless --$STUB_COUNT{$pkg}{$id};
}

sub AUTOLOAD {
    my $self = shift;
    (my $func = $AUTOLOAD) =~ s/.*:://;
    
    croak "Method call not found: $AUTOLOAD"
        unless ref $self and UNIVERSAL::isa( $self, __PACKAGE__ );

    unshift @_, $self, $func;
    goto &field;
}

sub field {
    my $self  = shift;
    my $field = shift;
    my $id    = $self->id;
    my $pkg   = ref $self;
    my $table = $pkg->_table_name;
    my $type  = $pkg->_accessor_type($field);

    croak "Invalid object accessor: $pkg\::$field"
        unless $type;
    
    if ( $type eq 'indirect' ) {
        carp "$pkg\::$field is a read-only accessor" if @_;
        return $TABLE_INFO{$field}{class}->search( $table => $id );
    }

    ## load-on-demand -- because the 'local' below autovivifies
    ## maybe fixme -- don't load on demand if updating the value
    
    if ( not exists $OBJ_DATA{$pkg}{$id}{$field} ) {
        $OBJ_DATA{$pkg}{$id}{$field} =
            sql_do("select $field from $table where id=?", $id);
    }

    ## save some typing
    use vars '$attr_value';
    local *attr_value = \$OBJ_DATA{$pkg}{$self->id}{$field};

    if ( $type eq 'direct' ) {

        if (my $new = shift) {
            my $ref_id = ref $new ? $new->id : $new;
            
            sql_do("update $table set $field=? where id=?", $ref_id, $id)
                and $attr_value = $new;
        }

        ## inflate foreign key IDs into respective objects
        $attr_value = $TABLE_INFO{$field}{class}->fetch($attr_value)
            if exists $TABLE_INFO{$field}{class}
            and not ref $attr_value;

    ## normal vanilla accessor
    } else {
    
        if (my $new = shift) {
            sql_do("update $table set $field=? where id=?", $new, $id)
                and $attr_value = $new;
        }
    }

    return $attr_value;
}


sub delete {
    my $self  = shift;
    my $id    = $self->id;
    my $pkg   = ref $self;
    my $table = $pkg->_table_name;
    
    sql_do("delete from $table where id=?", $id);
    delete $OBJ_DATA{$pkg}{$id};
    
    ## fixme? cascade to remove *all* stub occurences from %OBJ_DATA
    ## (as in foreign key refs)
}

use overload '""' => sub {
    my $self  = shift;
    my $pkg   = ref $self;
    my $table = $pkg->_table_name;

    return exists $TABLE_MAP{$table}{'name'}
        ? $self->name
        : $pkg . ":" . $self->id;
};

###################################
## play nice with HTML::Template ##
###################################

sub dump {
    my ($self, @ignore) = @_;
    my $pkg    = ref $self;
    my $table  = $pkg->_table_name;
    my %ignore = map { $_ => 1 } @ignore;

    my @fields = grep { not $ignore{$_} } $pkg->_fields;
    push @ignore, $table;

    my %h = map {
        my $type   = $pkg->_accessor_type($_);
        my @result = $self->$_;
        my $value;
        
        if ($type eq 'indirect') {
            $value = [ map { $_->dump(@ignore) } @result ];
        } elsif ($type eq 'direct') {
            $value = $result[0] ? $result[0]->dump(@ignore) : undef;
        } else {
            $value = $result[0];
        }
        
        $_ => $value
    } @fields;

    return \%h;
}

###########################
## private class methods ##
###########################

sub _preload_columns {
    my $pkg   = shift;
    my $table = $pkg->_table_name;
    
    $CLASS_INFO{$pkg}{preload_columns} ||= [
        grep { $TABLE_MAP{$table}{$_} !~ /blob|text/ }
        keys %{ $TABLE_MAP{$table} }
    ];
    
    return @{ $CLASS_INFO{$pkg}{preload_columns} };
}

sub _stub {
    my ($pkg, $id) = @_;
    $STUB_COUNT{$pkg}{$id}++;
    bless \$id, $pkg;
}

sub _table_name {
    $CLASS_INFO{ $_[0] }{table};
}

sub _fill_stubs {
    my $pkg = shift;
    
    my @empty_stub_ids = grep { not exists $OBJ_DATA{$pkg}{$_} }
                         map  { $_->id } @_;

    return unless @empty_stub_ids;                         
                      
    my $sql = sprintf( "select id%s from %s where id in (%s)",
                  join( "" => map { ",$_" } $pkg->_preload_columns ),
                  $pkg->_table_name,
                  join( "," => ("?") x @empty_stub_ids )
              );
              
    my $q = sql_query($sql, @empty_stub_ids);
    while ( my $hr = $q->fetchrow_hashref ) {
        $OBJ_DATA{$pkg}{ $hr->{id} } = { %$hr };
    }
    $q->finish;    
}

sub _fields {
    my $pkg   = shift;
    my $table = $pkg->_table_name;
    return ('id',
            keys %{ $TABLE_MAP{$table} },
            grep { exists $TABLE_MAP{$_}{$table} } keys %TABLE_MAP);
}

sub _accessor_type {
    my ($pkg, $field) = @_;
    my $table = $pkg->_table_name;
    
    return 'indirect'
        if exists $TABLE_MAP{$field} and exists $TABLE_MAP{$field}{$table};
    return 'direct'
        if exists $TABLE_MAP{$field};
    return 'plain'
        if exists $TABLE_MAP{$table}{$field}
        or $field eq 'id';
    return undef;
}

##################
## private subs ##
##################

sub _parse_tables {
    my $q_table = sql_query("show tables");
	while ( my ($table, $view) = $q_table->fetchrow_array ) {
	
		my $q_column = sql_query("describe $table");
		while ( my $hr = $q_column->fetchrow_hashref ) {
			my $col  = $hr->{Field};
			my $type = $hr->{Type};
			
			next if $col eq 'id';
			
			$TABLE_MAP{$table}{$col}        = $type;
			$TABLE_INFO{$table}{order_by} ||= $col;
		}
		$q_column->finish;

        my $pkg = _table_to_package_name($table);
        $TABLE_INFO{$table}{class} = $pkg;
        $CLASS_INFO{$pkg}{table}   = $table;
        
        _generate_package($pkg);
        
	}
	$q_table->finish;
}

sub _generate_package {
    my $pkg = shift;
    no strict 'refs';
    
    @{ $pkg . '::ISA' } = ( __PACKAGE__ );
}

sub _table_to_package_name {
    my $table = lc shift;
    $table =~ s/(?:^|_)(.)/uc $1/ge;
    return $table;
}

######################################
## private db convenience functions ##
######################################

sub sql_query {
    confess "No DBH supplied" unless $DBH;
    my $sql = shift;
	my $sth = $DBH->prepare_cached($sql) or confess $DBH::errstr;

	eval {
		$sth->execute(@_) or die $sth->errstr;
	};

	if ($@) {
		confess $@; return undef;
	}

	return $sth;
}

sub sql_insertid {
	return $DBH->{'mysql_insertid'};
}

sub sql_do {
	my $sth = sql_query(@_) || return undef;

	my @ret = $_[0] =~ /^\s*select/i 
        ? $sth->fetchrow_array
        : (1);
	$sth->finish;

	return wantarray ? @ret : $ret[0];
}


######################################

1;

__END__

=head1 NAME

Class::Tables - Relational-object interface with no configuration necessary

=head1 SYNOPSIS

The I<only> thing you need to do is give it a database handle to look at, 
and it Just Works, right out of the box, provided your database follows some
very basic rules:
  
  use Class::Tables;
  Class::Tables->dbh( DBI->connect($dsn, $user, $passwd) );
  ## that's all you have to do to get this:
  
  my $new_guy = Employee->new( name => "Bilbo Baggins" );
  my $old_guy = Employee->fetch( $id );
  my $john    = Employee->search( name => "John Doe" );
  
  $john->name( "Jonathan Doe" );     ## simple accessors/mutators
  print $john->age, $/;
  
  print "Stringification to the object's 'name' attribute: $john\n";
  
  my $dept = $john->department;      ## because we also have a table named
  print $dept->description, $/;      ## "department", it returns an object
  
  $john->department( $other_dept );  ## assign a Department object
  $john->department( 15 );           ##  .. or just the ID of one
  
  my @coworkers = $dept->employee;   ## get all Employee objects that
                                     ## reference this Department
                                     
                                     ## this is also equivalent:
  my @coworkers = Employee->search( department => $dept );

=head1 DESCRIPTION

The goal of this module is not an all-encompassing object abstraction for
relational data. If you want that, see L<Class::DBI> or L<Alzabo> and the
like. Instead, Class::Tables aims to be a zero-configuration object
abstraction. Using simple rules about the metadata -- the names of tables,
columns, and their types -- Class::Tables automatically generates
appropriate classes, with object relationships intact. These rules are
so simple that you may find you are already following them.

=head2 Meta-Data

=over

=item Primary Key

All tables must have an C<id> column, which is the primary key of the table,
and set to C<AUTO_INCREMENT>.

=item Foreign Key Inflating

A column that shares a name with a table is treated as a foreign key
reference to items of that table.

If the C<employee> table has a column called C<department>, and there
is a table in the database also named C<department>, then the
C<department> accessor for Employee objects will return the I<object>
referred to by the ID in that column. The mutator will also accept
an appropriate object (or ID).

Conversely, an C<employee> accessor (read-only) would be available to
all Department objects that returns all Employee objects referencing
the Department object in question.

=item Lazy Loading

All C<*blob> and C<*text> columns will be lazy-loaded: not queried
or stored into memory until requested.

=item Automatic Sort Order

The first column in the table which is not the C<id> column is the
default sort order. All result sets returning multiple objects from
a table will be sorted in this order (ascending).

=item Stringification

If the table has a C<name> column, then its value will be used as
the stringification value of an object. Otherwise, the object will
stringify to C<CLASS:ID>.

=item Class Names

Each table must be associated with a package. The default package
name for a table in C<underscore_separated> style is the
corresponding name translated to C<StudlyCaps>. However, foreign-key
accessors are still named according to the column name. So calling
C<$obj-E<gt>foo_widget> returns a C<FooWidget> object.

=back


=head1 INTERFACE

=head2 Public Interface

=over

=item C<Class::Tables-E<gt>dbh( $dbh )>

You must pass Class::Tables an active database handle before you can
use any generated object classes.

=back

=head2 Data Class Methods

Every class that Class::Tables generates gets the following class methods:

=over

=item C<SomeClass-E<gt>new( [ field =E<gt> value, ... ] )>

Creates a new object in the database with the given values set. If
successful, returns the object, otherwise returns undef. You can pass
an object or an ID as the value if the field is a foreign key.

=item C<SomeClass-E<gt>search( [ field =E<gt> value, ... ] )>

Searches the appropriate table for objects matching the given restrictions.
In list context, returns all objects that matched (or an empty list if no
objects matched). In scalar context returns only the first object returned
by the query (or undef if no objects matched). The scalar context query is
slightly optimized. If no arguments are passed to C<search>, every object in
the class is returned. 

=item C<SomeClass-E<gt>fetch( $id )>

Semantically equivalent to C<SomeClass-E<gt>search( id =E<gt> $id )>, but
slightly optimized internally. Unlike C<search>, will never return multiple
items. Returns undef if no object with the given ID exists in the database.

=back

=head2 Object Methods

Every object in a Class::Tables-generated class has the following methods:

=over

=item C<$obj-E<gt>delete()>

Removes the object from the database.

=item Accessor/Mutators: C<$obj-E<gt>I<foo>( [ $new_val ] )>

For each column I<foo> in the table, an accessor/mutator is provided by
the same name. It returns the current value of that column for the object.
If I<foo> is also the name of another table in the database, then the
accessor will return the corresponding Foo object with that ID, or undef
if there is no such object. You may pass either a Foo object or an integer
ID as the new value,

Alternately, I<foo> can also be the name of a table that has a foreign key
pointing to objects of the same type as C<$obj>. If C<$obj> is a Bar object,
C<$obj-E<gt>foo> is exactly equivalent to C<Foo-E<gt>search( bar =E<gt> $obj )>.

=item C<$obj-E<gt>field( $field [, $new_val ] )>

This is an alternative syntax to accessors/mutators. If you aren't a fan
of variable method names, you can use the C<field> method:

  for my $thing (qw/name age favorite_color/) {
      ## these two are equivalent:
      print $obj->$thing, $/;
      print $obj->field($thing), $/;
  }

=item C<$obj-E<gt>dump>

Returns a hashref containing the object's attribute data. Recursively
inflates foreign keys, too. Reverse foreign keys are mapped to an array ref.
You may find this useful with HTML::Template! Use Data::Dumper on this to
see how it does things...

=back

=head1 OTHER STUFF

You can still override/augment object methods if you need to with SUPER:

  package Employee;
  sub ssn {
      my $self = shift;
      my $ssn = $self->SUPER::ssn(@_);
      $ssn =~ s/(\d{3})(\d{2})(\d{4})/$1-$2-$3/;
      return $ssn;
  }

But since the objects are blessed scalars, you have to use some sort of
inside-out mechanism to store extra (non-persistent) subclass attributes
with the objects:

  ## if you want to do something like this:
  
  for my $emp ( grep { not $_->seen_already } @employees ) {
     ## do something to $emp that you only want to do once..
     ## maybe give $emp a raise?
     
     $emp->see;
  }
  
  ## in the subclass, you can do this:
  
  package Employee;
  my %seen;
  sub seen_already { $seen{+shift};   }
  sub see          { $seen{+shift}++; }

=head1 CAVEATS

So far, the table parsing code only works with MySQL. Same with getting the
ID of the last inserted object. Testers/patchers for other DBMS's welcome!

=head1 AUTHOR

Class::Tables is written by Mike Rosulek E<lt>mike@mikero.comE<gt>. Feel 
free to contact me with comments, questions, patches, or whatever.

=head1 COPYRIGHT

Copyright (c) 2003 Mike Rosulek. All rights reserved. This module is free 
software; you can redistribute it and/or modify it under the same terms as Perl 
itself.

