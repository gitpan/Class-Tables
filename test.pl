#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 36;
use DBI;
use Class::Tables;

# $Class::Tables::SQL_DEBUG++;

############################
## get DB connection info ##
############################

unless ( $ENV{DBI_DSN} and $ENV{DBI_USER} and $ENV{DBI_PASS} ) {
    warn "A working DBI connection is required for the remaining tests.\n";
    warn "Please enter the following parameters (or pre-set in your ENV):\n";
}

sub get_line {
    print "  $_[0] (or accept default '$_[1]'): ";
    chomp( my $input = <STDIN> );
    return length($input) ? $input : $_[1]
}

my $dsn  = $ENV{DBI_DSN}  || get_line(DBI_DSN => 'dbi:mysql:test');
my $user = $ENV{DBI_USER} || get_line(DBI_USER => '');
my $pass = $ENV{DBI_PASS} || get_line(DBI_PASS => '');

######################
## import test data ##
######################

my $dbh = DBI->connect($dsn, $user, $pass);
die "Unable to connect to DB for testing!" unless $dbh;

$dbh->do($_) for (split /\s*;\s*/, <<'END_OF_SQL');

    drop table if exists department;
    create table department (
        id            int not null primary key auto_increment,
        name          varchar(50) not null
    );
    drop table if exists employee;
    create table employee (
        employee_id   int not null primary key auto_increment,
        name          varchar(50) not null,
        department_id int not null,
        photo         longblob
    );
    drop table if exists purchase;
    create table purchase (
        id            int not null primary key auto_increment,
        product_id    int not null,
        employee_id   int not null,
        quantity      int not null,
        date          date
    );
    drop table if exists product;
    create table product (
        id            int not null primary key auto_increment,
        name          varchar(50) not null,
        weight        int not null,
        price         decimal
    );
    insert into department values (1,'Hobbiton Division');
    insert into department values (2,'Bree Division');
    insert into department values (3,'Buckland Division');
    insert into department values (4,'Michel Delving Division');
    insert into employee   values (1,'Frodo Baggins',3,'');
    insert into employee   values (2,'Bilbo Baggins',3,'');
    insert into employee   values (3,'Samwise Gamgee',3,'');
    insert into employee   values (4,'Perigrin Took',2,'');
    insert into employee   values (5,'Fredegar Bolger',2,'');
    insert into employee   values (6,'Meriadoc Brandybuck',2,'');
    insert into employee   values (7,'Lotho Sackville-Baggins',4,'');
    insert into employee   values (8,'Ted Sandyman',4,'');
    insert into employee   values (9,'Will Whitfoot',4,'');
    insert into employee   values (10,'Bandobras Took',1,'');
    insert into employee   values (11,'Folco Boffin',1,'');
    insert into product    values (1,'Southfarthing Pipeweed',10,200);
    insert into product    values (2,'Prancing Pony Ale',150,300);
    insert into product    values (3,'Farmer Cotton Mushrooms',200,150);
    insert into product    values (4,'Green Dragon Ale',150,350);
    insert into purchase   values (1,2,6,6,'2002-12-10');
    insert into purchase   values (2,4,3,1,'2002-12-10');
    insert into purchase   values (3,1,2,20,'2002-12-09');
    insert into purchase   values (4,3,4,8,'2002-12-11');
    insert into purchase   values (5,1,1,1,'2002-12-13');
    insert into purchase   values (6,3,1,2,'2002-12-15');
    insert into purchase   values (7,3,3,3,'2002-12-12');
    insert into purchase   values (8,3,3,15,'2002-12-08');
    insert into purchase   values (9,2,6,11,'2002-12-08');
    insert into purchase   values (10,3,2,8,'2002-12-14')

END_OF_SQL

################
## real tests ##
################

## initialization

my $timer = times;

Class::Tables->dbh($dbh);

use Data::Dumper;
#print Dumper \%Class::Tables::CLASS;

ok( UNIVERSAL::isa($_, 'Class::Tables'),  "$_ class created" )
    for qw/Department Employee Product Purchase/;

## fetch class method

ok( ref Employee->fetch(1),               "fetch works" );
ok( ! defined Employee->fetch(234332),    "returns undef for no results" );

## search class method

my @hobbits = Employee->search;
ok( scalar @hobbits,                      "search returned" );
ok( ! grep({ not ref $_ } @hobbits),      "search returned objects" );


my @sorted_ids = sort { $hobbits[$a]->name cmp $hobbits[$b]->name }
                 0 .. $#hobbits;

ok( join(":" => @sorted_ids) eq
    join(":" => 0 .. $#hobbits),          "search results sorted" );

ok( ! defined Employee->search(name => "asdfasdfasdf"),
                                          "returns undef for no results");
    
ok( scalar(() = Employee->search(name => "asdfasdfasdf")) == 0,
                                          "returns () for no results");

my $h = Employee->search( name => "Frodo Baggins" );

ok( $h,                                   "search with terms" );
ok( $h->name eq "Frodo Baggins",          "search gives correct result" );

ok( scalar(() = Employee->search(department => Department->fetch(3))) > 0,
                                          "search with object as constraint" );

## basic object accessors

ok( "$h" eq $h->name,                     "stringify to name column" );
ok( ref $h->department,                   "foreign key => object" );
ok( ! ref $h->name,                       "normal accessor => non-object" );
ok( scalar(() = $h->purchase) > 1,        "indirect foriegn key => list" );
ok( do { eval { $h->age }; $@ },          "die on bad accessor" );

my $count = $Class::Tables::SQL_QUERIES;
$h->photo;
ok( $count < $Class::Tables::SQL_QUERIES, "blobs lazy-loaded" );

my @p1 = $h->purchase;
my @p2 = $h->purchase( product => 3 );
ok( @p1 > @p2,                            "constraints for indirect keys" );

## basic mutators

my $dept = Department->fetch(1);
$h->department($dept);
$h->name("Frodo Nine-Fingers");

ok( $h->department->id == $dept->id,      "mutate foreign key with obj" );
ok( $h->name eq "Frodo Nine-Fingers",     "mutate column" );

$h->department( $dept->id );
ok( ref $h->department,                   "mutate foreign key with ID" );

ok( Employee->search(name => "Frodo Nine-Fingers", department => $dept),
                                          "changes visible in database" );

## this depends on MySQL version, sadly..
# $h->department("asdfasdf");
# ok( ref $h->department,                   "gracefully handle bad changes" );
# $h->department( $dept );

## concurrency

my $p1 = Purchase->fetch(1);
my $p2 = Purchase->fetch(1);
$p1->quantity(1);
$p2->quantity(99999);

ok( $p2->quantity == $p1->quantity,       "updates concurrently visible" );

## creating objects

my $new = Employee->new(name => "Grima Wormtongue", department => $dept);

ok( $new,                                 "created new, with object args" );
ok( $new->name eq "Grima Wormtongue",     "created with correct info" );
ok( $new->department->id == $dept->id,    "created with correct foreign key" );


## dump method

my $dump = $h->dump;

ok( ref $dump eq 'HASH',                  "dump returns hashref" );
ok( $dump->{'department.name'},           "foreign keys are alright" );
ok( $dump->{purchase}[0]{'product.name'}, "lots of nesting in the dump" );

ok( ref $dept->dump->{employee} eq 'ARRAY',
                                          "indirect foreign keys to arrayref" );

# print Dumper $dept->dump;

## deleting objects

my $id = $new->id;
$new->delete;

ok( ! defined Employee->fetch($id),       "deleted from database" );

$_->delete for Employee->search;

ok( ! scalar(() = Employee->search),      "table cleared out" );

$timer = times - $timer;
ok( 1, "summary: $Class::Tables::SQL_QUERIES queries, $timer secs" );

## done!
