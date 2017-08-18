#!/usr/bin/perl -w
use strict;
use XMLRPC::Lite;
use Digest::MD5 qw(md5_hex);
use DBI;
use Time::Local;
use lib "$ENV{'LJHOME'}/cgi-bin";
use LJR::Viewuserstandalone;

do $ENV{'LJHOME'} . "/cgi-bin/ljconfig.pl";
#
#Настройки
#

#Свойства соединения с базой
my $qhost = $LJ::DBINFO{'master'}->{'host'};
my $quser = $LJ::DBINFO{'master'}->{'user'};
my $qpass = $LJ::DBINFO{'master'}->{'pass'};
my $qsock = $LJ::DBINFO{'master'}->{'sock'};
my $qport = $LJ::DBINFO{'master'}->{'port'};
#my $qdb = $LJ::DBINFO{'master'}->{'dbname'};
my $qdb = "prod_ljgate";

#Сайт, с которого копируем
my $source_site = "127.0.0.2";

#Сайт, на которой копируем
my $dest_site = "www.livejournal.com";

#Частота синхронизации в формате ЧЧ:ММ:СС
#(то есть синхронизация каждые 15 минут будет выглядеть как
#00:15:00
my $sync_freq = "00:10:00";

#Разница во времени между машиной, на которой установлен гейт,
#и машиной, на которой установлен исходный LJ-сервер (записи
#датируются локальным временем пользователя, а время синхронизации
#отсчитывается по часам машины, где крутится LJ, блин).
#Разница указывается в количестве секунд. Если время гейта меньше
#времени сервера, разница должна быть положительным числом, больше ---
#понятное дело, отрицательным.
my $time_diff = 0;

#Настройки закончилсь

#Аккаунт, который копируем
my $source_user;
my $source_pass;

#Аккаунт, в который копируем
my $dest_user;
my $dest_pass;

#Здесь будут храниться логины и пароли синхронизируемых
#дневников (на нашем и чужом серверах)
my %journals;

open (STDERR, "+>>$ENV{LJHOME}/logs/ljgate.log") || die "Can't open logfile:$!";

#Вычисляем время предыдущего обновления
my ($fr_hour,$fr_min,$fr_sec);
my ($ls_year,$ls_month,$ls_day,$ls_hour,$ls_min,$ls_sec);
($fr_hour,$fr_min,$fr_sec) = split(/:/,$sync_freq);
my $lastsync = (time() - ($fr_hour * 60 * 60)
                    - ($fr_min * 60)
	            - $fr_sec);
$lastsync = $lastsync + $time_diff;
($ls_sec,$ls_min,$ls_hour,$ls_day,$ls_month,$ls_year) = localtime($lastsync);
$ls_year += 1900;
$ls_month += 1;
$ls_month=sprintf("%.02d",$ls_month);
$ls_day=sprintf("%.02d",$ls_day); 
$ls_sec=sprintf("%.02d",$ls_sec);
$ls_min=sprintf("%.02d",$ls_min); 
$ls_hour=sprintf("%.02d",$ls_hour); 
$lastsync = $ls_year."-".
            $ls_month."-".
            $ls_day." ".
            $ls_hour.":".
            $ls_min.":".
            $ls_sec;
#print "$lastsync\n";

#Связываемся с базой
my $dbh = DBI->connect(
   "DBI:mysql:mysql_socket=$qsock;hostname=$qhost;port=$qport;database=$qdb",
   $quser, $qpass,
   ) || die  localtime(time) . ": Can't connect to database\n";

#Забираем из базы ID журналов, которые нужно синхронизировать
my $sqh = $dbh->prepare("SELECT userid,alienid
                      FROM rlj2lj");
$sqh->execute;

my $result;

#Помещаем результаты запроса в хэш %journals
while ($result = $sqh->fetchrow_hashref) {
    $journals{$result->{'userid'}} = $result->{'alienid'};
}

#Инициализируем интерфейс протокола XMLRPC
my $xmlrpc = new XMLRPC::Lite;

#Синхронизируем журналы
foreach (keys(%journals)) {
    #Забираем из базы очередного пользователя исходного журнала
    $sqh = $dbh->prepare("SELECT our_user,our_pass
                          FROM our_user
                          WHERE userid=$_");
    $sqh->execute;
    ($source_user,$source_pass) = $sqh->fetchrow_array;

    #Забираем из базы очередного пользователя чужого сервиса
    $sqh = $dbh->prepare("SELECT alien,alienpass
                          FROM alien
                          WHERE alienid=$journals{$_}");
    $sqh->execute;
    ($dest_user,$dest_pass) = $sqh->fetchrow_array;

    #Копируем все записи, добавленные или изменённые
    #после предыдущего обновления
    eval {
	sync_journals($source_site,$source_user,$source_pass,
	      $dest_site,$dest_user,$dest_pass,
	      $lastsync,$_);
    };
    if ($@) {
	print STDERR localtime(time) . ": Syncronizing $source_user failed\n";
    }   
}


###SUBROUTINES###


#Синхронизация дневников
sub sync_journals{
 my ($source_site,$souce_user,$source_pass,
     $dest_site,$dest_user,$dest_pass,
     $lastsync, $user_id);

 #Получаем адреса используемых сайтов и пароли/логины
 #синхронизируемых аккаунтов из строки с аргументами
 ($source_site,$souce_user,$source_pass,
  $dest_site,$dest_user,$dest_pass,$lastsync,$user_id) = @_;

 my $proxy = "http://" . $source_site . "/interface/xmlrpc";
 $xmlrpc->proxy($proxy);

 #XMLRPC object, for login call
 my $get_challenge;

 #Challenge (random string from server for secure login)
 my $challenge;

 #String for md5 hash of server challenge and password
 my $response;

 #Получаем пару пароль-отзыв у исходного сервера
 eval {
     $get_challenge = xmlrpc_call("LJ.XMLRPC.getchallenge");
     $challenge = $get_challenge->{'challenge'};
     $response = md5_hex($challenge . md5_hex($source_pass));
 };
 #Error handling (russian over ssh doesn't work, sorry)
 if ($@) {
     print STDERR localtime(time) . ": Login on $source_site failed\n";
     die;
 };

 #XMLRPC object, for "getevents" call
 my $getevents;

 #Забираем все сообщения, появившиеся со времени последней синхронизации
 eval {
     $getevents = xmlrpc_call('LJ.XMLRPC.getevents', {
	'username' => $source_user,
	'auth_method' => 'challenge',
	'auth_challenge' => $challenge,
	'auth_response' => $response,
	'ver' => 1,
	'selecttype' => 'syncitems',
	'lastsync' => $lastsync,
	'lineendings' => 'unix',
    });
 };
 #Error handling
 if ($@) {
     print STDERR localtime(time) . ": Getevents on $source_site failed\n";
     die;
 }

 $proxy = "http://" . $dest_site . "/interface/xmlrpc";
 $xmlrpc->proxy($proxy);

 #Получаем пару пароль-отзыв у сервера, на который копируем записи
 eval {
     $get_challenge = xmlrpc_call("LJ.XMLRPC.getchallenge");
     $challenge = $get_challenge->{'challenge'};
     $response = md5_hex($challenge . md5_hex($dest_pass));
 };
 #Error handling
 if ($@) {
     print STDERR localtime(time) . ": Login on $dest_site failed\n";
     print STDERR "debug1: " . $@;
     print STDERR "\n\n";
     die;
 }

 my $entry;

 my( $entry_date, $entry_time, $sec, $min, $hour, $day, $month, $year );

 my $fields;

 my $postevent;

 foreach $entry (@{$getevents->{'events'}}) {
    #Получаем пару пароль-отзыв у сервера, на который переносим записи
    eval {
	$get_challenge = xmlrpc_call("LJ.XMLRPC.getchallenge");
	$challenge = $get_challenge->{'challenge'};
	$response = md5_hex($challenge . md5_hex($dest_pass));
    };
    #Error handling
    if ($@) {
	print STDERR localtime(time) . ": Login on $dest_site failed\n";
        print STDERR "debug2: " . $@;
        print STDERR "\n\n";
	die;
    }

    ($entry_date, $entry_time) = split(/ /,$entry->{'eventtime'});
    ($year, $month, $day) = split(/-/,$entry_date);
    ($hour, $min, $sec) = split(/:/,$entry_time);
    #Копируем в новую запись те поля, которые можно тупо скопировать
    $fields = {
	'username' => $dest_user,
	'auth_method' => 'challenge',
	'auth_challenge' => $challenge,
	'auth_response' => $response,
	'ver' => 1,
	'subject' => ($entry->{'subject'})? 
	              LJR::Viewuserstandalone::expand_ljuser_tags($entry->{'subject'})
		       : "",
	'year' => $year,
	'mon' => $month,
	'day' => $day,
	'hour' => $hour,
	'min' => $min,
    };
    #Выясняем уровень доступа копируемой записи
    if (!$entry->{'security'}) {
	 $fields->{'security'} = 'public';
    } else {
	$fields->{'security'} = $entry->{'security'};
	if ($entry->{'allowmask'}) {
	    $fields->{'allowmask'} = $entry->{'allowmask'};
	}
    };
    #Задаём строку с метаданными
    if ($entry->{'props'}->{'current_mood'})
    {
	$fields->{'props'}->{'current_mood'} = 
	    $entry->{'props'}->{'current_mood'};
    }
    if ($entry->{'props'}->{'mood_id'})
    {
	$fields->{'props'}->{'mood_id'} =
	    $entry->{'props'}->{'mood_id'};
    }
    if ($entry->{'props'}->{'current_music'})
    {
	$fields->{'props'}->{'current_music'} = 
            $entry->{'props'}->{'current_music'};
    }
    if ($entry->{'props'}->{'opt_backdated'})
    {
	$fields->{'props'}->{'opt_backdated'} = 
            $entry->{'props'}->{'opt_backdated'};
    }

    #Запрещаем комментарии в копируемой записи
    $fields->{'props'}->{'opt_nocomments'} = 1;

    #Добавляем к тексту записи ссылку на комментарии в исходном журнале
    my $talklink_line = "<div style=\"text-align:right\">".
	               "<font size=\"-2\"><a href=\"".
	               $entry->{'url'}.
                       "\">Comments</a> | <a href=\"".
                       $entry->{'url'}.
                       "?mode=reply\">Comment on this</a></div>";
    $fields->{'event'} = LJR::Viewuserstandalone::expand_ljuser_tags($entry->{'event'}).$talklink_line;
    
#    print STDERR "\n" . $fields->{'event'} . "\n";
    
    #Отправляем очередную запись...
    unless ($entry->{'props'}->{'revnum'}) {
	eval {
	    $postevent = xmlrpc_call('LJ.XMLRPC.postevent', $fields);
	    #Записываем соответствие ID исходного постинга и
	    #ID отгейтованного постинга в таблицу rlj_lj_id
	    $sqh = $dbh->prepare ("INSERT INTO rlj_lj_id(userid,ljr_id,lj_id)
                                   VALUES ($user_id, 
                                   $entry->{'itemid'},
                                   $postevent->{'itemid'})");
	    $sqh->execute;
        };
	#Обработка исключения: если не удался вызов XMLRPC
        if ($@) {
	    print STDERR localtime(time) . ": Posting event on $dest_site failed\n";
            print STDERR "debug3: " . $@;
            print STDERR "\n\n";
        };

    #...или редактируем её, если она имеет ненулевой номер ревизии
    } else {
	#Ищем в базе ID аналогичной записи дневника-копии
	$sqh = $dbh->prepare ("SELECT lj_id
                               FROM rlj_lj_id
                               WHERE userid=$user_id
                                AND ljr_id=$entry->{'itemid'}");
	$sqh->execute;

	#ID записи в дневнике-копии
	my $lj_id;

	#Если нашли, редактируем запись с найденным ID...
	if (($lj_id) = $sqh->fetchrow_array) {
	    $fields->{'itemid'} = $lj_id;
	    eval {
		$postevent = xmlrpc_call('LJ.XMLRPC.editevent', $fields);
	    };
	    #Обработка исключительной ситуации
	    if ($@) {
		print STDERR localtime(time) . ": Editing event on $dest_site failed\n";
                print STDERR "debug4: " . $@;
                print STDERR "\n\n";
	    };
	#...а если нет, сравниваем её дату
	#с датой предыдущей синхронизации
	} else {
	    #Если запись новая, то просто постим её...
	    if (timelocal($ls_sec,$ls_min,$ls_hour,$ls_day,$ls_month,$ls_year)<
		 timelocal($sec, $min, $hour, $day, $month, $year))
	    {
		eval {
		    $postevent = xmlrpc_call('LJ.XMLRPC.postevent', $fields);
		    #Записываем соответствие ID исходного постинга и
		    #ID отгейтованного постинга в таблицу rlj_lj_id
		    $sqh = $dbh->prepare (
				   "INSERT INTO rlj_lj_id(userid,ljr_id,lj_id)
                                   VALUES ($user_id, 
                                   $entry->{'itemid'},
                                   $postevent->{'itemid'})");
		    $sqh->execute;
		};
		#Обработка исключения: если не удался вызов XMLRPC
		if ($@) {
		    print STDERR localtime(time) . ": Posting event on $dest_site failed\n";
                    print STDERR "debug5: " . $@;
                    print STDERR "\n\n";
		};
	    #...иначе постим её с атрибутом backdate
	    } else {
		$fields->{'props'}->{'opt_backdated'} = 1;
		eval {
		    $postevent = xmlrpc_call('LJ.XMLRPC.postevent', $fields);
		    #Записываем соответствие ID исходного постинга и
		    #ID отгейтованного постинга в таблицу rlj_lj_id
		    $sqh = $dbh->prepare (
				   "INSERT INTO rlj_lj_id(userid,ljr_id,lj_id)
                                   VALUES ($user_id, 
                                   $entry->{'itemid'},
                                   $postevent->{'itemid'})");
		    $sqh->execute;
		};
		#Обработка исключения: если не удался вызов XMLRPC
		if ($@) {
		    print STDERR localtime(time) . ": Posting event on $dest_site failed\n";
                    print STDERR "debug4: " . $@;
                    print STDERR "\n\n";
		};
	    };
	};
    };
  };
};

sub xmlrpc_call {
    my ($method, $req) = @_;
    my $res = $xmlrpc->call($method, $req);
    if ($res && $res->fault) {
        print STDERR "XML-RPC Error:\n".
        " String: " . $res->faultstring . "\n" .
        " Code: " . $res->faultcode . "\n";
        die;
    }
    elsif (!$res) {
        print STDERR "Unknown XML-RPC Error.\n";
        die;
    }
    return $res->result;
}
