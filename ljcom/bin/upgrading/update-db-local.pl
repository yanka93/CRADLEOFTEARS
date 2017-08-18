#
# database schema & data info for livejournal.com
#

mark_clustered(@LJ::USER_TABLES_LOCAL);

register_tablecreate("paycredit", <<EOC);
CREATE TABLE paycredit (
  userid int(10) unsigned NOT NULL default '0',
  days smallint(5) unsigned NOT NULL default '0',
  issued datetime NOT NULL default '0000-00-00 00:00:00',
  used enum('N','Y') NOT NULL default 'N',
  useddate datetime default NULL,
  KEY (userid),
  KEY (used)
) TYPE=MyISAM
EOC

# when cart:
#   forwhat = 'cart'
#   userid = id of remote user, or 0
#   amount = total amount
#   months = 0
#   method ::= "" (new cart) | "authnet-cc" | "authnet-echeck" | "paypal" | "check"
#   datesent = cart creation
#   daterecv = payment processed (cc/paypal), or entered (if check)
#   used = 'C' (still cart) then after pay 'N' (now awaiting paybatch), then 'Y' (done)
#   mailed = likewise. ^^
register_tablecreate("payments", <<EOC);
CREATE TABLE payments (
  payid int(10) unsigned NOT NULL auto_increment,
  userid int(10) unsigned NOT NULL default '0',
  datesent datetime NOT NULL default '0000-00-00 00:00:00',
  daterecv datetime NOT NULL default '0000-00-00 00:00:00',
  amount decimal(8,2) default NULL,
  months tinyint(3) unsigned default NULL,
  used enum('N','Y') NOT NULL default 'N',
  mailed enum('N','Y') NOT NULL default 'N',
  notes text,
  method varchar(20) NOT NULL default '',
  forwhat varchar(20) default NULL,
  PRIMARY KEY  (payid),
  KEY (userid),
  KEY (used),
  KEY (method),
  KEY (forwhat),
  KEY (mailed)
) TYPE=MyISAM PACK_KEYS=1
EOC

# keep track of ip address of buyer, first/last name,
# email address (if non-logged in user), etc.  not indexed
# like payment search
register_tablecreate("payvars", <<'EOC');
CREATE TABLE payvars (
  payid  INT UNSIGNED NOT NULL,
  pkey   VARCHAR(40),
  INDEX (payid, pkey(4)),
  pval   VARCHAR(255)
)
EOC

# Items one can buy:
#    paidacct     qty=<months>
#    perm
#    rename
#    morestats    qty=<months>
#    morepics?

register_tablecreate("payitems", <<'EOC');
CREATE TABLE payitems (
   piid     INT UNSIGNED NOT NULL AUTO_INCREMENT,
   PRIMARY KEY (piid),
   payid    INT UNSIGNED NOT NULL,
   INDEX (payid),
   item       VARCHAR(25),
   qty        SMALLINT UNSIGNED,
   rcptid     INT UNSIGNED NOT NULL, # cart owner's ID, gift rcpt's ID, or 0 for invite/"pay" code emailed
   amt        DECIMAL(8,2),
   status     ENUM('cart','pend','done','refund','bogus'),
   INDEX (status),
   rcptemail  VARCHAR(80),     # email address to mail paycode to, if non-user
   anon       ENUM('0','1'),   # is gift anonymous?
   giveafter  INT UNSIGNED     # unixtime to give gift after
)
EOC

# payid <=> state mappings
register_tablecreate("paystates", <<'EOC');
CREATE TABLE paystates (
   payid int unsigned NOT NULL,
   PRIMARY KEY (payid),
   state VARCHAR(25) NOT NULL DEFAULT '??',
   INDEX (state)
)
EOC

# clothing  babydoll-royalblue-xl  234  220
register_tablecreate("inventory", <<'EOC');
CREATE TABLE inventory (
   item     VARCHAR(25) NOT NULL,
   subitem  VARCHAR(35) NOT NULL,
   PRIMARY KEY (item, subitem),
   qty      SMALLINT UNSIGNED NOT NULL,
   avail    SMALLINT UNSIGNED NOT NULL,
   price    DECIMAL(8,2)
)
EOC

register_tablecreate("shipping", <<'EOC');
CREATE TABLE shipping (
   payid   INT UNSIGNED NOT NULL,
   PRIMARY KEY (payid),
   status   ENUM('needs', 'shipped') NOT NULL,
   INDEX (status),
   dateready    DATETIME,
   dateshipped  DATETIME
)
EOC

register_tablecreate("coupon", <<'EOC');
CREATE TABLE coupon (
   cpid    MEDIUMINT UNSIGNED NOT NULL PRIMARY KEY AUTO_INCREMENT,
   auth    CHAR(10),
   type    VARCHAR(20),   # freeclothingitem, dollaroff (-$arg), percentoff (-%arg)
   arg     VARCHAR(30),
   rcptid  INT UNSIGNED NOT NULL,
   INDEX   (rcptid),
   locked  ENUM('0', '1') DEFAULT '0' NOT NULL,
   payid   INT UNSIGNED NOT NULL,
   INDEX   (payid)
)
EOC

register_tablecreate("paymentsearch", <<'EOC');
CREATE TABLE paymentsearch
(
 payid INT UNSIGNED NOT NULL,
 INDEX (payid),
 ikey  varchar(12) NOT NULL,
 ival  varchar(50) NOT NULL,
 INDEX (ikey, ival)
)
EOC

register_tablecreate("authnetlog", <<'EOC');
CREATE TABLE authnetlog
(
 payid     INT UNSIGNED NOT NULL,
 INDEX (payid),
 datesent  DATETIME,
 ip        VARCHAR(15),
 amt       DECIMAL(8,2),
 result    ENUM('pass','fail'),
 response  TEXT
)
EOC

register_tablecreate("transferinfo", <<EOC);
CREATE TABLE transferinfo (
  userid int(10) unsigned NOT NULL default '0',
  state enum('on','off','bad') default NULL,
  method enum('ftp','scp','post','webdav') NOT NULL default 'ftp',
  host varchar(100) default NULL,
  username varchar(50) default NULL,
  password varchar(50) default NULL,
  directory varchar(100) default NULL,
  filename varchar(50) default NULL,
  lastxfer datetime NOT NULL default '0000-00-00 00:00:00',
  styleid int(11) NOT NULL default '0',
  PRIMARY KEY  (userid)
) TYPE=MyISAM
EOC

register_tablecreate("contributed", <<'EOC');
CREATE TABLE contributed
(
 coid    INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
 userid  INT UNSIGNED NOT NULL,
 INDEX (userid),
 cat    ENUM('code','doc','creative','biz','other') NOT NULL DEFAULT 'other',
 INDEX (cat),
 des    VARCHAR(255) NOT NULL,
 url    VARCHAR(100),
 dateadd  DATETIME NOT NULL,
 acks   SMALLINT NOT NULL DEFAULT '0',
 INDEX (acks)
 )
EOC

register_tablecreate("contributedack", <<'EOC');
CREATE TABLE contributedack
(
 coid   INT UNSIGNED NOT NULL,
 ackuserid  INT UNSIGNED NOT NULL,
 UNIQUE (coid, ackuserid),
 INDEX (ackuserid)
)
EOC

register_tabledrop("tmp_contributed");

# old payment system:  payment row is the item
register_tablecreate("acctpay", <<'EOC');
CREATE TABLE acctpay
(
  payid   INT UNSIGNED NOT NULL,
  acid    INT UNSIGNED NOT NULL,
  PRIMARY KEY (payid),
  UNIQUE (acid)
)
EOC

# new payment system, where payments contain multiple items
register_tablecreate("acctpayitem", <<'EOC');
CREATE TABLE acctpayitem
(
  piid   INT UNSIGNED NOT NULL,
  acid   INT UNSIGNED NOT NULL,
  PRIMARY KEY (piid),
  UNIQUE (acid)
)
EOC

register_tablecreate("acctinvite", <<'EOC');
CREATE TABLE acctinvite
(
  userid INT UNSIGNED NOT NULL,
  reason VARCHAR(20) NOT NULL,
  UNIQUE (userid, reason),
  dateadd DATETIME NOT NULL,
  acid   INT UNSIGNED NOT NULL,
  INDEX (acid)
)
EOC

register_tablecreate("paiduser", <<'EOC');
CREATE TABLE paiduser
(
 userid  INT UNSIGNED NOT NULL PRIMARY KEY,
 paiduntil     datetime NOT NULL,
 paidreminder  datetime,
 INDEX (paiduntil)
)
EOC

register_tablecreate("paytrans", <<'EOC');
CREATE TABLE paytrans (
  userid INT UNSIGNED NOT NULL,
  time INT UNSIGNED NOT NULL,
  what ENUM('paidaccount'),
  action ENUM('new', 'renew', 'expire', 'return'),
  KEY (userid),
  KEY (time)
)
EOC

register_tablecreate("email_aliases", <<'EOC');
CREATE TABLE email_aliases
(
 alias VARCHAR(100) NOT NULL,
 PRIMARY KEY (alias),
 rcpt  VARCHAR(200) NOT NULL
)
EOC

register_tablecreate("abuse_mail", <<'EOC');
CREATE TABLE abuse_mail
(
 mailid int(10) UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
 userid int(10) UNSIGNED NOT NULL,
 INDEX (userid),
 spid int(10) UNSIGNED,
 INDEX (spid),
 status ENUM('S','F') DEFAULT 'F' NOT NULL,
 timesent DATETIME NOT NULL,
 mailto VARCHAR(100) NOT NULL,
 subject VARCHAR(100) NOT NULL,
 message TEXT
)
EOC

register_tablecreate("renames", <<'EOC');
CREATE TABLE renames
(
  renid  MEDIUMINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  token  CHAR(10) NOT NULL,
  payid  INT UNSIGNED NOT NULL,
  INDEX (payid),
  userid    INT UNSIGNED,
  INDEX (userid),
  fromuser  CHAR(15),
  touser    CHAR(15),
  INDEX (fromuser),
  INDEX (touser),
  rendate  DATETIME
)
EOC

register_tablecreate("meetup_ints", <<'EOC');
CREATE TABLE meetup_ints (
   intid   INT UNSIGNED NOT NULL,
   PRIMARY KEY (intid),
   urlkey  VARCHAR(30) NOT NULL,
   name    VARCHAR(50)
)
EOC

# Bazaar tables
register_tablecreate("bzrs", <<'EOC');
CREATE TABLE bzrs (
   bzid       SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
     PRIMARY KEY (bzid),
   name       VARCHAR(80),
   datestart  DATETIME,
   open       ENUM('0','1')
)
EOC

register_tablecreate("bzrpot", <<'EOC');
CREATE TABLE bzrpot (
   bzid       SMALLINT UNSIGNED NOT NULL,
   dateadd    DATETIME,
   amt        DECIMAL(8,2),
   reason     VARCHAR(255)
)
EOC

register_tablecreate("bzrvote", <<'EOC');
CREATE TABLE bzrvote (
   bzid       SMALLINT UNSIGNED NOT NULL,
   userid     INT UNSIGNED NOT NULL,
   coid       INT UNSIGNED NOT NULL,
   weight     SMALLINT UNSIGNED NOT NULL,
   PRIMARY KEY (bzid, userid, coid),
   INDEX (userid),
   INDEX (coid)
)
EOC

register_tablecreate("bzrvoter", <<'EOC');
CREATE TABLE bzrvoter (
   bzid       SMALLINT UNSIGNED NOT NULL,
   userid     INT UNSIGNED NOT NULL,
   weight     FLOAT(7,5) UNSIGNED,
   PRIMARY KEY (bzid, userid)
)
EOC

# amt: amount earned in given bazaar
# owed:  how much remains to be be paid/expired
# expired:  money lost to expiration
# note: "bzid=<n>" for owed, free form (check number, etc) for paid
register_tablecreate("bzrbalance", <<'EOC');
CREATE TABLE bzrbalance (
   userid        INT UNSIGNED NOT NULL,
   bzid          SMALLINT UNSIGNED NOT NULL,
   PRIMARY KEY (userid, bzid),

   date          DATETIME,

   amt           DECIMAL(5,2),
   owed          DECIMAL(5,2),
   expired       DECIMAL(5,2)
)
EOC

# note = "coupon:(\S+)" when method = "coupon"
# note = free form when method='money'
register_tablecreate("bzrpayout", <<'EOC');
CREATE TABLE bzrpayout (
   userid        INT UNSIGNED NOT NULL,
   date          DATETIME,
   amt           DECIMAL(5,2),
   method        ENUM('money','coupon'),
   note          VARCHAR(80),
   INDEX (userid)
)
EOC

register_tablecreate("tshirtpoll", <<'EOC');
CREATE TABLE tshirtpoll (
  userid  INT UNSIGNED NOT NULL,
  INDEX (userid),
  style   VARCHAR(20),
  color   VARCHAR(20),
  size    VARCHAR(5),
  qty     SMALLINT UNSIGNED NOT NULL
)
EOC

# paid item expiration times
register_tablecreate("paidexp", <<'EOC');
CREATE TABLE paidexp (
  userid INT unsigned NOT NULL default '0',
  item VARCHAR(25) NOT NULL default '',
  expdate DATETIME NOT NULL default '0000-00-00 00:00:00',
  daysleft SMALLINT NOT NULL DEFAULT '0',
  PRIMARY KEY (userid, item)
)
EOC

register_tablecreate("phonepostlogin", <<'EOC');
CREATE TABLE phonepostlogin (
  phone       VARCHAR(20)  NOT NULL,
  pin         VARCHAR(10)  NOT NULL,
  userid      INT UNSIGNED NOT NULL,
  journalid   INT UNSIGNED NOT NULL,
  PRIMARY KEY (phone, pin),
  UNIQUE KEY (userid, journalid)
)
EOC

# blob from blobid must be of type 'phonepost'.
# security is inferred from jitemid; if there is no log2 row, it's private.
register_tablecreate("phonepostentry", <<'EOC');
CREATE TABLE phonepostentry (
  userid      INT       UNSIGNED NOT NULL,
  blobid      MEDIUMINT UNSIGNED NOT NULL,
  lengthsecs  MEDIUMINT UNSIGNED NOT NULL,
  anum        TINYINT   UNSIGNED NOT NULL,
  jitemid     MEDIUMINT UNSIGNED NOT NULL,
  posttime    INT       UNSIGNED NOT NULL,
  PRIMARY KEY (userid, blobid),
  INDEX (posttime)
)
EOC

# blob from blobid must be of type 'phonepost'.
# security is inferred from jitemid; if there is no log2 row, it's private.
register_tablecreate("phoneposttrans", <<'EOC');
CREATE TABLE phoneposttrans (
  journalid   INT       UNSIGNED NOT NULL,
  blobid      MEDIUMINT UNSIGNED NOT NULL,
  revid       TINYINT   UNSIGNED NOT NULL,
  posterid    INT       UNSIGNED NOT NULL,
  posttime    INT       UNSIGNED NOT NULL,
  subject     VARCHAR(255) BINARY,
  body        BLOB,
  PRIMARY KEY (journalid, blobid, revid)
)
EOC

# TEMP: Survey of unknown8bit posts, populated by
#  a postpost hook in ljcom.pl .
register_tablecreate("survey_v0_8bit", <<'EOC');
CREATE TABLE survey_v0_8bit (
  userid INT UNSIGNED NOT NULL,
  timepost  INT UNSIGNED NOT NULL,
  PRIMARY KEY (userid),
  INDEX (timepost)
)
EOC

# keep track of avs fails per user
register_tablecreate("ccfail", <<'EOC');
CREATE TABLE ccfail (
  email VARCHAR(50) NOT NULL,
  time INT UNSIGNED NOT NULL,
  userid INT UNSIGNED,
  why VARCHAR(100),
  PRIMARY KEY (email, time),
  KEY (userid)
)
EOC

# FotoBilder feedback surveys
register_tablecreate("fotobilder_feedback", <<'EOC');
CREATE TABLE fotobilder_feedback (
  url         VARCHAR(100) NOT NULL,
  userid      INT UNSIGNED,
  state       CHAR(1) NOT NULL,
  body        BLOB,

  INDEX       (url),
  INDEX       (state),
  INDEX       (userid)
)
EOC

# Payment fraud
register_tablecreate("fraudsuspects", <<'EOC');
CREATE TABLE fraudsuspects (
        payid INT UNSIGNED NOT NULL,
        PRIMARY KEY (payid),
        dateadd INT UNSIGNED NOT NULL,
        reason TEXT
)
EOC

# External phonepost destinations
# For an explaination of this table, see
# ljcomint/doc/notes/external_phoneposting.txt
register_tablecreate("phonepostdests", <<'EOC');
CREATE TABLE phonepostdests (
    userid INT UNSIGNED NOT NULL DEFAULT 0,
    destid INT UNSIGNED NOT NULL DEFAULT 0,
    namespace INT UNSIGNED NOT NULL,
    audio_type VARCHAR(20) NULL,
    audio_post_url VARCHAR(255) NULL,
    audio_user VARCHAR(255) NULL,
    audio_password VARCHAR(255) NULL,
    blog_type VARCHAR(20) NULL,
    blog_name VARCHAR(255) NULL,
    blog_post_url VARCHAR(255) NULL,
    blog_user VARCHAR(255) NULL,
    blog_password VARCHAR(255) NULL,
    PRIMARY KEY (userid, destid, namespace)
)
EOC

# Style contest
register_tablecreate("temp_stylecontest2poll", <<'EOC');
CREATE TABLE temp_stylecontest2poll (
    userid    INT UNSIGNED NOT NULL,
    votetime  INT UNSIGNED NOT NULL,
    vote      VARCHAR(50),
    UNIQUE (userid, vote),
    INDEX (vote)
);
EOC

register_alter(sub {

    unless (column_type("payments", "giveafter")) {
        do_alter("payments",
                 "ALTER TABLE payments ADD giveafter INT UNSIGNED");
    }

    unless (column_type("payments", "anum")) {
        do_alter("payments",
                 "ALTER TABLE payments ".
                 "ADD anum SMALLINT UNSIGNED AFTER payid, ".
                 "MODIFY used ENUM('N','Y','C') NOT NULL DEFAULT 'N', ".
                 "MODIFY mailed ENUM('N','Y','C') NOT NULL DEFAULT 'N'");
    }

    unless (column_type("payments", "mailed") =~ /'X'/i) {
        do_alter("payments",
                 "ALTER TABLE payments ".
                 "MODIFY mailed ENUM('N','Y','C','X') NOT NULL DEFAULT 'N'");
    }

    unless (column_type("payitems", "token")) {
        do_alter("payitems",
                 "ALTER TABLE payitems ADD token VARCHAR(25), ADD tokenid INT UNSIGNED");
    }

    unless (index_name("payitems", "INDEX:rcptemail")) {
        do_alter("payitems",
                 "ALTER TABLE payitems ADD INDEX (rcptemail), ".
                 "ADD INDEX (rcptid)");
    }

    unless (column_type("payitems", "subitem")) {
        do_alter("payitems",
                 "ALTER TABLE payitems ADD subitem VARCHAR(35) AFTER item, ".
                 "ADD qty_res SMALLINT UNSIGNED");
    }

    unless (column_type("authnetlog", "cmd")) {
        do_alter("authnetlog",
                 "ALTER TABLE authnetlog ".
                 "ADD cmd ENUM('authcap','credit','void') NOT NULL DEFAULT 'authcap' AFTER payid, ".
                 "ADD cmdnotes VARCHAR(255)");
    }

    unless (column_type("authnetlog", "cmd") =~ /authonly/) {
        do_alter("authnetlog",
                 "ALTER TABLE authnetlog ".
                 "MODIFY cmd ENUM('authcap','credit','void','authonly','priorcap','caponly') NOT NULL DEFAULT 'authcap'");

    }

    unless (index_name("contributed", "INDEX:dateadd")) {
        do_alter("contributed",
                 "ALTER TABLE contributed ADD INDEX (dateadd)");
    }

    unless (index_name("abuse_mail", "INDEX:mailto")) {
        do_alter("abuse_mail",
                 "ALTER TABLE abuse_mail ADD INDEX (mailto)");
    }

    unless (column_type("paytrans", "action") =~ 'ext') {
        do_alter("paytrans",
                 "ALTER TABLE paytrans MODIFY action " .
                 "ENUM('new', 'renew', 'expire', 'return', 'ext')");
    }

    unless (column_type("coupon", "ppayid")) {
        do_alter("coupon",
                 "ALTER TABLE coupon ADD ppayid INT UNSIGNED NOT NULL DEFAULT 0 AFTER payid, " .
                 "ADD INDEX(ppayid)");

        # populate ppayids of old coupons
        if (column_type("coupon", "ppayid")) {
            print "Populating coupon.ppdayid from payitems...\n";

            # query will get a lot of rows, but probably not too many
            my $dbh = LJ::get_db_writer();
            my $sth = $dbh->prepare("SELECT payid, tokenid FROM payitems " .
                                    "WHERE item='coupon' AND amt>0 AND status<>'cart'");
                                    # amt>0 means where it was bought, not used
            $sth->execute();
            my $ct = 0;
            while (my ($payid, $tokenid) = $sth->fetchrow_array) {
                $dbh->do("UPDATE coupon SET ppayid=? WHERE cpid=?", undef, $payid, $tokenid);
                print "$ct rows...\n" if ++$ct % 500 == 0;
            }
            print "$ct total rows updated.\n\n";
        }
    }

    # change phonepost entry
    unless (column_type("phonepostentry", "filetype")) {
        do_alter("phonepostentry",
                "ALTER TABLE phonepostentry DROP INDEX posttime, ".
                "ADD filetype TINYINT UNSIGNED NOT NULL DEFAULT '0'");
    }

    # email reminder date on bonus features
    unless (column_type("paidexp", "lastmailed")) {
        do_alter("paidexp",
                 "ALTER TABLE paidexp ADD lastmailed datetime NOT NULL DEFAULT 0 AFTER daysleft");
    }

    # size and state on bonus features
    unless (column_type("paidexp", "size")) {
        do_alter("paidexp",
                 "ALTER TABLE paidexp ADD size INT unsigned NOT NULL DEFAULT 0 AFTER item");
    }

    # add dates to fotobilder feedback
    unless (column_type("fotobilder_feedback", "datetime")) {
        do_alter("fotobilder_feedback",
                 "ALTER TABLE fotobilder_feedback ADD datetime DATETIME NOT NULL AFTER state");
    }

    unless (column_type("phonepostentry", "location")) {
        do_alter("phonepostentry",
                 "ALTER TABLE phonepostentry ADD COLUMN location ENUM('blob','mogile','none') DEFAULT NULL");
    }

    unless (column_type("phonepostentry", "location") =~ /none/) {
        do_alter("phonepostentry",
                 "ALTER TABLE phonepostentry MODIFY COLUMN location ENUM('blob','mogile','none') DEFAULT NULL");
    }

    unless (column_type("abuse_mail", "type")) {
        do_alter("abuse_mail",
                 "ALTER TABLE abuse_mail ADD COLUMN type VARCHAR(20) NOT NULL DEFAULT ''");

        do_alter("abuse_mail",
                 "UPDATE abuse_mail SET type='abuse'");
    }
});

1;  # true
