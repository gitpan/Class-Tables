package Class::Tables;

use Carp;
use strict;
use warnings;
use vars qw/$VERSION $DBH $SQL_DEBUG $PLURALIZE $SQL_QUERIES $CASCADE/;

$VERSION   = "0.25";
$PLURALIZE = 1;
$CASCADE   = 1;

## flyweight data

my ( %CLASS, %OBJ, %TABLE_MAP );

######################
## public interface ##
######################

sub import {
    my $class = shift;
    for (@_) {
        if (/^no_cascade$/) {
            $CASCADE = 0;
            next;
        } elsif (/^cascade$/) {
            $CASCADE = 1;
            next;
        } else {
            croak "Unknown parameter for 'use $class' : $_\n";
        }
    }
}

sub dbh {
    my ($super, $dbh) = @_;
    croak "No DBH given" unless $dbh;
    ($DBH, %CLASS, %OBJ, %TABLE_MAP) = $dbh;

    no strict qw/refs subs/;
    
    *PL_N = ($PLURALIZE && eval "use Lingua::EN::Inflect; 1")
        ? \&Lingua::EN::Inflect::PL_N
        : sub { $_[0] };

    $super->_parse_tables();
}

#############################
## inherited class methods ##
#############################

sub fetch {
    my ($class, $id) = @_;
    my $id_col = $class->_id_col;
    
    if (exists $OBJ{$class}{$id}) {
        $CLASS{$class}{stub_count}{$id}++;
        return bless \$id, $class;
    }
    
    return scalar $class->_stubs("where $id_col=?", $id);
}

sub search {
    my ($class, %params) = @_;
    
    return unless defined wantarray;
    
    my @fields = grep { exists $CLASS{$class}{accessors}{$_} } keys %params;
    my @binds  = map { UNIVERSAL::can($_, 'id') ? $_->id : $_ } @params{@fields};
    my @cols   = map { $CLASS{$class}{accessors}{$_}{col} } @fields;

    my $clause = @cols
        ? "where " . join(" and " => map "$_=?", @cols)
        : "";
    $clause .= " order by " . $class->_order_by;
    $clause .= " limit 1" unless wantarray;
    
    return $class->_stubs($clause, @binds);
}

sub new {
    my ($class, %params) = @_;
    $params{id} = undef;

    my @fields = grep { exists $CLASS{$class}{accessors}{$_} } keys %params;
    my @binds  = map { UNIVERSAL::can($_, 'id') ? $_->id : $_ } @params{@fields};
    my @cols   = map { $CLASS{$class}{accessors}{$_}{col} } @fields;

    my $table  = $class->_table;
    my $sql    = "insert into $table set " . join("," => map { "$_=?" } @cols);
                
    sql_do($sql, @binds) or return undef;
    
    my $id  = sql_insertid();
    my $obj = $class->_mk_stub($id);
    @{ $OBJ{$class}{$id} }{@cols} = @binds;
    
    return $obj;
}

##############################
## inherited object methods ##
##############################

sub id { ${ $_[0] }  }

sub DESTROY {
    my $self  = shift;
    my $class = ref $self;
    my $id    = $self->id;

    delete $OBJ{$class}{$id}
        unless --$CLASS{$class}{stub_count}{$id};
}

sub AUTOLOAD {
    my $self = shift;
    (my $func = $Class::Tables::AUTOLOAD) =~ s/.*:://;
    
    croak qq{Can't locate object method "$func" via package "$self"}
        unless ref $self and UNIVERSAL::isa( $self, "Class::Tables" );

    unshift @_, $self, $func;
    goto &field;
}

sub field {
    my $self   = shift;
    my $field  = shift;
    my $id     = $self->id;
    my $class  = ref $self;
    my $table  = $class->_table;
    my $id_col = $class->_id_col;

    croak qq{Can't locate accessor "$field" via package "$class"}
        unless exists $CLASS{$class}{accessors}{$field};

    my $type   = $CLASS{$class}{accessors}{$field}{type};
    my $ref    = $CLASS{$class}{accessors}{$field}{ref};
    my $col    = $CLASS{$class}{accessors}{$field}{col};

    return $TABLE_MAP{$ref}->search( $col => $id, @_ )
        if $type eq 'indirect';

    ## lazy-load columns now
    $OBJ{$class}{$id}{$col} =
            sql_do("select $col from $table where $id_col=?", $id)
        if not exists $OBJ{$class}{$id}{$col};

    if ( $type eq 'direct' ) {
        if (@_) {
            my $ref_id = UNIVERSAL::can($_[0], 'id') ? $_[0]->id : $_[0];
            
            sql_do("update $table set $col=? where $id_col=?", $ref_id, $id)
                and $OBJ{$class}{$id}{$col} = $ref_id;
        }
        
        ## inflate keys
        return unless defined wantarray;
        
        return $TABLE_MAP{$ref}->fetch( $OBJ{$class}{$id}{$col} )
            if defined $OBJ{$class}{$id}{$col};

    } elsif ( $type eq 'normal' ) {
        if (@_) {
            sql_do("update $table set $col=? where $id_col=?", $_[0], $id)
                and $OBJ{$class}{$id}{$col} = shift;
        }
    }

    return $OBJ{$class}{$id}{$col};
}

sub delete {
    my $self   = shift;
    my $id     = $self->id;
    my $class  = ref $self;
    my $table  = $class->_table;
    my $id_col = $class->_id_col;

    if ($CASCADE) {    
        my @cascade = grep { $CLASS{$class}{accessors}{$_}{type} eq 'indirect' }
                      keys %{ $CLASS{$class}{accessors} };
        
        for my $accessor (@cascade) {
            $_->delete for $self->$accessor;
        }
    }

    sql_do("delete from $table where $id_col=?", $id);
    delete $OBJ{$class}{$id};
    
}

use overload
    fallback => 1,
    '""' => sub {
        my $self  = shift;
        my $class = ref $self;
    
        return exists $CLASS{$class}{accessors}{'name'}
            ? $self->name
            : $class . ":" . $self->id;
    },
    'bool' => sub { 1 };

###################################
## play nice with HTML::Template ##
###################################

sub dump {
    my ($self, @ignore) = @_;
    my $class  = ref $self;
    my $table  = $class->_table;
    my %ignore = map { $_ => 1 } @ignore;
    my @fields = grep { not $ignore{  $CLASS{$class}{accessors}{$_}{ref}  } }
                 keys %{ $CLASS{$class}{accessors} };

    push @ignore, $table;

    my %h = map {
        my $type   = $CLASS{$class}{accessors}{$_}{type};
        my @result = $self->$_ unless $type eq 'alias';
        my %values;
        
        if ($type eq 'indirect') {
        
            $values{$_} = [ map { $_->dump(@ignore) } @result ];
            
        } elsif ($type eq 'direct') {
            if ($result[0]) {
                my $r = $result[0]->dump(@ignore);
                my $prefix = $_;

                %values = map {; "$prefix.$_" => $r->{$_} } keys %$r;
                
            } else {
                $values{$_} = undef;
            }

        } elsif ($type eq 'normal') {
            $values{$_} = $result[0];
        }
        
        %values;
        
    } @fields;

    $h{id} = $self->id;

    return \%h;
}

###########################
## private class methods ##
###########################

sub _table     { $CLASS{ $_[0] }{table}; }
sub _load_cols { @{ $CLASS{ $_[0] }{load_cols} }; }
sub _id_col    { $CLASS{ $_[0] }{id_col}; }
sub _accessors { keys %{ $CLASS{ $_[0] }{accessors} }; }
sub _order_by  { $CLASS{ $_[0] }{order_by} ||= $_[0]->_id_col; }

sub _mk_stub {
    my ($class, $id) = @_;
    $CLASS{$class}{stub_count}{$id}++;
    return bless \$id, $class;
}

my $MAX_ROWS = 5_000;

sub _stubs {
    my $class  = shift;
    my $clause = shift;
    my $id_col = $class->_id_col;
    my $table  = $class->_table;
    my @stubs;
    my @cols   = ($id_col, $class->_load_cols);
    
    my $sql    = sprintf "select %s from $table $clause", join "," => @cols;
    my $q      = sql_query($sql, @_);
    
    $q->execute(@_);

    while (my $row = $q->fetchrow_arrayref) {
        my $id = $row->[0];
        push @stubs, $class->_mk_stub($id);
        @{ $OBJ{$class}{$id} }{@cols} = @$row;
    }

#    for (@{ $q->fetchall_arrayref }) {
#        my $id = $_->[0];
#        push @stubs, $class->_mk_stub($id);
#        @{ $OBJ{$class}{$id} }{@cols} = @$_;
#    }

#    while (my $rows = $q->fetchall_arrayref(undef, $MAX_ROWS)) {
#        for (@$rows) {
#            my $id = $_->[0];
#            push @stubs, $class->_mk_stub($id);
#            
#            @{ $OBJ{$class}{$id} }{@cols} = @$_;
#        }
#    }

    $q->finish;
    
    return wantarray ? @stubs : $stubs[0];
}


##################
## private subs ##
##################

sub _parse_tables {
    my $super = shift;
    my @tables;
    
    my $q = sql_query("show tables")
        or die "Error listing tables";
    while ( my ($table) = $q->fetchrow_array ) {
        my $class             = _table_to_package_name($table);
        
        croak "Tables '$table' and '$CLASS{$class}{table}' both become "
            . "the '$class' class"
            if exists $CLASS{$class};
        
        $TABLE_MAP{$table}    = $class;
        $CLASS{$class}{table} = $table;
        
        $super->_generate_package($class);
        push @tables, $table;
    }
    $q->finish;

    for my $table (@tables) {
        my $class = $TABLE_MAP{$table};

        $q = sql_query("describe $table")
            or die "Error describing table $table";
        while ( my $hr = $q->fetchrow_hashref ) {
            my $col = $hr->{Field};
            my ($field, $type, $ref) = _accessor_type($table, $col);
            
            $CLASS{$class}{accessors}{$field} = {
                col  => $col,
                type => $type,
                ref  => $ref,
            };

            $CLASS{$class}{id_col} = $col, next if $type eq 'id';

            ## reverse-map the direct foreign keys
            if ($type eq 'direct') {
                my $ref_class = $TABLE_MAP{$ref};
                $CLASS{$ref_class}{accessors}{$table} = {
                    col  => $field,
                    type => 'indirect',
                    ref  => $table
                };
            }

            push @{ $CLASS{$class}{load_cols} }, $col
                if $hr->{Type} !~ /blob|text/;
                
            $CLASS{$class}{order_by} ||= $col;
        }
        $q->finish;
        
    }

}

#####

sub _accessor_type {
    my ($table, $name) = @_;

    my $type = 'normal';
    my $ref  = '';
    
    if ($name =~ s/_id$//) {
        if ($name eq $table) {
            $name = $type = 'id';
        } elsif (PL_N($name) eq $table) {
            $name = $type = 'id';
        } elsif (exists $TABLE_MAP{$name}) {
            $type = 'direct';
            $ref  = $name;
        } elsif ( exists $TABLE_MAP{ PL_N($name) } ) {
            $type = 'direct';
            $ref  = PL_N($name);
        }
    } elsif ($name eq 'id') {
        $type = 'id';
    } elsif (exists $TABLE_MAP{$name}) {
        $type = 'direct';
        $ref  = $name;
    } elsif (exists $TABLE_MAP{ PL_N($name) }) {
        $type = 'direct';
        $ref  = PL_N($name);
    }

    ## $name is the name of the accessor METHOD
    ## $ref  is the name of the table in a direct accessor

    return ($name, $type, $ref);
}

sub _table_to_package_name {
    return join "" => map ucfirst, split /_/, lc shift;
    my $table = lc shift;
    $table =~ s/(?:^|_)(.)/uc $1/ge;
    return $table;
}

sub _generate_package {
    my ($super, $class) = @_;
    no strict 'refs';
    
    unshift @{ "$class\::ISA" }, $super
        unless UNIVERSAL::isa( $class, $super );
}

######################################
## private db convenience functions ##
######################################

sub sql_query {
    confess "No DBH supplied" unless $DBH;
    my $sql = shift;
    my $sth;

    eval {
        local $DBH->{RaiseError} = 1;
        local $DBH->{PrintError} = 0;
        
        print "$sql\n" if $SQL_DEBUG;
        $SQL_QUERIES++;
        
        $sth = $DBH->prepare_cached($sql);
        $sth->execute(@_);

        1;
    } or return undef;

    return $sth;
}

sub sql_insertid {
    return $DBH->{'mysql_insertid'};
}

sub sql_do {
    my $sth = sql_query(@_) or return undef;

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

Class::Tables - Auto-vivification of persistent classes, based on RDBMS schema

=head1 SYNOPSIS

Telling your relational object persistence class about all your table
relationships is no fun. Wouldn't it be nice to just include a few lines in a
program:

  use Class::Tables;
  Class::Tables->dbh($dbh);

and magically have all the object persistence classes from the database,
preconfigured, with table relations auto-detected, etc?

This is the goal of Class::Tables. Its aim is not to be an all-encompassing 
tool like L<Class::DBI|Class::DBI>, but to handle the most common and useful
cases smartly, quickly, and without needing your help. Just pass in a database
handle, and this module will read your mind (by way of your database's table
schema) in terms of relational object persistence. The very simple (and
flexible) rules it uses to determine your object relationships from your
database's schema are so simple, you will probably find that you are already
following them.

=head2 Introductory Example

Suppose your database schema were as unweildy as the following SQL. The
incosistent naming, the plural table names and singular column names are not
a problem for Class::Tables.

  create table departments (
      id            int not null primary key auto_increment,
      name          varchar(50) not null
  );
  create table employees (
      employee_id   int not null primary key auto_increment,
      name          varchar(50) not null,
      salary        int not null,
      department_id int not null
  );

To use Class::Tables, you need to do no more than this:

  use Class::Tables;
  my $dbh = DBI->connect($dsn, $user, $passwd) or die;
  Class::Tables->dbh($dbh);

Et voila! Class::Tables looks at your table schema and generates two classes,
C<Departments> and C<Employees>, each with constructor and search class
methods:

  my $marketing  = Departments->new( name => "Marketing" );
  my @underpaid  = Employees->search( salary => 20_000 );
  my @marketeers = Employees->search( department => $marketing );
  my $self       = Employees->fetch($my_id);

It also generates the following instance methods:

=over

=item A deletion method for both classes

This simply removes the object from the database.

  $marketing->delete;

=item Readonly id accessor methods for both classes

For C<Departments> objects, this corresponds to the C<id> column in the table,
and for C<Employees> objects, this corresponds to the C<employee_id> column.
Class::Tables is smart enough to figure this out, even though "employee" is
singular and "employees" is plural (See L<Plural And Singular Nouns>).

  print "You're not just a name, you're a number: " . $self->id;

=item Normal accessor/mutator methods

C<Departments> objects get a C<name> accessor/mutator method, and C<Employees>
objects get C<name> and C<salary> accessor/mutator methods, referring to the
respective columns in the database.

  $self->salary(int rand 100_000);
  print "Pass go, collect " . $self->salary . " dollars";

=item Foreign key methods

When Class::Tables sees the C<department_id> column in the C<employees> table,
it knows that there is also a C<departments> table, so it treats this column
as a foreign key. Thus, C<Employees> objects get a C<department>
accessor/mutator method, which returns (and can be set to) a C<Departments>
object.

  print "I'd rather be in marketing than " . $self->department->name;
  $self->department($marketing);

It also reverses the foreign key relationship, so that all C<Departments>
objects have a readonly C<employees> method, which returns a list of all
C<Employees> objects referencing the particular C<Departments> object.

  my @overpaid  = $marketing->employees;
  ## same as:     Employees->search( department => $marketing )
  
  my @coworkers = $self->department->employees;

Notice how the plural vs. singular names of the methods match their return
values. This is all automatic! (See L<Plural And Singular Nouns>)

=back

=head1 USAGE

Class::Tables offers more functionality than just the methods in this example.

=head2 Database Metadata

Here's a more concrete explanation of how Class::Tables will use your table
schema to generate the persistent classes.

=over

=item Class Names

Each table in the database must be associated with a class. The table name
will be converted from C<underscore_separated> style into C<StudlyCaps> for
the name of the class/package. 

=item Primary Key

All tables must have a primary key column in the database, which is an integer
column set to C<AUTO_INCREMENT>. This column must be named either C<id>, the
table name followed by an C<_id> suffix, or the singular form of the table
name followed by an C<_id> suffix.

In our above example, the C<employees> table could have had a primary key
column named C<employee_id>, C<employees_id>, or C<id>. The flexibility allows
for reasonable choices whether you name your tables as singular or plural
nouns. (See L<Plural And Singular Nouns>)

For simplicity and transparency, the associated object accessor is always
named C<id>, regardless of the underlying column name.

=item Foreign Key Inflating

If a column has the same name as another table, that column is treated as a
foreign key reference to that table. Alternately, the column may be the
singular form of the table name, and an optional C<_id> suffix may be added.
The name of the accessor is the name of the column, minus the C<_id>.

In our above example, the foreign key column relating each employee with a
department could have been named C<departments>, C<departments_id>,
C<department>, or C<department_id>. Again, the flexibility allows for a
meaningful column name whether your table names are singular or plural. (See
L<Plural And Singular Nouns>).

The foreign key relationship is also reversed as described in the example. The
name of the accessor in the opposite direction is the name of the table. In
our example, this means that objects of the C<Departments> class get an
accessor named C<employees>. For this reason, it is often convenient to name
the tables as plural nouns.

=item Lazy Loading

All C<*blob> and C<*text> columns will be lazy-loaded: not loaded from the
database until their values are requested or changed. 

=item Automatic Sort Order

The first column in the table which is not the primary key is the default
sort order for the class. All operations that return a list of objects will be
sorted in this order (ascending). In our above example, both tables are sorted
on C<name>.

=item Stringification

If the table has a C<name> column, then any objects of that type will
stringify to the value of C<< $obj->name >>. Otherwise, the object will
stringify to C<CLASS:ID>.

=back


=head2 Public Interface

=over

=item C<< use Class::Tables $option >>

C<$option> may be either C<'no_cascade'> or C<'cascade'> to disable and
enable cascading deletes, respectively. See C<delete> below. The default
is to enable cascading deletes. If you need to change cascading delete
behavior on the fly, set C<$Class::Tables::CASCADE>.

=item C<< Class::Tables->dbh($dbh) >>

You must pass Class::Tables an active database handle before you can use any
generated object classes. 

=back

=head2 Object Instance Methods

Every object in a Class::Tables-generated class has the following methods:

=over

=item C<< $obj->id >>

This readonly accessor returns the primary key of the object.

=item C<< $obj->delete >>

Removes the object from the database. The behavior of further method calls on
the object are undefined.

If cascading deletes are enabled, then all other objects in the database that
have foreign keys pointing to C<$obj> are deleted as well, and so on. Cyclic
references are not handled gracefully, so if you have a complicated
database structure, you should disable cascading deletes. You can roll your
own cascading delete (to add finer control) very simply:

  package Department;
  sub delete {
      my $self = shift;
      $_->delete for $self->employees;
      $self->SUPER::delete;
  }

It's important to point out that in this process, if an object looses all
foreign key references to it, it is not deleted. For example, if all
Employees in a certain department are deleted, the department object is not
automatically deleted. If you want this behavior, you must add it yourself
in the Employees::delete method.

=item C<< $obj->attrib >> and C<< $obj->attrib($new_val) >>

For normal columns in the table (that is, columns not determined to be a
foreign key reference), accessor/mutator methods are provided to get and
set the value of the column, depending if an argument is given.

For foreign key reference columns, calling the method as an accessor is
equivalent to a C<fetch> (see below) on the appropriate class, so will return
the referent object or C<undef> if there is no such object. When called as a
mutator, the argument may be either an ID or an appropriate object:

  ## both are ok:
  $self->department( $marketing );
  $self->department( 10 );

For the reverse-mapped foreign key references, the method is readonly, and
returns a list of objects. It is equivalent to a C<search> (see below) on the
appropriate class, which means you can also pass additional constraints:

  my @marketeers = $marketing->employees;
  ## same as Employees->search( department => $marketing );

  my @volunteers = $marketing->employees( salary => 0 );
  ## same as Employees->search( department => $marketing, salary => 0 );
  

=item C<< $obj->field($field) >> and C<< $obj->field($field, $new_val) >>

This is an alternative syntax to accessors/mutators. When C<$field> is the
name of a valid accessor/mutator method for the object, this is equivalent to
saying C<< $obj->$field >> and C<< $obj->$field($new_val) >>.

=item C<< $obj->dump >>

Returns a hashref containing the object's attribute data. It recursively
inflates foreign keys and maps reverse foreign keys to an array reference.
This is particularly useful for generating structures to pass to
L<HTML::Template|HTML::Template> and friends.

As an example, suppose we also have tables for Purchases and Products, with
appropriate foreign keys. Then the result of C<dump> on an Employees object
may look something like this:

  {
      'name'            => 'John Doe',
      'id'              => 7,
      
      'department.name' => 'Sales',
      'department.id'   => 4,
      
      'purchases'       => [
          {
              'date'           => '2002-12-13',
              'quantity'       => 1,
              'id'             => 5,
              
              'product.id'     => 1,
              'product.name'   => 'Widgets',
              'product.price'  => 200,
              'product.weight' => 10
          },
          {
              'date'           => '2002-12-15',
              'quantity'       => 2,
              'id'             => 6,
              
              'product.id'     => 3,
              'product.name'   => 'Foobars',
              'product.price'  => 150,
              'product.weight' => 200
          }
      ]
  };

The amount of foreign key inflation is bounded: A foreign key accessor will
only be followed if its corresponding table hasn't been seen before in the
dump. This is necessary because, for example, our Purchases objects have a
foreign key pointing back to the John Doe employee object. But following that
foreign key would cause an infinite recursion. This means there is no quick
way to get a list such as C<< $john_doe->department->employees >> from the
dump, because the employees table would be visited twice.

=back

=head2 Data Class Methods

Every persistent object class that Class::Tables generates gets the following
class methods:

=over

=item C<< Class->new( field1 => $value1, field2 => $value2, ... ) >>

Creates a new object in the database with the given attributes set. If
successful, returns the object, otherwise returns C<undef>. This is
equivalent to the following:

  my $obj = Class->new;
  $obj->field1($value1);
  $obj->field2($value2);
  ...

So for foreign key attributes, you may pass an actual object or an ID:

  ## both are ok:
  Employee->new( department => $marketing );
  Employee->new( department => 10 );

=item C<< Class->search( field1 => $value1, field2 => $value2, ... ) >>

Searches the appropriate table for objects matching the given constraints.
In list context, returns all objects that matched (or an empty list if no
objects matched). In scalar context returns only the first object returned
by the query (or C<undef> if no objects matched). The scalar context SQL query
is slightly optimized.

As usual, for foreign key attributes, you may pass an actual object or an ID.
If no arguments are passed to C<search>, every object in the class is
returned.

=item C<< Class->fetch($id) >>

Equivalent to C<< Class->search( id => $id ) >> in scalar context, but
slightly optimized internally. Returns the object, or C<undef> if no object
with the given ID exists in the database.

=back

=head2 Notes On Persistent Classes

Objects in these persistent classes are implemented as lightweight blessed
scalars in an inside-out mechanism. This has some benefits, mainly that
concurrency across identical objects is always preserved:

  my $bob1 = Employees->fetch(10);
  my $bob2 = Employees->fetch(10);
  
  ## now $bob1 and $bob2 may not be the same physical object, but...
  
  $bob1->name("Bob");
  $bob2->name("Robert");
  
  print $bob1->name, $bob2->name;
  
  ## will print "Robert" twice

You can still override/augment object methods if you need to with C<SUPER::>

  ## Suppose the "last_seen" column in a "users" table was a
  ## YYYYMMDDHHMMSS timestamp column. We could override the last_seen
  ## method to return a Time::Piece object, and accept one when used
  ## as a mutator:
  
  package Users;
  my $date_fmt = "%Y%m%d%H%M%S";
  sub last_seen {
      my $self = shift;
      my $ret  = @_
        ? $self->SUPER::last_seen( $_[0]->strftime($date_fmt) );
        : $self->SUPER::last_seen;
  
      Time::Piece->strptime($ret, $date_fmt);
  }

But since these objects are implemented as blessed scalars, you have to use
some sort of inside-out mechanism to store extra (non-persistent) subclass
attributes with the objects:

  package Employees;
  my %foo;
  sub foo {
      my $self = shift;
      @_ ? $foo{ $self->id } = shift
         : $foo{ $self->id };
  }

=head2 Plural And Singular Nouns

Class::Tables makes strong use of L<Lingua::EN::Inflect|Lingua::EN::Inflect>
to convert between singular and plural, in an effort to make accessor names
more meaningful and allow a wide range of column-naming schemes. So when this
documentation talks about plural and singular nouns, it does not just mean
"adding an S at the end." You zoologists may have a C<mice> table with a
corresponding primary/foreign key named C<mouse_id>! Goose to geese, child to
children, etc. The only limitations are what
L<Lingua::EN::Inflect|Lingua::EN::Inflect> doesn't know about.

I recommend naming tables with a plural noun and foreign key columns with a
singular noun (optionally with the "_id" suffix). This combination makes the
accessor names much more meaningful, and is (to my knowledge) the most common
relational naming convention.

If L<Lingua::EN::Inflect|Lingua::EN::Inflect> is not available on your system,
Class::Tables will still work fine, but without the distinction between
plurals and singulars. Thus a primary key column can be named only C<id> or
the name of the table with an C<_id> suffix. Similar statments are true for
foreign key columns, etc.

You can manually disable the pluralization by setting
C<$Class::Tables::PLURALIZE> to a false value before you generate the classes.

=head1 CAVEATS

=over

=item *

So far, the table parsing code only works with MySQL. Same with getting the
ID of the last inserted object. Testers/patchers for other RDBMSs welcome!

=item *

Pluralization code is only for English at the moment, sorry.

=item *

All modifications to objects are instantaneous -- no asynchronous updates
and/or rollbacks (yet?)

=back

=head1 AUTHOR

Class::Tables is written by Mike Rosulek E<lt>mike@mikero.comE<gt>. Feel 
free to contact me with comments, questions, patches, or whatever.

=head1 COPYRIGHT

Copyright (c) 2003 Mike Rosulek. All rights reserved. This module is free 
software; you can redistribute it and/or modify it under the same terms as Perl 
itself.

