#!/usr/bin/perl

use Test::More 'no_plan';
use DBI;
use Class::Tables;

my $loaded = 1;
my $finished_all_tests = 0;
END {
    ok( $loaded, "use succeeded" ); 
    ok( $finished_all_tests, "finished all tests!" );
}

############################
## get DB connection info ##
############################

unless ( $ENV{DBI_DSN} and exists $ENV{DBI_USER} and exists $ENV{DBI_PASS} ) {
    warn "A working DBI connection is required for the remaining tests.\n";
    warn "Please enter or accept the following parameters (or pre-set in your ENV):\n";
}

sub get_line {
    print "  $_[0] (or accept default '$_[1]'): ";
    chomp( my $input = <STDIN> );
    return length($input) ? $input : $_[1]
}

my $dsn = $ENV{DBI_DSN} || get_line( DBI_DSN => 'dbi:mysql:test' );
my $user = exists $ENV{DBI_USER} ? $ENV{DBI_USER} : get_line( DBI_USER => '' );
my $pass = exists $ENV{DBI_PASS} ? $ENV{DBI_PASS} : get_line( DBI_PASS => '' );

######################
## import test data ##
######################

my $dbh = DBI->connect($dsn, $user, $pass);
ok( $dbh, "connect to DB" );
die "Unable to connect to DB" unless $dbh;

my @sql_import = split /\s*;\s*/, q[
    drop table if exists department;
    create table department (
        id          int not null primary key auto_increment,
        name        varchar(50) not null
    );
    drop table if exists employee;
    create table employee (
        id          int not null primary key auto_increment,
        name        varchar(50) not null,
        department  int not null
    );
    drop table if exists purchase;
    create table purchase (
        id          int not null primary key auto_increment,
        product     int not null,
        employee    int not null,
        quantity    int not null,
        date        date
    );
    drop table if exists product;
    create table product (
        id          int not null primary key auto_increment,
        name        varchar(50) not null,
        weight      int not null,
        price       decimal
    );
    insert into department values (1,'Hobbiton Division');
    insert into department values (2,'Bree Division');
    insert into department values (3,'Buckland Division');
    insert into department values (4,'Michel Delving Division');
    insert into employee   values (1,'Frodo Baggins',3);
    insert into employee   values (2,'Bilbo Baggins',3);
    insert into employee   values (3,'Samwise Gamgee',3);
    insert into employee   values (4,'Perigrin Took',2);
    insert into employee   values (5,'Fredegar Bolger',2);
    insert into employee   values (6,'Meriadoc Brandybuck',2);
    insert into employee   values (7,'Lotho Sackville-Baggins',4);
    insert into employee   values (8,'Ted Sandyman',4);
    insert into employee   values (9,'Will Whitfoot',4);
    insert into employee   values (10,'Bandobras Took',1);
    insert into employee   values (11,'Folco Boffin',1);
    insert into product    values (1,'Southfarthing Pipeweed',10,200);
    insert into product    values (2,'Prancing Pony Ale',150,300);
    insert into product    values (3,'Farmer Cotton Mushrooms',200,150);
    insert into product    values (4,'Green Dragon Ale',150,350);
    insert into purchase   values (1,2,6,6,'2002-12-10');
    insert into purchase   values (2,4,3,1,'2002-12-10');
    insert into purchase   values (3,1,2,20,'2002-12-09');
    insert into purchase   values (4,3,4,8,'2002-12-11');
    insert into purchase   values (5,1,1,1,'2002-12-13');
    insert into purchase   values (6,1,1,2,'2002-12-15');
    insert into purchase   values (7,3,3,3,'2002-12-12');
    insert into purchase   values (8,3,3,15,'2002-12-08');
    insert into purchase   values (9,2,6,11,'2002-12-08');
    insert into purchase   values (10,3,2,8,'2002-12-14')
];

$dbh->do($_) for (@sql_import);

################
## real tests ##
################

## initialization

Class::Tables->dbh($dbh);

ok( UNIVERSAL::isa($_, 'Class::Tables'),           "$_ class created" )
    for qw/Department Employee Product Purchase/;
ok( ! UNIVERSAL::isa('asdfasdf', 'Class::Tables'), "sanity" );

## fetch class method

ok( ref Employee->fetch(1),            "fetch works" );
ok( ! defined Employee->fetch(234332), "fetch returns undef for no results" );

## search class method

my @hobbits = Employee->search;
ok( scalar(@hobbits),                "search returned" );
ok( ! grep({ not ref $_ } @hobbits), "search returned objects" );

my @sorted_ids = sort { $hobbits[$a]->name cmp $hobbits[$b]->name }
                 0 .. $#hobbits;
ok( join(":" => @sorted_ids) eq join(":" => 0 .. $#hobbits),
    "search results sorted" );

ok( ! defined Employee->search( name => "asdfasdfasdf" ),
    "search returns undef for no results");
ok( scalar( () = Employee->search( name => "asdfasdfasdf" ) ) == 0,
    "search returns empty list for no results");

my $h = Employee->search( name => "Frodo Baggins" );
ok( $h,                          "search with terms" );
ok( $h->name eq "Frodo Baggins", "search gives correct result" );

ok( scalar( () = Employee->search( department => Department->fetch(3) )) > 0,
    "search using an object as constraint" );

## basic object accessors

ok( "$h" eq $h->name,                   "stringify to name column" );
ok( ref $h->department,                 "foreign key => object" );
ok( ! ref $h->name,                     "normal accessor => non-object" );
ok( scalar( () = $h->purchase ) > 1,    "indirect foriegn key => list" );

eval { $h->age };
ok( $@, "die on bad accessor" );

## basic mutators

my $dept = Department->fetch(1);
$h->department($dept);
$h->name("Frodo Nine-Fingers");

ok( $h->department->id == $dept->id,  "mutate foreign key" );
ok( $h->name eq "Frodo Nine-Fingers", "mutate column" );

$h->department( $dept->id );
ok( ref $h->department,               "inflate foreign IDs after mutation");

ok( Employee->search( name => "Frodo Nine-Fingers", department => $dept ),
    "changes visible in database" );

## concurrency

my $p1 = Purchase->fetch(1);
my $p2 = Purchase->fetch(1);

$p1->quantity( 1 );
$p2->quantity( 99999 );
ok( $p2->quantity == $p1->quantity, "updates visible to concurrent objects" );

## creating objects

my $new = Employee->new( name => "Grima Wormtongue", department => $dept );
ok( $new,                              "create new, with object args" );
ok( $new->name eq "Grima Wormtongue",  "created with correct info" );
ok( $new->department->id == $dept->id, "created with correct foreign key" );


## dump method

my $dump = $new->dump;
ok( ref $dump eq 'HASH',               "dump returns hashref" );
ok( ref $dump->{department} eq 'HASH', "foreign keys dumped to hashref" );

$dump = $dept->dump;
ok( ref $dump->{employee} eq 'ARRAY', "indirect foreign keys to arrayref" );

## deleting objects

my $id = $new->id;
$new->delete;
ok( ! defined Employee->fetch($id), "deleted from database" );

$_->delete for Employee->search;

ok( scalar( () = Employee->search ) == 0, "table cleared out" );

## done

$finished_all_tests = 1;
