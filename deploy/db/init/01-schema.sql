-- deploy/db/init/01-schema.sql -- from server/docs/install.md; database is created
-- by the MYSQL_DATABASE env var, so only the tables are defined here.
create table users (
	screenname varchar (255) not null,
	emailAddress varchar (255),
	emailSecret varchar (64),
	prefs json,
	ctHits int not null default 0,
	ctHitsToday int not null default 0,
	whenLastHit datetime,
	whenCreated datetime default current_timestamp,
	whenUpdated datetime default current_timestamp on update current_timestamp,
	primary key (screenname),
	index emailAddress (emailAddress)
	) character set utf8mb4 collate utf8mb4_unicode_ci;

create table items (
	id int unsigned not null auto_increment,
	feedUrl varchar (512),
	author varchar (255),
	inReplyTo int unsigned,
	title text,
	link text,
	description longtext,
	pubDate datetime,
	enclosureUrl text,
	enclosureType text,
	enclosureLength int,
	whenCreated datetime default current_timestamp,
	whenUpdated datetime default current_timestamp on update current_timestamp,
	markdowntext longtext,
	outlineJsontext text,
	flDeleted tinyint (1) not null default 0,
	primary key (id),
	index feedUrl (feedUrl),
	index author (author)
	) character set utf8mb4 collate utf8mb4_unicode_ci;

create table likes (
	screenname varchar (255),
	itemId int unsigned,
	whenCreated datetime default current_timestamp,
	primary key (screenname, itemId),
	index itemId (itemId)
	) character set utf8mb4 collate utf8mb4_unicode_ci;
